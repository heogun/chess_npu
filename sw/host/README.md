ARM host runtime, 버전별 Stockfish patch, HW/CPU/비교 모드와 context 관리.

상태: 계획 단계. SF19 구현·검증 미완료.

- `generated/nnue_spec.h`: `tools/gen_spec.py` 생성물.
- `nnue_ctx.h`: 슬롯 할당과 요청 계획. 시뮬레이션과 보드 harness에서 사용한다. 정책은 두 가지다. `STACK`은 탐색 stack의 조상 slot을 쓰고, `NEAREST`는 특징 차이가 가장 작은 slot을 쓴다.
- `nnue_golden.h`: golden 파일 형식, 서술자 인코딩, tensor 비교. `tb_core`와 보드 harness가 함께 쓴다.
- `plan_sim.cpp`: 탐색 trace에서 요청 계획 정책별로 읽는 행 수를 세는 모델. 현재 정책의 행 수는 보드 카운터와 같다. [성능 개선 제안](../../docs/reports/perf_proposal.md) 참고.
- `patches/0001-trace-search-ops.patch`: 공식 탐색의 연산을 기록하는 patch. 빌드 복사본에만 적용하며 bench 노드 수는 변하지 않는다.

런타임, 드라이버 연결, Stockfish 평가 경로 통합은 미구현이다.
