#!/usr/bin/env bash
# Assembles the SD image from build-boot.sh and build-rootfs.sh outputs, without root.
#
#   sector 0        MBR
#   1 MiB, 16 MiB   type a2, raw u-boot-with-spl.sfp, found by the Boot ROM
#   17 MiB, 4 GiB   ext4 root, bootable flag, holds /boot/extlinux/extlinux.conf for U-Boot
#                   and /boot/fpga/board.rbf, which U-Boot loads before Linux (linux/uboot.fragment)
#
# There is no FAT partition: U-Boot reads ext4. RBF=<file> selects the FPGA image; CPU_ONLY=1 makes
# the earlier CPU-only image (no .rbf, 3 GiB root). The ext4 UUID, hash seed and times are fixed so
# the same inputs give the same image. Output: $BUILD_ROOT/boot/out/de1soc.img (de1soc-cpu.img).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

BOOT="$BUILD_ROOT/boot"
OUT="$BOOT/out"
WORK="$BOOT/image-work"
A2_START=2048 A2_SECTORS=32768
ROOT_START=34816
if [[ -n "${CPU_ONLY:-}" ]]; then
    IMG="$OUT/de1soc-cpu.img" ROOT_SECTORS=$((3 * 1024 * 1024 * 2)) RBF=""
else
    IMG="$OUT/de1soc.img" ROOT_SECTORS=$((4 * 1024 * 1024 * 2))
    [[ -s "${RBF:-}" ]] || { echo "FAIL: set RBF to the FPGA image (or CPU_ONLY=1)"; exit 1; }
fi
EPOCH="${SOURCE_DATE_EPOCH:?set SOURCE_DATE_EPOCH (tools/build-release.sh does)}"
# Any fixed values do; these keep two builds of the same inputs comparable byte for byte.
ROOT_UUID=6d8f3c2a-5b1e-4f7a-9c0d-de1500c0ffee HASH_SEED=0b5e2f71-3c4d-4e8a-a1b2-de1500c0ffee
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
    work="$1"; out="$2"; tarball="$3"; sectors="$4"; rbf="$5"; epoch="$6"; uuid="$7"; seed="$8"
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
    append console=ttyS0,115200 root=/dev/mmcblk0p2 rw rootwait \${fpga_bootargs}
EOF
    # U-Boot bootcmd loads this if present and then sets fpga_bootargs=mem=768M (linux/uboot.fragment).
    if [[ -n "$rbf" ]]; then mkdir -p "$work/root/boot/fpga"; cp "$rbf" "$work/root/boot/fpga/board.rbf"; fi
    chown -R 0:0 "$work/root/boot"
    find "$work/root/boot" -exec touch -h -d "@$epoch" {} +
    touch -d "@$epoch" "$work/root"
    E2FSPROGS_FAKE_TIME="$epoch" mke2fs -q -t ext4 -F -L rootfs -b 4096 -U "$uuid" -E "hash_seed=$seed" \
        -O ^metadata_csum,^metadata_csum_seed,^64bit,^orphan_file \
        -d "$work/root" "$work/root.ext4" "$((sectors / 8))"
' _ "$WORK" "$OUT" "$BOOT/rootfs.tar" "$ROOT_SECTORS" "$RBF" "$EPOCH" "$ROOT_UUID" "$HASH_SEED"

e2fsck -fn "$WORK/root.ext4"

rm -f "$IMG"
truncate -s $((TOTAL * 512)) "$IMG"
sfdisk -q "$IMG" <<EOF
label: dos
label-id: 0xde150c19
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
dd if="$IMG" of="${IMG%.img}-head.img" bs=512 count="$ROOT_START" status=none
sha256sum "${IMG%.img}-head.img"
rm -rf "$WORK"
ls -ls "$IMG"
