#!/usr/bin/env bash
# M8: the whole SD image from pinned sources, in one run inside WSL.
#   RBF=/path/board.rbf tools/build-release.sh
# RBF is the Quartus output (tools/export-rbf.ps1 copies it with its provenance board.rbf.json);
# Quartus runs on Windows and is not part of this script. Every other input is fetched by pinned
# commit or hash, or generated: official Stockfish, the net, the packed weights, the regression
# corpora, U-Boot, Linux, the Debian rootfs. SOURCE_DATE_EPOCH is the project commit time, so
# two builds of one commit can be compared file by file.
# Output: $BUILD_ROOT/release/<image id>/ with the compressed image, boot files, manifest.json and
# SHA256SUMS. tools/make-source-bundle.sh adds the corresponding sources. A finished build says
# nothing about booting: that is the board regression (linux/README.md).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
T="$REPO_ROOT/tools"
RBF="$(realpath "${RBF:?set RBF to the FPGA image}")"
[[ -s "$RBF" ]] || { echo "FAIL: no FPGA image at $RBF"; exit 1; }
export RBF
export SOURCE_DATE_EPOCH="$(git -C "$REPO_ROOT" log -1 --format=%ct)"
LOGS="$BUILD_ROOT/release-logs"
mkdir -p "$LOGS"
step() { echo "== $(date -u +%T) $1"; }
logged() { local name="$1"; shift; "$@" >"$LOGS/$name.log" 2>&1 || { tail -30 "$LOGS/$name.log"; echo "FAIL: $name"; exit 1; }; }

step "official Stockfish $(lock_get tag)"
if [[ ! -d "$SF_SRC/.git" ]]; then
    git clone -q --depth 1 --branch "$(lock_get tag)" "$(lock_get repository)" "$SF_SRC"
fi
[[ "$(git -C "$SF_SRC" rev-parse HEAD)" == "$(lock_get commit)" ]] || { echo "FAIL: Stockfish commit"; exit 1; }
"$T/fetch-net.sh"

step "engines and harness (official flags)"
HARNESS=1 logged sf_general64 "$T/build-stockfish.sh" general-64
HARNESS=1 logged sf_armv7 "$T/build-stockfish.sh" armv7-neon
FPGA=1 logged sf_armv7_fpga "$T/build-stockfish.sh" armv7-neon
TRACE=1 logged sf_trace "$T/build-stockfish.sh" x86-64-avx2

step "spec and packed weights"
logged gen_spec "$T/gen-spec.sh"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain -- hw/rtl/generated sw/host/generated)" ]]; then
    echo "FAIL: regenerated spec files differ from the committed ones"; git -C "$REPO_ROOT" status --short; exit 1
fi

step "regression corpora (refresh 100,000 states, official bench search trace)"
H="$BUILD_ROOT/sf/general-64/src/golden_harness"
G="$BUILD_ROOT/golden/seed20261105"
mkdir -p "$G" "$BUILD_ROOT/trace"
logged corpus_refresh "$H" trace "$NET_PATH" "$REPO_ROOT/tests/corpus/sf19_fixed.txt" --seed 20261105 \
    --states 100000 --digest "$G/general-64.dig" --stim "$G/stim.bin" --stim-every 20
NODES="$(cd "$BUILD_ROOT/sf/x86-64-avx2-trace/src" && SF_TRACE_FILE="$BUILD_ROOT/trace/bench.ops" ./stockfish bench 2>&1 >/dev/null \
         | awk '/Nodes searched/{print $4}')"
[[ "$NODES" == "$(lock_get official_bench_nodes)" ]] || { echo "FAIL: traced bench $NODES nodes"; exit 1; }
logged corpus_events "$H" replay "$NET_PATH" "$BUILD_ROOT/trace/bench.ops" \
    --digest "$BUILD_ROOT/trace/search_scalar.dig" --events "$BUILD_ROOT/trace/search.ev" --evals-per-root 2000

step "board programs"
logged board_sw "$T/build-board-sw.sh"

step "U-Boot and Linux"
logged boot "$T/build-boot.sh"

step "Debian rootfs"
logged rootfs "$T/build-rootfs.sh"

step "SD image"
logged image "$T/make-sd-image.sh"

step "release directory"
OUT="$BUILD_ROOT/boot/out"
ID="$(python3 -c "import json;print(json.load(open('$BUILD_ROOT/boot/payload/usr/share/chess-npu/manifest.json'))['image_id'])")"
REL="$BUILD_ROOT/release/$ID"
rm -rf "$REL"
mkdir -p "$REL"
cp "$OUT"/{u-boot-with-spl.sfp,zImage,socfpga_cyclone5_de1_soc.dtb,u-boot.config,linux.config,de1soc-head.img} "$REL/"
cp "$RBF" "$REL/board.rbf"
[[ -f "$RBF.json" ]] && cp "$RBF.json" "$REL/board.rbf.json"
cp "$BUILD_ROOT/boot/rootfs-packages.txt" "$REL/"
cp "$BUILD_ROOT/boot/payload/usr/share/chess-npu/manifest.json" "$REL/image-manifest.json"
cp "$BUILD_ROOT/boot/payload/usr/share/chess-npu/SHA256SUMS" "$REL/rootfs-payload.SHA256SUMS"
sha256sum "$BUILD_ROOT/boot/rootfs.tar" | sed 's#  .*/#  #' >"$REL/rootfs.tar.sha256"
sha256sum "$OUT/de1soc.img" | sed 's#  .*/#  #' >"$REL/de1soc.img.sha256"
stat -c %s "$OUT/de1soc.img" >"$REL/de1soc.img.bytes"
xz -T0 -6 -c "$OUT/de1soc.img" >"$REL/de1soc.img.xz"
REPO_ROOT="$REPO_ROOT" BUILD_ROOT="$BUILD_ROOT" python3 "$T/release_manifest.py" release "$REL"
(cd "$REL" && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs sha256sum >SHA256SUMS)
cp -r "$LOGS" "$REL/build-logs"
echo "release: $REL"
cat "$REL/de1soc.img.sha256"
