# sw/host

ARM host runtime, 버전별 Stockfish patch, HW/CPU/비교 모드와 context 관리.

상태: 요청 계획, golden 형식, 장치 접근, 엔진 adapter를 구현했다. 시뮬레이션(`tb_core`), 보드 harness(`sw/board/nnue_board.cpp`), 엔진(M7)에서 쓴다. 보드에서 비트 일치로 통과했다(2026-11-07, [M7 보고서](../../docs/reports/M7_engine.md)). **kernel driver와 IRQ는 미구현이다**(`/dev/mem`과 polling).

- `generated/nnue_spec.h`: `tools/gen_spec.py` 생성물.
- `nnue_ctx.h`: 슬롯 할당과 요청 계획. 정책은 두 가지다.
  - `STACK`: 탐색 stack의 조상 slot을 원천으로 쓴다.
  - `NEAREST`: 특징 차이가 가장 작은 slot을 원천으로 쓴다. 후보는 최근 쓴 순서(MRU)로 K개까지 본다. 종류마다 128-bit parity signature를 NEON popcount로 비교해 하한을 구하고, 하한이 낮은 후보부터 정확한 차이를 merge로 센다. 하한이 지금까지 가장 좋은 비용 이상이면 나머지는 merge하지 않는다. 고르는 slot과 목록은 MRU 순서로 볼 때와 같다(`boundOrder = false`, `plan_sim --check`). 보드 기본값은 후보 16개다.
  - `HWPLAN`: 코어가 원본을 고른다(`nnue_core` `HW_PLAN`). 호스트는 전체 목록과 가장 오래 쓰지 않은 슬롯을 보내고, 실행 뒤 CSR PLAN을 `commit_plan()`에 넘겨 LRU를 갱신한다. 엔진은 `SF_NNUE_PLANNER=hw`, harness와 `tb_core`는 `--policy hw`다.
  - 호출하는 쪽이 `FullFeatures`와 `Request`를 재사용하면 정상 상태에서 메모리를 할당하지 않는다(`full_of(f, out)`, `plan(full, r)`).
- `nnue_device.h`: 보드의 코어를 장치로 다룬다. `/dev/mem` window, 식별자 확인, F2SDRAM 포트 해제, 가중치 적재와 다시 읽기, 서술자 실행. `nnue_board`와 엔진 adapter가 함께 쓴다.
- `engine/fpga_eval.{h,cpp}`: 엔진 adapter. `SF_NNUE_MODE`(cpu·plan·hw·compare)로 고르고, 공식 특징 코드로 목록을 만들어 `NEAREST`로 계획한다. 장치 오류는 FATAL이고 CPU로 대체하지 않는다. 한 탐색 thread만 허용한다.
- `nnue_golden.h`: golden 파일 형식, 서술자 인코딩(128-bit 코어를 위해 짝수 워드로 채움), tensor 비교, CSR 번호와 성능 카운터 이름(`PERF_NAMES`). `tb_core`와 보드 harness가 함께 쓴다.
- `plan_sim.cpp`: 탐색 trace에서 정책별로 읽는 행 수와 계획 시간을 재는 모델. `STACK`의 행 수는 보드 카운터와 같다. 보드에서 FPGA 없이 돌려 ARM 계획 비용을 잰다(`--only K`, `--preload-mb M`, `--mru-order`). `--check K`는 하한 순서와 MRU 순서의 요청이 모두 같은지 확인한다. [성능 개선 제안](../../docs/reports/perf_proposal.md) 참고.
- `patches/0001-trace-search-ops.patch`: 공식 탐색의 연산을 기록하는 patch. 빌드 복사본에만 적용하며 bench 노드 수는 변하지 않는다.
- `patches/0002-fpga-eval.patch`: `Eval::evaluate()`의 평가 호출을 adapter 분기로 바꾸고 Makefile에 adapter를 더한다. `FPGA=1 tools/build-stockfish.sh <ARCH>`로 빌드한다. 보드용은 `NO_EMBED=1`도 준다(네트워크를 실행 시 읽음, 이진 파일 2.5 MB).

ARM 요청 계획은 `plan_sim` 기준(A9, 후보 16개, 탐색 trace 전체) 21.5 → 17.1 µs로 줄었다. 여전히 ARM+FPGA 경로에서 큰 항목이다. 탐색 tree의 ply별 변경으로 차이를 만드는 방법과 bitset 방법은 재 보니 merge보다 느려 넣지 않았다(제안서의 "1단계 후속 2").
