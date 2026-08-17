#!/usr/bin/env bash
# M0: Stockfish-18 armv7-neon 크로스 빌드 (DE1-SoC HPS Cortex-A9 대상)
# 호스트: macOS + Lima VM(Ubuntu) + gcc-arm-linux-gnueabihf
#
# 1) lima VM 준비:
#    brew install lima
#    limactl start --name=chess
#    limactl shell chess sudo apt-get update && sudo apt-get install -y \
#        crossbuild-essential-armhf make
# 2) 빌드:
#    limactl shell chess -- bash -c "cd /tmp/sf/src && make clean && make -j4 build ARCH=armv7-neon COMP=gcc COMPCXX=arm-linux-gnueabihf-g++"
# 3) 바이너리 추출:
#    limactl shell chess cat /tmp/sf/src/stockfish > ./stockfish-armv7
#
# 주의: 디버그 패치(RAWVERIFY/SMALLRAWVERIFY 등)가 포함된 상태로 빌드됨.
# 필요한 패치 제거 후 재빌드하려면 Stockfish/src에서 make clean 후 동일 명령.
set -euo pipefail

VM="chess"
SRC_HOST="/Users/mumal/Documents/chess_npu/Stockfish"
OUT="$(cd "$(dirname "$0")" && pwd)/stockfish-armv7"

if ! limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$VM"; then
    echo "VM 없음: limactl start --name=$VM 먼저 실행" >&2
    exit 1
fi

limactl shell "$VM" -- bash -c \
    "rm -rf /tmp/sf_arm && mkdir -p /tmp/sf_arm && cp -r '$SRC_HOST' /tmp/sf_arm/sf && cd /tmp/sf_arm/sf/src && make clean >/dev/null 2>&1; make -j4 build ARCH=armv7-neon COMP=gcc COMPCXX=arm-linux-gnueabihf-g++ 2>&1 | tail -2"

limactl shell "$VM" cat /tmp/sf_arm/sf/src/stockfish > "$OUT"
echo "OK -> $OUT"
file "$OUT"