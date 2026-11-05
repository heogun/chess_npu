#!/usr/bin/env bash
# Assembles the CPU-only SD image from build-boot.sh and build-rootfs.sh outputs, without root.
#
#   sector 0        MBR
#   1 MiB, 16 MiB   type a2, raw u-boot-with-spl.sfp, found by the Boot ROM
#   17 MiB, 3 GiB   ext4 root, bootable flag, holds /boot/extlinux/extlinux.conf for U-Boot
#
# There is no FAT partition yet: FAT files could not be written without mtools, and U-Boot reads
# ext4. Output: $BUILD_ROOT/boot/out/de1soc-cpu.img and its SHA-256.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

BOOT="$BUILD_ROOT/boot"
OUT="$BOOT/out"
IMG="$OUT/de1soc-cpu.img"
WORK="$BOOT/image-work"
A2_START=2048 A2_SECTORS=32768
ROOT_START=34816 ROOT_SECTORS=$((3 * 1024 * 1024 * 2))
TOTAL=$((ROOT_START + ROOT_SECTORS))

SFP="$OUT/u-boot-with-spl.sfp"
for f in "$SFP" "$OUT/zImage" "$OUT/socfpga_cyclone5_de1_soc.dtb" "$BOOT/rootfs.tar"; do
    [[ -s "$f" ]] || { echo "FAIL: missing $f"; exit 1; }
done
SFP_SECTORS=$(( ($(stat -c %s "$SFP") + 511) / 512 ))
(( SFP_SECTORS <= A2_SECTORS )) || { echo "FAIL: SPL image does not fit the a2 partition"; exit 1; }
(( A2_START + A2_SECTORS <= ROOT_START )) || { echo "FAIL: partitions overlap"; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK"

# fakeroot keeps file ownership and device nodes for mke2fs -d. metadata checksums and the other
# newer ext4 features are off so the U-Boot ext4 reader has nothing to reject.
fakeroot bash -euo pipefail -c '
    work="$1"; out="$2"; tarball="$3"; sectors="$4"
    mkdir "$work/root"
    tar -xpf "$tarball" -C "$work/root" --numeric-owner
    mkdir -p "$work/root/boot/extlinux"
    cp "$out/zImage" "$out/socfpga_cyclone5_de1_soc.dtb" "$work/root/boot/"
    cat >"$work/root/boot/extlinux/extlinux.conf" <<EOF
default linux
timeout 3
label linux
    kernel /boot/zImage
    fdt /boot/socfpga_cyclone5_de1_soc.dtb
    append console=ttyS0,115200 root=/dev/mmcblk0p2 rw rootwait
EOF
    chown -R 0:0 "$work/root/boot"
    mke2fs -q -t ext4 -F -L rootfs -b 4096 \
        -O ^metadata_csum,^metadata_csum_seed,^64bit,^orphan_file \
        -d "$work/root" "$work/root.ext4" "$((sectors / 8))"
' _ "$WORK" "$OUT" "$BOOT/rootfs.tar" "$ROOT_SECTORS"

e2fsck -fn "$WORK/root.ext4"

rm -f "$IMG"
truncate -s $((TOTAL * 512)) "$IMG"
sfdisk -q "$IMG" <<EOF
label: dos
unit: sectors
start=$A2_START, size=$A2_SECTORS, type=a2
start=$ROOT_START, size=$ROOT_SECTORS, type=83, bootable
EOF
dd if="$SFP" of="$IMG" bs=512 seek="$A2_START" conv=notrunc,sparse status=none
dd if="$WORK/root.ext4" of="$IMG" bs=1M seek=$((ROOT_START / 2048)) conv=notrunc,sparse status=none

sfdisk -d "$IMG"
cmp -n "$(stat -c %s "$SFP")" "$SFP" <(tail -c +$((A2_START * 512 + 1)) "$IMG") && echo "a2 contents match"
# SPL must find a legacy image header (27 05 19 56) at the sector it was configured for.
UBOOT_SECTOR="$(sed -n 's/^CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=//p' "$OUT/u-boot.config")"
MAGIC="$(dd if="$IMG" bs=512 skip=$((UBOOT_SECTOR)) count=1 status=none | head -c 4 | od -An -tx1 | tr -d ' ')"
[[ "$MAGIC" == 27051956 ]] || { echo "FAIL: no U-Boot image at sector $UBOOT_SECTOR, found $MAGIC"; exit 1; }
echo "U-Boot image header found at sector $UBOOT_SECTOR"
sha256sum "$IMG" | tee "$IMG.sha256"
# The MBR and a2 partition alone, for updating the boot code without rewriting the rootfs.
dd if="$IMG" of="$OUT/de1soc-cpu-head.img" bs=512 count="$ROOT_START" status=none
sha256sum "$OUT/de1soc-cpu-head.img"
rm -rf "$WORK"
ls -ls "$IMG"
