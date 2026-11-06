고정 Stockfish 공식 코드를 호출하는 golden harness와 중간값 추출 adapter. 독립 재구현을 검증 기준으로 사용하지 않는다.

상태: M1·M2 구현 완료, M5용 탐색 재생 추가. 보드 검증과 무관한 CPU 측 결과다. 결과는 [M1·M2 보고서](../../docs/reports/M1_M2_baseline.md)와 [M5 보고서](../../docs/reports/M5_incremental.md)에 있다.

`golden_harness.cpp`는 수정 없는 공식 object와 링크하며, `tools/build-stockfish.sh`로 공식 Makefile의 flag를 그대로 사용해 빌드한다.

```bash
HARNESS=1 tools/build-stockfish.sh general-64
```

| 명령 | 내용 |
|---|---|
| `spec <net>` | 소스 상수와 net header를 JSON으로 출력 |
| `reject <net> <dir>` | 손상된 net 4종이 거부되는지 확인 |
| `export <net> <out>` | 파일 순서의 가중치 출력 (스칼라 빌드 전용) |
| `trace <net> <corpus> --seed S --states N --digest F [--stim F --stim-every K] [--events F]` | 고정 수순과 seed 무작위 수순 재생, digest와 RTL stimulus 생성 |
| `replay <net> <ops> --digest F [--events F --evals-per-root N] [--max-evals N]` | 기록된 공식 탐색을 재생하고 기록된 평가값과 대조 |

상태마다 증분·cold refresh·cached refresh 세 공식 경로의 tensor를 비교하고, 층별 재생 결과를 공식 `Network::evaluate()`와 대조한다. 하나라도 다르면 즉시 실패한다.

`arm_replay.cpp`는 같은 빌드(`HARNESS=1`)로 함께 만들어지는 ARM 단독 시간 측정 도구다. 기록된 공식 탐색을 공식 경로로 다시 실행하고, event stream에 있는 평가만 `Network::evaluate()` 경계에서 시간을 재며 결과 pair와 기록된 평가값을 대조한다. 결과는 [보드 NNUE 보고서](../../docs/reports/board_nnue_core.md)에 있다.
