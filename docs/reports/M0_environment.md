# M0 환경 보고서

수집일: 2026-11-05. **상태: 일부 완료.** 도구 확인은 끝났지만 보드 확인이 남아 있어 게이트는 미통과다.

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

## 미확인·미비치 항목

- **보드:** Windows 장치 목록과 `quartus_pgm -l`에서 USB-Blaster나 UART 어댑터가 보이지 않았다. 보드 revision, JTAG, UART, SD 접근은 미확인이다. 물리 연결이 필요하다.
- **debootstrap과 qemu 연동:** 미시험. Ubuntu 26.04에서 `qemu-user-static`은 가상 패키지이며 이미 설치된 `qemu-user-binfmt`가 제공하므로 추가 설치는 필요 없다. `/usr/bin/qemu-arm`은 static-pie이고 binfmt가 `POF` flag로 등록되어 있으며, ARM 바이너리 직접 실행을 확인했다. 실제 armhf rootfs 생성은 M8에서 확인한다.
- **Terasic reference 프로젝트:** 미확보. LED/HPS 최소 프로젝트는 보드가 연결된 뒤 진행한다.
