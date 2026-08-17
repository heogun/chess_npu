# chess_npu — NNUE Batch Accelerator for DE1-SoC

Stockfish 18의 NNUE(Neural Network + One) 평가 함수를 Terasic DE1-SoC
(Intel Cyclone V SoC-FPGA, dual ARM Cortex-A9)의 FPGA 패브릭으로 옮기는
하드웨어 가속 프로젝트. 보드 없이 시뮬레이션으로 검증 가능한 범위(M1~M4-RTL)를
**bit-exact**로 완료했고, 온보드 실행(unboard)이 남아 있다.

> 핵심 게이트(G2): FPGA가 계산한 psqt/positional 쌍이
> `networks.big/small.evaluate()` 결과와 **바이트 단위로 일치**해야 한다.
> 맞지 않으면 성능은 무의미하다.

```
                          FEN
                           │
                     ┌─────▼─────┐
                     │  ARM HPS  │  nnue_batch.cpp ── UIO ──► FPGA
                     │ (SF18)    │  (descriptor ring)
                     └─────┬─────┘
                           │ lwhps2fpga (창 메모리 0x14000)
                     ┌─────▼──────────┐
                     │  fpga_top.sv   │  CSR/desc/feat/result 링 +
                     │  (M4-RTL NPU)  │  FSM (REFRESH v1)
                     └─────┬──────────┘
              ┌────────────┼──────────────┐
         ┌────▼────┐  ┌────▼────┐  ┌──────▼─────┐
         │ FTE     │  │ FC pipe │  │ psqt bram  │
         │ (M2)    │  │ (M3)    │  │ (FTE + FC) │
         └─────────┘  └─────────┘  └────────────┘
             └──────────────┬──────────────┘
                      ┌────▼─────┐
                      │ weight  │  FT 80MB / FC / PSQT
                      │ BRAM/DDR│  (big net: DDR3 스트리밍)
                      └──────────┘
```

## 상태 (Status)

| 단계 | 내용 | 상태 |
|---|---|---|
| M1 | `.nnue` 로더 + C++ 스칼라 참조 평가 (`ref_eval`/`featgen`) | ✅ 4-way bit-exact |
| M2 | FTE RTL (어큐뮬레이터 + quantize) | ✅ small 25/25, big 25/25 |
| M3 | FC 파이프라인 RTL | ✅ big/small 25/25 |
| M4-SW | UIO 드라이버 + 배칭 + evaluate_hw.patch | ✅ 단위테스트/armv7 빌드 통과 |
| M4-RTL | fpga_top 토프 + E2E 검증 | ✅ **big/small `RESULT: PASS fails=0`** |
| M5 | 온보드 실행 + 성능 튜닝 | ⏳ 남은 작업 (보드 필요) |
| M6 | UX/데모 | ⏳ |

## 디렉토리 구조

```
hw/
├── rtl/           SystemVerilog RTL + Verilator TB
│   ├── fpga_top.sv        M4-RTL 토프: CSR/desc/feat/result 링 + FSM
│   ├── fpga_top_soc.sv    ★ Avalon-MM 래퍼 (Quartus/Platform Designer 통합용)
│   ├── top_fte.sv, fte.sv, accumulator.sv, quantize.sv, weight_bram.sv   (M2 FTE)
│   ├── top_fc.sv, fc_pipe.sv, fc_bram.sv                                 (M3 FC)
│   ├── psqt_bram.sv, nnue_defs.sv
│   └── tb_fpga_top.cpp    E2E 하네스 (big/small 파라미터 재컴파일)
├── ref_eval/       C++ 참조 구현 (검증 기준)
│   ├── ref_eval.cc    스칼라 평가 + FTBIN/FCBIN/PSQTBIN/RESDUMP 덤프
│   ├── featgen.cc     FEN → active feature 인덱스 목록 (FTLIST/THREATLIST)
│   └── nnue_dump.cc, idx_check.cc
└── arm/            ARM(HPS) 소프트웨어
    ├── nnuehw/      UIO 커널 드라이버 (nnuehw.c/.h + Makefile)
    ├── nnue/        nnue_batch.{h,cpp} 배칭 스케줄러 + 유닛테스트
    ├── evaluate_hw.patch   SF18 integrate.cpp/hook 패치 (USE_NNUE_HW)
    ├── build_armv7.sh      lima VM armv7-neon 크로스 빌드
    └── stockfish-armv7     107MB armv7 바이너리 (빌드 산출물)
docs/
├── DESIGN.md       설계 문서 (수식, 메모리 레이아웃, 검증 전략, 체크리스트)
├── INTERFACE.md    HW/SW 인터페이스 명세 (CSR 맵, 흐름)
└── AI_CONTEXT.md   ★ 새 에이전트를 위한 핸드오프 문서 (시작점)
```

## 빠른 시작 (검증 재현)

```bash
# 0) 사전: verilator (≥5.x), g++11+, Stockfish/src에 배치된 .nnue 2개
BIG=Stockfish/src/nn-c288c895ea92.nnue      # big (109MB)
SMALL=Stockfish/src/nn-37f18f62d772.nnue     # small (3.5MB)
T=/tmp/fpt && mkdir -p $T

# 1) 참조 가중치/특징 기준 데이터 생성 (ref_eval.cc, env-variable 덤프)
cd hw/ref_eval
FTBIN=$T/ft.bin   ./ref_eval $BIG ""    # FT bias+weights
FCBIN=$T/fc.bin   ./ref_eval $BIG ""    # FC 가중치 (8 bucket)
PSQTBIN=$T/psq.bin ./ref_eval $BIG ""   # psqt 가중치
./featgen $BIG "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3" > fg.txt
grep '^FTLIST' fg.txt  > $T/f1.txt    # (THREATLIST 제외)
RESDUMP=$T/r1.txt ./ref_eval $BIG "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3"
# 매니페스트: "<w|b> <FTLIST> <THREATLIST> <RESDUMP> <bucket>" 한 줄/FEN

# 2) RTL E2E (big — 기본 파라미터)
cd ../rtl
verilator --cc --trace fpga_top.sv top_fte.sv top_fc.sv fte.sv accumulator.sv \
  quantize.sv weight_bram.sv fc_pipe.sv fc_bram.sv psqt_bram.sv nnue_defs.sv \
  --top-module fpga_top --exe tb_fpga_top.cpp --build -j
./obj_dir/Vfpga_top $T/ft.bin $T/fc.bin $T/psq.bin $T/manifest.txt
# 기대: RESULT: PASS total=3 fails=0

# 3) small 넷은 파라미터 -G 오버라이드로 재컴파일
verilator --cc --trace fpga_top.sv ... --build -j \
  -GHD=128 -GNF=22528 -GTFF=0 -GPSQI=22528 -GFT_ADDR_W=22 -GFC_ADDR_W=15 -GPSQ_ADDR_W=18
```

## 온보드 실행 (남은 작업)

환경: macOS(개발/검증) ↔ Bootcamp Windows(Quartus 20.1 합성) ↔ lima VM(armv7
크로스 빌드) ↔ DE1-SoC 보드. 상세 절차는 `docs/AI_CONTEXT.md`의
「온보드 계획」 섹션 참조. 핵심 순서만 요약하면:

1. **Linux 이미지**: rsYocto(robseb) 1.042 기반 부팅 이미지 확보
   (커스텀 Yocto 빌드는 Linux 호스트 필요 — lima VM 사용; macOS는 미지원)
2. **FPGA 설정**: `hw/rtl/fpga_top_soc.sv`를 시작점으로 Quartus HPS
   프로젝트 구성 (lwhps2fpga ↔ 창 메모리, f2h_irq, 100MHz 클럭) → `.rbf`
3. **SW 주입**: 커널 5.11 맞춰 `nnuehw.ko` 재빌드 + `stockfish-armv7` 배치
4. **부팅 검증**: MSEL 설정, SD 플래싱, UART 콘솔, 첫 eval 대조

## 라이선스/산출물 주의

- Stockfish 소스(수정본 포함)는 GPL-3.0 — 별도 참조
- `cpw_korean/`(체스 위키 한글 번역 참조)는 스크래치 자료로 커밋 제외
- 대형 바이너리(`*.nnue`, `stockfish-armv7`, `bak.zip`, `obj_dir/`)는 `.gitignore`