# DE1-SoC Stockfish 18 NNUE 배칭 가속기 — 상세 설계 (v1.0)

> 스코프: **배칭 풀 NNUE NPU** (선택 #2)
> 대상: Terasic DE1-SoC, Cyclone V SE 5CSEMA5F31C6 (85K LE, 87 DSP, 4,450Kb M10K, A9 듀얼 @925MHz, 1GB DDR3)
> 엔진: 로컬 SF18 (`sf_18-10-gb708fcf`, `Stockfish/src/`)

---

## 1. 목표와 성공 기준

| 지표 | 목표 |
|---|---|
| NNUE eval 처리율 | **SW 대비 3~8배**: big net 100–300 kN/s (배칭 B=64~128) |
| 정확성 | SW 평가와 **bit-exact 일치** (합성 vs SF18 ARM 실행) |
| 탐색 | ARM에서 `search.cpp` 그대로, 평가만 HW로 |
| UX | 7-seg/스위치 체스컴퓨터 (별도 PH 내에서 병렬) |
| 게이트 | 정확성 우선: "틀리면 성능은 무의미" |

**핵심 단일 사항 (G2 게이트)**: `networks.big.evaluate()`와 `networks.small.evaluate()`의
결과(psqt, positional 쌍)가 패브릭 구현과 바이트 단위로 동일해야 함.

---

## 2. SF18 평가 파이프라인 (로컬 소스 기준 — HW 명세의 근거)

```
evaluate.cpp:66  networks.{big|small}.evaluate(pos, accumulatorStack, cache)
network.cpp:177  Network::evaluate()
  bucket = (pos.count<ALL_PIECES>() - 1) / 4          // 0..7 (LayerStacks=8)
  featureTransformer.transform(pos, accStack, cache, transformedFeatures, bucket)
  positional = network[bucket].propagate(transformedFeatures)
  return { static_cast<Value>(psqt / OutputScale),
           static_cast<Value>(positional / OutputScale) }
```

### 2.1 Feature Transformer (`nnue_feature_transformer.h::transform`)
- 어큐뮬레이터(accumulator)를 갱신(증분 또는 refresh) 후, **쌍(pair) 곱과 클리핑으로
  int16 accumulation → int8 1024 (big) / 128 (small) 으로 변환**.
- 이 출력이 fc_0의 입력 `transformedFeatures` (`TransformedFeatureType = uint8`).
- shape: big → `HalfDimensions=1024`, small → `128`. 오리엔테이션별 2쪽(perspective).

### 2.2 FC 네트워크 (`nnue_architecture.h::propagate`)

| 계층 | 타입 | 치수 (big) | 치수 (small) | 입력/출력 |
|---|---|---|---|---|
| fc_0 | AffineTransformSparseInput | 1024→16 | 128→16 | uint8 → int32 |
| ac_sqr_0 | SqrClippedReLU | 16 → 16 | 16 → 16 | int32 → uint8 |
| ac_0 | ClippedReLU | 16 → 16 | 16 → 16 | int32 → uint8 |
| concat | `memcpy(+FC_0_OUTPUTS)` | 16+15 = 31 → **30 취함** | 동일 | |
| fc_1 | AffineTransform | 30→32 | 30→32 | uint8 → int32 |
| ac_1 | ClippedReLU | 32 → 32 | 32→32 | |
| fc_2 | AffineTransform | 32→1 | 32→1 | uint8 → int32 |

- fc_0의 `FC_0_OUTPUTS+1=16` : 15 실출력 + **상수 1.0 편향 출력(출력[15])**.
  `propagate()` 마지막에 `fwdOut = fc_0_out[15] * (600*OutputScale)/(127*(1<<WeightScaleBits))`
  를 fc_2_out[0]에 더함 — **이 보정 상수를 HW가 반드시 재현**해야 함.
- fc_1 입력은 `FC_0_OUTPUTS*2 = 30`. ac_sqr_0[0..15] + ac_0[0..14]로 구성됨 (주의).

### 2.3 활성화 수식 (bit-exact를 위한 정확한 형태)

```cpp
// sqr_clipped_relu.h:109
min(127, ((long long)input[i] * input[i]) >> (2*WeightScaleBits + 7))   // WeightScaleBits=6 → >>19
// clipped_relu.h:167
clamp(input[i] >> WeightScaleBits, 0, 127)                              // >>6
```

- `SqrClippedReLU`의 SIMD 경로는 `mulhi`+`srli 3` 트릭을 쓰지만 **수학적 결과는
  스칼라 경로와 동일** → HW는 스칼라 수식으로 구현하고 테스트로 검증.

### 2.4 어큐뮬레이터 (`nnue_accumulator.h`, `nnue_accumulator.cpp`)
- `Accumulator<Size>`: `accumulation[2][Size]` int16 + `psqtAccumulation[2][PSQTBuckets]` int32.
- 구동 방식:
  - **refresh**: 모든 active feature의 weight 컬럼을 처음부터 더함 (cache/`find_last_usable`)
  - **incremental(forward/backward)**: dirty piece의 added/removed feature 인덱스로
    weight 컬럼만 add/sub. `updateContext.apply<>` (accumulator.cpp:471–631).
- FT 가중치 레이아웃 (featureTransformer.h:418–426):
  - `weights[HalfDimensions * InputDimensions]` int16: HalfKAv2_hm, Dimensions=512
  - `threatWeights[HalfDimensions * ThreatInputDimensions]` int8: FullThreats, Dimensions=79856 (big만)
  - `biases[HalfDimensions]` int16
  - `psqtWeights[InputDimensions * PSQTBuckets]` int32
- **파일 저장 형식 (network.cpp / .nnue 파일)**: LEB128 압축 + SIMD용 permutation.
  파일에 저장된 순서는 메모리 배치(weights index)와 다름. → HW를 위해
  **로더가 '물리 행렬 레이아웃'으로 사전 변환**한 버퍼를 만들어 DDR에 배치해야 함.

### 2.5 네트워크 선택 및 init (중요 제약)
- `evaluate.cpp:65`: `smallNet = (|simple_eval(pos)| > 962)`. 그 외에는 big.
- `evaluate.cpp:72`: small 후 |nnue| < 277 면 big으로 재계산 (fallback).
- → HW는 **big/small 둘 다** 지원해야 하고, small 결정 로직 + fallback은 ARM에서 유지.

---

## 3. 시스템 아키텍처

```
┌──────────────────────────── HPS (ARM A9, Linux) ───────────────────────────┐
│ Stockfish (SF18)                                                          │
│ ├─ search.cpp / position.cpp / tt.cpp  (수정 없음)                        │
│ ├─ evaluate.cpp  →  "evaluate_hw"로 교체 (br->bw 호출)                     │
│ ├─ nnue_batch.cpp [신규]: 배칭 큐, 디스패처, 결과 폴링                      │
│ └─ nnuehw /dev/uio0 mmap + ioctl  ←── UIO 드라이버 [신규]                  │
└───────────────┬───────────────────────────────────────────────┬────────────┘
                │ AXI (FPGA-to-HPS bridge, 64-bit)                │ AXI-Lite (lw bridge)
┌───────────────▼───────────────────────────────────────────────▼────────────┐
│ FPGA                                                                       │
│ AUD ✦ SW(스위치/7-seg): 기존 I/O 슬레이브 (실체: 별도 PH)                    │
│ NNUE 가속 IP:                                                              │
│ ├─ AXI 채널 (기존, 128/64-bit)  ← AFC/AvMM master                          │
│ ├─ Weight SRAM 컨트롤러 → DDR3 (big), M10K (small)                          │
│ ├─ Feature Transformer 엔진 (어큐뮬레이터 + quantize)                       │
│ ├─ FC 파이프라인 (fc_0 systolic, fc_1, fc_2, ReLU)                         │
│ ├─ 배칭/명령 어큐: descriptor ring, 결과 ring                              │
│ └─ CSR: lightweight bridge 슬레이브                                        │
└────────────────────────────────────────────────────────────────────────────┘
        DDR3 1GB (HPS 컨트롤러 경유) — big net 가중치 + 배치 버퍼
```

### 3.1 HW/SW 분할
| 기능 | 주체 | 근거 |
|---|---|---|
| 탐색/알파-베타, TT, movegen | ARM | 분기형 직렬 — HW 불가 |
| 왕 위치·bucket 계산, dirty piece | ARM | `evaluate.cpp:188` 등 |
| active feature 인덱스 나열 | ARM | feature 중복·가벼운 비트보드 |
| **어큐뮬레이터 갱신 + quantize(transform)** | FPGA | FT가 전체 병목의 대부분 |
| fc_0/fc_1/fc_2 + 활성화 | FPGA | 밀집 MAC — systolic/SIMD 구조 |
| small net FT 가중치 | M10K | 128×22528 int16 = **5.76MB → M10K 피팅 불가** (아래 §5.1 참조) |
| big net FT 가중치 | HPS DDR3 (FPGA DMA) | 1024×(512+79856)→ 약 80MB+ — 패브릭 불가 |

### 3.2 배칭 모델 — 왜, 언제, 얼마나
- alpha-beta는 순차 의존이라 전부 배칭 불가. 배칭 가능 지점:
  1. **노드의 모든 자식(move) 평가** — 한 노드의 ~30개 자식을 한 배치로
  2. **Quiescence + capture들** — stand-pat 비교용 (SF는 q 확장에서 여럿 평가)
  3. **Pakage/결정적 순서 배칭**: depth가 낮은 리프에서 참고 평가
- 프로토콜: **descriptor ring (비동기) + 결과 ring**. ARM이 평가가 필요한 시점에
  descriptor를 enqueue하고, **결과가 실제로 필요한 지점까지 다른 작업(movegen/TT)을 수행**해
  지연을 숨김. 진짜 블로킹은 PV 노드 한정.
- 배칭 크기: `B=64` (descriptor 64B×64 = 4KB 전송) 를 기준값으로 시작, 벤치마크로 조정.

### 3.3 동작 흐름 (big net eval 1회)
```
ARM:  transform 이전까지 상태만 어큐뮬레이터 갱신 대기
  → descriptor: {mode=ACCUMULATE, feature드 delta 목록, king, side, bucket}
  → enqueue (SM4, CMS 후작)
FPGA: FT 엔진이 weight 컬럼을 DDR에서 스트리밍 → 어큐뮬레이터 SRAM
  → quantize → FC 파이프라인 → result ring에 (psqt, positional) 기록, IRQ
ARM:  (다른 업무 후) result ring에서 수거
```

**설계 결정 (v1)**: 어큐뮬레이터 갱신은 **패브릭에서 수행**하되, 갱신이 필요할 때마다
weight 컬럼 스트리밍이 조회되는 구조로 통일. refresh(무지개)에 드는 모든 feature 인덱스를
descriptor에 실어 보내면 incremental과 동일 경로로 처리 가능 → **경로 1개로 통일**.

---

## 4. FPGA 내부 블록 상세

### 4.1 Weight 메모리 맵
| 영역 | 크기 | 내용 | 위치 |
|---|---|---|---|
| small FT weights+biases | (22528+128)×128 int16 = **5.76MB** | small FT | DDR (M10K 불가) |
| small psqt weights | 22528×8 int16 = 352KB | small PSQT | DDR |
| big FT PSQ weights | 1024×512 int16 = 1MB | big PSQ | DDR |
| big FT threat weights | 1024×79856 int8 ≈ 80MB | big threat | DDR |
| big psqt weights | 512×8 + 79856×8 int32 … | big PSQT | DDR |
| fc_0/1/2 weights (big) | 8 스택 ×(16KB+…+…) | FC | DDR 캐시 |
| fc_0/1/2 (small) | 8 스택 × 소량 | FC | M10K |

- big FT가 ~80MB로 DDR 상주 주역. **경량 브리지가 아니라 FPGA-to-HPS (64비트) / 기존
  HPS 메모리 포트**로 직접 읽음. A9 1GB 용량 내 OK.
- weight 접근 단위는 **int16/int8 열벡터(1 feature = 1024 or 128 값)**.
  → 2B granularity를 연속 버스트로 읽어 SRAM에 넣음.

**FTBIN 물리 레이아웃** (`ref_eval.cc FTBIN` 덤프, RTL `weight_bram.sv` 로딩용):
```
[0 .. HD-1]                          biases  (int16)
[HD + f*HD .. HD + (f+1)*HD-1]       main feature f weight 열 (int16; small 은 x2 반영)
[HD + NF*HD + f*HD .. ]              threat feature f weight 열 (int16 부호확장, big 만)
```
- big: `HD=1024, NF=PSQInputDim=512, TFF=ThrInputDim=79856` → 총 104,842,240 워드
  (209,684,480 B). threat 영역 base = `HD + NF*HD = 23,069,696` (ADDR_W=27).
- small: `HD=128, NF=22528, TFF=0`, ADDR_W=22. 크기 5.9M 워드 ≈ 5.76MB.

### 4.2 Feature Transformer 엔진 (FTE)
- 어큐뮬레이터 메모리: `accumulation[2][1024]` int16 (big), 2 copies (perspective).
  **M10K ~2–4KB × 몇 카피**.
- 델타 적용: `PSQFeatureSet/ThreatFeatureSet`이 만든 added/removed 인덱스 쌍을 받아
  weight 컬럼 fetch → add/sub. dirty piece 한 수에 보통 1–4개 인덱스.
- quantize(transform): 참조 구현(§2.3) 그대로. HalfDimensions/2 파티션, 백/흑 각각.
- 클리핑 값: big은 `One=255`, small은 `127*2` — UseThreats 차이 주의.

**구현 (M2 완료, 시뮬레이션 검증 25/25×2)** — `hw/rtl/{fte,top_fte,weight_bram,accumulator,quantize}.sv`:
- 상태 머신: `S_ROW0 → S_ROW1 → [big] S_TROW0 → S_TROW1 → S_Q0 → S_Q1 → done`.
  main feature 행은 bias 열로 시작(누적 베이스), threat 행은 **dummy 열에서 0-쓰기**로
  ref `assign(thrAcc, 0)` 초기화를 재현 (bias 없음).
- 누적 루프: 열(jctr)당 2클럭 (ph0=read, ph1=write). `acc_rd_data`(main)/`thr_rd_data`
  (threat) 를 자기 누적값으로 사용 — `acc_rd_data`를 threat에 쓰면 틀림 (버그 #2).
- quantize: qj당 4클럭, `q[(HD/2)*p + j]` 출력 순서 = `{stm, ~stm}` (ref 와 동일).
  big: `clamp(acc+thr,0,255)^2 >> 9`, small: `clamp(acc,0,254)^2 >> 9`.
- feature FIFO: `FMAX=4096`, **행 경계에서 프리페치가 이미 발화되므로 전환 시 추가
  `fifo_rd` 금지** (버그 #3). FEN 사이 FIFO 포인터 리셋 필요 (버그 #4).
- threat 누적 읽기는 main 과 동일 주소/요청 (`thr_rd_* = acc_rd_*`), 쓰기만 별도.

### 4.3 FC 파이프라인
- fc_0: 입력 1024 uint8 → 16 출력. `AffineTransformSparseInput`는 CPU용 nnz 트릭이므로
  **HW는 밀집(matrix-vector)으로 구현**하고 결과만 일치시키면 됨.
- **M3 시뮬레이션 구현**: `fc_pipe.sv` — 시퀀셜 MAC 상태머신 (성능 최적화는 M5).
  - FCBIN 가중치(8 bucket 연속, int32 bias + int8 weights)를 `fc_bram.sv`(단일 바이트
    조합 리드)에 로드, bias 4바이트 LE 수집 → 순차 MAC 누적(int64).
  - fc0: 16 출력 × PAD0(=HD, 1024/128) — `S_FC0B`/`S_FC0W`. q 로드 포트 단일.
  - 활성화 `S_ACT`: `fcin[0..14]`=sqr(`min(127, x²>>19)`), `fcin[15..29]`=ac0
    (`clamp(x>>6,0,127)`, **ref/SF 는 ac_sqr_0[15+i]=ac_0[i] 가 sqr(15) 를 덮어씀**),
    `fcin[30..31]`=0. `fwd_mul32 = fc0_raw[15]*9600` (int32 래핑 재현).
  - fc1 (32×32), ac_1, fc2 (1×32). `fwdDiv = int32/int32 trunc-toward-zero`,
    `result = (int32)(v2 + fwdOut)` — POS.
- **중요: ref_eval 의 fc0 와 SF18 간 bucket 분리** — ref 의 scalar loop 는
  `q[0..HD-1]` 을 fc0 입력으로 쓰고 8개 bucket 전부 출력. RTL 도 동일하게 bucket
  스택 인덱스 포함. FCDUMP env 로 8 bucket 전체 dump (SF NETL1 은 선택 bucket 만).
- `fwdOut` 상수 보정(`fc0_out[15]*9600/8128`)은 fc_2 결과에 합산.

### 4.4 배칭/명령 경로
- **Descriptor ring**: DDR (HPS 컨트롤러 경유) 또는 FPGA 로컬 SRAM. 초기에는 로컬 SRAM
  (4KB) → 검증 후 DDR로 확장.
- descriptor 포맷 (§8), 결과 ring 포맷 (§8), IRQ/폴링.

### 4.5 클록/자원 예상
| 리소스 | 예상 |
|---|---|
| DSP (fc MAC) | 20–40 / 87 |
| M10K | FC 캐시, 어큐뮬레이터, FIFO (FT weight는 DDR) | < 556KB (4,450Kb) |
| ALM | FT/quantize/제어 ≈ 5–10K / 85K |
| Fmax | 150MHz 목표 (DDR 버스트 중심 설계) |

---

## 5. 소프트웨어 스택 (M4-SW 구축 완료)

### 5.1 ABI 계약 — `hw/arm/nnuehw/nnuehw.h` (커널/유저/FPGA-Top 공유 단일 헤더)

| 항목 | 값 |
|---|---|
| 창 크기 | `NNUEHW_WINDOW_SIZE` = 0x14000 (모든 서브블록 포함) |
| CSR 영역 | 0x0000: VERSION/CONTROL/STATUS/DESC_HEAD/DESC_TAIL/RESULT_HEAD/RESULT_TAIL/DONE/IRQ_STATUS/IRQ_ACK (10 reg) |
| descriptor 링 | 0x0040: 64×64B (`nnuehw_desc`) — magic/mode/bucket/side/n_add/n_rem/add_frame[16]/rem_frame[16]/seq |
| feature 프레임 영역 | 0x1040: 64×1024B (256 u32 × 64) — 입력 버퍼, descriptor 프레임 오프셋으로 참조 |
| result 링 | 0x11040: 256×16B (`nnuehw_result`) — seq/psqt/positional/status |
| 도어벨 | DESC_HEAD 쓰기 = 시작; DONE/IRQ로 완료 통지 |
| ioctl | `/dev/nnuehw` (misc device): RESET/START/STOP/SET_BATCH/GET_STATUS, 매직 0xEE |
| 커널/유저 호환 | `nnuehw_u32/nnuehw_s32` typedef 가드, 크기 검증 매크로(kernel: `extern char[]`, user: `static_assert`), `_IO/_IOW/_IOR` 호스트 폴백 |

### 5.2 UIO 드라이버 — `hw/arm/nnuehw/nnuehw.c` + `Makefile`

- **표준 UIO + misc 디바이스 구조**: uio_info는 커스텀 fops 미지원 → `/dev/uio0`는 커널
  표준 경로(mem[0]=전체 창 mmap, read=IRQ 대기), ioctl은 별도 misc 디바이스 `/dev/nnuehw`.
- **DT 호환**: `compatible = "nnue,nnue-hw-1.0"`. Makefile `dtbs` 타겟에 overlay 예제:
  `nnue@0xC000`, `reg = <0x0000C000 0x00014000>`, `interrupt-parent = <&intc>`,
  `interrupts = <0 42 4>` (SPI 42).
- **빌드**: `make KDIR=/lib/modules/$(uname -r)/build` → `nnuehw.ko` (VM에서 384KB 확인,
  modinfo에 DT 호환 스트링 표시).
- **커널 컴파일 이슈 해결 기록**:
  1. `stdint.h` 커널 금지 → `__KERNEL__`일 때 `nnuehw_u32/nnuehw_s32` typedef.
  2. `BUILD_BUG_ON` 파일 스코프 금지 → `extern char _nnuehw_size_check[…]` 배열 기법.
  3. uio_info fops 미지원 → 표준 UIO mmap + misc ioctl로 전환.

### 5.3 배칭 라이브러리 — `hw/arm/nnue/nnue_batch.{h,cpp}`

| 구성요소 | 내용 |
|---|---|
| `HWBackend` 추상화 | open/close/submit/pollResult/reset/doneCount/name/batchHint + `submitAuto` |
| `UIOBackend` | `/dev/uio0` mmap, descriptor head push(desc+feature 프레임 기록, DESC_HEAD 도어벨), result tail 폴링(timeout) |
| `MockBackend` | runner 주입식 동기 결과 생성 (호스트 테스트용) |
| `BatchScheduler` | `enqueue()` — 자동 seq 발급 + inflight++; `waitResult()` — inflight--. start/stop |

- 단일 seq 키로 요청/응답 짝짓기, 결과 status ≥ 0이면 유효.
- 배칭 라이브러리는 SF 소스 밖(`hw/arm/nnue`)에 두고 평가 경로에서만 참조 — SF 트리 오염 최소화.

### 5.4 SF18 통합 — `evaluate_hw` (패치: `hw/arm/evaluate_hw.patch`)

- **`evaluate.cpp`**: `networks.evaluate()` 후 `#if defined(USE_NNUE_HW)` 후크 — `evaluate_hw(pos)`
  성공 시 psqt/positional 교체, 실패(nullopt) 시 SW 값 유지 (fallback).
- **`src/nnue/nnue_hw.{h,cpp}`**: env `NNUE_HW=1` + UIO open 성공 시에만 HW 경로 활성화.
- **링크 이슈 (해결)**: `evaluate_hw`/`hw_enabled`가 anonymous namespace 안에 있어 내부
  링키지 심볼(`...L11evaluate_hw...`) 생성 → evaluate.cpp의 외부 참조 실패. 두 함수를
  anonymous namespace 밖으로 이동해 전역 `T` 심볼로 확정.
- **Makefile 수정**: SRCS에 `nnue/nnue_hw.cpp` + `../../hw/arm/nnue/nnue_batch.cpp`,
  HEADERS에 `nnue/nnue_hw.h`, VPATH에 `../../hw/arm/nnue`, `INCLUDES
  += -I../../hw/arm/nnue -I../../hw/arm/nnuehw` (CXXFLAGS에 `$(INCLUDES)` 배선).
- **호환성**: SF18 `ARCH=armv7-neon` 타깃 유지. Linux 표준 DE1-SoC BSP의 UIO 사용.

---

## 6. 검증 전략 (bit-exact 게이트)

1. **Unit (C++ 추출)**: `AffineTransform`, `SqrClippedReLU` 등을 스칼라로 재구현한
   C++ 리퍼런스를 만들고… (1) SF18 ARM 실행 결과, (2) 수치모델, (3) RTL 시뮬, (4) FPGA
   실측 — 4개가 전부 일치하는지.
2. **랜덤 포지션 배치**: 10,000개 랜덤 FEN → 각각 psqt+positional 비교.
3. **게임 일관성**: HW 가속 ON/OFF로 10×2 게임 → bestmove/평가 동일 sequence.
4. **성능 게이트**: bench 명령 NPS 비교 (SW vs HW), 목표 대비 보고.

### M2 검증 파이프라인 (구축 완료)

```
FTBIN(1회) ──────────────────────────────┐
  ref_eval.cc FTBIN 덤프 (small: x2 반영,
  big: bias+main+threat int16 부호확장)  │
                                         ▼
FEN → featgen.cc (FEN→FTLIST/THREATLIST) ──→ 매니페스트(stm, 파일 경로)
FEN → ref_eval.cc FTDMPD (FTDMP q[0..HD-1])  → TB 가 RTL q 와 대조
```

- `hw/ref_eval/featgen.cc`: halfka_index/collect_active/FullThreats 를 ref_eval 과
  **동일 로직으로 재구현** (small/big 50 FEN parity 50/50). FTLIST/THREATLIST 파일 출력.
- `ref_eval.cc` 디버그 env: `FTBIN`(가중치 바이너리), `FEATLIST`, `FTDMPD`(파일 q),
  `FTDMPN`(threat 제외 q), `ACCDBG`(perspective별 acc/thrAcc 1024×2 덤프).
- TB: `hw/rtl/tb_fte_big.cpp` (배치, 매니페스트, `RTLQ`/`DUMPACC` 덤프 env),
  `hw/rtl/tb_fte_full.cpp` (small). `--trace --trace-max-array` 대신 **2nd read port
  (`rd2_*`) 로 셀 덤프** (배열은 VCD에서 확인 불가 → top_fte 디버그 포트 경유).
- 랜덤 FEN 25개: small 25/25, big 25/25 통과 (threat 포함 bit-exact).

**디버깅 중 발견한 버그 기록** (M2):
1. `6'(HD/2)` 등 상수 폭이 HD=1024에서 0으로 자름 → `$clog2(HD)'(...)` 캐스트로 통일.
2. threat 누적이 `thr_rd_data` 대신 `acc_rd_data`(main)를 베이스로 → main acc 값이
   threat 누적에 섞임. 셀 덤프(DUMPACC)로 main 2048/2048 vs threat 3/1024 에서 적발.
3. threat 행 전환 시 중복 `fifo_rd<=1` → fout 이 다음 그룹 첫 feature 를 건너뜀
   (t0[1..15]+t1[0] 오염). main 전환은 fifo_rd 없이 정확한 점과 대조 → 제거.
4. FIFO 포인터(`fw`/`fr`)가 FEN 간 리셋되지 않음 → 배치 2번째 FEN부터 feature 오프셋
   오염. `rst` 시 fifo/fw/fr/fout 초기화 추가.

**디버깅 중 발견한 버그 기록** (M3):
1. TB 로딩 루프가 `negedge` 만 사용 → `@(posedge clk)` 메모리(q/FCBIN) 미기록 → 전부 0.
   M2 TB 패턴대로 `clk=1; eval(); clk=0; eval();` 으로 수정.
2. `fwdOut` 계산에서 `$signed(64'(fwd_q))` — fwd_q 는 **unsigned 32** 라 음수가 제로
   확장되어 526734 같은 양수 오염. ref 의 int32 산술(래핑 + trunc)을 재현하려면
   `fwd_mul32 = $signed(fc0_raw[15])*9600` (32-bit wrap) 후 `fwd_div32 =
   $signed(fwd_q)/32'sd8128` 로 분리해 컨텍스트 폭 문제 회피. 음수 FWDOUT FEN(big FEN2 B0)
   에서 적발.

### M3 검증 파이프라인 (구축 완료)

```
FCBIN(1회) ──────────────────────────────────────────┐
  ref_eval.cc FCBIN 덤프 (8 bucket 연속: fc0.bias[16]
  int32 + fc0.w[16*PAD0] int8, fc1 32×32, fc2 1×32)  │
                                                      ▼
FEN → ref_eval.cc FCDUMP (8 bucket FC0RAW/FC1IN/     → tb_fc.cpp:
      FC1RAW/FC1ACT/FC2RAW/FWDOUT/POS 덤프)             RTL result==POS,
FTDMPD(q) → q 로드                                     RTL fwd==FWDOUT
```

- `hw/rtl/fc_bram.sv` (단일 바이트 리드, 8×BUCKET), `hw/rtl/fc_pipe.sv` (시퀀셜 MAC
  상태머신, S_FC0B/FC0W/ACT/FC1B/FC1W/ACT1/FC2B/FC2W/DONE), `hw/rtl/top_fc.sv`
  (래퍼), `hw/rtl/tb_fc.cpp` (FCBIN+q+FCDUMP 대조).
- **SF18 NETL1 대조**: big FEN1 bucket 3 — FC0RAW/FC1IN/FC1RAW/FC1ACT/FC2RAW/FWDOUT/POS
  전부 일치 → ref_eval 의 FC 구현 자체가 SF18 과 bit-exact 임을 교차 확인.
- FC bit-exact: big 25/25, small 25/25 (8 bucket × 각 POS/FWDOUT).
- **FT+FC 엔드투엔드**: FT RTL 출력 q(RTLQ 덤프)를 FC 파이프라인에 투입 → FCDUMP 대조.
  big/small 각 25 FEN (FT q==ref q 는 M2 에서 확인, E2E 는 연결 경로 검증).

### M4-SW 검증 파이프라인 (구축 완료)

```
nnuehw.h ──────────┐
  (ABI 계약)       ├─→ nnuehw.c (UIO+misc) ──→ nnuehw.ko (VM 빌드 성공)
                   ├─→ nnue_batch.{h,cpp} ──→ test_nnue_batch (호스트 유닛 테스트: ALL PASS)
evaluate_hw.patch ─┘        │
                             ├─→ SF18 통합 (evaluate.cpp 후크 + nnue/nnue_hw.{h,cpp})
                             └─→ armv7-neon 크로스 빌드: stockfish 생성 성공
                                    + 호스트 빌드 성공 (컴파일 경고 0)
```

- **유닛 테스트** (`test_nnue_batch.cpp`, `g++ -std=c++17`): seq 짝짓기 + 역순 완료 대기,
  BatchScheduler inflight, MockBackend runner 동기 결과, UIO 디바이스 부재 시 fallback — ALL PASS.
- **빌드 검증**:
  - 호스트: `make build ARCH=x86-64-avx2 EXTRACXXFLAGS="-DUSE_NNUE_HW"` — 경고 0.
  - armv7 (VM): `make build ARCH=armv7-neon COMPCXX=arm-linux-gnueabihf-g++
    EXTRACXXFLAGS="-DUSE_NNUE_HW"` → ELF 32-bit ARM, `evaluate_hw`/`hw_enabled` 전역 `T` 심볼.
- **링크 이슈 기록**: `evaluate_hw`/`hw_enabled`가 anonymous namespace 안에 있어 내부
  링키지(`...L11evaluate_hw...`) → evaluate.cpp 외부 참조 실패. anonymous namespace 밖으로
  이동해 `T` 심볼 확정, armv7 링크 성공.
- **런타임 fallback 검증**: NNUE_HW 미설정 또는 백엔드 미가동 시 `go depth`에서 bestmove
  정상 생성 (SW 경로 유지).

---

## 7. 마일스톤 (병렬 SW/HW)

| 단계 | 내용 | 산출물 | 게이트 |
|---|---|---|---|
| M0 | 환경: armv7 크로스 빌드, UIO 뼈대, DDR weight 배치 툴 | 부팅/벤치 베이스라인 | SW eval NPS 측정 |
| M1 | `.nnue` 로더 + 리퍼런스 C++ 스칼라 평가 | `ref_eval` | 4-way bit-exact |
| M2 | RTL: CSR + descriptor ring + FTE(어큐뮬레이터+quantize) | 시뮬 | transform bit-exact (**small 25/25 + big 25/25 통과**) |
| M3 | RTL: FC 파이프라인 + 결과 ring | 시뮬 | **evaluate bit-exact (G2) — big/small 25/25 + E2E 통과** |
| M4 | UIO + `nnue_batch.cpp` + evaluate_hw 연결 | 온보드 실행 | **M4-SW 완료**: `nnuehw.ko`/배칭/통합 빌드 성공 + fallback 검증. **FPGA-Top RTL 완료**: big/small E2E bit-exact 통과 (`fpga_top.sv`). 남은 것: 온보드 실행 |
| M5 | 배칭 튜닝 (B, prefetch, DDR 버스트) | 성능 보고 | big net ≥100 kN/s |
| M6 | SW eval fallback + AB 전환, 7-seg/스위치 UX 병렬 | 제품 데모 | UX 데모 |

각 게이트: 이전 단계 결과가 bit-exact해야 통과. M2–M3는 시뮬레이션에서 끝내고
M4에서 온보드로.

---

## 8. 리스크

| 리스크 | 완화 |
|---|---|
| FT weight 80MB DDR 읽기 대역폭 부족 | 64-bit 브리지 + 연속 버스트, 배칭 증폭; small net은 M10K |
| quantize/활성화의 SIMD 경로 함정 | 스칼라 수식만 구현, 4-way 검증 |
| fwdOut 상수 보정 누락 | §2.2를 명세에 명시, 리퍼런스에 포함 |
| bucket 스택 8개 처리 | 스케줄러에 bucket 포함, 테스트 |
| evaluate_hw 시맨틱 미스 | 기존 SW eval과 동일 시그니처로 두고 fallback 유지 |
| descriptor 지연폭 (PV 의존) | 결과가 필요하기 전까지 다른 작업 수행(어큐뮬레이터 prefetch) |

---

## 9. 시작하기 전 체크리스트
- [x] DE1-SoC Linux 부팅 + armv7 크로스 툴체인 (VM에서 armv7-neon 크로스 빌드 확인)
- [x] 로컬 SF18 (`korean-comments`) armv7-neon 빌드 확인 (USE_NNUE_HW 포함, `stockfish` 생성)
- [x] small net FT weight 5.76MB — M10K 불가 확정(합성 前), DDR 스트리밍으로 통일 운용
- [x] UIO 드라이버 `nnuehw.ko` 빌드 + `nnue_batch` 유닛 테스트 (+ `evaluate_hw.patch`)
- [x] FPGA-Top RTL 골격 (CSR/descriptor/result ring) — E2E 검증 통과
  - big (`nn-c288c895ea92.nnue`) 3-FEN 매니페스트: `RESULT: PASS total=3 fails=0` (220M 사이클)
  - small (`nn-37f18f62d772.nnue`, `-GHD=128` 재컴파일): `RESULT: PASS total=3 fails=0`
  - FAULT 경로 / DONE=25 / IRQ_STATUS=0x3 / RESET 모두 PASS
  - 버그 2건 수정: ① psqt 누적 부호확장 (`64'()` 제로확장 → `{{32{s}},s}`), ② descriptor 단위 FTE FIFO 리셋 펄스 (`fte_rst`, M2 버그 #4 회귀)
- [ ] 온보드 실행 (DE1-SoC 연동)