고정 corpus·seed·산술/프로토콜/회귀 테스트 정의. 대형 생성 벡터는 WSL의 `~/chess_npu_build` 아래 둔다.

상태: M1·M2·M4·M5 시뮬레이션 회귀 구현. 보드 회귀는 미구현이다.

- `corpus/sf19_fixed.txt`: castling, en passant, 승격, check/pin, pawn-pair, 반복, bucket별 위치를 담은 고정 수순.

| 명령 | 게이트 |
|---|---|
| `tools/run-m1.sh [ARCH]` | UCI smoke, 공식 bench 일치, 손상된 net 거부 |
| `tools/run-m2.sh [states] [seed]` | 스칼라·AVX2·ARM NEON(qemu) digest 일치 |
| `tools/run-m4.sh [states] [seed]` | 산술 단위시험, 음성·시스템 시험, 전체 코어와 golden tensor 비교 |
| `tools/run-m5.sh prepare` 후 `tools/run-m5.sh sim ...` | 공식 탐색 trace 기록·재생, 증분 경로, 슬롯 eviction, 중단, context 교차 |

M4와 M5는 Verilator 시뮬레이션이다. 보드 정확성이나 부팅을 입증하지 않는다.
