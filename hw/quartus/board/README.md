# HPS 연결 보드

목적: M6의 보드 설계. 같은 Platform Designer 시스템과 top에 두 가지 설계를 넣는다.
- **측정 설계** (`-Design probe`, `USE_NNUE=0`): FPGA→SDRAM(F2SDRAM) 대역폭·지연과 경량 HPS→FPGA 브리지의 CSR 왕복을 잰다.
- **NNUE 설계** (`-Design nnue`, `USE_NNUE=1`): `nnue_core`를 F2SDRAM master와 CSR slave에 연결한 가속기다.

각각 F2SDRAM 포트 폭 64-bit(기본)와 128-bit(`-Width 128`)로 만들 수 있다.

**현재 상태 (2026-11-07)**
- 카드의 `/boot/fpga/board.rbf`는 **NNUE 128-bit 하드웨어 계획 이미지**(`WIDE_FC = 1`, `HW_PLAN = 1`)다. 100 MHz, setup +0.573 ns, hold +0.155 ns(코어 clock, 최악 corner). ALM 15,223, M10K 291, DSP 68. `.rbf` SHA-256 `7c581145…07d2`. 보드에서 refresh corpus 100,000개와 탐색 trace 94,770개(`stack`, `nearest`, 하드웨어 계획)를 비트 일치로 통과했다([성능 개선 제안](../../../docs/reports/perf_proposal.md)의 "요청 계획 하드웨어 이전").
- 카드에 함께 둔 이전 이미지: `board_v5.rbf`(5단계, `ca527ec1…894d`), `board_v4.rbf`(4단계 128-bit, `90edaa9b…692f`), `board_v1~v3.rbf`(이전 64-bit NNUE 이미지), `probe.rbf`·`probe_w128.rbf`(측정 설계). 쓰려면 `board.rbf`로 이름을 바꿔 다시 부팅한다.
- 측정 설계 결과: 64-bit는 [`board_f2sdram_csr.md`](../../../docs/reports/board_f2sdram_csr.md)에 있다. CSR 읽기 왕복 290 ns, 800 MB/s(64비트 × 100 MHz 상한), 첫 beat 지연 약 135 ns, 8 byte 무작위 읽기 445 MB/s다. 128-bit는 순차 읽기 1,567 MB/s다(제안서의 "4단계 사전 측정").
- **128-bit 포트는 `fpgaportrst` 0x133이 필요하다.** U-Boot는 0x111을 쓰므로, 보드 프로그램(`nnue_board`, `probe --portrst 0x133`)이 Linux에서 실행 시에 쓴다([`sw/board`](../../../sw/board/README.md)).
- compile 뒤 map 보고서에서 경고 10030·10027을 확인한다. Quartus Standard가 반복문 안의 계산된 index를 잘못 elaborate해 128-bit 첫 이미지가 보드에서 실패한 적이 있다. 무해한 것은 `mac_value`(10030)와 `perf[stage]`(10027) 두 개다.

아래 표와 "컴파일 결과"는 처음 만든 64-bit 측정 설계의 기록이다.

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

- [`build.ps1`](build.ps1): 전체 흐름. `qsys-script` → `qsys-generate` → 프로젝트 생성 → Analysis & Synthesis → 생성된 `hps_sdram_p0_pin_assignments.tcl`을 `quartus_sta -t`로 적용 → 전체 컴파일. `-From map` 등으로 중간부터 다시 돌 수 있다. `-Design nnue`는 NNUE core, `-Width 128`은 128-bit F2SDRAM 포트(`w128/soc.qsys`, 출력 폴더 `_w128`)를 쓴다. 로그는 `build/board/logs/`. 순서는 HPS SDRAM 설계의 표준 흐름(합성 뒤 핀 스크립트, 그 뒤 컴파일; Rocketboards GSRD/참조 Makefile)과 같다.
- [`project.tcl`](project.tcl): `build/board/quartus/board.qpf`를 만든다. 전역 설정과 HPS 주변 핀의 `3.3-V LVTTL`은 참조 `.qsf`에서 왔다. HPS 핀에는 위치를 주지 않는다(참조도 주지 않는다). DDR3 핀 설정은 생성된 핀 스크립트가 넣는다.
- [`board.sdc`](board.sdc): CLOCK_50, `derive_pll_clocks`. HPS SDRAM·HPS I/O 제약은 `soc.qip`에 딸린 `.sdc`가 넣는다.
- [`extract_hps_params.py`](extract_hps_params.py): 참조 프로젝트 `DE1_SOC_Linux_FB`(VCTLabs, U-Boot `README.socfpga`가 인용)의 `.qsys`에서 HPS 핀 먹스, 클럭, DDR3 파라미터를 뽑아 `hps_params.tcl`을 만든다. 참조 프로젝트는 저장소 밖 WSL `~/chess_npu_build/ref/DE1_SOC_Linux_FB`에 있다.
- [`hps_params.tcl`](hps_params.tcl): 생성물. `GPIO_Enable`, `LOANIO_Enable`은 쉼표 문자열로 저장되어 있고 `soc.tcl`이 목록으로 바꿔 넘긴다.
- [`soc.tcl`](soc.tcl): `qsys-script`용. 구성:
  - `clk_0` 50 MHz → `pll_0` 100 MHz (locked 출력)
  - `hps_0` (`altera_hps`): 위 파라미터 + FPGA 부팅 끔, F2S/S2F AXI 브리지 끔, 경량 H2F 켬, F2SDRAM 포트 0을 64비트 Avalon-MM 양방향으로. `qsys-script --cmd="set width 128"`이면 128비트이고 `w128/soc.qsys`에 저장한다(handoff `F2SDRAM_RESET_PORT_USED = 0x133`)
  - `csr_bridge` (`altera_avalon_mm_bridge`, 32비트, 12비트 바이트 주소): 경량 H2F 마스터의 0x0에 연결
  - 내보내기: `clk`, `reset`, `clk_100`, `pll_locked`, `hps_reset`, `memory`, `hps_io`, `csr`(마스터), `sdram`(슬레이브)
- `soc.qsys`, `soc.sopcinfo`, `w128/soc.qsys`, `w128/soc.sopcinfo`: 생성물(64·128-bit).
- [`../../rtl/board/board_top.sv`](../../rtl/board/board_top.sv): HPS 포트와 연결은 참조 `DE1_SOC_Linux_FB.v`를 따른다(`hps_io` 포트 55개 이름이 참조와 같음을 비교로 확인). 시스템 리셋은 참조처럼 `h2f_reset`을 되돌려 쓴다. `mem_probe` 리셋은 `h2f_reset`과 `pll_locked`의 AND를 `clk_100`에 동기 해제한다. LEDR0 = PLL locked, LEDR9 = 약 0.75 Hz 깜빡임(리셋이 풀렸다는 표시).
- [`../../rtl/board/mem_probe.sv`](../../rtl/board/mem_probe.sv): 측정 마스터. CSR 맵은 파일 머리 주석에 있다. `ADDR_W = 29`(64비트 워드 주소, `sdram_address[28:0]`과 일치), `BURST_W = 8`. 읽기 beat의 검증과 지연 통계는 4단 파이프라인이고, `done`은 파이프라인이 비워진 뒤 1이 된다. STATUS bit0(busy)는 비우는 동안에도 1이다.
- [`../../rtl/tb/tb_mem_probe.cpp`](../../rtl/tb/tb_mem_probe.cpp): 무작위 대기와 읽기 지연을 넣은 메모리 모델. burst 1/4/8/16 × 동시 요청 1/2/8/32 × 순차/무작위 읽기의 32조합과 추가 2회에서 개수, 쓰기 패턴, 검증을 보고, **지연 합·최소·최대와 히스토그램 64칸 전부를 모델이 계산한 값과 정확히 비교한다**(명령 수락 edge부터 첫 beat를 받는 edge까지). 지연을 1 늘린 변형은 34회 모두 세 검사에서 실패한다. 1비트를 뒤집으면 개수와 주소를 정확히 찾는다.

## 실행 방법

Quartus Lite 25.1std (`C:\altera_lite\25.1std\quartus`) 기준:

```powershell
powershell -ExecutionPolicy Bypass -File hw\quartus\board\build.ps1
powershell -ExecutionPolicy Bypass -File hw\quartus\board\build.ps1 -Design nnue -Width 128
```

결과: `build/board/quartus/board.sof`, 보고서 `board.sta.rpt`, `board.fit.rpt`, handoff `build/board/quartus/hps_isw_handoff/soc_hps_0/`. NNUE 설계는 `build/board/quartus_nnue/`에, `-Width 128`이면 폴더 이름 끝에 `_w128`이 붙는다(예: `quartus_nnue_w128/`). `-From qsys|project|map|pins|compile|rbf`로 중간부터 다시 돈다. 지금 카드의 이미지는 두 번째 명령의 결과다.

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

## 자동 부팅 (카드의 `.rbf`, 2026-11-06 보드 확인)

전원만 켜면 된다. U-Boot `bootcmd`([`linux/uboot.fragment`](../../../linux/uboot.fragment))가 다음을 한다.

1. rootfs의 `/boot/fpga/board.rbf`를 읽어 `fpga load`. SW10(MSEL)은 00000(FPP ×16, 압축 없음)이어야 하고, 이 보드는 이미 00000이다(FPGA 매니저 STAT 0x4로 확인). `.rbf`는 `build.ps1`의 `rbf` 단계가 압축 없이 만든다(7,007,204 byte).
2. 성공하면 `bridge enable`과 `setenv fpga_bootargs mem=768M`.
3. `run distro_bootcmd`. `extlinux.conf`의 `append` 끝에 `${fpga_bootargs}`가 있어서, FPGA 부팅에서만 `mem=768M`이 붙는다. U-Boot가 `append`의 변수를 확장한다(`boot/pxe_utils.c`의 `cli_simple_process_macros`). 정의되지 않은 변수는 빈 문자열이 된다.

파일이 없거나 적재에 실패하면 그대로 CPU 전용 부팅이고 Linux는 1 GiB를 다 쓴다. **CPU 전용으로 부팅하려면 `/boot/fpga/board.rbf`의 이름을 바꾼다**(예: `board.rbf.off`). U-Boot 환경 저장(`saveenv`)은 쓰지 않는다. 환경 위치(0x4400)가 MBR 바로 뒤라서다.

보드 확인 결과:

| 경우 | U-Boot 출력 | Linux RAM | `probe verify` |
|---|---|---|---|
| `.rbf` 있음 | `FPGA loaded, bridges enabled, mem=768M` | 0x00000000–0x2FFFFFFF | PASS (BAD 0) |
| `.rbf` 없음 | `No FPGA image, CPU-only boot` | 0x00000000–0x3FFFFFFF (1 GiB) | 실행 거부 |

웜 리부트에서는 FPGA가 이전 부팅의 구성을 유지한다(STAT mode 4). 이때도 U-Boot가 브리지를 리셋 상태로 두고 측정 블록은 시작되지 않는다. FPGA가 비어 있는 CPU 전용 상태가 필요하면 전원을 껐다 켠다.

새 카드는 [`tools/make-sd-image.sh`](../../../tools/make-sd-image.sh)가 `${fpga_bootargs}`를 넣고, `build/.../boot/out/board.rbf`가 있으면 `/boot/fpga/`에 복사한다. 이 스크립트 변경으로 이미지를 다시 만들어 보지는 않았다. 지금 카드는 보드 위 Linux에서 `extlinux.conf`를 고치고(원본 `extlinux.conf.cpu-only`) `.rbf`를 올린 뒤, A2에 새 U-Boot를 쓰고 다시 읽어 확인했다.

## 수동 절차 (JTAG, 첫 측정 때 쓴 것)

1. **SPL/U-Boot**: [`tools/build-boot.sh uboot`](../../../tools/build-boot.sh)이 [`linux/uboot-de1soc-fpgaportrst.patch`](../../../linux/uboot-de1soc-fpgaportrst.patch)(`FPGAPORTRST` 0x0 → 0x111)를 적용해 빌드한다. 다른 qts 값은 그대로다. SPL은 FPGA가 이미 설정된 경우에만 이 값을 컨트롤러에 쓰므로 CPU 전용 부팅은 바뀌지 않는다(같은 카드로 Debian 자동 부팅 확인).
2. **카드**: 카드 앞 17 MiB(MBR + A2)만 [`tools/write-sd.ps1`](../../../tools/write-sd.ps1)로 쓴다. rootfs는 그대로 둔다.
3. **FPGA 적재**: U-Boot 자동 부팅을 멈춘 뒤(지연 2초) PC에서
   `quartus_pgm -c "DE-SoC [USB-1]" -m JTAG -o "p;build/board/quartus/board.sof@2"`.
   JTAG는 MSEL(SW10)과 무관하다. 카드의 `.rbf`로 올리는 경로는 위 "자동 부팅"을 본다.
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
- 위 "컴파일 결과"와 첫 측정값은 64비트 포트 하나, 100 MHz 구성의 결과다. 128비트 포트는 따로 쟀다(제안서의 "4단계 사전 측정"). 포트 수를 늘린 구성은 재지 않았다.
