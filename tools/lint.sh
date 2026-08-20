#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RTL="$ROOT/hw/rtl"

command -v verilator >/dev/null 2>&1 || {
    echo "verilator is required" >&2
    exit 2
}

mapfile -t SOURCES < <(find "$RTL" -type f \( -name '*.sv' -o -name '*.v' \) | sort)
if ((${#SOURCES[@]} == 0)); then
    echo "no canonical RTL sources yet"
    exit 0
fi

verilator --lint-only --language 1800-2012 --timing --Wall \
    -Wno-fatal -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
    "${SOURCES[@]}"
