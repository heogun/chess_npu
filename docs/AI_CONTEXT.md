# AI_CONTEXT — 새 에이전트를 위한 프로젝트 핸드오프

> 이 문서는 chess_npu 프로젝트를 처음 맡는 AI 에이전트가 **코드를 전부 읽지
> 않고도** 작업을 이어갈 수 있도록 작성된 컨텍스트 스냅샷. 최종 수정: M4-RTL
> E2E 통과 시점. 이후 변경 사항은 이 문서를 갱신하면서 진행할 것.

## 1. 프로젝트 한 줄 요약

Stockfish 18의 NNUE 평가 함수(transform → sparse accumulation → quantize →
FC 3-layer + fwdOut)를 Terasic DE1-SoC(Intel Cyclone V SoC-FPGA)의 FPGA에
구현해 `evaluate()`를 하드웨어로 오프로드하는 프로젝트. **합법적 성공 기준은
100 kN/s 같은 성능이 아니라 "패브릭 출력이 SW 참조와 바이트 단위 동일"** (G2
게이트) — 정확성이 먼저다.

- 시뮬레이션 검증 가능 범위(M1~M4-RTL): **완료**. big/small 모두
  `RESULT: PASS total=3 fails=0`
- 남은 작업: **온보드 실행** (DE1-SoC 부팅 + `.rbf` 로드 + first-eval 대조)

## 2. 핵심 용어/상수 (모든 코드에 걸쳐 반복됨)

| 상수 | 값 | 비고 |
|---|---|---|
| HD | 1024 (big) / 128 (small) | hidden dimension |
| NF (PSQI) | 22528 | main feature 차원 |
| TFF | 79856 (big) / 0 (small) | threat feature 차원 |
| NBUCKETS | 8 | bucket 스택 |
| NPERSP | 2 | perspective (persp0/1 = 고정색: 0=WHITE, 1=BLACK) |
| OVERLAP | 64 | 합성 인덱스 공간 (ref_eval/featgen) |
| 창 크기 | 0x14000 (32b 워드 주소) | nnuehw ABI 창 |
| MAGIC | 0x4E4E5545 ("NNUE") | descriptor 검증 |
| MODE_REFRESH | 1 | v1 지원 모드 (ACCUMULATE=0 미지원 → FAULT) |
| RES_OK / RES_FAULT | 0 / 2 | result status |
| IRQ_AVAIL / IRQ_FAULT | bit0 / bit1 | |

NNUE 인덱싱: 실질 idx = (color | piece_type) >> 1, 차원 64. ref_eval.cc의
`init_index()`가 주소 매핑의 기준. `docs/DESIGN.md` §2에 수식 전체.

## 3. 아키텍처 (데이터 흐름)

```
ARM(HPS) SW                              FPGA
──────────                               ────
evaluate_hw hook ──► nnue_batch ──► UIO ──► [window mem 0x14000]
                                              │
   feature frame (n_add 인덱스 목록 ≤256)      │
   desc[64B]: MAGIC/mode/bucket/side/n_add/    │
              add_frame/seq/cnt_*              │
   CSR.DESC_HEAD 레지스터 doorbell ────────────►│
                                              ▼
                                        fpga_top FSM
                                          │
   ┌──────────────── FTE (M2) ────────────┤
   │ smoke/big: FT bias+weights (int16)    │  main/thr accumulator(big) int32
   │ feature 스트림 → int16→int32 래칭      │  → quantize → q[HD] int8
   └──────────────── FC (M3) ──────────────┤
   │ q[] → fc0(16)→SqrClipReLU+ClipReLU    │  fc1(32)→Clip→fc2(1)+fwdOut
   │ (ref_eval evaluate() 651-687 재현)     │  → result[16B] {seq,psqt,pos,OK}
   └── psqt (fpga_top FSM 직접) ───────────┤
      psqtAcc[2][8]/thrPsqt[2][8] int64     │  → result ring → DONE/IRQ
                                            ▼
                                CSR.DESC_TAIL 진행, IRQ_STATUS set
```

REFRESH v1 의미: desc 당 전체 feature 목록(add)을 새 프레임에 기록, 누적 전
어큐뮬레이터 32셀(2persp×8bucket×2acc) 클리어 후 재누적. `acc`+`thr` 병렬
2-포트 어큐뮬레이터(TFF>0일 때만 thr 사용). seq는 요청-응답 짝짓기 키.

## 4. 파일 인벤토리 (읽는 순서 포함)

### 검증 기준 (먼저 읽을 것)
- `hw/ref_eval/ref_eval.cc` — **모든 결과의 기준**. evaluate() 577-583(psqt),
  651-687(FC)가 RTL 재현 대상. env 변수로 FTBIN/FCBIN/PSQTBIN/FEATLIST/
  RESDUMP/FTDMPD/ACCDBG/FCDUMP 덤프 → 종료. `networks.{big|small}.evaluate()`
  와 4-way bit-exact 검증됨.
- `hw/ref_eval/featgen.cc` — FEN → active feature 인덱스 목록. 출력 파일:
  `FTLIST <cnt0> <cnt1> <feat...>` / `THREATLIST ...`(big만). stdout 첫 줄
  (`big=1 n0=...`)은 로그 — 파일 파싱 시 grep `^FTLIST` 등 필수.

### RTL (M2 → M3 → M4 순서)
- `hw/rtl/fte.sv` — 트랜스폼 FSM. 1-entry 프리페치(행 진입 시 fifo_rd 1회)로
  인덱스 래그를 흡수 → **descriptor 단위 리셋이 필수** (fpga_top의 `fte_rst`).
  누적 j당 2클럭, quantize qj당 4클럭. 메모리: bias[HD], main
  `HD+f*HD`, threat `HD+NF*HD+f*HD`.
- `hw/rtl/accumulator.sv` — INT32 2-포트 BRAM, 1사이클 sync read.
- `hw/rtl/quantize.sv` — big: `clamp(acc+thr,0,255)^2>>9`, small:
  `clamp(acc,0,254)^2>>9` (DESIGN §2.3).
- `hw/rtl/weight_bram.sv` — FTBIN 로드 메모리.
- `hw/rtl/fc_pipe.sv` — ref_eval 651-687 그대로. 시퀀셜 MAC. q 램(HD).
- `hw/rtl/fc_bram.sv` — FCBIN 로드. bucket 당
  fc0.bias[16]+fc0.w[16*pad0]+fc1.bias[32]+fc1.w[32*32]+fc2.bias[1]+fc2.w[32].
- `hw/rtl/psqt_bram.sv` — PSQTBIN 로드 (main 먼저, threat 뒤).
- `hw/rtl/fpga_top.sv` — **M4-RTL 토프**. CSR/desc/feat/result 링 메모리 +
  FSM(ST_IDLE→LD_DESC→PSQT_PREP/RUN→FEAT→FEAT_GAP→FEAT_START→Q→FC_START→
  FC_WAIT→RES/FAULT). psqt는 FSM이 직접 누적(부호확장 `{{32{s[31]}},s}`).
- `hw/rtl/fpga_top_soc.sv` — **Avalon-MM 래퍼 (온보드용 신규)**. lwhps2fpga
  ↔ 창 메모리, hps2fpga ↔ 가중치 로드 3포트, f2h irq. 쓰기 0-wait/읽기
  1사이클(readdatavalid). Quartus에서 이 모듈을 톱레벨로 사용.

### TB (Verilator; `tb_*.cpp`=C++ 하네스, `tb_*.sv`=SV 하네스)
- `tb_fpga_top.cpp` — **E2E**. `<FTBIN> <FCBIN> <PSQTBIN> <MANIFEST>` 인자.
  manifest: `<w|b> <FTLIST파일> <THREATLIST파일> <RESDUMP파일> <bucket>` (bucket
  무시·8개 desc 순차 제출). FAULT(잘못된 desc), RESET, IRQ, DONE 전부 검증.
  small은 `-GHD=128 ...`로 재컴파일.
- `tb_fte_smoke.sv` / `tb_fte_big.cpp` / `tb_fc.cpp` / `tb_fte_full.cpp` —
  M2/M3 서브모듈 검증 (25 FEN 배치).

### ARM 소프트웨어
- `hw/arm/nnuehw/nnuehw.h` — **HW/SW 단일 계약**. 창 레이아웃, CSR 오프셋,
  desc/result 구조체(크기 static_assert), ioctl, DT 호환 문자열
  `nnue,nnue-hw-1.0`. RTL과 이 헤더가 서로 정의를 공유해야 한다.
- `hw/arm/nnuehw/nnuehw.c` + `Makefile` — UIO 기반 타이닉 드라이버 (ioctl:
  RESET/START/STOP/SET_BATCH/GET_STATUS).
- `hw/arm/nnue/nnue_batch.{h,cpp}` — 배칭 스케줄러: seq 짝짓기, 역순 완료
  대기, inflight, MockBackend. `test_nnue_batch.cpp` 유닛테스트 ALL PASS.
- `hw/arm/evaluate_hw.patch` — SF18 evaluate.cpp 후크 삽입
  (`evaluate_hw`/`hw_enabled` 전역, anonymous namespace 밖 이동 — 링크 이슈
  기록). NNUE_HW 미설정 시 fallback 유지.
- `hw/arm/build_armv7.sh` — lima VM(`chess`)에서 armv7-neon 크로스 빌드.
- `stockfish-armv7` — 산출물 (113MB, 리포 미커밋).

### 문서
- `docs/DESIGN.md` — 수식/메모리 레이아웃/검증 전략/체크리스트 (M4-RTL ✓).
- `docs/INTERFACE.md` — CSR 맵, 링 흐름, IRQ 정책.
- `README.md` — 요약/빠른 시작.

## 5. 검증 명령 (재현 스크립트)

```bash
# E2E big
cd hw/rtl
verilator --cc --trace fpga_top.sv top_fte.sv top_fc.sv fte.sv accumulator.sv \
  quantize.sv weight_bram.sv fc_pipe.sv fc_bram.sv psqt_bram.sv nnue_defs.sv \
  --top-module fpga_top --exe tb_fpga_top.cpp --build -j
./obj_dir/Vfpga_top <ft.bin> <fc.bin> <psq.bin> <manifest.txt>
# 기대 출력:
#   FEN$1..3 PASS, FAULT path PASS, DONE=25 IRQ_STATUS=0x3, RESET PASS
#   RESULT: PASS total=3 fails=0 (220028735 cycles)

# E2E small (파라미터 재컴파일)
verilator --cc --trace ... --build -j \
  -GHD=128 -GNF=22528 -GTFF=0 -GPSQI=22528 -GFT_ADDR_W=22 -GFC_ADDR_W=15 -GPSQ_ADDR_W=18
# 기대: RESULT: PASS total=3 fails=0 (6686523 cycles)
```

- TB 데이터 생성은 `hw/ref_eval`의 env 덤프 + featgen (`README.md` 빠른 시작
  참조). 테스트 FEN 3개는 DESIGN.md §6에 기록.
- `-Wall`은 unused-signal 경고(37건)로 실패하므로 `--cc`(경고 억제) 사용.
- `--trace` 없으면 VCD 심볼 링크 에러로 빌드 실패 — 반드시 포함.

## 6. 마일스톤 상태와 이력 (버그 수정 기록)

| 단계 | 상태 | 비고 |
|---|---|---|
| M1 ref_eval/featgen/nnue_dump | ✅ | SF18과 4-way bit-exact 교차 확인 |
| M2 FTE | ✅ | small 25/25, big 25/25. lfsr 없음, feature 프리페치 |
| M3 FC | ✅ | big/small 25/25 + E2E |
| M4-SW | ✅ | nnuehw.ko/배칭/패치/armv7 빌드 + fallback |
| M4-RTL | ✅ | big/small E2E PASS |

**직면했던 버그 2건 (재발 시 참고):**
1. **psqt 가비지(INT32_MAX 오프셋)** — `$signed(64'(psq_rd_data))`는 int32를
   제로 확장 → 음수 가중치가 2^32 단위로 밀림. 수정:
   `$signed({{32{psq_rd_data[31]}}, psq_rd_data})`. (fpga_top.sv psqt_acc/
   thr_psqt 두 곳)
2. **두 번째 FEN부터 POS만 전부 틀림** — FTE FIFO `fw/fr/fout`가 descriptor
   경계에서 정렬 붕괴 (1-entry 프리페치 오버리드, M2 버그 #4의 토프 통합 누락).
   수정: `ST_LD_DESC`에서 `fte_rst` 1펄스 → `u_fte.rst`. (재발 시: small 넷은
   TFF=0이라 threat 경로 없음 — big에서만 발생했음)

## 7. 온보드 계획 (다음 작업 — 보드 필요)

환경: macOS(개발/검증) · Bootcamp Windows(Quartus 20.1) · lima VM(Ubuntu,
armv7 크로스 빌드 + 추후 SoC EDS/Yocto) · DE1-SoC(5CSEMA5F31C6, Cyclone V SE).

| 단계 | 작업 | 머신 | 의존 |
|---|---|---|---|
| 1 | Linux 부팅 이미지 확보 | macOS/VM | rsYocto 1.042 (DE1-SoC는 비공식지원 — DE0-Nano/DE10-Nano 이미지 또는 커스텀 빌드; MSEL 스위치는 DE10-Nano와 동일 설정) |
| 2 | Quartus HPS 프로젝트 | Windows | `fpga_top_soc.sv`를 톱레벨로, lwhps2fpga+창 메모리, f2h_irq0, 100MHz → **`.rbf` 생성** |
| 3 | `.ko`/SW 주입 | macOS→VM | 커널 5.11 헤더로 `nnuehw.ko` 재빌드, `stockfish-armv7`(재빌드: 디버그 패치 제거) 배치 |
| 4 | 부팅 + 첫 eval | 보드 | MSEL, SD 플래싱(Rufus/dd), UART 콘솔, `nnuehw` DT 노드(compat `nnue,nnue-hw-1.0`, `reg`=창 물리주소), 첫 FEN의 psqt/pos 대조 |

아키텍처 결정(미정): **가중치 로드 경로** — (a) SW가 lwhps2fpga로 워드 단위
기록(레퍼런스 ABI 그대로, 수 초 소요, 변경 최소) 또는 (b) DDR3에 배치 후
브리지 스트리밍(M5 성능 전제). `fpga_top_soc.sv`의 `s_load` 슬레이브는 (a)를
위한 지름길. 성능(RTL)은 FTE가 병목(누적 2clk/j) — DESIGIN §5 참조.

## 8. 함정/주의 (과거에 시간 낭비했던 지점)

- **리포는 아직 git 아님** — 푸시 전 `git init` 필요.
- **featgen stdout 첫 줄은 로그** (`big=1 ...`) — 파일 파싱은 `grep '^FTLIST'`
  등으로 필터.
- **small 넷**: `use_big=0`, TFF=0 → threat 경로 미사용. psqt는 `/2` 내 sgmn.
  `fpga_top_soc.sv` 파라미터도 small 값으로 재컴파일해야 함.
- **UIO 창 접근**: nnuehw.c는 창을 UIO map0으로 mmap; 물리주소는 DT `reg`
  (lw bridge 상). ioctl GET_STATUS로 드라이버 상태 확인 가능.
- **armv7 빌드**: build_armv7.sh의 바이너리는 디버그 패치 포함 상태 — 온보드
  테스트 전 `make clean` 후 재빌드 권장.
- **CPW/Stockfish**: cpw_korean(스크래치), Stockfish 폴더(거대) — 커밋 제외
  대상. SF 소스 라이선스 GPL-3.0.