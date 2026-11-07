Debian armhf rootfs, U-Boot/SPL, kernel/DT, SD 이미지 생성 레시피.

상태: 보드에서 부팅한다(2026-11-06). [보드 ARM 기준선](../docs/reports/board_a9_baseline.md) 참조. M8 이미지 결과는 [M8 보고서](../docs/reports/M8_image.md)에 있다.
- **FPGA 적재:** U-Boot가 rootfs의 `/boot/fpga/board.rbf`를 찾아 FPGA에 올리고 `bridge enable` 뒤 `mem=768M`으로 부팅한다. 파일이 없거나 적재에 실패하면 1 GiB를 다 쓰는 CPU 전용 부팅이다([`uboot.fragment`](uboot.fragment), 자세한 것은 [보드 빌드](../hw/quartus/board/README.md)의 "자동 부팅").
- **F2SDRAM 포트:** [`uboot-de1soc-fpgaportrst.patch`](uboot-de1soc-fpgaportrst.patch)가 `FPGAPORTRST`를 0x133(128-bit 포트 설계의 handoff 값)으로 둔다. SPL은 FPGA가 이미 구성되었을 때만 이 값을 쓴다.
- **아직 아닌 것:** DDR3와 핀 설정은 이 프로젝트의 Quartus handoff가 아니라 U-Boot 저장소의 qts 값이다. 가속기용 kernel driver, DT의 FPGA 노드, reserved memory 대신 `mem=768M`을 쓰는 점은 M6 남은 일이다.

## 한 번에 만들기 (M8)

Windows에서 Quartus 출력을 WSL로 넘긴 뒤, WSL에서 나머지를 모두 고정된 commit·hash로 만든다.

```powershell
powershell -ExecutionPolicy Bypass -File hw\quartus\board\build.ps1 -Design nnue -Width 128
powershell -ExecutionPolicy Bypass -File tools\export-rbf.ps1 -Distro <WSL 배포판>
```

```bash
RBF=~/chess_npu_build/release-inputs/board.rbf tools/build-release.sh
tools/make-source-bundle.sh ~/chess_npu_build/release/<image id> --debian
```

- 결과: `~/chess_npu_build/release/<image id>/`에 `de1soc.img.xz`, 압축 전 hash(`de1soc.img.sha256`), boot 파일, `board.rbf`와 출처(`board.rbf.json`), `manifest.json`, `SHA256SUMS`, `sources/`(프로젝트·Stockfish·U-Boot·Linux 소스와 license, `--debian`이면 Debian 소스 패키지 전부).
- `SOURCE_DATE_EPOCH`는 프로젝트 commit 시각이다. ext4 UUID·hash seed·시각도 고정이라 같은 입력이면 같은 이미지를 기대한다. 실제로 같았는지는 M8 보고서에 적는다.
- 깨끗한 WSL에 필요한 패키지: `build-essential g++-arm-linux-gnueabihf python3 git curl rsync bc bison flex libssl-dev libgnutls28-dev swig python3-dev python3-setuptools mmdebstrap debian-archive-keyring uidmap fakeroot e2fsprogs fdisk xz-utils qemu-user-binfmt`(armhf rootfs의 package 설정을 qemu로 실행).

## 이미지 안

| 경로 | 내용 |
|---|---|
| `/usr/local/bin/stockfish` | 공식 sf_19 armv7-neon (수정 없음, net 내장) |
| `/usr/local/bin/stockfish-fpga` | 같은 소스 + NNUE 코어 adapter. `SF_NNUE_MODE=cpu|hw|compare`, `SF_NNUE_PLANNER=hw` |
| `/usr/local/bin/{nnue_board,probe,arm_replay}` | 보드 harness, F2SDRAM 측정, ARM 단독 trace 재생 |
| `/usr/share/chess-npu/` | `weights.bin`, `regress/{stim.bin,search.ev,bench.ops}`, `manifest.json`, `SHA256SUMS` |
| `/usr/lib/chess-npu/selftest.sh` | 부팅마다 `chess-npu-selftest.service`가 실행. FPGA 적재, 파일 hash, refresh 2,000·증분 3,000개(tensor 비교), 엔진 비교 모드 depth 7. 결과는 console, `/run/chess-npu/selftest.status`, `/var/log/chess-npu/selftest.log`. 실패하면 unit이 failed가 되고 CPU로 대신하지 않는다 |
| `/usr/lib/chess-npu/regress.sh` | 전체 온보드 회귀(corpus 100,000, trace 94,770 두 planner, ARM 재생, bench 노드 수와 비교 모드, UCI) 뒤 10회 A/B 시간 측정. 약 1시간 |

## 카드 기록

Windows 관리자 권한으로 [`tools/write-sd.ps1`](../tools/write-sd.ps1)을 쓴다. 디스크 번호와 정확한 크기를 함께 지정해야 하며, `-Confirmed` 없이는 점검만 한다. 덮어쓰기 전 백업은 [`tools/read-sd.ps1`](../tools/read-sd.ps1)(사용 영역만, 두 번 읽어 비교)이다. 이미 부팅되는 카드의 rootfs에 파일만 넣을 때는 [`tools/sd-partition.ps1`](../tools/sd-partition.ps1)로 ext4 파티션을 이미지로 읽고, WSL의 `debugfs`로 고친 뒤 다시 쓴다(WSL은 USB 카드 리더를 붙이지 못한다).

복구: 백업 이미지를 `write-sd.ps1`로 다시 쓴다. CPU 전용으로 부팅하려면 rootfs의 `/boot/fpga/board.rbf`를 지우거나 이름을 바꾼다.

개별 단계(`tools/build-boot.sh`, `tools/build-rootfs.sh`, `tools/make-sd-image.sh`)는 `SOURCE_DATE_EPOCH`와 `RBF`를 요구한다. `CPU_ONLY=1`이면 이전 CPU 전용 이미지(`de1soc-cpu.img`)다.
