#!/bin/sh
# Boot self-test of the NNUE accelerator (chess-npu-selftest.service, once per boot).
# It never falls back to the CPU: any failed check makes the result FAIL and the unit fails.
# The result goes to /run/chess-npu/selftest.status, the console and /var/log/chess-npu/selftest.log.
#   ./selftest.sh          the boot check, about one minute
set -u
SHARE=/usr/share/chess-npu
STATUS_DIR=/run/chess-npu
LOG_DIR=/var/log/chess-npu
mkdir -p "$STATUS_DIR" "$LOG_DIR"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id)"
WORK="$(mktemp -d /tmp/selftest.XXXXXX)"
FAILS=0
LOG="$WORK/selftest.log"

say() { echo "$*" | tee -a "$LOG"; }
check() {  # check <name> <command...>: runs the command, keeps its output, counts a failure
    name="$1"; shift
    if "$@" >"$WORK/$name.out" 2>&1; then say "PASS $name"; else say "FAIL $name (exit $?)"; FAILS=$((FAILS + 1)); fi
}

say "chess-npu selftest, boot $BOOT_ID, uptime $(cut -d' ' -f1 /proc/uptime) s"
say "kernel $(uname -r), cmdline: $(cat /proc/cmdline)"
say "image $(sed -n 's/.*"image_id": *"\([^"]*\)".*/\1/p' "$SHARE/manifest.json")"

# U-Boot sets mem=768M only after the FPGA image loaded and the bridges were enabled.
check fpga_loaded grep -qw 'mem=768M' /proc/cmdline
# Installed files against the hashes written at image build time (the large corpora are checked by
# regress.sh, which reads them anyway).
check files sh -c "cd / && sha256sum -c --quiet $SHARE/SHA256SUMS.boot"

if [ "$FAILS" -eq 0 ]; then
    # Identity, weight load and read-back, then refresh and incremental windows with tensor checks.
    check refresh_2000 /usr/local/bin/nnue_board "$SHARE/weights.bin" "$SHARE/regress/stim.bin" \
        --max 2000 --mode refresh --tensor-every 10 --report "$WORK/refresh.json"
    check events_3000_hw /usr/local/bin/nnue_board "$SHARE/weights.bin" "$SHARE/regress/search.ev" \
        --max 3000 --mode events --tensor-every 10 --no-load --policy hw --report "$WORK/events.json"
    # The engine in compare mode: every evaluation is computed by both paths and must agree, and
    # the node count must equal that of the official binary at the same depth.
    check engine_compare sh -c "SF_NNUE_MODE=compare SF_NNUE_PLANNER=hw SF_NNUE_LOAD=0 \
        /usr/local/bin/stockfish-fpga bench 16 1 7 >/dev/null 2>$WORK/compare.err; rc=\$?; cat $WORK/compare.err; exit \$rc"
    check engine_official sh -c "/usr/local/bin/stockfish bench 16 1 7 2>&1 >/dev/null"
    want="$(awk '/Nodes searched/{print $4}' "$WORK/engine_official.out")"
    got="$(awk '/Nodes searched/{print $4}' "$WORK/engine_compare.out")"
    if [ -n "$want" ] && [ "$want" = "$got" ] && grep -q 'mismatches 0, errors 0, fallbacks 0' "$WORK/engine_compare.out"
    then say "PASS engine_nodes ($got nodes, depth 7)"
    else say "FAIL engine_nodes (fpga '$got', official '$want')"; FAILS=$((FAILS + 1)); fi
    for f in refresh_2000 events_3000_hw; do grep -h '^RESULT' "$WORK/$f.out" | sed "s/^/  $f: /" | tee -a "$LOG"; done
    grep -h 'fpga_eval: mode' "$WORK/engine_compare.out" | sed 's/^/  /' | tee -a "$LOG"
else
    say "skipping the accelerator checks"
fi

if [ "$FAILS" -eq 0 ]; then RESULT=PASS; else RESULT=FAIL; fi
say "SELFTEST $RESULT ($FAILS failed)"
echo "$RESULT $BOOT_ID" >"$STATUS_DIR/selftest.status"
{ echo "=== boot $BOOT_ID"; cat "$LOG"; for f in "$WORK"/*.out; do echo "--- $(basename "$f")"; tail -20 "$f"; done; } \
    >>"$LOG_DIR/selftest.log"
cp "$WORK"/*.json "$STATUS_DIR/" 2>/dev/null
rm -rf "$WORK"
[ "$RESULT" = PASS ]
