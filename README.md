# Stockfish 19 NNUE NPU — DE1-SoC

DE1-SoC 전용 신경망 프로세서 프로젝트. **Stockfish 19 공식 NNUE 출력과 정수 비트 단위 일치**를 최우선으로 한다. 게이트별 판정은 [로드맵](docs/ROADMAP.md)을 따른다.

## 현재 상태 (2026-11-06)

- **보드 비트 일치 통과.** 실제 DE1-SoC에서 NNUE 코어(128-bit F2SDRAM 포트, 100 MHz)를 돌렸다. refresh corpus 100,000개와 공식 탐색 trace 94,770개 평가 모두 최종 pair와 중간 tensor가 공식 sf_19와 같다. mismatch·error·fallback은 0이다.
- **같은 보드의 ARM 단독보다 빠르다.** 탐색 trace를 warm-up 뒤 10회 교대 측정했다.
  - ARM 단독 평균 124.18 µs.
  - ARM+FPGA 호스트 관측 42.34 µs(2.93배), ARM 요청 계획 시간까지 넣으면 59.77 µs(**2.08배**).
  - 근거: [성능 개선 제안](docs/reports/perf_proposal.md)의 "4단계 실측 결과"와 "1단계 후속 2".
- **아직 아닌 것**
  - Stockfish 엔진 통합(M7)이 없다. 위 비교에서 ARM+FPGA 쪽 특징 목록은 trace에 미리 들어 있으므로, 엔진 전체 속도는 M7에서 다시 재야 한다.
  - IRQ와 kernel driver가 없다. 지금은 `/dev/mem`과 STATUS polling을 쓰는 사용자 공간 harness다.
  - 다중 context·중단·실행 중 reset 시험은 시뮬레이션에서만 통과했다.

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

보고서(`docs/reports/`):

| 보고서 | 내용 |
|---|---|
| [M0](docs/reports/M0_environment.md), [M1·M2](docs/reports/M1_M2_baseline.md), [M3](docs/reports/M3_resources.md), [M4](docs/reports/M4_rtl_simulation.md), [M5](docs/reports/M5_incremental.md) | 단계별 환경·기준선·ABI·시뮬레이션 결과 |
| [보드 ARM 기준선](docs/reports/board_a9_baseline.md) | Cortex-A9에서 공식 sf_19의 평가 시간 |
| [F2SDRAM·CSR 측정](docs/reports/board_f2sdram_csr.md) | 64-bit 포트 대역폭·지연과 CSR 왕복 |
| [보드 NNUE 첫 실행](docs/reports/board_nnue_core.md) | 개선 전 코어의 보드 비트 일치와 시간(0.70배) |
| [성능 개선 제안](docs/reports/perf_proposal.md) | 개선 1~4단계와 계획 변경의 보드 실측(현재 2.08배)과 남은 후보 |
| [ARM 프로파일](docs/reports/profile_search.md) | 탐색 중 NNUE 비중(에뮬레이터 측정과 추정) |

```text
config/                 버전·네트워크 기준선
docs/                   SF19 문서
third_party/stockfish/  공식 sf_19 소스 (다운로드 완료, 부모 Git 추적 제외)
hw/rtl/                 SF19 NNUE 코어, 보드 top, testbench
hw/quartus/             DE1-SoC 프로젝트·Platform Designer 원본
sw/reference/           공식 구현을 호출하는 golden harness, ARM 단독 시간 측정
sw/host/                요청 계획·golden 형식 (런타임·Stockfish 통합은 미구현)
sw/board/               보드에서 도는 측정·검증 프로그램
sw/driver/              Linux 드라이버 (미착수)
tools/                  빌드·추출·검증 도구
tests/                  회귀 테스트·corpus 정의
linux/                  부트 체인·Debian rootfs·SD 이미지 레시피
archive/                기존 소스 복구용 압축본 (Git 추적 제외)
build/, artifacts/      생성물 전용 (필요할 때 생성). WSL 빌드 출력은 ~/chess_npu_build
```

새 checkout에서 `./tools/fetch-stockfish.ps1`로 공식 소스를 다시 확보하고 고정 commit을 검증한다.

SF18 big/small 구현과 PASS 기록은 현재 기준선에서 제외했다. 향후 구조 변경은 버전 어댑터·생성 사양으로 격리하며 현재 실행 대상은 SF19 하나다. Stockfish는 GPL-3.0-or-later이며 엔진 배포 시 대응 소스·라이선스·빌드 방법을 제공한다.
