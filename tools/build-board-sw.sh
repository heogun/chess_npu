#!/usr/bin/env bash
# Cross-compiles the DE1-SoC programs (static armhf, Debian trixie runs them without matching glibc).
# Output: $BUILD_ROOT/board/{probe,nnue_board,plan_sim}. Building says nothing about running on the
# board. plan_sim is the request-planning model; on the board it measures the ARM planner cost.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

OUT="$BUILD_ROOT/board"
mkdir -p "$OUT/include"
cp "$REPO_ROOT/sw/host/generated/nnue_spec.h" "$OUT/include/generated_spec.h"
CC=arm-linux-gnueabihf-gcc
CXX=arm-linux-gnueabihf-g++
$CC -O2 -Wall -Wextra -static -o "$OUT/probe" "$REPO_ROOT/sw/board/probe.c"
$CXX -O2 -mfpu=neon -Wall -Wextra -std=c++17 -static -I"$OUT/include" -I"$REPO_ROOT/sw/host" \
    -o "$OUT/nnue_board" "$REPO_ROOT/sw/board/nnue_board.cpp"
$CXX -O2 -mfpu=neon -Wall -Wextra -std=c++17 -static -I"$OUT/include" -I"$REPO_ROOT/sw/host" \
    -o "$OUT/plan_sim" "$REPO_ROOT/sw/host/plan_sim.cpp"
sha256sum "$OUT/probe" "$OUT/nnue_board" "$OUT/plan_sim"
