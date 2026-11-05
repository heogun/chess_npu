# HPS 연결 측정 보드

목적: M6의 출발점으로, 실제 DE1-SoC에서 FPGA→SDRAM(F2SDRAM) 대역폭·지연과 경량 HPS→FPGA 브리지의 CSR 왕복 지연을 잰다. 가속기가 아니라 측정용 구성이다. FC 온칩 등 가속 설계는 이 측정 뒤에 정한다.

**현재 상태: 보드에서 측정 완료(2026-11-06).** 정확성 BAD 0, 결과는 [`docs/reports/board_f2sdram_csr.md`](../../../docs/reports/board_f2sdram_csr.md). 요약: CSR 읽기 왕복 290 ns, F2SDRAM은 이 구성의 상한인 800 MB/s(64비트 × 100 MHz)에 도달, 요청 1개 첫 beat 지연 약 135 ns, 8 byte 무작위 읽기는 445 MB/s에서 멈춘다.

| 단계 | 상태 |
|---|---|
| 참조 qsys에서 HPS 파라미터 추출 | 완료 (`hps_params.tcl`, 198개, 미적용 0개) |
| Platform Designer 시스템 생성 | 완료. 오류 0, 22 모듈 |
| 측정 블록 `mem_probe.sv` | Verilator PASS (지연 통계는 모델과 정확히 일치까지 검사) |
| 보드 top, Quartus 프로젝트 | 작성. 전체 컴파일 오류 0 |
| 타이밍 | 모든 corner 통과 (아래 "컴파일 결과") |
| handoff 확인 | 완료. `F2SDRAM_RESET_PORT_USED = 0x111` |
| U-Boot `FPGAPORTRST` 수정, 카드 쓰기 | 완료. 보드에서 `bridge enable` 후 `FPGAPORTRST` = 0x111 확인 |
| 호스트 측정 프로그램, 보드 측정 | 완료. 2회 실행, 모든 지점 BAD 0 |

## 파일

- [`build.ps1`](build.ps1): 전체 흐름. `qsys-script` → `qsys-generate` → 프로젝트 생성 → Analysis & Synthesis → 생성된 `hps_sdram_p0_pin_assignments.tcl`을 `quartus_sta -t`로 적용 → 전체 컴파일. `-From map` 등으로 중간부터 다시 돌 수 있다. 로그는 `build/board/logs/`. 순서는 HPS SDRAM 설계의 표준 흐름(합성 뒤 핀 스크립트, 그 뒤 컴파일; Rocketboards GSRD/참조 Makefile)과 같다.
- [`project.tcl`](project.tcl): `build/board/quartus/board.qpf`를 만든다. 전역 설정과 HPS 주변 핀의 `3.3-V LVTTL`은 참조 `.qsf`에서 왔다. HPS 핀에는 위치를 주지 않는다(참조도 주지 않는다). DDR3 핀 설정은 생성된 핀 스크립트가 넣는다.
- [`board.sdc`](board.sdc): CLOCK_50, `derive_pll_clocks`. HPS SDRAM·HPS I/O 제약은 `soc.qip`에 딸린 `.sdc`가 넣는다.
- [`extract_hps_params.py`](extract_hps_params.py): 참조 프로젝트 `DE1_SOC_Linux_FB`(VCTLabs, U-Boot `README.socfpga`가 인용)의 `.qsys`에서 HPS 핀 먹스, 클럭, DDR3 파라미터를 뽑아 `hps_params.tcl`을 만든다. 참조 프로젝트는 저장소 밖 WSL `~/chess_npu_build/ref/DE1_SOC_Linux_FB`에 있다.
- [`hps_params.tcl`](hps_params.tcl): 생성물. `GPIO_Enable`, `LOANIO_Enable`은 쉼표 문자열로 저장되어 있고 `soc.tcl`이 목록으로 바꿔 넘긴다.
- [`soc.tcl`](soc.tcl): `qsys-script`용. 구성:
  - `clk_0` 50 MHz → `pll_0` 100 MHz (locked 출력)
  - `hps_0` (`altera_hps`): 위 파라미터 + FPGA 부팅 끔, F2S/S2F AXI 브리지 끔, 경량 H2F 켬, F2SDRAM 포트 0을 64비트 Avalon-MM 양방향으로
  - `csr_bridge` (`altera_avalon_mm_bridge`, 32비트, 12비트 바이트 주소): 경량 H2F 마스터의 0x0에 연결
  - 내보내기: `clk`, `reset`, `clk_100`, `pll_locked`, `hps_reset`, `memory`, `hps_io`, `csr`(마스터), `sdram`(슬레이브)
- `soc.qsys`, `soc.sopcinfo`: 생성물.
- [`../../rtl/board/board_top.sv`](../../rtl/board/board_top.sv): HPS 포트와 연결은 참조 `DE1_SOC_Linux_FB.v`를 따른다(`hps_io` 포트 55개 이름이 참조와 같음을 비교로 확인). 시스템 리셋은 참조처럼 `h2f_reset`을 되돌려 쓴다. `mem_probe` 리셋은 `h2f_reset`과 `pll_locked`의 AND를 `clk_100`에 동기 해제한다. LEDR0 = PLL locked, LEDR9 = 약 0.75 Hz 깜빡임(리셋이 풀렸다는 표시).
- [`../../rtl/board/mem_probe.sv`](../../rtl/board/mem_probe.sv): 측정 마스터. CSR 맵은 파일 머리 주석에 있다. `ADDR_W = 29`(64비트 워드 주소, `sdram_address[28:0]`과 일치), `BURST_W = 8`. 읽기 beat의 검증과 지연 통계는 4단 파이프라인이고, `done`은 파이프라인이 비워진 뒤 1이 된다. STATUS bit0(busy)는 비우는 동안에도 1이다.
- [`../../rtl/tb/tb_mem_probe.cpp`](../../rtl/tb/tb_mem_probe.cpp): 무작위 대기와 읽기 지연을 넣은 메모리 모델. burst 1/4/8/16 × 동시 요청 1/2/8/32 × 순차/무작위 읽기의 32조합과 추가 2회에서 개수, 쓰기 패턴, 검증을 보고, **지연 합·최소·최대와 히스토그램 64칸 전부를 모델이 계산한 값과 정확히 비교한다**(명령 수락 edge부터 첫 beat를 받는 edge까지). 지연을 1 늘린 변형은 34회 모두 세 검사에서 실패한다. 1비트를 뒤집으면 개수와 주소를 정확히 찾는다.

## 실행 방법

Quartus Lite 25.1std (`C:\altera_lite\25.1std\quartus`) 기준:

```powershell
powershell -ExecutionPolicy Bypass -File hw\quartus\board\build.ps1
```

결과: `build/board/quartus/board.sof`, 보고서 `board.sta.rpt`, `board.fit.rpt`, handoff `build/board/quartus/hps_isw_handoff/soc_hps_0/`.

시뮬레이션(WSL Ubuntu, Verilator 5.032):

```bash
verilator --cc --exe --build -Wall -Wno-fatal --top-module mem_probe hw/rtl/board/mem_probe.sv hw/rtl/tb/tb_mem_probe.cpp -o tb && ./obj_dir/tb
```

## 컴파일 결과 (2026-11-06, Quartus Lite 25.1std)

- 전체 컴파일 오류 0. ALM 2,887 / 32,070 (9 %), 레지스터 4,325, 블록 메모리 1,952비트, 핀 138.
- 타이밍(모든 corner, TNS 0):
  - `clk_100`(PLL 출력): setup +2.045 ns, hold +0.137 ns
  - HPS SDRAM `afi_clk`: setup +1.727 ns, hold +0.077 ns
- UniPHY "Report DDR"(`hps_sdram_p0_report_timing.tcl`, Slow 1100mV 85C), setup/hold ns: Address Command 0.600/0.583, Core 1.730/0.143, Core Recovery/Removal 3.375/0.470, DQS vs CK 0.657/0.274, Postamble 0.489/0.489, Read Capture 0.234/0.187, Write 0.243/0.243. 로그 `build/board/logs/report_ddr.log`. 이 margin은 Quartus 쪽 HPS 파라미터 기준이다. 실제 DDR 타이밍 레지스터는 SPL(qts)이 넣는다(아래 "주의").
- Critical Warning 2건은 HPS DDR3 72핀(RZQ 포함)에 위치 지정이 없다는 것이다. HPS 전용 핀이라 fitter가 고정 위치에 둔다. 배치 결과 72핀 전부가 Terasic DE1-SoC User Manual rev F(2019-01-28) Table 3-27과 같다.
- 첫 컴파일에서는 `clk_100`이 setup −4.81 ns(TNS −7967 ns)였다. 원인은 첫 읽기 beat에서 FIFO RAM 읽기 → 32비트 빼기 → 히스토그램 칸 선택 → 32비트 증가가 한 사이클에 몰린 것이었다. 파이프라인으로 나눠 해결했다.
- Quartus Standard는 `ADDR_W'(x)`처럼 파라미터 폭으로 cast하는 것과 typedef cast를 받지 않았다(Error 10170). 0으로 확장한 wire로 바꿨다.

## U-Boot와 F2SDRAM 포트 (소스로 확인)

U-Boot 2026.07(`~/chess_npu_build/boot/u-boot`) 기준:

- SPL `drivers/ddr/altera/sdram_gen5.c`가 `CFG_HPS_SDR_CTRLCFG_FPGAPORTRST`를 `SYSMGR.ISWGRP.HANDOFF3`에 저장한다.
- U-Boot `arch_early_init_r()`(`arch/arm/mach-socfpga/misc_gen5.c`)가 HANDOFF 레지스터를 셸 시작 전에 캐시한다. `bridge enable`(`do_bridge_reset`)은 캐시된 HANDOFF3가 0이 아닐 때만 `fpgaport_rst`에 쓰고 staticcfg를 적용한다. 따라서 **U-Boot 셸에서 HANDOFF3를 `mw`로 바꿔도 효과가 없고, SPL 설정을 바꿔 다시 빌드해야 한다.**
- DE1-SoC qts `board/terasic/de1-soc/qts/sdram_config.h`의 값은 `0x0`이다.
- U-Boot의 `tools/cv_bsp_generator/emif.py`는 이 값을 handoff `hps.xml`의 `F2SDRAM_RESET_PORT_USED`로 정한다. 이 설계의 handoff 값은 **`0x111`**이다(`F2SDRAM_COMMAND/READ/WRITE_PORT_USED`는 각 `0x1`).

## 보드 실행 절차 (2026-11-06에 실제로 쓴 것)

1. **SPL/U-Boot**: [`tools/build-boot.sh uboot`](../../../tools/build-boot.sh)이 [`linux/uboot-de1soc-fpgaportrst.patch`](../../../linux/uboot-de1soc-fpgaportrst.patch)(`FPGAPORTRST` 0x0 → 0x111)를 적용해 빌드한다. 다른 qts 값은 그대로다. SPL은 FPGA가 이미 설정된 경우에만 이 값을 컨트롤러에 쓰므로 CPU 전용 부팅은 바뀌지 않는다(같은 카드로 Debian 자동 부팅 확인).
2. **카드**: 카드 앞 17 MiB(MBR + A2)만 [`tools/write-sd.ps1`](../../../tools/write-sd.ps1)로 쓴다. rootfs는 그대로 둔다.
3. **FPGA 적재**: U-Boot 자동 부팅을 멈춘 뒤(지연 2초) PC에서
   `quartus_pgm -c "DE-SoC [USB-1]" -m JTAG -o "p;build/board/quartus/board.sof@2"`.
   JTAG는 MSEL(SW10)과 무관하다. 카드에서 `fpga load`로 올리려면 Terasic 매뉴얼상 MSEL을 00000으로 바꿔야 하며, 이 경로는 시험하지 않았다.
4. **U-Boot**: `bridge enable`. 포트 리셋 해제는 U-Boot만 한다. 확인: `md.l 0xffc25080 1` → 0x111, `md.l 0xff200000 1` → 0x4d505231.
5. **Linux**: extlinux를 바꾸지 않고 U-Boot에서 직접 부팅한다.
   `load mmc 0:2 ${kernel_addr_r} /boot/zImage; load mmc 0:2 ${fdt_addr_r} /boot/socfpga_cyclone5_de1_soc.dtb; setenv bootargs console=ttyS0,115200 root=/dev/mmcblk0p2 rw rootwait mem=768M; bootz ${kernel_addr_r} - ${fdt_addr_r}`
6. **측정**: [`sw/board/probe.c`](../../../sw/board/probe.c)를 정적 링크로 빌드해 [`tools/serial-put.ps1`](../../../tools/serial-put.ps1)로 올린 뒤 `/root/probe all`. 프로그램은 Linux RAM이 측정 창(0x30000000–0x3FFFFFFF)과 겹치면 실행을 거부하고, BAD가 0이 아니면 속도를 보고하지 않는다.

## 남은 경고 (확인함, 조치 안 함)

- `qsys-script` 시작 시 `ERROR: Device family can not be determined` 3회. 그 뒤 모든 파라미터가 적용되고 생성도 오류 0으로 끝난다. 원인은 확인하지 않았다.
- `pll_0.outclk0`, `hps_0.h2f_reset`을 연결과 내보내기에 동시에 쓴다는 경고. 생성된 `soc.v`에서 두 신호는 내부 연결과 포트(`clk_100_clk`, `hps_reset_reset_n`) 모두에 이어져 있다.
- `h2f_mpu_events`를 내보내라는 경고, HPS 사용자 클럭 97.37 MHz, QSPI 370 MHz 근사 경고. 측정에 쓰지 않는 신호다.

## 주의

- DDR3 설정은 여전히 U-Boot qts에서 온다. qts는 CL7/CWL7/TRFC 120이고 참조 qsys는 CL11/WTCL8/TRFC 350 등이다. 측정에는 이미 부팅이 확인된 SPL을 쓰고, DDR handoff 교체는 뒤로 미룬다.
- 측정값은 이 구성(64비트 포트 하나, 100 MHz)의 결과다. 다른 폭이나 포트 수에는 일반화하지 않는다.
