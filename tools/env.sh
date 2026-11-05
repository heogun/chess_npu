# Shared paths for SF19 tooling. Source from bash inside WSL.
# Build outputs stay on the Linux filesystem; override with CHESS_NPU_BUILD.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${CHESS_NPU_BUILD:-$HOME/chess_npu_build}"
LOCK_FILE="$REPO_ROOT/config/stockfish.lock.json"
SF_SRC="$REPO_ROOT/third_party/stockfish"
lock_get() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$LOCK_FILE" "$1"; }
NET_NAME="$(lock_get default_network)"
NET_DIR="$BUILD_ROOT/net"
NET_PATH="$NET_DIR/$NET_NAME"
