#!/usr/bin/env bash
# M1 gate: official bench on the pinned commit/net, net rejection, source and file spec agree.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
ARCH="${1:-x86-64-avx2}"
OUT="$BUILD_ROOT/sf/$ARCH/src"
WANT="$(lock_get official_bench_nodes)"

UCI="$(printf 'uci\nisready\nposition startpos moves e2e4\ngo depth 8\nquit\n' | (cd "$OUT"; sleep 0; ./stockfish) )"
grep -q '^uciok'   <<<"$UCI" || { echo "FAIL: no uciok"; exit 1; }
grep -q '^readyok' <<<"$UCI" || { echo "FAIL: no readyok"; exit 1; }
grep -q '^bestmove' <<<"$UCI" || { echo "FAIL: no bestmove"; exit 1; }
echo "UCI smoke: PASS ($(grep '^bestmove' <<<"$UCI"))"

NODES="$(cd "$OUT" && ./stockfish bench 2>&1 >/dev/null | awk '/Nodes searched/{print $4}')"
[[ "$NODES" == "$WANT" ]] || { echo "FAIL: bench $NODES, official $WANT"; exit 1; }
echo "Bench $ARCH: PASS ($NODES nodes)"

SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
"$OUT/golden_harness" reject "$NET_PATH" "$SCRATCH"
echo "Net rejection: PASS"
