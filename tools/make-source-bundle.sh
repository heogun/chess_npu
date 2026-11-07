#!/usr/bin/env bash
# Corresponding sources and licenses for the release built by tools/build-release.sh (M8).
#   tools/make-source-bundle.sh <release dir> [--debian]
# Writes <release dir>/sources/:
#   chess-npu-<commit>.tar.gz        this project at the built commit (patches, adapter, RTL, scripts)
#   stockfish-sf_19.tar.gz           official Stockfish at the locked commit (GPL-3.0)
#   u-boot-<tag>.tar.gz, linux-<tag>.tar.xz   at the locked commits; the patch, config fragments and
#                                    final .config files are in the project archive and the release
#   licenses/                        license texts of the above
#   debian-sources.tsv               binary package, version, source package, source version
#   debian/                          with --debian: every source package of the rootfs, downloaded
#                                    from the same snapshot.debian.org timestamp (.dsc and its files)
# Then SHA256SUMS of the release is rewritten to include the bundle.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
REL="${1:?release directory}"
S="$REL/sources"
BOOT="$BUILD_ROOT/boot"
lockb() { python3 -c "import json,sys;print(json.load(open('$REPO_ROOT/config/boot.lock.json'))[sys.argv[1]][sys.argv[2]])" "$1" "$2"; }
rm -rf "$S"
mkdir -p "$S/licenses"
export SOURCE_DATE_EPOCH="$(git -C "$REPO_ROOT" log -1 --format=%ct)"

C="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
[[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]] || echo "WARNING: project tree has uncommitted changes; the archive is HEAD"
git -C "$REPO_ROOT" archive --format=tar --prefix="chess-npu-$C/" HEAD | gzip -n -9 >"$S/chess-npu-$C.tar.gz"

[[ "$(git -C "$SF_SRC" rev-parse HEAD)" == "$(lock_get commit)" ]] || { echo "FAIL: Stockfish commit"; exit 1; }
git -C "$SF_SRC" archive --format=tar --prefix=stockfish-sf_19/ HEAD | gzip -n -9 >"$S/stockfish-sf_19.tar.gz"
cp "$SF_SRC/Copying.txt" "$S/licenses/stockfish-Copying.txt"

for key in u_boot linux; do
    dir="$BOOT/${key/_/-}"
    [[ "$(git -C "$dir" rev-parse HEAD)" == "$(lockb "$key" commit)" ]] || { echo "FAIL: $dir commit"; exit 1; }
done
git -C "$BOOT/u-boot" archive --format=tar --prefix="u-boot-$(lockb u_boot tag)/" HEAD | gzip -n -9 \
    >"$S/u-boot-$(lockb u_boot tag).tar.gz"
cp -r "$BOOT/u-boot/Licenses" "$S/licenses/u-boot"
git -C "$BOOT/linux" archive --format=tar --prefix="linux-$(lockb linux tag)/" HEAD | xz -T0 -6 \
    >"$S/linux-$(lockb linux tag).tar.xz"
mkdir -p "$S/licenses/linux"
cp "$BOOT/linux/COPYING" "$S/licenses/linux/"
cp -r "$BOOT/linux/LICENSES/preferred" "$BOOT/linux/LICENSES/exceptions" "$S/licenses/linux/"

cp "$REL/rootfs-packages.txt" "$S/debian-sources.tsv"
SNAP="$(lockb debian snapshot)"
cat >"$S/README.txt" <<EOF
Sources for the DE1-SoC SD image $(basename "$REL").
Project commit $(git -C "$REPO_ROOT" rev-parse HEAD); Stockfish $(lock_get tag) $(lock_get commit);
U-Boot $(lockb u_boot tag) $(lockb u_boot commit); Linux $(lockb linux tag) $(lockb linux commit).
Debian packages: trixie armhf from http://snapshot.debian.org/archive/debian/$SNAP/ ;
debian-sources.tsv lists binary package, version, source package and source version.
Each Debian package's license is in /usr/share/doc/<package>/copyright inside the image.
The project itself carries no license file; see the project README.
EOF

if [[ "${2:-}" == "--debian" ]]; then
    mkdir -p "$S/debian"
    # One line per source package. The pool directory is lib<x> for lib* sources, else the first letter.
    cut -f3,4 "$S/debian-sources.tsv" | LC_ALL=C sort -u | while IFS=$'\t' read -r src ver; do
        v="${ver#*:}"
        case "$src" in lib*) p="${src:0:4}" ;; *) p="${src:0:1}" ;; esac
        base="http://snapshot.debian.org/archive/debian/$SNAP/pool/main/$p/$src"
        dsc="${src}_${v}.dsc"
        curl -sSfL --retry 3 -o "$S/debian/$dsc" "$base/$dsc" || { echo "FAIL: $base/$dsc"; exit 1; }
        # Files section of the .dsc: " <md5> <size> <name>"
        awk '/^Files:/{f=1;next} /^[^ ]/{f=0} f{print $3}' "$S/debian/$dsc" | while read -r name; do
            [[ -f "$S/debian/$name" ]] || curl -sSfL --retry 3 -o "$S/debian/$name" "$base/$name" \
                || { echo "FAIL: $base/$name"; exit 1; }
        done
    done
    (cd "$S/debian" && ls *.dsc | wc -l) | sed 's/$/ Debian source packages downloaded/'
fi

(cd "$REL" && find . -type f ! -name SHA256SUMS ! -path './build-logs/*' -printf '%P\n' | LC_ALL=C sort \
    | xargs sha256sum >SHA256SUMS)
du -sh "$S"
