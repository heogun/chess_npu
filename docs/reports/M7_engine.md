# M7 엔진 통합 보고서

수행일: 2026-11-07. **이 결과는 실제 DE1-SoC에서 잰 것이다.** 카드의 4단계 128-bit FPGA 이미지, 100 MHz 코어, 같은 보드·같은 네트워크(`nn-1a298aa575a0.nnue`, SHA-256 `1a298aa5…2dfc2`)를 썼다.

## 결과: 게이트 통과

| 항목 | 결과 |
|---|---|
| HW 강제 bench (공식 bench, depth 13, 51개 위치) | 노드 2,497,913, 공식 값과 같음. 11회(warm-up 포함) 모두 error 0, fallback 0 |
| 비교 모드 bench | 평가 951,268개 모두 FPGA pair와 공식 `Network::evaluate()` pair가 같음, mismatch 0 |
| UCI | `uci`·`isready`·`position`(startpos+수순, FEN)·`go depth`·`go infinite`+`stop`·`ucinewgame`·`go movetime`·`quit` 정상. 비교 모드에서 평가 48,148개 mismatch 0, 종료 코드 0 |
| thread 정책 | `Threads 2`에서 두 번째 탐색 thread가 평가를 부르자 명시적 FATAL로 멈춤(종료 코드 1, bestmove 없음). 조용한 CPU 대체 없음 |
| **엔진 전체 속도** | 같은 이진 파일 cpu 모드 **17,084 ± 23 NPS**, hw 모드 **26,889 ± 62 NPS**, **1.57배** (warm-up 뒤 10회 교대) |

- 처음으로 엔진 전체를 비교한 값이다. 지금까지의 2.08배는 NNUE 평가만, 특징 목록을 trace에 미리 넣고 잰 값이었다.
- 1.57배는 [성능 개선 제안](perf_proposal.md)이 식으로 낸 1.70배(특징 생성 비용 없음 가정)보다 낮다. 아래처럼 특징 목록을 만드는 비용(평가당 약 15 µs)이 새로 붙었기 때문이다.

로그: [board_m7](logs/board_m7/)(bench 22회, 비교, UCI, thread 시험, 이진 파일 SHA-256), [세션](logs/board_m7_session.txt).

## 구조

- **patch 하나:** [`0002-fpga-eval.patch`](../../sw/host/patches/0002-fpga-eval.patch)는 `Eval::evaluate()`의 `network.evaluate()` 호출 한 줄을 분기로 바꾸고, Makefile에 adapter 소스 하나를 더한다. 원본 checkout(`third_party/stockfish`)은 그대로다.
- **adapter:** [`sw/host/engine/fpga_eval.cpp`](../../sw/host/engine/fpga_eval.cpp). 빌드 복사본의 `src/nnue/`에 복사된다(`FPGA=1 tools/build-stockfish.sh`).
  - 평가마다 공식 특징 코드(`HalfKAv2_hm::make_index`, `FullThreats`·`PP_3Wide::append_active_indices`)로 양 관점의 전체 목록을 만든다.
  - 요청 계획은 [`nnue_ctx.h`](../../sw/host/nnue_ctx.h)의 `NEAREST`(후보 16개)다. 보드 harness와 같은 코드다.
  - 장치 접근은 새 [`nnue_device.h`](../../sw/host/nnue_device.h)다. `nnue_board`도 같은 header를 쓰도록 바꿨다(보드에서 3,000개 window 재검증, mismatch 0).
- **모드:** `SF_NNUE_MODE` = `cpu`(기본, 공식 경로) · `plan`(공식 결과 + HW 쪽 ARM 작업만, 장치 없이 비용 측정) · `hw` · `compare`. 장치 오류는 FATAL로 멈춘다.
- **식별자:** 시작할 때 CSR의 ID·ABI·architecture hash·net ID·slot 수를 build의 spec과 비교한다. 가중치 이미지는 DDR에서 전부 다시 읽어 파일과 비교한다. 네트워크 구조 hash는 컴파일 시 `static_assert`로 확인한다. 가중치 내용이 엔진의 네트워크와 같은지는 비교 모드가 확인한다(951,268개 일치).
- **시작 시점:** 장치는 프로그램 시작 때 연다. 가중치 다시 읽기에 약 2 s가 걸리는데, 첫 평가 때 열면 그 시간이 첫 탐색에 들어가 depth 6 bench가 0.54배로 잘못 보였다.
- **보드 빌드:** `NO_EMBED=1`로 네트워크를 이진 파일에 넣지 않는다(`-DNNUE_EMBEDDING_OFF`). 이진 파일이 101 MB에서 2.5 MB가 되어 serial로 올릴 수 있다. 평가 코드는 그대로이고, 실행할 때 작업 디렉터리의 net 파일을 읽는다. ARM 단독 기준도 같은 이진 파일의 cpu 모드다.

## 시간이 쓰이는 곳 (hw 모드, 평가당, 1회 timing 실행)

| 항목 | 시간 |
|---|---:|
| 특징 목록 생성 (양 관점 전체 열거와 정렬) | 14.94 µs |
| 요청 계획과 서술자 인코딩 | 16.03 µs |
| 호스트 관측 (서술자 쓰기부터 결과 읽기까지) | 41.50 µs |

- timing 실행은 평가마다 시계를 세 번 읽어 bench가 약 4 % 느려진다(25,884 NPS). 속도 표의 hw 값은 timing 없이 잰 것이다.
- bench 평가는 평가당 행 21.87개다(탐색 trace window는 22.4개).
- 두 모드의 bench 시간 차는 53.3 s, 평가당 56 µs다. hw 평가를 위 분해의 약 70 µs(timing 비용 제외)로 두면, 평가 외 시간은 약 26 s이고 ARM 단독 평가는 약 126 µs가 된다. `arm_replay`로 잰 124 µs와 맞는다. 평가 외 시간이 두 모드에서 같다고 가정한 추정이다.

## 재 보고 넣지 않은 것: 특징 목록 증분 갱신

- **방법:** 평가한 stack 항목마다 목록을 저장해 둔다. 새 평가는 같은 배치를 가진 가장 가까운 조상 항목에서 시작해, 탐색이 이미 만든 공식 ply별 변경(`Dirties`)을 적용한다. 조상 항목은 배치 hash로 찾고, null move를 건너뛴다. 그 사이에 king이 움직인 관점은 전체를 열거한다.
- **정확성:** x86에서 bench 951,268개 평가의 목록을 전부 전체 열거와 비교해 모두 같았다. 보드 비교 모드도 mismatch 0, 노드 수 같음.
- **속도:** A9에서 오히려 느렸다. 특징 14.9 → 20.9 µs, bench 26,905 → 25,244 NPS(각 1회).
  - 평가당 평균 2.25 ply를 적용했다. 그런데 관점의 33 %는 king 이동 때문에 여전히 전체를 열거했다.
  - 변경 목록 계산, 정렬된 vector 삽입·삭제, 목록 저장 복사가 A9에서는 전체 열거보다 비쌌다.
- 그래서 코드에서 뺐다. 기록은 [세션](logs/board_m7_session.txt)에 있다.

## 남은 일

- 특징 목록 생성(15 µs)과 요청 계획(16 µs)이 ARM 쪽에 남아 있다. 둘 다 계획을 하드웨어로 옮기는 다음 단계의 대상이다.
- 다중 thread와 다중 context는 지원하지 않는다(코어는 context ID를 받지만 adapter는 한 thread만 허용).
- IRQ·kernel driver 없이 `/dev/mem`과 polling을 쓴다. root 권한이 필요하다.
- 시간 제한 대국 강도(Elo) 비교와 전력·온도 측정은 M8 범위다.
