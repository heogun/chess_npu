# hw/quartus

DE1-SoC 전용 QPF/QSF/SDC, Platform Designer 원본·IP 정의. 생성물은 `build/` 아래 둔다.

상태: 보드 설계가 보드에서 동작한다(2026-11-06). NNUE 코어를 넣은 128-bit F2SDRAM 이미지가 100 MHz에서 모든 corner timing을 통과했고, 보드에서 비트 일치로 통과했다. IRQ와 kernel driver는 아직 없다.

| 경로 | 내용 |
|---|---|
| [`board/`](board/README.md) | HPS 연결 보드 프로젝트. 측정 설계(`mem_probe`)와 NNUE 설계, 64·128-bit F2SDRAM 포트 |
| `fit_core.tcl`, `nnue_core.sdc` | 코어 단독의 자원과 Fmax 측정용. 포트가 virtual pin이라 프로그램할 수 없으며 DE1-SoC top이 아니다 |
| `m0_blink/` | M0의 LED 확인용 최소 프로젝트 |

결과: [F2SDRAM·CSR 측정](../../docs/reports/board_f2sdram_csr.md), [보드 NNUE 첫 실행](../../docs/reports/board_nnue_core.md), [성능 개선 제안](../../docs/reports/perf_proposal.md).
