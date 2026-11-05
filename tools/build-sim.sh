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
