# NNUE 가속기 — HW/SW 인터페이스 명세 (v1.0)

> 이 문서는 DE1-SoC NNUE 가속 IP와 Linux HPS 소프트웨어 사이의 계약서이다.
> 설계 근거: `docs/DESIGN.md`

---

## 1. 개요

- HW: FPGA 내 NNUE 가속 IP. CSR은 **lightweight HPS-to-FPGA bridge**로 노출.
- SW: `/dev/uio0` (UIO)로 CSR+링 메모리 접근. `nnue_batch.cpp`가 사용.
- 평가 요청/결과는 **차가운 링(descriptor ring / result ring)** 을 통해 전달.

```
ARM (Stockfish)                     FPGA
  evaluate_hw()                       NNUE IP
   ├─ CMD ring에 descriptor enqueue    ├─ CSR 폴링/IRQ 로 배치 가져감
   ├─ (병행 작업 수행)                  ├─ FT+FC 계산
   └─ RESULT ring 폴링                 └─ 결과 기록 + IRQ
```

---

## 2. CSR 맵 (lightweight bridge, 32-bit, offset 기준)

베이스: `0xFF200000` (DE1-SoC lw2hps 표준) + 라우터 오프셋. 실제 로드는 HPS 소프트웨어가
`/dev/mem` 또는 UIO로 mmap한다.

| Offset | 이름 | RW | 설명 |
|---|---|---|---|
| 0x00 | CTRL | RW | bit0 GO (1=enabled), bit1 IRQ_EN, bit2 SOFT_RESET |
| 0x04 | STATUS | RO | bit0 BUSY, bit1 CMD_EMPTY, bit2 RESULT_AVAIL, bit3 FAULT, bit4 IRQ_PENDING |
| 0x08 | CMD_BASE_LO | RW | CMD descriptor 링 물리주소 하위 32 |
| 0x0C | CMD_BASE_HI | RW | 상위 32 (0) |
| 0x10 | CMD_LENGTH | RW | 링 바이트 길이 (512B 배수, ≤64KB) |
| 0x14 | CMD_HEAD | RO-클리어 | SW가 소비한 마지막 descriptor 인덱스 (HW가 증가) |
| 0x18 | CMD_TAIL | RW | SW가 추가한 마지막+1 인덱스 |
| 0x1C | RES_BASE_LO/HI | RW | 결과 링 |
| 0x24 | RES_LENGTH | RW | 결과 링 길이 (≤64KB) |
| 0x28 | RES_HEAD | RW-클리어 | HW가 기록한 마지막 결과 인덱스 |
| 0x2C | RES_TAIL | RO | SW가 소비한 위치 (HW가 볼 수 있는 free 공간=tail~head) |
| 0x30 | WEIGHT_BIG_LO | RO | big net weight 베이스 물리주소 (SW가 설정, DDR 주소) |
| 0x34 | WEIGHT_SMALL_LO | RO | small net weight 베이스 |
| 0x38 | NETCFG | RW | bit0 USE_SMALL (M10K), bit1 PREFETCH_EN, bit2 BATCH_MODE |
| 0x3C | STATS0..2 | RO | 디버그: 처리 수/주기 |
| 0x48 | BATCAP | RW | 배치 캡처 크기 (기본 64) — FP 리소스가 감당하는 한 |

- **인덱스 의미**: 링에 있는 각 슬롯 = 1 descriptor (고정 크기, 아래 §4). Head/Tail은
  슬롯 단위 카운터가 아니라 **바이트 오프셋**으로, `(head == tail)` = 비어있음.
- HW는 tail을 보고 새 명령을 가져가고, head를 증가시켜 "처리 완료"를 알린다.
- 결과 링은 반대로: HW가 result 원자적 기록 후 head 증가, SW가 tail을 올려 공간 반환.

---

## 3. 배칭 프로토콜

### 3.1 두 가지 디스패치 모드
| 모드 | NETCFG | 설명 |
|---|---|---|
| 즉시(동기) | BATCH=0 | descriptor 1개 = 평가 1개. 디버그/단순 검증용 |
| 배칭(비동기) | BATCH=1 | SW가 최대 BATCAP개를 쌓아 한꺼번에 제출. FPGA가 순차 처리. |

### 3.2 배칭 흐름
```
1. SW: nnue_batch_flush()
   - CMD_TAIL에 최대 BATCAP개의 descriptor(인덱스 t0..t1)를 기록
   - CMD_TAIL = t1
2. HW: CMD_EMPTY가 아니면 descriptor t0부터 pop
   - FT+FC 파이프라인으로 배치 수행
   - 결과를 RESULT 링에 기록, RES_HEAD 증가, IRQ
3. SW: (병행 작업 후) RESULT ring에서 (psqt, positional) 수거
   - RES_TAIL 갱신
```

### 3.3 순서 보장
- CMD 링에서의 순서대로 처리되고 결과도 그 순서대로 기록된다.
- PV 노드처럼 결과가 즉시 필요한 경우: SW는 descriptor 제출 후 `STATUS.RESULT_AVAIL`
  폴링 또는 IRQ 대기. 그 외에는 지연 허용.

---

## 4. Descriptor 포맷 (32-byte 고정)

| Byte | 필드 | 타입 | 설명 |
|---|---|---|---|
| 0 | cmd | u8 | 0x01 EVAL |
| 1 | flags | u8 | bit0 USE_SMALL, bit1 REFRESH(전체 feature), bit2 RESERVED |
| 2 | bucket | u8 | 0..7 (LayerStacks) |
| 3 | side | u8 | 0=white, 1=black (perspective 0 기준) |
| 4 | n_add | u8 | added feature 인덱스 수 (0..8) |
| 5 | n_sub | u8 | removed feature 인덱스 수 (0..8) |
| 6 | n_threat_add | u8 | threat feature added 수 (big만, 0..8) |
| 7 | n_threat_sub | u8 | threat feature removed 수 (0..8) |
| 8–19 | idx_add[4] | u16×4 | added PSQ feature 인덱스 |
| 20–31 | idx_sub[4] | u16×4 | removed PSQ feature 인덱스 |
| *(32–47)* | idx_thr_add[4] | u16×4 | threat added |
| *(48–63)* | idx_thr_sub[4] | u16×4 | threat removed |

> v1 스펙은 **fixed 32B + 최대 4+4개** 인덱스로 제한. dirty piece 하나당 실질 1~3개라
> 충분. 만약 초과 시 REFRESH(전체 갱신) 명령으로 대체한다.

- **REFRESH mode(flags bit1)**: n_add가 "전체 active feature 수"로 해석됨
  (`printf` 해보면 왕+기물 ≈ ≤32). 이 경우 idx_add 전체 목록으로 어큐뮬레이터를
  처음 계산. idx_sub/fhrsr은 무시.
- threat 인덱스 구분: `n_threat_add` >0 이면 idx_thr_add 블록 사용.

---

## 5. 결과 포맷 (8-byte 고정)

| Byte | 필드 | 설명 |
|---|---|---|
| 0–3 | psqt | int32 (S16→Value 시 OutputScale=16 사용: `Value(psqt)/16`) |
| 4–7 | positional | int32 (fc_2_out[0] + fwdOut, OutputScale 적용 전) |

- SW가 `evaluate()` 시그니처와 동일하게 `(Value, Value)`로 변환.
- `fwdOut`은 HV 내부 처리 (§2.2). HW는 **순수 `positional` 정수**를 반환.

---

## 6. SW API (nnuehw.h [신규])

```c
int nnuehw_open(void);                      // /dev/uio0, 링 초기화, NETCFG 설정
void nnuehw_close(void);
void nnuehw_set_weights(uint64_t big_base, uint64_t small_base); // DDR 물리주소
int  nnuehw_eval(const EvalInfo* in, EvalResult* out);           // 동기 1회 (디버그)
int  nnuehw_batch_begin(int cap);           // 배치 버퍼 시작
int  nnuehw_batch_add(const EvalInfo* in);  // descriptor enqueue (SW측 미러링)
int  nnuehw_batch_submit(void);             // CMD_TAIL 게시
int  nnuehw_batch_wait(EvalResult* out, int n); // 결과 수거 (폴링 또는 IRQ)
```

- `EvalInfo`: {uint8 flags, uint8 bucket, uint8 side, uint16 add[], uint16 sub[], ...}
  ← `evaluate_hw()`에서 feature transformer의 입력으로 직결.
- ARM은 CMD 링과 RESULT 링 모두 mmap(UIO 버퍼)으로 접근 → **memcpy 없음**.
  descriptor를 링에 직접 스토어.

---

## 7. evaluate_hw() 통합 지점 (검토용 스케치)

`evaluate.cpp:57`의 `Eval::evaluate()`를 대체하는 **evaluate_hw()**:

```
Value Eval::evaluate_hw(networks, pos, accumulators, caches, optimism) {
    // 1. bucket, side 결정 (예: (pos.count<ALL_PIECES>()-1)/4)
    // 2. dirty piece 처리: nnue_accumulator의 added/removed를 그대로 사용
    //    (기존 incremental 경로와 동일 feature 인덱스를 HW descriptor에 실는다)
    // 3. nnuehw_batch_add()
    //    - 배치가 찼으면 submit + 4에서 결과 수거
    // 4. 필요 시 nnuehw_batch_wait() 로 (psqt, positional) 확보
}
```
- 어큐뮬레이터 자체는 SW에 두고 added/removed 인덱스만 뽑아 HW에 넘기는 형태가
  **가장 손이 덜 간다** — 그러나 그것은 FT를 HW로 안 옮기는 셈이다.
  → v1 목표(전체 FT/FC 오프로드)를 위해선 어큐뮬레이터 **refresh 경로부터 HW로**.
- 우선 `USE_NNUE_HW` 매크로 + 기존 SW 경로 fallback으로 A/B 전환 가능하게 한다.

---

## 8. DDR weight 배치 (로더) 요구사항
- M1의 `.nnue` 로더가 만드는 물리 레이아웃:

| 오프셋 (DDR) | 내용 |
|---|---|
| 0x0000_0000 | big: biases[1024] int16 |
| 0x0000_0800 | big: PSQ weights[1024][512] int16 |
| 0x0010_0800 | big: threat weights[1024][79856] int8 |
| 0x0090_0000 | small: biases/PSQ weights (서브셋만, small net용) |
| ... | FC 가중치 (8 bucket × fc_0/1/2) |

- 정확한 오프셋은 M1에서 결정하고 여기 갱신. **작은 단위의 row-major로 다시 재배열**:
  HW가 DDR에서 열(column) 단위로 버스트 읽기 쉽도록.
- 작은 net은 M10K 사본으로도 중복 저장 (빠른 패스).

---

## 9. 상태머신 요약 (HSM 묘사)
```
IDLE
 ├─ GO=1 & CMD_EMPTY=0 → FETCH (descriptor pop)
 ├─ accumulation:  REFRESH? 전체 : added/sub된 컬럼만
 ├─ quantize transform (2 × HalfDimensions/2)
 ├─ fc_0 → sqr/clip → fc_1 → clip → fc_2 → fwdOut 보정
 ├─ RESULT 기록, RES_HEAD++, CMD_HEAD++, IRQ(EN이면)
 └─ IDLE
FAULT: CMD 링 불일치/weight 미설정 시 STATUS.FAULT=1, BUSY=0
```

---

## 10. 검증 체크리스트 (HW)
- [ ] CMD/RESULT 링이 head/tail 오프셋 경계에서 정확히 랩어라운드
- [ ] 대용량 배칭(≥BATCAP)에서 순서 보존 + 오버플로 FAULT
- [ ] REFRESH 경로가 incremental과 동일 결과 (같은 포지션)
- [ ] bucket 0..7 모두 동작 (각 스택 가중치 사용 확인)
- [ ] big/small 전환: small 포지션에서도 big과 동일 Score (fallback 규칙)
- [ ] IRQ 폴링 둘 다 동작, 배칭 중간 GO=0 시 즉시 정지/복구