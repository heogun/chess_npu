#!/usr/bin/env bash
# M4 gate: arithmetic unit test, then the full core against golden stimulus in Verilator.
# Usage: run-m4.sh [max-states] [seed] (extra arguments go to tb_core)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

MAX="${1:-200}"
SEED="${2:-20261105}"
shift $(( $# > 2 ? 2 : $# ))

OUT="$BUILD_ROOT/sim"
STIM="${STIM:-$BUILD_ROOT/golden/seed20261105/stim.bin}"

"$REPO_ROOT/tools/build-sim.sh"
"$OUT/math/Vnnue_math_unit"
grep -E '^%Warning' "$OUT/core.log" | sed 's/^/  /' | head -20 || true

"$OUT/core/Vnnue_core" "$BUILD_ROOT/spec/weights.bin" "$STIM" --mode refresh --max "$MAX" --seed "$SEED" \
    --report "$OUT/m4_report.json" "$@"
