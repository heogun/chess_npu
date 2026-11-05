Debian armhf rootfs, U-Boot/SPL, kernel/DT, SD 이미지 생성 레시피.

상태: CPU 단독 이미지가 보드에서 부팅된다. [보드 ARM 기준선](../docs/reports/board_a9_baseline.md) 참조. FPGA 통합은 아직 없고, DDR3와 핀 설정은 이 프로젝트의 Quartus handoff가 아니라 U-Boot 저장소의 값이다.

```bash
tools/build-boot.sh
tools/build-rootfs.sh
tools/make-sd-image.sh
```

카드 기록은 Windows 관리자 권한으로 [`tools/write-sd.ps1`](../tools/write-sd.ps1)을 쓴다. 디스크 번호와 정확한 크기를 함께 지정해야 하며, `-Confirmed` 없이는 점검만 한다.
