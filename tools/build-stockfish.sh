#!/usr/bin/env bash
# Build official sf_19 for one ARCH from a private copy, leaving third_party/ untouched.
# With HARNESS=1 the golden harness joins the same make invocation, so it gets exactly
# the official compile flags. TRACE=1 builds a patched copy in <ARCH>-trace. Usage: build-stockfish.sh <ARCH> (general-64, x86-64-avx2, armv7-neon)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
ARCH="${1:?ARCH required}"

want="$(lock_get commit)"
got="$(git -C "$SF_SRC" rev-parse HEAD)"
[[ "$got" == "$want" ]] || { echo "Stockfish commit mismatch: $got" >&2; exit 1; }
[[ -z "$(git -C "$SF_SRC" status --porcelain --untracked-files=no)" ]] || { echo "third_party/stockfish has local edits" >&2; exit 1; }

"$(dirname "${BASH_SOURCE[0]}")/fetch-net.sh" >/dev/null
OUT="$BUILD_ROOT/sf/$ARCH${TRACE:+-trace}"
mkdir -p "$OUT"
rsync -a --delete --exclude .git --exclude '*.o' --exclude '.depend' --exclude stockfish \
      --exclude 'golden_harness*' --exclude "$NET_NAME" "$SF_SRC/" "$OUT/"
ln -f "$NET_PATH" "$OUT/src/$NET_NAME"

# TRACE=1 adds the search trace patch. The private copy changes; third_party/ does not.
if [[ -n "${TRACE:-}" ]]; then
    patch -d "$OUT" -p1 --quiet <"$REPO_ROOT/sw/host/patches/0001-trace-search-ops.patch"
fi

MAKE_ARGS=(ARCH="$ARCH" -j"$(nproc)")
case "$ARCH" in
    armv7*) MAKE_ARGS+=(COMP=gcc COMPCXX=arm-linux-gnueabihf-g++ "LDFLAGS=-static") ;;
    *)      MAKE_ARGS+=(COMP=gcc) ;;
esac

cd "$OUT/src"
make build "${MAKE_ARGS[@]}" >"$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
echo "Built $OUT/src/stockfish"

if [[ "${HARNESS:-0}" == 1 ]]; then
    cp "$REPO_ROOT"/sw/reference/golden_harness.cpp .
    srcs="$(ls ./*.cpp | sed 's#^\./##' | grep -vE '^(main|golden_harness)\.cpp$' | tr '\n' ' ') nnue/network.cpp nnue/nnue_accumulator.cpp nnue/nnue_misc.cpp nnue/features/half_ka_v2_hm.cpp nnue/features/full_threats.cpp nnue/features/pp_3wide.cpp syzygy/tbprobe.cpp golden_harness.cpp"
    make build "${MAKE_ARGS[@]}" EXE=golden_harness SRCS="$srcs" >"$OUT/harness.log" 2>&1 \
        || { tail -40 "$OUT/harness.log"; exit 1; }
    echo "Built $OUT/src/golden_harness"
fi
