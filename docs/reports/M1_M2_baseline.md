# M1·M2 기준선 보고서

수행일: 2026-11-05. CPU 측 결과이며 DE1-SoC에서 실행한 결과가 아니다. ARM 결과는 qemu-user 실행이다.

## M1 기준선 동결: 통과

| 항목 | 결과 |
|---|---|
| Stockfish | `sf_19`, `edb0d9db6731067ec50ce619ff372b463bc4dd5d`, 추적 파일 변경 없음 |
| 기본 net | `nn-1a298aa575a0.nnue`, 98,511,183 bytes |
| 전체 SHA-256 | `1a298aa575a085434d29027978dc36867fe9c5bcea9376654b7a8eba1e52dfc2` |
| network hash / 파일 버전 | `0xA85B2205` / `0x6A448AFA` (소스 상수와 net 파일 일치) |
| 공식 bench (릴리스 값 2,497,913) | general-64, x86-64-avx2, armv7-neon(qemu) 모두 2,497,913 |
| UCI smoke | `uci`, `isready`, `position`, `go`, `quit` 정상 (x86-64-avx2) |
| 손상된 net 거부 | 버전 오류, hash 오류, 잘림, 후행 바이트 모두 거부 |

사양은 harness가 컴파일된 공식 상수와 net header에서 추출하고, `tools/gen_spec.py`가 JSON, SV package, C++ header, DDR 이미지를 함께 생성한다. 소스·net·lock 값이 다르면 생성이 실패한다.

```bash
tools/fetch-net.sh
```

```bash
HARNESS=1 tools/build-stockfish.sh x86-64-avx2
```

```bash
tools/run-m1.sh x86-64-avx2
```

```bash
tools/gen-spec.sh
```

## M2 golden 검증: 통과

seed `20261105`, 100,000개 평가 상태, 고정 수순 141개 상태 포함.

| 항목 | 결과 |
|---|---|
| 스칼라 / AVX2 / ARM NEON(qemu) digest | 100,000개 상태 모두 동일, 불일치 0 |
| 증분 / cold refresh / cached refresh | 모든 상태의 모든 tensor 동일 |
| 층별 재생과 공식 `Network::evaluate()` | 모든 상태 일치 |
| 특징 목록으로 다시 계산한 누산기 (스칼라) | 공식 누산기와 일치 |
| 비교 tensor | 누산기, PSQT, FT, FC0, concat, FC1, FC2, skip, 최종 pair, 특징 목록, optimism 포함 `Eval::evaluate()` |

| Coverage | 값 |
|---|---|
| bucket 0~7 | 61,776 / 19,379 / 6,695 / 3,234 / 2,686 / 2,216 / 2,050 / 1,964 |
| 차례 (백 / 흑) | 50,140 / 49,860 |
| move / undo / null / undo null | 88,277 / 7,298 / 3,562 / 321 |
| castling / en passant / capture | 45 / 40 / 7,366 |
| 승격 N / B / R / Q | 68 / 51 / 50 / 410 |
| king 이동 / 미러 변경 | 60,480 / 6,954 |
| check / 반복·무승부 판정 | 3,741 / 249 |
| pawn-pair 변화 수 / threat 변화 수 | 9,590 / 18,286 |
| 최대 특징 수 (PSQ / threat+pair) | 32 / 81 |
| 최종 positional / psqt 범위 | [-2690, 3417] / [-6966, 6959] |

## 한계

- 무작위 수순은 종반에 치우친다. 62%가 bucket 0이고 bucket 7은 2%다.
- 탐색 trace 재생과 다중 context 교차는 [M5 보고서](M5_incremental.md)에서 다룬다.
- 일치율은 시험한 corpus에 대한 수치이며 모든 입력의 증명이 아니다.
