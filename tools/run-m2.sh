#!/usr/bin/env bash
# M2 gate: identical digests across scalar, AVX2 and ARM NEON builds for one seed.
# ARM runs under qemu-user, which proves the code path and NOT the DE1-SoC.
# Usage: run-m2.sh [states] [seed]   ARM_STATES overrides the qemu state count.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
STATES="${1:-100000}"
SEED="${2:-20261105}"
ARM_STATES="${ARM_STATES:-$STATES}"
CORPUS="$REPO_ROOT/tests/corpus/sf19_fixed.txt"
OUT="$BUILD_ROOT/golden/seed$SEED"
mkdir -p "$OUT"

H() { echo "$BUILD_ROOT/sf/$1/src/golden_harness"; }

"$(H general-64)" trace "$NET_PATH" "$CORPUS" --seed "$SEED" --states "$STATES" \
    --digest "$OUT/general-64.dig" --stim "$OUT/stim.bin" --stim-every "${STIM_EVERY:-20}" \
    | tee "$OUT/general-64.json" &
P1=$!
"$(H x86-64-avx2)" trace "$NET_PATH" "$CORPUS" --seed "$SEED" --states "$STATES" \
    --digest "$OUT/x86-64-avx2.dig" >"$OUT/x86-64-avx2.json" &
P2=$!
qemu-arm "$(H armv7-neon)" trace "$NET_PATH" "$CORPUS" --seed "$SEED" --states "$ARM_STATES" \
    --digest "$OUT/armv7-neon.dig" >"$OUT/armv7-neon.json" &
P3=$!
wait $P1; wait $P2; wait $P3

python3 "$REPO_ROOT/tools/compare_digests.py" "$OUT/general-64.dig" "$OUT/x86-64-avx2.dig" "$OUT/armv7-neon.dig"
