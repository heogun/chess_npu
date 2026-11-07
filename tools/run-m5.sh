#!/usr/bin/env bash
# M5 gate: incremental hardware path against official Stockfish, in Verilator.
# Stages: record a real search, replay it through official code, then drive the core with
# the official per-ply changes. Simulation only; no statement about the board.
# Usage: run-m5.sh prepare | sim <name> <input.ev> <max> [tb_core options]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

T="$BUILD_ROOT/trace"
mkdir -p "$T"
CORPUS="$REPO_ROOT/tests/corpus/sf19_fixed.txt"
H="$BUILD_ROOT/sf/general-64/src/golden_harness"
A="$BUILD_ROOT/sf/x86-64-avx2/src/golden_harness"

case "${1:-}" in
prepare)
    # The patch must not change the search: bench has to match the official value exactly.
    TRACE=1 "$REPO_ROOT/tools/build-stockfish.sh" x86-64-avx2 >/dev/null
    WANT="$(lock_get official_bench_nodes)"
    NODES="$(cd "$BUILD_ROOT/sf/x86-64-avx2-trace/src" && SF_TRACE_FILE="$T/bench.ops" ./stockfish bench 2>&1 >/dev/null \
             | awk '/Nodes searched/{print $4}')"
    [[ "$NODES" == "$WANT" ]] || { echo "FAIL: traced bench $NODES, official $WANT"; exit 1; }
    echo "Traced bench: PASS ($NODES nodes)"

    # Every evaluation of the search is compared in scalar and AVX2; a window reaches the RTL.
    "$H" replay "$NET_PATH" "$T/bench.ops" --digest "$T/search_scalar.dig" --events "$T/search.ev" \
        --evals-per-root "${EVALS_PER_ROOT:-2000}" >"$T/search_scalar.json" &
    P1=$!
    "$A" replay "$NET_PATH" "$T/bench.ops" --digest "$T/search_avx2.dig" >"$T/search_avx2.json" &
    P2=$!
    wait $P1; wait $P2
    python3 "$REPO_ROOT/tools/compare_digests.py" "$T/search_scalar.dig" "$T/search_avx2.dig"
    cat "$T/search_scalar.json"

    "$H" trace "$NET_PATH" "$CORPUS" --seed 20261105 --states "${RANDOM_STATES:-100000}" \
        --digest "$T/random.dig" --events "$T/random.ev" >"$T/random.json"
    echo "Random-walk events: $(python3 -c "import json;print(json.load(open('$T/random.json'))['states'])") states"
    ;;
sim)
    NAME="$2"; INPUT="$3"; MAX="$4"; shift 4
    "$BUILD_ROOT/sim/core/Vnnue_core" "$BUILD_ROOT/spec/weights.bin" "$INPUT" --mode events --max "$MAX" \
        --seed 20261105 --report "$BUILD_ROOT/sim/m5_$NAME.json" "$@"
    ;;
*)
    echo "usage: run-m5.sh prepare | sim <name> <input.ev> <max> [tb_core options]" >&2
    exit 2
    ;;
esac
