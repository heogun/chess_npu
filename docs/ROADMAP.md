# 프로젝트 로드맵 — Stockfish 19 / DE1-SoC

작성일: 2026-11-05. 현재 대상은 공식 **sf_19 한 버전**으로 고정한다. 향후 변경 비용을 낮추되 SF18·레거시 ABI 호환성은 요구하지 않는다. 완료 여부는 일정 추정보다 산출물·검증 게이트로 판단한다.

최종 평가 방법은 [보드 평가 기준](BENCHMARK.md)을 따른다. 동일 DE1-SoC의 ARM 단독을 기준으로 ARM+FPGA의 비트 일치를 먼저 검증하고, 통과 후 통신·동기화 포함 전체 평가 시간과 엔진 성능을 비교한다.

## 현재 상태

폴더 조사·기존 소스 보존·산출물 정리와 공식 sf_19 확보는 완료했다. 아래 표가 게이트별 현재 판정이다(2026-11-06 갱신). 기존 SF18 PASS와 이전 부팅 기록은 SF19 완료로 인정하지 않는다.

**실제 DE1-SoC에서 한 것**
- CPU 전용 Debian 부팅과 Cortex-A9 평가 시간 측정([보드 ARM 기준선](reports/board_a9_baseline.md)).
- 측정 전용 FPGA 구성(`mem_probe`)으로 F2SDRAM 대역폭·지연과 CSR 왕복 측정. 64-bit 포트([결과](reports/board_f2sdram_csr.md))와 128-bit 포트([결과](reports/perf_proposal.md)의 "4단계 사전 측정") 모두 BAD 0이다.
- 카드의 `.rbf`로 FPGA를 올리는 자동 부팅. FPGA 부팅에서만 `mem=768M`이다.
- NNUE 코어의 보드 실행. refresh corpus 100,000개와 탐색 trace 94,770개 평가에서 mismatch·error·fallback 0이다.
  - 처음 구조: 평균 177.1 µs, 같은 평가의 ARM 단독 124.2 µs 대비 **0.70배**([보고서](reports/board_nnue_core.md), 각 1회 실행).
  - 개선 1~6단계 뒤(카드의 이미지, 코어가 요청을 계획): 호스트 관측 35.86 µs, ARM 쪽 작업 포함 40.82 µs, ARM 단독 124.43 µs 대비 **3.05배**. warm-up 뒤 10회 A/B 교대 측정으로, BENCHMARK의 반복 조건을 채웠다([성능 개선 제안](reports/perf_proposal.md)).

| 단계 | 판정 | 근거 |
|---|---|---|
| M0 | 일부 완료. 도구·JTAG·UART·SD·FPGA 구성·HPS 부팅 확인, 보드 revision 미기록 | [M0 보고서](reports/M0_environment.md) |
| M1 | 통과 | [M1·M2 보고서](reports/M1_M2_baseline.md) |
| M2 | 통과 | [M1·M2 보고서](reports/M1_M2_baseline.md) |
| M3 | 측정 완료. ABI·자원과 보드 F2SDRAM·CSR 실측(64·128-bit)이 있다. 측정을 바탕으로 FC cache, read queue, 128-bit 포트를 넣었다 | [M3 보고서](reports/M3_resources.md), [F2SDRAM·CSR 측정](reports/board_f2sdram_csr.md), [성능 개선 제안](reports/perf_proposal.md) |
| M4 | 시뮬레이션 통과. 보드에서 refresh corpus 100,000개 통과 (stall·reset 시험은 보드 미실행) | [M4 보고서](reports/M4_rtl_simulation.md), [보드 실행](reports/board_nnue_core.md) |
| M5 | 시뮬레이션 통과. 보드에서 탐색 trace 94,770개 단일 context 통과. 다중 context·chaos는 보드 미실행, 공백 있음 | [M5 보고서](reports/M5_incremental.md), [보드 실행](reports/board_nnue_core.md) |
| M6 | 일부 진행. HPS 연결 보드(64·128-bit F2SDRAM), 가속기 top(`USE_NNUE`), 100 MHz timing closure, SD 자동 FPGA 적재, polling 방식 사용자 공간 harness, 온보드 pair·tensor 검증 통과. IRQ·kernel driver 미착수. U-Boot는 아직 `FPGAPORTRST` 0x111을 쓰고 128-bit 포트는 harness가 0x133으로 연다 | [보드 빌드](../hw/quartus/board/README.md), [보드 프로그램](../sw/board/README.md) |
| M7 | 통과. HW 강제 bench 노드 수 공식 값과 같음, fallback 0, 비교 모드 평가 951,268개 일치, UCI·thread 정책 정상. 단일 thread, `/dev/mem` 사용자 공간 | [M7 보고서](reports/M7_engine.md) |
| M8 | 미착수 | |

성능 개선 단계(자세한 것은 [성능 개선 제안](reports/perf_proposal.md)). 모두 보드에서 비트 일치로 통과했다. 탐색 trace 기준, 단위 µs.

| 단계 | 내용 | 호스트 관측 | 계획 포함 | ARM 단독 대비 (계획 포함) | 측정 |
|---|---|---:|---:|---:|---|
| 처음 | 기존 코어, `stack` 계획 | 177.8 | 196.3 | 0.63배 | 1회 |
| 1 | 가장 가까운 slot을 원천으로 고르는 요청 계획 | 119.9 | 144.3 | 0.86배 | 1회 |
| 2 | FC 가중치 칩 안 cache (bucket 2개) | 71.2 | 95.4 | 1.30배 | 1회 |
| 3 | 행·PSQT 읽기 queue | 63.05 | 85.23 | 1.46배 | 10회 |
| 4 | 128-bit F2SDRAM 포트와 datapath | 42.35 | 64.61 | 1.92배 | 10회 |
| 4+ | 요청 계획: 하한 순서 merge, 인코딩·signature 정리 (요청은 같음) | 42.34 | 59.77 | 2.08배 | 10회 |
| 5 | FC0·FC1 열을 한 cycle에, 비영 word만 scan, 활성화 pipeline | 32.85 | 50.49 | 2.46배 | 10회 |
| 6 | 요청 계획을 코어로 (PLAN 요청) | **35.86** | **40.82** | **3.05배** | 10회 |

- 이제 가장 큰 항목은 행 읽기(20.4 µs)이고, 다음이 ARM 요청 계획(17.4 µs)이다. 탐색 tree의 ply별 변경으로 차이를 만드는 방법은 재 보니 merge보다 느려 넣지 않았다.
- 엔진 전체(M7): 공식 bench 17,036 → 33,299 NPS, **1.95배**(하드웨어 계획, 10회 교대. 5단계 이미지 1.75배, 4단계 이미지 1.57배). ARM에는 특징 목록 생성(약 15 µs)과 요청 계획(약 16 µs)이 남았다.
- 특징 생성 줄이기, U-Boot의 `FPGAPORTRST` 0x133 반영, 다중 context용 FC cache entry 확대는 미착수다.
- 가속 대상 판단의 근거는 [보드 ARM 기준선](reports/board_a9_baseline.md)(실측), [F2SDRAM·CSR 측정](reports/board_f2sdram_csr.md)(실측)과 [ARM 프로파일](reports/profile_search.md)(에뮬레이터 측정과 추정)에 있다.

WSL·VS·Quartus가 있다는 사용자 환경을 전제로 한다. 실제 설치 버전·배포판·보드 접근은 M0에서 확인한다.

## 단계별 작업·완료 게이트

| 단계 | 작업·산출물 | 완료 기준 |
|---|---|---|
| M0 환경·보드 | WSL2, compiler(C++17/20), make, Python, Verilator/Icarus, ARM hard-float cross compiler, dtc, debootstrap/qemu-user-static 확인. Quartus Cyclone V 지원·라이선스, 보드 revision·JTAG/UART·SD 기록. 최소 LED/HPS reference 프로젝트 | 도구 버전 보고서와 보드 UART/JTAG 접근·간단한 FPGA 동작 확인 |
| M1 기준선 동결 | 공식 `scripts/net.sh` endpoint에서 기본 net 확보. SHA-256 prefix·전체 hash·크기·network header/hash 기록. CPU 엔진과 공식 호출 harness 빌드. 특징·레이어·타입·scale·연결 사양 추출 | 고정 commit/net로 CPU UCI smoke·bench 통과. 사양과 공식 소스 일치, hash 오류 거부 |
| M2 golden 검증 | 공식 Position/feature/Network 사용. 양 관점 특징·accumulator·PSQT·FT 출력·FC와 활성화·최종 pair 덤프. 직렬화 형식과 seed 고정 | 스칼라/지원 SIMD 결과 일치. refresh/incremental 결과 일치 |
| M3 자원·ABI | 패킹 후 가중치 크기·MAC 수·DDR traffic·context 크기 계산. F2SDRAM 측정 IP, CSR/descriptor/IRQ·DMA ownership·cache sync·timeout 명세. DSP/M10K·clock/CDC 예산 | 실제 장치 자원과 대역폭에 맞는 보고서. 부족하면 병렬도·타일·cache 조정, 정확도 유지 |
| M4 전체 refresh RTL | accumulator/PSQT→FT→FC0→두 활성화→FC1→두 활성화→concat/FC2→skip/scaling. 단위·전체 harness | 중간값과 최종 pair 모두 오차 0. 모든 bucket·관점·경계·stall/reset/error 통과 |
| M5 증분·문맥 | feature add/remove, threats/pawn-pairs, king refresh, make/unmake·null move·context 전환·cache 무효화. 실제 탐색 trace 재생 | 각 ply에서 refresh golden 일치, undo·반복·다중 context 상태 오염 0 |
| M6 보드 통합 | DE1-SoC top/pin/PLL/reset, Platform Designer 원본·handoff, memory master·CSR·IRQ, driver/runtime. Quartus fit/STA·rbf | 목표 clock timing closure, 제약 누락 확인. 실제 DDR·명령/완료·timeout·온보드 pair 검증 |
| M7 엔진 통합 | 원본 checkout은 보존하고 작은 patch series로 평가 경계 연결. CPU 강제/HW 강제/비교 모드·식별자·재시작·thread 정책 | HW 강제 corpus 완주, fallback 0, 최종 Eval 일치. UCI isready/position/go/stop/quit 정상 |
| M8 이미지·배포 | 아래 SD 파이프라인 완성. CPU 대비 latency/throughput·검색 NPS·DDR·자원·온도·전력 측정. 대응 소스·license bundle | 깨끗한 WSL에서 이미지 재생성, SD cold boot·온보드 회귀 통과. M3 성능 기준과 비교 |

M0 이후 Debian 부팅 기반 작업은 M1~M5와 독립적으로 진행한다. **FPGA 완성 전 CPU-only Stockfish 19를 Debian에서 부팅·실행**하고 M6부터 동일 boot chain/rootfs에 가속기를 통합한다. CPU-only 부팅은 중간 산출물이다.

## 비트 일치 검증

주 경계는 `Network::evaluate()`의 `(psqt, positional)` 정수 pair이며 허용 오차는 0이다. 최종 나눗셈 이전 중간값과 통합 후 `Eval::evaluate()`도 비교한다. FEN 최종 점수만으로 판정하지 않고 수순·관점·bucket·context·refresh 상태를 기록한다.

- 고정 corpus: 시작/중반/종반, 모든 piece-count bucket·양 차례, king 이동/미러·castling·en passant·promotion/underpromotion·check/pin·capture·pawn-pair 생성/소멸·threat 변화·null move·undo·반복.
- 최소 100,000개 평가 상태의 고정 seed 무작위 합법 수순과 검색 trace. RTL·보드에 같은 corpus 사용. 이는 초기 수락 기준이며 모든 입력의 수학적 증명을 뜻하지 않는다.
- 산술 단위시험: 부호·최소/최대·누산기 폭·clipping 경계·곱셈/shift·음수 나눗셈·concat/skip. 작은 입력 영역은 전수 검사, 넓은 영역은 경계·무작위 병행.
- 시스템 시험: DDR stall·backpressure·진행 중 reset·IRQ·timeout·queue wrap·context 교차 실행·잘못된 net/ABI 거부.
- 첫 불일치 시 net hash·trace·최초 다른 tensor/index·expected/actual·waveform 저장. 평균 오차나 CPU fallback으로 통과 처리하지 않는다.

## Debian 부팅 이미지 작업 패키지

목표 userland는 **Debian 13 trixie armhf**다. Debian의 armhf 지원과 DE1-SoC 전용 부팅 지원은 별도이므로 bootloader·kernel·DT·FPGA 통합을 실제 보드에서 검증한다.

1. **Boot chain**: Cyclone V Boot ROM→SPL/preloader→U-Boot→Linux zImage/DTB→Debian rootfs. SoC 지원이 확인된 U-Boot·kernel commit을 선정·고정한다. SPL은 동일 Quartus HPS handoff의 pinmux/DDR 설정에서 생성한다. FPGA load와 bridge enable 순서는 채택한 부트 방식에 맞게 명시한다.
2. **기초 부팅**: 새 reference 프로젝트로 UART·HPS DDR·SD/MMC·Ethernet을 확인한다. 이전 바이너리 DTB/프리로더 패치를 재사용하지 않는다. UART boot log와 U-Boot 환경을 보존한다.
3. **Kernel/DT**: Cyclone V·MMC·Ethernet·UART·FPGA manager/bridge·CMA/DMA·driver를 설정한다. IP 주소·IRQ·reserved memory는 실제 Platform Designer 결과와 맞춘다. Linux DMA API로 캐시 일관성을 처리한다. 정적 DT/overlay 중 검증한 방식을 고정한다.
4. **Rootfs**: WSL2 Linux filesystem에서 debootstrap `--arch=armhf`와 qemu-user-static을 사용한다. Debian package snapshot·패키지 목록을 고정한다. systemd/udev·네트워크·UART login·시간·진단 도구와 초기 계정/SSH 키 생성 정책을 설정한다.
5. **Stockfish 포함**: sf_19를 armv7-neon hard-float로 빌드해 `/usr/local/bin/stockfish`에 설치한다. compiler/sysroot/flags를 기록한다. C++17 본체와 C++20 universal 관련 target의 toolchain 요구를 구분한다. net를 `/usr/share/stockfish/`에 두고 EvalFile 경로를 명시한다. CPU-only/가속 실행 경로와 동일 net hash를 제공한다.
6. **가속 통합**: bitstream·driver·runtime·manifest·self-test 설치. FPGA 설정/bridge/driver 초기화 후 별도 oneshot self-test 서비스 실행. UCI 엔진은 stdin/stdout 프로세스로 유지한다. 실패가 정상 부팅·fallback에 가려지지 않도록 기록한다.
7. **이미지 생성**: 채택한 bootloader에 맞춰 raw boot/A2 영역·FAT boot·ext4 rootfs 위치/정렬/크기를 명세하고 겹침을 검사한다. boot에 zImage/DTB/rbf/script, rootfs에 엔진/net/driver를 배치한다. raw offset은 SPL 방식 확인 후 확정한다. SHA256SUMS·manifest를 생성한다.
8. **수락**: SD cold boot 반복·UART login·메모리·Ethernet·파일시스템·UCI/bench·FPGA 강제 corpus·전원 재투입 후 식별자 일치·복구 절차를 검증한다. QEMU userspace 실행만으로 보드 부팅을 완료 처리하지 않는다.

최종 산출물은 압축 SD 이미지와 SHA256SUMS, build manifest·boot log, kernel/U-Boot config/patch·DT, Quartus 원본과 handoff 재생성 절차, bitstream·driver·CPU/가속 Stockfish, net 식별자, 대응 소스·GPL 라이선스, 재빌드·SD 기록·복구 안내다.

## 유지보수·업데이트

master 자동 추적과 임의 최신 net를 금지한다. 다음 버전은 별도 lock/adapter로 feature·header/hash·타입/scale·refresh·graph 차이를 조사한다. 사양에서 JSON/SV/C++와 가중치를 재생성하고 CPU→단위 RTL→전체 RTL→보드→엔진→이미지 게이트를 다시 통과시킨다. 공통 MAC/DDR/CSR은 유지하고 버전 의존 특징·graph·패커·patch를 교체한다. 새 연산은 명시적으로 RTL을 확장한다.

최적화는 정확성 회귀 이후 진행한다. NPU latency 향상이 전체 검색 속도를 보장하지 않으므로 NPS와 DDR 비용도 측정한다. 물리 보드·SD·UART/JTAG가 실제로 연결되지 않은 단계는 완료로 표시하지 않는다.

## 공식 근거

- [Stockfish 19 릴리스](https://github.com/official-stockfish/Stockfish/releases/tag/sf_19): SFNNv16, pawn-pair 추가, small net 제거.
- [고정 소스](https://github.com/official-stockfish/Stockfish/tree/edb0d9db6731067ec50ce619ff372b463bc4dd5d): 구조·정수 연산·평가 경계·빌드 대상.
- [Terasic DE1-SoC 자료](https://www.terasic.com.tw/cgi-bin/page/archive.pl?Language=English&No=836): revision별 핀·메모리·reference는 M0에서 확보·검증한다.
- [Debian trixie armhf 설치 가이드](https://www.debian.org/releases/trixie/armhf/): ARMv7 hard-float userland 기준. 보드 전용 이미지는 별도 구축한다.
