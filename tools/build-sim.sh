#!/usr/bin/env bash
# Builds the Verilator simulations into $BUILD_ROOT/sim.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

RTL="$REPO_ROOT/hw/rtl"
OUT="$BUILD_ROOT/sim"
mkdir -p "$OUT"

cp "$REPO_ROOT/sw/host/generated/nnue_spec.h" "$OUT/generated_spec.h"
PKGS=("$RTL/generated/nnue_spec_pkg.sv" "$RTL/nnue_math_pkg.sv")

verilator --cc --exe --build -j "$(nproc)" -O3 --x-assign fast --x-initial unique \
    -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
    --Mdir "$OUT/math" --top-module nnue_math_unit -CFLAGS "-O2 -std=c++17" \
    "${PKGS[@]}" "$RTL/tb/nnue_math_unit.sv" "$RTL/tb/tb_math.cpp" >"$OUT/math.log" 2>&1 \
    || { tail -40 "$OUT/math.log"; exit 1; }

verilator --cc --exe --build -j "$(nproc)" -O3 --x-assign fast --x-initial unique \
    -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
    -GWATCHDOG_CYCLES=4000 \
    --Mdir "$OUT/core" --top-module nnue_core -CFLAGS "-O2 -std=c++17 -I$OUT -I$REPO_ROOT/sw/host" \
    "${PKGS[@]}" "$RTL/sdp_ram.sv" "$RTL/nnue_core.sv" "$RTL/tb/tb_core.cpp" >"$OUT/core.log" 2>&1 \
    || { tail -40 "$OUT/core.log"; exit 1; }

# The 8-wide FC path (WIDE_FC = 0, before perf_proposal.md step 5): kept for cycle regressions.
verilator --cc --exe --build -j "$(nproc)" -O3 --x-assign fast --x-initial unique     -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE     -GWATCHDOG_CYCLES=4000 -GWIDE_FC=0     --Mdir "$OUT/core_narrow" --top-module nnue_core -CFLAGS "-O2 -std=c++17 -I$OUT -I$REPO_ROOT/sw/host"     "${PKGS[@]}" "$RTL/sdp_ram.sv" "$RTL/nnue_core.sv" "$RTL/tb/tb_core.cpp" >"$OUT/core_narrow.log" 2>&1     || { tail -40 "$OUT/core_narrow.log"; exit 1; }

# 128-bit memory bus variant (perf_proposal.md step 4): same testbench, 16-byte beats.
verilator --cc --exe --build -j "$(nproc)" -O3 --x-assign fast --x-initial unique \
    -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
    -GWATCHDOG_CYCLES=4000 -GBUS_W=128 \
    --Mdir "$OUT/core_b128" --top-module nnue_core \
    -CFLAGS "-O2 -std=c++17 -I$OUT -I$REPO_ROOT/sw/host -DNNUE_BUS_W=128" \
    "${PKGS[@]}" "$RTL/sdp_ram.sv" "$RTL/nnue_core.sv" "$RTL/tb/tb_core.cpp" >"$OUT/core_b128.log" 2>&1 \
    || { tail -40 "$OUT/core_b128.log"; exit 1; }
