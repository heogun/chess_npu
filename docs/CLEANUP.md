# 폴더 정리 기록 — 2026-11-05

기존 루트는 `.git`, `.vscode`, `docs`, `hw`, `remove`, `tools`였다. `hw`에는 약 6,535 MiB, `remove`에는 약 1,614 MiB가 있었다. README는 SF18 및 macOS/lima 환경을 설명했고 실제 구현 상태와 문서가 일치하지 않았다. Git 작업 트리에는 이미 수정·삭제·미추적 파일이 있었다.

## 처리

- `.git`과 기존 이력을 유지했다. 커밋·reset·이력 변경은 수행하지 않았다.
- 기존 `hw`, `docs`, `tools`, `.vscode`, `remove`의 소스·설정과 루트 README·gitignore를 **155개 항목의 `archive/sf18-source-snapshot.zip`**으로 보존한 후 기존 폴더를 제거했다. 수정 중이던 `PROGRESS.md`, `g2_check.py`, 미추적 RTL·SD 이미지 생성 스크립트도 포함한다.
- 이미지·가중치·백업 데이터(`.img`, `.bak`, `.bin`, `.fat`, `.nnue`)와 Quartus 생성 폴더·보고서·캐시는 백업에서 제외하고 삭제했다. 이전 SD 이미지와 파티션 추출본·이전 가중치는 압축본에 없다.
- 시작 전에 이미 삭제되어 있던 `hw/legacy` 파일 등은 새 백업에 없으며 기존 Git 이력에서 확인한다.
- SF18 전용 참조 평가기·검증 도구·기존 IP 복사본은 활성 트리에서 제외했다. 재사용 모듈은 압축본에서 검토하고 SF19 회귀를 통과시킨 뒤 가져온다.
- macOS 전용 `.vscode` 설정을 제거했다. 새 IDE 설정은 WSL·실제 도구 경로 확인 후 작성한다.

복구할 때는 압축본을 별도 임시 디렉터리에 풀어 필요한 파일만 가져온다. 현재 소스 위에 전체 덮어쓰기를 하지 않는다. 압축본은 로컬 복구용으로 Git 추적에서 제외되므로 다른 PC로 옮길 때 별도 복사한다.

공식 sf_19는 `third_party/stockfish`에 독립 shallow clone했다. commit은 `config/stockfish.lock.json`으로 고정한다. 부모 Git에는 중첩 등록하지 않는다. 새 개발 경로는 역할만 정의했으며 이전 테스트 성공을 승계하지 않는다.
