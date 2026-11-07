#!/bin/sh
# Full on-board regression of the installed image (M8), then optional A/B timing.
#   regress.sh [--rounds N] [--out DIR]
# Correctness first: refresh corpus 100,000 states, search trace 94,770 evaluations with the ARM
# and the core planner, ARM-only replay of the same trace, official bench node counts, engine
# compare mode over the whole bench, and a UCI session in hw mode. Timing runs only if all pass:
# warm-up, then N alternating rounds (default 10) as in docs/BENCHMARK.md. Results stay in DIR
# (default /var/log/chess-npu/regress-<boot id prefix>-<n>), with summary.txt last.
set -u
ROUNDS=10
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rounds) ROUNDS="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) echo "usage: regress.sh [--rounds N] [--out DIR]"; exit 2 ;;
    esac
done
S=/usr/share/chess-npu
R=$S/regress
NB=/usr/local/bin/nnue_board
SF=/usr/local/bin/stockfish
SFF=/usr/local/bin/stockfish-fpga
AR=/usr/local/bin/arm_replay
W=$S/weights.bin
NET=/usr/share/stockfish/nn-1a298aa575a0.nnue
WANT_NODES="$(sed -n 's/.*"official_bench_nodes": *\([0-9]*\).*/\1/p' $S/manifest.json)"
if [ -z "$OUT" ]; then
    b="$(cut -c1-8 /proc/sys/kernel/random/boot_id)"; n=0
    while [ -e "/var/log/chess-npu/regress-$b-$n" ]; do n=$((n + 1)); done
    OUT="/var/log/chess-npu/regress-$b-$n"
fi
mkdir -p "$OUT"
cd "$OUT" || exit 1
FAILS=0
say() { echo "$*" | tee -a summary.txt; }
gate() {  # gate <name> <pattern> <file>: the file must contain the pattern
    if grep -q "$2" "$3"; then say "PASS $1"; else say "FAIL $1 (see $3)"; FAILS=$((FAILS + 1)); fi
}
progress() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >>progress; }

say "regress $(date -u +%FT%TZ) (board clock, not synchronised), boot $(cat /proc/sys/kernel/random/boot_id)"
say "kernel $(uname -r), cmdline: $(cat /proc/cmdline)"
cp $S/manifest.json .
{ sha256sum /boot/fpga/board.rbf $NB $SF $SFF $AR $W $NET; cat /proc/cpuinfo | grep -m1 -i 'model name'; } >sha.txt

progress hashes
(cd / && sha256sum -c $S/SHA256SUMS) >files.txt 2>&1
if grep -qv ': OK$' files.txt; then say "FAIL files (see files.txt)"; FAILS=$((FAILS + 1)); else say "PASS files ($(wc -l <files.txt) hashes)"; fi

progress refresh
$NB $W $R/stim.bin --mode refresh --tensor-every 10 --report w_refresh.json >w_refresh.txt 2>&1
gate refresh_100000 '^RESULT PASS' w_refresh.txt
progress events_nearest
$NB $W $R/search.ev --mode events --tensor-every 10 --no-load --policy nearest --candidates 16 \
    --report w_near16.json >w_near16.txt 2>&1
gate events_nearest16 '^RESULT PASS' w_near16.txt
progress events_hw
$NB $W $R/search.ev --mode events --tensor-every 10 --no-load --policy hw --report w_hw.json >w_hw.txt 2>&1
gate events_hw '^RESULT PASS' w_hw.txt
progress arm_replay
$AR $NET $R/bench.ops $R/search.ev --mode search --report w_arm.json >w_arm.txt 2>&1
gate arm_replay '^RESULT PASS' w_arm.txt

progress bench_official
$SF bench >/dev/null 2>bench_official.err
gate bench_official_nodes "Nodes searched *: *$WANT_NODES\$" bench_official.err
progress bench_compare
SF_NNUE_MODE=compare SF_NNUE_PLANNER=hw SF_NNUE_LOAD=0 $SFF bench >/dev/null 2>bench_compare.err
gate bench_compare_nodes "Nodes searched *: *$WANT_NODES\$" bench_compare.err
gate bench_compare_pairs 'mismatches 0, errors 0, fallbacks 0' bench_compare.err

progress uci
# position, go depth, go infinite + stop, a second game, quit. bestmove must come back twice.
{ printf 'uci\nisready\nucinewgame\nposition startpos moves e2e4 e7e5 g1f3\ngo depth 10\n'; sleep 30
  printf 'position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 10\ngo infinite\n'; sleep 5
  printf 'stop\nisready\nquit\n'; } | SF_NNUE_MODE=compare SF_NNUE_PLANNER=hw SF_NNUE_LOAD=0 $SFF >uci.out 2>uci.err
echo "exit $?" >>uci.err
if [ "$(grep -c '^bestmove' uci.out)" -eq 2 ] && [ "$(grep -c '^readyok' uci.out)" -eq 2 ] && grep -q '^uciok' uci.out \
   && grep -q 'mismatches 0, errors 0, fallbacks 0' uci.err && grep -q '^exit 0$' uci.err
then say "PASS uci"; else say "FAIL uci (see uci.out, uci.err)"; FAILS=$((FAILS + 1)); fi

if [ "$FAILS" -ne 0 ]; then
    say "REGRESS FAIL ($FAILS failed), timing skipped"
    echo FAIL >result; exit 1
fi
say "REGRESS PASS (correctness), timing $ROUNDS rounds after warm-up"

# Timing: the same programs with tensor checks off. Round 0 is the warm-up.
i=0
while [ $i -le "$ROUNDS" ]; do
    progress "trace $i"
    $AR $NET $R/bench.ops $R/search.ev --mode search --report arm_$i.json >arm_$i.txt 2>&1
    $NB $W $R/search.ev --mode events --tensor-every 1000000 --no-load --policy hw --report hwp_$i.json >hwp_$i.txt 2>&1
    i=$((i + 1))
done
i=0
while [ $i -le "$ROUNDS" ]; do
    progress "bench $i"
    SF_NNUE_MODE=cpu $SFF bench >/dev/null 2>cpu_$i.err
    SF_NNUE_MODE=hw SF_NNUE_PLANNER=hw SF_NNUE_LOAD=0 $SFF bench >/dev/null 2>hwh_$i.err
    i=$((i + 1))
done
bad=0
for f in arm_*.txt hwp_*.txt; do grep -q '^RESULT PASS' "$f" || bad=$((bad + 1)); done
for f in cpu_*.err hwh_*.err; do grep -q "Nodes searched *: *$WANT_NODES\$" "$f" || bad=$((bad + 1)); done
for f in hwh_*.err; do grep -q 'mismatches 0, errors 0, fallbacks 0' "$f" || bad=$((bad + 1)); done
if [ "$bad" -ne 0 ]; then say "FAIL timing runs ($bad runs without a passing result)"; echo FAIL >result; exit 1; fi
say "PASS timing runs (all results and node counts as required)"
echo PASS >result
