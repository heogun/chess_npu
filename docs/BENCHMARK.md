# 보드 내 ARM 단독 / ARM+FPGA 평가 기준

## 목적과 기준 실행

동일한 DE1-SoC에서 공식 Stockfish 19의 ARM 단독 실행을 기준으로 ARM+FPGA 실행의 결과 일치와 시간을 측정한다. ARM 기준 실행은 실제 사용할 최적화 경로(가능한 NEON 포함)를 사용한다. 스칼라 oracle은 진단용이며 느린 스칼라만을 성능 비교 대상으로 삼지 않는다.

가능하면 같은 엔진 빌드의 CPU 강제/HW 강제 모드를 사용하고, CPU 경로가 수정 없는 공식 ARM 실행과 일치함을 먼저 확인한다. 별도 빌드라면 동일 compiler·최적화·엔진 설정을 사용하고 HW 연결 부분의 차이를 기록한다.

## 정확성: 필수 통과 게이트

여기서 정확성은 실제 승패를 얼마나 잘 예측하는지가 아니라 **공식 NNUE 계산을 정확히 재현하는지**다. 동일 함수·가중치의 하드웨어 구현이므로 허용 오차는 없다.

| 항목 | 통과 기준 |
|---|---|
| `Network::evaluate()` psqt/positional pair | 모든 시험 상태에서 두 정수 각각 동일 |
| 중간 accumulator/FT/PSQT/FC tensor | 비교 가능한 원래 정수 표현에서 모두 동일 |
| 통합 `Eval::evaluate()` | 동일 상태·optimism 등 입력에서 동일 |
| HW 실행 유효성 | mismatch=0, timeout/error=0, fallback=0 |

보고서에는 비교 상태 수, 일치율, 불일치 수, 각 출력의 최대 절대 오차를 기재한다. 목표는 일치율 100%, 최대 오차 0이다. 이 일치율은 시험한 corpus에 대한 수치이며 모든 합법 입력에 대한 증명을 의미하지 않는다. 분류 정확도·Elo·승률은 이 게이트의 대체물이 아니다.

같은 FEN 집합의 refresh 비교뿐 아니라 동일 수순과 make/unmake·null move·king refresh·context 전환 trace를 양 경로에 재생한다. 내부 상태가 다르게 준비된 실행을 같은 조건으로 간주하지 않는다. corpus 세부 항목은 ROADMAP의 비트 일치 검증을 따른다.

## 시간: 정확성 통과 후 비교

주 지표는 **ARM에서 관측한 평가 호출 전체 경과 시간**이다. 공통 입력 상태 준비 경계부터 결과가 CPU에 사용 가능해지는 동일 경계까지 측정한다. 특징 생성·명령 구성·전송·DMA/cache 동기화·대기·IRQ 또는 polling·결과 회수를 포함하며, 계측 경계를 구현 시 코드 위치와 함께 고정한다.

- 단일 요청 latency: median, p95, p99와 전체 총시간/평가 수를 보고한다. 평균도 함께 기록한다.
- 평가 처리량: 동일 trace의 evaluations/s. batch 크기 1을 기본으로 하고 batch 실험은 크기·대기 시간을 별도 표기한다.
- 가속비: 동일 workload의 `ARM 총시간 / ARM+FPGA 총시간`.
- FPGA 계산 전용 cycle/time, DDR bytes·대기 시간은 원인 분석용 보조 지표다.
- cold start의 net load·패킹·FPGA 설정 시간과 warm steady-state 평가 시간을 구분한다. 초기화 비용을 숨기지 않는다.
- refresh와 incremental을 분리 보고하고 실제 검색 trace의 혼합 결과도 제공한다. 가속기만 전체 refresh 또는 CPU만 전체 refresh인 결과를 동등한 최적화 비교로 제시하지 않는다.

정확성 비교 실행은 로깅·tensor dump·CPU와 HW 이중 실행이 가능하다. 성능 실행에서는 이를 끄고 CPU/HW 경로를 각각 측정한다. 두 경로를 동시에 실행하여 자원을 경쟁시키지 않는다. 출력 checksum 등으로 결과가 실제 소비됨을 확인한다.

## 실험 조건

보드·Debian/kernel·엔진 commit·net 전체 SHA-256·compiler/flags·driver/bitstream hash·ARM/FPGA clock·CPU affinity/governor·thread 수·메모리 설정을 기록한다. 단일 엔진 thread를 기본 비교로 하고 2-thread 실행은 별도 실험으로 진행한다. IRQ 등 시스템 처리를 위한 코어 사용과 CPU 점유율도 기록한다.

동일 corpus·순서·seed·cache 준비 절차를 사용한다. warm-up 후 최소 10회 반복하고 A/B 실행 순서를 교대로 바꾼다. 타이머 overhead를 측정하고, 짧은 호출은 충분한 표본을 모은다. 온도·백그라운드 부하와 반복 간 변동도 기록한다. 작은 시간 차이가 변동 범위 안이면 유의미한 향상으로 단정하지 않는다.

## 엔진 전체 성능은 별도 측정

같은 UCI 설정·hash·thread 수에서 고정 depth 또는 nodes workload의 시간·실제 nodes·NPS를 기록한다. 시간 제한 탐색은 처리량에 따라 방문 상태와 bestmove가 달라지므로 NNUE 정확성 검증에 사용하지 않는다. NNUE 가속비와 전체 엔진 가속비를 나누어 보고한다.

## 결과 표 양식

| Workload/모드 | 상태 수 | 불일치/최대 오차 | 오류/fallback | 총시간 | median/p95/p99 | eval/s | 가속비 |
|---|---|---|---|---|---|---|---|
| Refresh ARM | 미측정 | 기준 | 미측정 | 미측정 | 미측정 | 미측정 | 1.0 |
| Refresh ARM+FPGA | 미측정 | 미측정 | 미측정 | 미측정 | 미측정 | 미측정 | 미측정 |
| Trace ARM | 미측정 | 기준 | 미측정 | 미측정 | 미측정 | 미측정 | 1.0 |
| Trace ARM+FPGA | 미측정 | 미측정 | 미측정 | 미측정 | 미측정 | 미측정 | 미측정 |
