# Stockfish 19 NNUE NPU — DE1-SoC

DE1-SoC 전용 신경망 프로세서 프로젝트. **Stockfish 19 공식 NNUE 출력과 정수 비트 단위 일치**를 최우선으로 한다. 전체 refresh와 증분 RTL을 시뮬레이션에서 공식 tensor와 대조했으며, 보드 통합과 엔진 통합은 미구현이고 보드 검증도 미완료다. 게이트별 판정은 [로드맵](docs/ROADMAP.md)을 따른다.

- 릴리스: `sf_19`, commit `edb0d9db6731067ec50ce619ff372b463bc4dd5d`
- 공식 소스: `third_party/stockfish/` (독립 Git checkout, 수정 없음)
- 기본 신경망: `nn-1a298aa575a0.nnue` (전체 SHA-256은 lock 파일에 기록, 파일은 `tools/fetch-net.sh`로 확보)
- 타깃: DE1-SoC / Cyclone V `5CSEMA5F31C6`, Cortex-A9, Debian armhf
- 환경: WSL에서 소프트웨어·시뮬레이션·이미지 생성, Windows VS/Quartus에서 편집·FPGA 빌드

## 문서

- [진행 로드맵](docs/ROADMAP.md): 단계별 작업·산출물·통과 기준
- [설계 계약](docs/ARCHITECTURE.md): 출력 경계·구조·모듈 분리
- [보드 평가 기준](docs/BENCHMARK.md): ARM 단독과 ARM+FPGA의 정확성·시간 비교
- [AI 작업 지침](AGENTS.md): 현재 기준선과 이전 자료 취급 규칙
- [정리 기록](docs/CLEANUP.md): 삭제 범위와 복구 위치
- [버전 고정 파일](config/stockfish.lock.json)

```text
config/                 버전·네트워크 기준선
docs/                   SF19 문서
third_party/stockfish/  공식 sf_19 소스 (다운로드 완료, 부모 Git 추적 제외)
hw/rtl/                 새 SF19 RTL
hw/quartus/             DE1-SoC 프로젝트·Platform Designer 원본
sw/reference/           공식 구현을 호출하는 golden harness
sw/host/                ARM 런타임·Stockfish 통합
sw/driver/              Linux 드라이버
tools/                  빌드·추출·검증 도구
tests/                  회귀 테스트·corpus 정의
linux/                  부트 체인·Debian rootfs·SD 이미지 레시피
archive/                기존 소스 복구용 압축본 (Git 추적 제외)
build/, artifacts/      생성물 전용 (필요할 때 생성). WSL 빌드 출력은 ~/chess_npu_build
```

새 checkout에서 `./tools/fetch-stockfish.ps1`로 공식 소스를 다시 확보하고 고정 commit을 검증한다.

SF18 big/small 구현과 PASS 기록은 현재 기준선에서 제외했다. 향후 구조 변경은 버전 어댑터·생성 사양으로 격리하며 현재 실행 대상은 SF19 하나다. Stockfish는 GPL-3.0-or-later이며 엔진 배포 시 대응 소스·라이선스·빌드 방법을 제공한다.
