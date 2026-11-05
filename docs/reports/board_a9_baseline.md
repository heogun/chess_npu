# 보드 ARM 단독 기준선

수행일: 2026-11-06. **실제 DE1-SoC의 Cortex-A9 측정이다.** FPGA는 쓰지 않았다. ARM+FPGA 비교와 F2SDRAM, CSR 측정은 아직 하지 않았다.

## 결과

| 항목 | 측정값 | 근거 |
|---|---:|---|
| 공식 bench 노드 수 (depth 13) | **2,497,913, 공식값과 일치** | 측정 실행 5회 모두 일치 |
| 속도 | 17,133 / 17,062 / 17,105 NPS | 샘플링 없는 3회 |
| 탐색 시간 | 145.8 / 146.4 / 146.0 s | 위와 같음 |
| CPU 클럭 | **797 MHz** (cycles ÷ task-clock) | `perf stat` |
| IPC | **0.40** (CPI 2.48) | 1.194e11 cycles, 4.814e10 instructions |
| L1D load miss | 2.69e9 (55.8 / 1000 명령어) | `perf stat` |
| L1I load miss | 4.65e8 (9.6 / 1000 명령어) | `perf stat` |
| dTLB load miss | 3.35e8 (7.0 / 1000 명령어) | `perf stat` |
| 분기 예측 실패 | 3.65e8 (7.6 / 1000 명령어) | `perf stat` |

엔진은 공식 `sf_19` `armv7-neon` 정적 빌드다. 보드 파일의 SHA-256을 확인했다.

- net: `1a298aa5...2dfc2`, `config/stockfish.lock.json`과 일치
- 엔진: `c1658321...ae16e6`, 빌드 산출물과 일치

## 시간 비중

`perf record -e cpu-clock -F 1999`로 샘플링했다. stockfish 내부 표본은 309,523개이고, depth 1 실행(6,169개)을 주소별로 뺐다. kernel 표본 1,873개는 제외했다. 샘플링 중에도 노드 수가 일치했다. `.text`가 같은 `-g` 빌드의 DWARF로 [`profile_classify.py`](../../tools/profile_classify.py)가 분류했다.

평가당 시간은 `비중 × 146.1 s ÷ 951,268 평가`로 계산한 **평균**이다. 평가 수는 x86 공식 실행의 trace에서 얻었고 노드 수가 같으므로 같은 탐색으로 본다. 호출별로 잰 값이 아니어서 median, p95, p99는 아직 없다.

| 구성요소 | 시간 비중 | 평가당 평균 | 이전 추정 (중간) |
|---|---:|---:|---:|
| 누산기 | 46.4% | 71 µs | 53.4%, 102 µs |
| FC 층 | 28.1% | 43 µs | 27.0%, 50 µs |
| FT 출력 | 3.0% | 5 µs | 1.7% |
| 특징 인덱스 | 2.3% | 4 µs | 1.8% |
| **NNUE 합계** | **79.7%** | **122 µs** | 84.0%, 155 µs |
| 탐색 본체 | 4.4% | | 3.4% |
| 수 생성 | 2.8% | | 2.0% |
| Threat 갱신 | 2.4% | | 1.9% |
| `do_move` / `undo_move` | 2.3% | | 1.8% |

NNUE 시간이 0이 되어도 전체 속도 향상 상한은 **4.94배**다. Threat 관련 작업은 4.7%로 상한 1.05배이며, 앞선 판단대로 오프로드 후보에서 제외한다.

### 이전 프로파일과의 차이

[에뮬레이터 프로파일](profile_search.md)의 결론은 유지되지만 가정이 틀렸다.

- 클럭은 925 MHz가 아니라 797 MHz다.
- CPI는 가정한 1.0~1.6보다 큰 2.48이다.
- NNUE 비중 79.7%는 추정 범위 82.6~84.8%보다 낮다. 명령어 비중 75.4%와 그 범위 사이에 있다.
- 평가당 122 µs는 추정 범위 90~229 µs 안에 있다.

## 현재 RTL과의 관계

지연 없는 메모리를 가정한 100 MHz RTL 시뮬레이션의 탐색 trace 중앙값은 82 µs다. ARM의 122 µs는 평균이므로 직접 비교할 수 없다. FPGA 값에는 실제 DDR, 통신, 동기화가 빠져 있다. **ARM+FPGA 가속비는 아직 측정되지 않았다.**

## 부팅

전원만 켜면 SD 카드에서 Boot ROM → SPL → U-Boot → Linux → Debian 13 armhf까지 자동으로 부팅되고, UART root 로그인이 된다. JTAG와 키 입력은 필요 없다. 이 콜드 부팅은 1회 확인했으며 `systemctl is-system-running`은 `running`, 실패한 서비스는 없었다. M8의 반복 콜드 부팅 수락 시험은 아직 하지 않았다. [자동 부팅 로그](logs/autoboot.txt), [수동 첫 부팅 U-Boot 로그](logs/first_boot_uboot.txt), [수동 첫 부팅 세션 로그](logs/first_boot_session.txt).

| 구성 요소 | 내용 |
|---|---|
| U-Boot, Linux, Debian | [`config/boot.lock.json`](../../config/boot.lock.json) |
| 카드 | 7.37 GiB SDHC, MBR, `A2` 1 MiB부터, ext4 root 17 MiB부터 |
| DDR3, 핀 설정 | U-Boot의 `board/terasic/de1-soc/qts`. 이 프로젝트의 Quartus handoff가 **아니다** |
| 디바이스 트리 | [`linux/socfpga_cyclone5_de1_soc.dts`](../../linux/socfpga_cyclone5_de1_soc.dts). de0-nano 기반 |

### 처음 실패한 원인

원인은 하드웨어가 아니라 U-Boot 설정이었다.

1. 업스트림 `socfpga_de1_soc_defconfig`는 U-Boot를 절대 섹터 `0x200`에서 찾는다. `A2`를 섹터 `0x800`에 둔 이 카드에서는 `0xa00`이어야 한다.
2. 파티션 방식으로 바꾸려 한 첫 수정은 틀렸다. `SECTOR`는 `USE_SECTOR`에 의존해서 값이 버려졌고, SPL은 `A2` 시작점의 SPL 자신을 읽었다. 로그에 찍히는 `-38`은 파일시스템 대체 경로의 값이고, 실제 오류는 `-22`였다.
3. 같은 defconfig는 `bootcmd`를 비워 두어 U-Boot가 프롬프트에서 멈춘다.

빌드 스크립트가 이제 `.config`의 `0xa00`, `bootcmd`와 이미지 안의 U-Boot 헤더 위치를 검사한다.

### 진단 도구

[`hps_jtag_read.tcl`](../../tools/hps_jtag_read.tcl), [`hps_jtag_cpu.tcl`](../../tools/hps_jtag_cpu.tcl), [`hps_jtag_run_spl.tcl`](../../tools/hps_jtag_run_spl.tcl)은 Quartus 저수준 JTAG로 ARM 디버그 포트를 직접 다룬다. 레지스터 읽기, CPU 상태 확인, OCRAM에 SPL을 올려 실행하는 데 쓴다. 다만 카드의 SPL이 이미 카드를 초기화한 뒤 JTAG로 SPL을 올리면 `Card did not respond` 오류가 났으므로, 이 조합의 SD 오류는 판단 근거로 쓰지 않는다.

## 한계

- 샘플링은 `cpu-clock` 기반이다. `cycles` 샘플링은 표본이 나오지 않았고 원인은 조사하지 않았다.
- 온도, 반복 간 변동, A/B 교대를 [BENCHMARK](../BENCHMARK.md) 기준으로 하지 않았다. 샘플링 없는 실행은 3회다.
- 첫 전원 투입 때 UART가 0바이트였던 이유와 그때 리셋에 반응이 없던 이유는 확인하지 못했다.
- 고장으로 판단한 첫 카드는 검증되지 않았다. 내용이 이 보드의 OCRAM 값과 약 95% 비트까지 같은데, 그 이유를 설명하지 못한다.
- Terasic 사용 설명서는 인증서 오류로 읽지 못했다. LED 핀과 디바이스 트리를 그 문서와 대조하지 않았다.
- Ethernet은 링크가 없고 MAC 주소가 설정되지 않아 동작을 확인하지 못했다.
