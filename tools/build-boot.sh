#!/usr/bin/env bash
# Builds U-Boot with SPL and the Linux kernel at the commits in config/boot.lock.json.
# Output: $BUILD_ROOT/boot/out. A successful build says nothing about booting the board.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

BOOT="$BUILD_ROOT/boot"
OUT="$BOOT/out"
CROSS=arm-linux-gnueabihf-
BOOT_LOCK="$REPO_ROOT/config/boot.lock.json"
JOBS="${JOBS:-$(nproc)}"
mkdir -p "$OUT"

lock() { python3 -c "import json,sys; print(json.load(open('$BOOT_LOCK'))[sys.argv[1]][sys.argv[2]])" "$1" "$2"; }

checkout() {
    local key="$1" dir="$BOOT/$2"
    if [[ ! -d "$dir/.git" ]]; then
        git clone -q --depth 1 --branch "$(lock "$key" tag)" "$(lock "$key" repository)" "$dir"
    fi
    local got
    got="$(git -C "$dir" rev-parse HEAD)"
    [[ "$got" == "$(lock "$key" commit)" ]] || { echo "FAIL: $dir is at $got, lock has $(lock "$key" commit)"; exit 1; }
}

build_uboot() {
    checkout u_boot u-boot
    cd "$BOOT/u-boot"
    # Integration patch: release the FPGA-to-SDRAM port resets on `bridge enable`. The value is
    # F2SDRAM_RESET_PORT_USED from this project's Quartus handoff (hw/quartus/board). SPL writes it
    # to the controller only when the FPGA is already configured, so CPU-only boots are unchanged.
    local patch="$REPO_ROOT/linux/uboot-de1soc-fpgaportrst.patch"
    git apply --reverse --check "$patch" 2>/dev/null || git apply "$patch"
    grep -qP '^#define CFG_HPS_SDR_CTRLCFG_FPGAPORTRST\t+0x111$' board/terasic/de1-soc/qts/sdram_config.h || \
        { echo "FAIL: FPGAPORTRST patch not applied"; exit 1; }
    make -s CROSS_COMPILE="$CROSS" "$(lock u_boot defconfig)"
    scripts/kconfig/merge_config.sh -m .config "$REPO_ROOT/linux/uboot.fragment" >/dev/null
    make -s CROSS_COMPILE="$CROSS" olddefconfig
    # merge_config only warns when Kconfig drops an option, so check the result.
    grep -q '^CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=0xa00$' .config || { echo "FAIL: U-Boot sector not 0xa00"; exit 1; }
    grep -q '^CONFIG_BOOTCOMMAND="if load mmc 0:2 .*/boot/fpga/board.rbf.*run distro_bootcmd"$' .config || \
        { echo "FAIL: bootcmd not set"; exit 1; }
    make -s -j"$JOBS" CROSS_COMPILE="$CROSS"
    cp u-boot-with-spl.sfp .config "$OUT/" && mv "$OUT/.config" "$OUT/u-boot.config"
}

build_linux() {
    checkout linux linux
    local dts=arch/arm/boot/dts/intel/socfpga
    cd "$BOOT/linux"
    cp "$REPO_ROOT/linux/socfpga_cyclone5_de1_soc.dts" "$dts/"
    grep -q socfpga_cyclone5_de1_soc "$dts/Makefile" || \
        echo 'dtb-$(CONFIG_ARCH_INTEL_SOCFPGA) += socfpga_cyclone5_de1_soc.dtb' >>"$dts/Makefile"
    make -s ARCH=arm CROSS_COMPILE="$CROSS" "$(lock linux defconfig)"
    scripts/kconfig/merge_config.sh -m .config "$REPO_ROOT/linux/kernel.fragment" >/dev/null
    make -s ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig
    # merge_config only warns about dropped options, so check the ones the plan depends on.
    for opt in EXT4_FS=y HW_PERF_EVENTS=y ARM_PMU=y MMC_DW=y SERIAL_8250_DW=y STMMAC_ETH=y AUTOFS_FS=y; do
        grep -q "^CONFIG_$opt\$" .config || { echo "FAIL: CONFIG_$opt not set"; exit 1; }
    done
    make -s -j"$JOBS" ARCH=arm CROSS_COMPILE="$CROSS" zImage dtbs
    cp arch/arm/boot/zImage "$dts/socfpga_cyclone5_de1_soc.dtb" "$OUT/"
    cp .config "$OUT/linux.config"
}

case "${1:-all}" in
    uboot) build_uboot ;;
    linux) build_linux ;;
    all) build_uboot; build_linux ;;
    *) echo "usage: $0 [uboot|linux|all]"; exit 2 ;;
esac
ls -l "$OUT"
