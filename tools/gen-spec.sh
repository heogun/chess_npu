#!/usr/bin/env bash
# Regenerates the spec JSON, SV package, C++ header and DDR weight image.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
H="$BUILD_ROOT/sf/general-64/src/golden_harness"
OUT="$BUILD_ROOT/spec"
mkdir -p "$OUT"
"$H" spec "$NET_PATH" >"$OUT/harness_spec.json"
[[ -f "$OUT/raw_weights.bin" ]] || "$H" export "$NET_PATH" "$OUT/raw_weights.bin"
python3 "$REPO_ROOT/tools/gen_spec.py" --spec "$OUT/harness_spec.json" --lock "$LOCK_FILE" \
    --repo "$REPO_ROOT" --out-json "$OUT/nnue_spec.json" \
    --raw-weights "$OUT/raw_weights.bin" --weights "$OUT/weights.bin"
