고정 corpus·seed·산술/프로토콜/회귀 테스트 정의. 대형 생성 벡터는 WSL의 `~/chess_npu_build` 아래 둔다.

상태: M1·M2·M4·M5 시뮬레이션 회귀 구현. 보드에서는 같은 corpus와 탐색 trace를 [`sw/board/nnue_board`](../sw/board/README.md)로 수동 실행해 통과했다(2026-11-06). 보드 회귀를 한 번에 돌리는 스크립트는 아직 없다.

- `corpus/sf19_fixed.txt`: castling, en passant, 승격, check/pin, pawn-pair, 반복, bucket별 위치를 담은 고정 수순.

| 명령 | 게이트 |
|---|---|
| `tools/run-m1.sh [ARCH]` | UCI smoke, 공식 bench 일치, 손상된 net 거부 |
| `tools/run-m2.sh [states] [seed]` | 스칼라·AVX2·ARM NEON(qemu) digest 일치 |
| `tools/run-m4.sh [states] [seed]` | 산술 단위시험, 음성·시스템 시험, 전체 코어와 golden tensor 비교 |
| `tools/run-m5.sh prepare` 후 `tools/run-m5.sh sim ...` | 공식 탐색 trace 기록·재생, 증분 경로, 슬롯 eviction, 중단, context 교차 |

M4와 M5는 Verilator 시뮬레이션이다. 보드 정확성이나 부팅을 입증하지 않는다. `tools/build-sim.sh`는 64-bit 기본 코어와 128-bit 코어(`core_b128`)를 함께 빌드한다. 지금 보드 이미지는 128-bit이므로, RTL을 바꾸면 두 설정 모두 다시 통과시킨다.

보드에서 쓰는 입력과 명령(4단계 측정과 같은 조건):

| 보드 실행 | 입력 | 기준 |
|---|---|---|
| `nnue_board weights.bin stim.bin --mode refresh --tensor-every 10` | refresh corpus 100,000개 (`golden_harness trace --stim`) | mismatch·error·fallback 0 |
| `nnue_board weights.bin search.ev --mode events --tensor-every 10 --policy nearest --candidates 16` | 공식 탐색 trace 94,770개 평가 | mismatch·error·fallback 0 |
| `arm_replay <net> bench.ops search.ev --mode search` | 같은 탐색 기록 | 결과 pair·기록된 평가값 mismatch 0 |

성능 비교는 warm-up 1회 뒤 `arm_replay`와 `nnue_board --tensor-every 1000000`을 10회 번갈아 실행한다([BENCHMARK](../docs/BENCHMARK.md)).
