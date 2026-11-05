#!/usr/bin/env bash
# Builds the Debian 13 armhf rootfs tar for DE1-SoC, without root, from a pinned package snapshot.
# Needs mmdebstrap, debian-archive-keyring and uidmap. Output: $BUILD_ROOT/boot/rootfs.tar
# Building this proves nothing about booting; see linux/README.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

SNAPSHOT="${SNAPSHOT:-20261101T000000Z}"
OUT="$BUILD_ROOT/boot"
ENGINE="$BUILD_ROOT/sf/armv7-neon/src/stockfish"
mkdir -p "$OUT"

WANT="$(python3 -c "import json;print(json.load(open('$REPO_ROOT/config/stockfish.lock.json'))['network_sha256'])")"
GOT="$(sha256sum "$NET_PATH" | cut -d' ' -f1)"
[[ "$WANT" == "$GOT" ]] || { echo "FAIL: net hash $GOT, lock has $WANT"; exit 1; }
[[ -x "$ENGINE" ]] || { echo "FAIL: build the engine first: $ENGINE"; exit 1; }

PACKAGES=systemd-sysv,udev,dbus,kmod,iproute2,iputils-ping,openssh-server,ca-certificates,procps,util-linux,e2fsprogs,less,linux-perf

mmdebstrap --mode=unshare --variant=minbase --architectures=armhf \
    --include="$PACKAGES" \
    --aptopt='Acquire::Check-Valid-Until "false"' \
    --customize-hook="mkdir -p \"\$1/usr/share/stockfish\"" \
    --customize-hook="upload $ENGINE /usr/local/bin/stockfish" \
    --customize-hook="upload $NET_PATH /usr/share/stockfish/$NET_NAME" \
    --customize-hook="upload $REPO_ROOT/linux/rootfs-customize.sh /tmp/rootfs-customize.sh" \
    --customize-hook='sh "$1/tmp/rootfs-customize.sh" "$1"; rm "$1/tmp/rootfs-customize.sh"' \
    --customize-hook='chroot "$1" dpkg-query -W >"$1/usr/share/rootfs-packages.txt"' \
    --customize-hook="download /usr/share/rootfs-packages.txt $OUT/rootfs-packages.txt" \
    trixie "$OUT/rootfs.tar" \
    "deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://snapshot.debian.org/archive/debian/$SNAPSHOT/ trixie main"

ls -l "$OUT/rootfs.tar"
sha256sum "$OUT/rootfs.tar" | tee "$OUT/rootfs.tar.sha256"
echo "snapshot $SNAPSHOT, net $GOT, engine $(sha256sum "$ENGINE" | cut -d' ' -f1)"
