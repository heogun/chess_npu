#!/usr/bin/env bash
# Builds the Debian 13 armhf rootfs tar for DE1-SoC, without root, from a pinned package snapshot.
# Needs mmdebstrap, debian-archive-keyring and uidmap. Output: $BUILD_ROOT/boot/rootfs.tar
# Building this proves nothing about booting; see linux/README.md.
#
# The tar holds, besides Debian:
#   /usr/local/bin/stockfish        official sf_19, armv7-neon, net embedded (unmodified source)
#   /usr/local/bin/stockfish-fpga   the same with the NNUE core adapter (FPGA=1 build)
#   /usr/local/bin/{nnue_board,probe,arm_replay}   board harness, F2SDRAM probe, ARM-only replay
#   /usr/share/stockfish/<net>      the network file
#   /usr/share/chess-npu/           weights.bin, regress/{stim.bin,search.ev,bench.ops},
#                                   manifest.json, SHA256SUMS, SHA256SUMS.boot
#   /usr/lib/chess-npu/, chess-npu-selftest.service   from linux/rootfs-overlay
# CPU_ONLY=1 leaves out everything but the official engine and the net (the earlier image).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

SNAPSHOT="$(python3 -c "import json;print(json.load(open('$REPO_ROOT/config/boot.lock.json'))['debian']['snapshot'])")"
OUT="$BUILD_ROOT/boot"
ENGINE="$BUILD_ROOT/sf/armv7-neon/src/stockfish"
mkdir -p "$OUT"

WANT="$(lock_get network_sha256)"
GOT="$(sha256sum "$NET_PATH" | cut -d' ' -f1)"
[[ "$WANT" == "$GOT" ]] || { echo "FAIL: net hash $GOT, lock has $WANT"; exit 1; }
[[ -x "$ENGINE" ]] || { echo "FAIL: build the engine first: $ENGINE"; exit 1; }

# Everything outside Debian goes into one staging tree, copied in with sync-in.
STAGE="$OUT/payload"
rm -rf "$STAGE"
mkdir -p "$STAGE/usr/local/bin" "$STAGE/usr/share/stockfish"
install -m 0755 "$ENGINE" "$STAGE/usr/local/bin/stockfish"
install -m 0644 "$NET_PATH" "$STAGE/usr/share/stockfish/$NET_NAME"
if [[ -z "${CPU_ONLY:-}" ]]; then
    need() { for f; do [[ -s "$f" ]] || { echo "FAIL: missing $f"; exit 1; }; done; }
    FPGA_ENGINE="$BUILD_ROOT/sf/armv7-neon-fpga/src/stockfish"
    REPLAY="$BUILD_ROOT/sf/armv7-neon/src/arm_replay"
    WEIGHTS="$BUILD_ROOT/spec/weights.bin"
    STIM="$BUILD_ROOT/golden/seed20261105/stim.bin"
    EVENTS="$BUILD_ROOT/trace/search.ev"
    OPS="$BUILD_ROOT/trace/bench.ops"
    need "$FPGA_ENGINE" "$REPLAY" "$BUILD_ROOT/board/nnue_board" "$BUILD_ROOT/board/probe" \
         "$WEIGHTS" "$STIM" "$EVENTS" "$OPS"
    D="$STAGE/usr/share/chess-npu"
    mkdir -p "$D/regress"
    install -m 0755 "$FPGA_ENGINE" "$STAGE/usr/local/bin/stockfish-fpga"
    install -m 0755 "$REPLAY" "$BUILD_ROOT/board/nnue_board" "$BUILD_ROOT/board/probe" "$STAGE/usr/local/bin/"
    install -m 0644 "$WEIGHTS" "$D/weights.bin"
    install -m 0644 "$STIM" "$EVENTS" "$OPS" "$D/regress/"
    cp -a "$REPO_ROOT/linux/rootfs-overlay/." "$STAGE/"
    chmod 0755 "$STAGE"/usr/lib/chess-npu/*.sh
    chmod 0644 "$STAGE/etc/systemd/system/chess-npu-selftest.service"
    REPO_ROOT="$REPO_ROOT" BUILD_ROOT="$BUILD_ROOT" RBF="${RBF:?set RBF to the FPGA image}" \
        python3 "$REPO_ROOT/tools/release_manifest.py" image "$STAGE" >"$D/manifest.json"
    # SHA256SUMS: every payload file. SHA256SUMS.boot: the same without the corpora, checked at boot.
    (cd "$STAGE" && find . -type f ! -path ./usr/share/chess-npu/SHA256SUMS\* -printf '%P\n' | LC_ALL=C sort \
        | xargs sha256sum) >"$D/SHA256SUMS"
    grep -v ' usr/share/chess-npu/regress/' "$D/SHA256SUMS" >"$D/SHA256SUMS.boot"
fi
# Reproducible metadata: one fixed time for every staged file (SOURCE_DATE_EPOCH, set by the caller).
EPOCH="${SOURCE_DATE_EPOCH:?set SOURCE_DATE_EPOCH (tools/build-release.sh does)}"
find "$STAGE" -exec touch -h -d "@$EPOCH" {} +

# Leaf directories only: sync-in also applies the staged directory's owner and mode to its target.
PAYLOAD_HOOKS=()
[[ -z "${CPU_ONLY:-}" ]] && PAYLOAD_HOOKS=(
    --customize-hook="sync-in $STAGE/usr/share/chess-npu /usr/share/chess-npu"
    --customize-hook="sync-in $STAGE/usr/lib/chess-npu /usr/lib/chess-npu"
    --customize-hook="upload $STAGE/etc/systemd/system/chess-npu-selftest.service /etc/systemd/system/chess-npu-selftest.service")

PACKAGES=systemd-sysv,udev,dbus,kmod,iproute2,iputils-ping,openssh-server,ca-certificates,procps,util-linux,e2fsprogs,less,linux-perf

mmdebstrap --mode=unshare --variant=minbase --architectures=armhf \
    --include="$PACKAGES" \
    --aptopt='Acquire::Check-Valid-Until "false"' \
    --customize-hook="sync-in $STAGE/usr/local/bin /usr/local/bin" \
    --customize-hook="sync-in $STAGE/usr/share/stockfish /usr/share/stockfish" \
    "${PAYLOAD_HOOKS[@]}" \
    --customize-hook="upload $REPO_ROOT/linux/rootfs-customize.sh /tmp/rootfs-customize.sh" \
    --customize-hook='sh "$1/tmp/rootfs-customize.sh" "$1"; rm "$1/tmp/rootfs-customize.sh"' \
    --customize-hook='chroot "$1" dpkg-query -W -f "\${binary:Package}\t\${Version}\t\${source:Package}\t\${source:Version}\n" >"$1/usr/share/rootfs-packages.txt"' \
    --customize-hook="download /usr/share/rootfs-packages.txt $OUT/rootfs-packages.txt" \
    trixie "$OUT/rootfs.tar" \
    "deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://snapshot.debian.org/archive/debian/$SNAPSHOT/ trixie main"

ls -l "$OUT/rootfs.tar"
sha256sum "$OUT/rootfs.tar" | tee "$OUT/rootfs.tar.sha256"
echo "snapshot $SNAPSHOT, net $GOT, engine $(sha256sum "$ENGINE" | cut -d' ' -f1)"
