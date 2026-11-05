# M0 환경 보고서

수집일: 2026-11-05~06. **상태: 일부 완료.** 도구, JTAG, UART, SD, FPGA 구성, HPS 부팅을 보드에서 확인했다. 보드 revision 기록이 남아 있어 게이트는 미통과다.

## 도구 (실측 버전)

| 도구 | 위치 | 버전 |
|---|---|---|
| Linux | WSL2 | Ubuntu 26.04.1 LTS, kernel 6.18.54.1 |
| C++ | WSL | g++ 15.2.0 |
| make / Python | WSL | GNU Make 4.4.1 / Python 3.14.4 |
| 시뮬레이터 | WSL | Verilator 5.032, Icarus Verilog 12.0 |
| ARM cross compiler | WSL | arm-linux-gnueabihf-g++ 15.2.0 |
| ARM userspace 실행 | WSL | qemu-arm 10.2.1 (qemu-user) |
| dtc / debootstrap | WSL | DTC 1.7.2 / debootstrap 1.0.142ubuntu2 |
| FPGA 빌드 | Windows | Quartus Prime Lite 25.1std.0 Build 1129, Cyclone V device 설치됨 |

`C:\intelFPGA\20.1`에는 `embedded`와 `qprogrammer`만 있다. FPGA 빌드에는 25.1std를 사용한다.

## 보드 확인 (2026-11-05 실측)

| 항목 | 결과 | 근거 |
|---|---|---|
| JTAG 접근 | 통과 | `jtagconfig`: `DE-SoC [USB-1]`, `SOCVHPS` 4BA00477, `5CSE(BA5\|MA5)` 02D120DD |
| FPGA 구성 | 통과 | [`m0_blink`](../../hw/quartus/m0_blink/)를 `quartus_pgm`으로 SRAM에 로드, `Configuration succeeded`. timing 통과 |
| CLOCK_50 (PIN_AF14) | 동작 확인 | JTAG로 읽은 카운터 49.90~49.95 MHz. 기준이 PC 타이머라 정밀 측정은 아니다 |
| LED 핀 | 통과 | 0.17초 간격 패턴을 올린 뒤 사용자가 LED 모두 정상이라고 확인. 핀 번호를 Terasic 자료와 문서로 대조하지는 않았다 |
| UART (COM6, FT232 VID 0403 PID 6001) | 통과 | 115200 8N1로 부팅 로그 수신, root 셸에서 명령 실행 |
| HPS 부팅 | 통과 | 새 카드로 Debian 13까지 부팅. [보드 기준선](board_a9_baseline.md) |
| 기존 SD 카드 | **미확정** | PC 리더에서 읽기 전용으로 검사. 아래 참조 |

### 기존 SD 카드 검사

Apple 내장 리더(Windows Disk 1)에서 쓰기 없이 두 번 읽었다.

- 보고 용량이 127,139,840바이트(약 121 MB)다.
- 248,320개 섹터가 모두 같은 512바이트다. 앞 32바이트는 `55 AA` 반복이고 그 뒤는 무작위처럼 보인다.
- 유효한 MBR 서명, preloader 헤더, U-Boot, 커널, ext·FAT 파일시스템의 흔적이 없다.
- 두 번째 읽기는 첫 번째와 내용이 같았다. 첫 번째 사본의 끝 512개 섹터는 제 읽기 코드가 끝을 넘겨 0으로 채운 부분이라 비교에서 제외한다.

모든 주소에서 같은 값이 나오는 것은 카드 컨트롤러 고장의 증상일 수 있지만 확정하지 못했다. 이 리더로만 시험했고 표기 용량도 대조하지 않았다. 또한 이 내용은 이 보드의 OCRAM 값과 약 95% 비트까지 같은데, 그 이유를 설명하지 못한다.

## 미확인·미비치 항목

- **보드 revision:** JTAG로는 알 수 없다. 기판 표기 확인이 필요하다.
- **debootstrap과 qemu 연동:** 미시험. Ubuntu 26.04에서 `qemu-user-static`은 가상 패키지이며 이미 설치된 `qemu-user-binfmt`가 제공하므로 추가 설치는 필요 없다. `/usr/bin/qemu-arm`은 static-pie이고 binfmt가 `POF` flag로 등록되어 있으며, ARM 바이너리 직접 실행을 확인했다. 실제 armhf rootfs 생성은 M8에서 확인한다.
- **Terasic reference 프로젝트:** 미확보. LED/HPS 최소 프로젝트는 보드가 연결된 뒤 진행한다.
