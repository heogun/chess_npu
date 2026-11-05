ARM host runtime, 버전별 Stockfish patch, HW/CPU/비교 모드와 context 관리.

상태: 계획 단계. SF19 구현·검증 미완료.

- `generated/nnue_spec.h`: `tools/gen_spec.py` 생성물.
- `nnue_ctx.h`: 슬롯 할당과 변경 목록 병합. 시뮬레이션에서만 사용했다.
- `patches/0001-trace-search-ops.patch`: 공식 탐색의 연산을 기록하는 patch. 빌드 복사본에만 적용하며 bench 노드 수는 변하지 않는다.

런타임, 드라이버 연결, Stockfish 평가 경로 통합은 미구현이다.
