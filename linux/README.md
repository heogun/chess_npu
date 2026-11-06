Debian armhf rootfs, U-Boot/SPL, kernel/DT, SD 이미지 생성 레시피.

상태: 보드에서 부팅한다(2026-11-06). [보드 ARM 기준선](../docs/reports/board_a9_baseline.md) 참조.
- **FPGA 적재:** U-Boot가 rootfs의 `/boot/fpga/board.rbf`를 찾아 FPGA에 올리고 `bridge enable` 뒤 `mem=768M`으로 부팅한다. 파일이 없거나 적재에 실패하면 1 GiB를 다 쓰는 CPU 전용 부팅이다([`uboot.fragment`](uboot.fragment), 자세한 것은 [보드 빌드](../hw/quartus/board/README.md)의 "자동 부팅").
- **F2SDRAM 포트:** [`uboot-de1soc-fpgaportrst.patch`](uboot-de1soc-fpgaportrst.patch)가 `FPGAPORTRST`를 0x111(64-bit 포트)로 둔다. 지금 카드의 128-bit 이미지는 0x133이 필요하며, 보드 프로그램이 실행 시에 쓴다. patch 값은 아직 바꾸지 않았다.
- **아직 아닌 것:** DDR3와 핀 설정은 이 프로젝트의 Quartus handoff가 아니라 U-Boot 저장소의 qts 값이다. 가속기용 kernel driver, DT의 FPGA 노드, reserved memory 대신 `mem=768M`을 쓰는 점은 M6 남은 일이다.

```bash
tools/build-boot.sh
tools/build-rootfs.sh
tools/make-sd-image.sh
```

카드 기록은 Windows 관리자 권한으로 [`tools/write-sd.ps1`](../tools/write-sd.ps1)을 쓴다. 디스크 번호와 정확한 크기를 함께 지정해야 하며, `-Confirmed` 없이는 점검만 한다. 이미 부팅되는 카드의 rootfs에 파일만 넣을 때는 [`tools/sd-partition.ps1`](../tools/sd-partition.ps1)로 ext4 파티션을 이미지로 읽고, WSL의 `debugfs`로 고친 뒤 다시 쓴다(WSL은 USB 카드 리더를 붙이지 못한다).
