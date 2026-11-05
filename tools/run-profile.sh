#!/usr/bin/env bash
# Function-level profile of official sf_19 for the ARM target, without a board.
#  - Exact instruction counts from a QEMU TCG plugin (tools/qemu_prof/insn_count.c).
#  - Cache misses from QEMU's contrib cache plugin, configured like the Cortex-A9 on DE1-SoC.
#  - Depth 1 is measured as a baseline and subtracted, removing net load and table clears.
#  - x86 perf gives time-based shares as an independent cross-check. It is not ARM timing.
# Needs a QEMU with plugins in $BUILD_ROOT/qemu/build, see docs/reports/profile_search.md.
# These are emulator measurements, not board measurements.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

Q="$BUILD_ROOT/qemu"
P="$BUILD_ROOT/prof"
ARM="$BUILD_ROOT/sf/armv7-neon-prof"
X86="$BUILD_ROOT/sf/x86-64-avx2-prof"
DEPTH="${1:-13}"
QEMU="$Q/build/qemu-arm"
CACHE="$Q/build/contrib/plugins/libcache.so,dcachesize=32768,dassoc=4,dblksize=32,icachesize=32768,iassoc=4,iblksize=32,l2=on,l2cachesize=524288,l2assoc=8,l2blksize=32,cores=1,limit=2000000"
mkdir -p "$P"

gcc -O2 -fPIC -shared -I"$Q/src/include/qemu" $(pkg-config --cflags glib-2.0) \
    "$REPO_ROOT/tools/qemu_prof/insn_count.c" -o "$Q/libinsn_count.so"

# -g changes no generated code, which the node counts below confirm.
build_prof() {
    local arch="$1" out="$2"; shift 2
    if [[ ! -x "$out/src/stockfish" ]]; then
        mkdir -p "$out"
        rsync -a --delete --exclude .git "$SF_SRC/" "$out/"
        ln -f "$NET_PATH" "$out/src/$NET_NAME"
        (cd "$out/src" && make build ARCH="$arch" COMP=gcc EXTRACXXFLAGS=-g -j"$(nproc)" "$@" >"$out/build.log" 2>&1)
    fi
}
build_prof armv7-neon "$ARM" COMPCXX=arm-linux-gnueabihf-g++ LDFLAGS=-static
build_prof x86-64-avx2 "$X86"

nodes() { awk '/Nodes searched/{print $4}'; }

run_counts() {
    local d="$1"
    (cd "$ARM/src" && "$QEMU" -plugin "$Q/libinsn_count.so,out=$P/insn_d$d.txt" ./stockfish bench 16 1 "$d" 2>&1 >/dev/null | nodes) >"$P/nodes_d$d.txt"
}
run_cache() {
    local d="$1"
    (cd "$ARM/src" && "$QEMU" -plugin "$CACHE" -d plugin -D "$P/cache_d$d.txt" ./stockfish bench 16 1 "$d" 2>&1 >/dev/null | nodes) >"$P/nodes_cache_d$d.txt"
}

run_counts 1
run_cache 1
run_counts "$DEPTH" &
PC=$!
run_cache "$DEPTH" &
PK=$!

# Time-based shares on x86, while the emulated runs occupy other cores.
perf_samples() {
    local d="$1"
    (cd "$X86/src" && perf record -q -e cpu-clock -F 2000 -o "$P/perf_d$d.data" ./stockfish bench 16 1 "$d" >/dev/null 2>"$P/perf_d$d.err") \
        || { echo "perf record failed; see $P/perf_d$d.err"; return 0; }
    # Non-PIE offsets differ from runtime addresses when PIE, so use perf's symbol-relative map.
    perf script -i "$P/perf_d$d.data" -F ip,sym,symoff,dso --show-mmap-events 2>/dev/null >"$P/perf_d$d.script" || true
}
if command -v perf >/dev/null; then
    perf_samples 1
    perf_samples "$DEPTH"
fi

wait $PC
wait $PK

WANT="$("$BUILD_ROOT/sf/x86-64-avx2/src/stockfish" bench 16 1 "$DEPTH" 2>&1 >/dev/null | nodes)"
for f in nodes_d"$DEPTH".txt nodes_cache_d"$DEPTH".txt; do
    [[ "$(cat "$P/$f")" == "$WANT" ]] || { echo "FAIL: $f has $(cat "$P/$f") nodes, official build $WANT"; exit 1; }
done
echo "Node counts match the official build: $WANT (baseline $(cat "$P/nodes_d1.txt"))"
