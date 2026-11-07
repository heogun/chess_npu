# sw/board

DE1-SoC 위 Linux에서 실행하는 측정·검증 프로그램. 모두 `/dev/mem`으로 경량 HPS→FPGA 브리지(0xFF200000)의 CSR을 다루는 사용자 공간 프로그램이며, kernel driver가 아니다. FPGA가 적재되고 `mem=768M`으로 부팅해야 한다([보드 빌드](../../hw/quartus/board/README.md)의 "자동 부팅").

상태: 보드에서 실행했다(2026-11-06). 결과는 [F2SDRAM·CSR 측정](../../docs/reports/board_f2sdram_csr.md), [보드 NNUE 첫 실행](../../docs/reports/board_nnue_core.md), [성능 개선 제안](../../docs/reports/perf_proposal.md)에 있다.

| 파일 | 대상 FPGA 설계 | 내용 |
|---|---|---|
| [`nnue_board.cpp`](nnue_board.cpp) | NNUE (`USE_NNUE=1`) | 가중치를 0x30000000에 올리고, refresh corpus나 탐색 trace를 코어로 실행해 최종 pair와 중간 tensor를 golden과 비교한다. `host_us`·`fpga_us`·`plan_us`와 단계 카운터를 JSON으로 보고한다 |
| [`probe.c`](probe.c) | 측정 (`USE_NNUE=0`) | F2SDRAM 대역폭·지연과 CSR 왕복. 패턴을 다시 읽어 BAD가 0일 때만 속도를 보고한다 |
| [`probe_burst.py`](probe_burst.py) | 측정 | burst 길이 1~16을 모두 읽어 검증한다 |

빌드(WSL, 정적 armhf): `tools/build-board-sw.sh`. 출력은 `~/chess_npu_build/board/{probe,nnue_board,plan_sim}`이다. 보드로는 [`tools/serial-put.ps1`](../../tools/serial-put.ps1)로 올리고, 결과는 [`tools/serial-fetch.ps1`](../../tools/serial-fetch.ps1)로 가져온다. 큰 파일은 카드에 직접 넣는다([`tools/sd-partition.ps1`](../../tools/sd-partition.ps1)).

```text
nnue_board <weights.bin> <input> [--mode refresh|events] [--max N] [--tensor-every K]
           [--no-load] [--policy stack|nearest] [--candidates K] [--report out.json]
probe [all|csr|verify] [--portrst VALUE]
```

- `--mode refresh`: `<input>`은 `golden_harness trace --stim` 파일. 모든 상태가 전체 refresh다.
- `--mode events`: `<input>`은 `golden_harness --events` 파일. context 하나가 공식 ply별 변경으로 요청을 계획한다. 성능 측정 기본값은 `--policy nearest --candidates 16`이다.
- `--no-load`: 이미 올린 가중치를 다시 쓰지 않는다. 처음 실행은 가중치를 쓰고 다시 읽어 확인한다.
- `--tensor-every K`: K번째 평가마다 중간 tensor 전체를 비교한다. 성능 실행은 `1000000`으로 사실상 끈다. 최종 pair는 항상 매번 비교한다.
- 128-bit 이미지: `nnue_board`는 CSR 22 `BUS`를 읽고, 128이면 SDRAM 컨트롤러의 `fpgaportrst`(0xFFC25080)에 0x133이 있는지 확인해 빠진 비트만 쓴다. 2026-11-07부터 카드의 U-Boot가 0x133을 쓰므로 보통은 쓸 것이 없다(출력 `fpgaportrst 0x133 -> 0x133`). `probe`는 `--portrst 0x133`으로 같은 일을 한다.
- mismatch·error·fallback이 하나라도 있으면 `RESULT FAIL`이다.

ARM 단독 비교 쪽은 [`sw/reference/arm_replay.cpp`](../reference/arm_replay.cpp), ARM 요청 계획 비용 측정은 [`sw/host/plan_sim.cpp`](../host/plan_sim.cpp)다.
