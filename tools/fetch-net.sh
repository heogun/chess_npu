#!/usr/bin/env bash
# Fetch the pinned default net from the endpoints used by scripts/net.sh and
# verify it against the full SHA-256 in the lock file. A hash mismatch is fatal.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

want_prefix="$(lock_get network_sha256_prefix)"
want_full="$(lock_get network_sha256)"
mkdir -p "$NET_DIR"

verify() {
    local got; got="$(sha256sum "$1" | cut -d' ' -f1)"
    [[ "$got" == "$want_prefix"* ]] || { echo "SHA-256 prefix mismatch: $got" >&2; return 1; }
    if [[ "$want_full" != "None" && "$got" != "$want_full" ]]; then
        echo "SHA-256 mismatch: $got (lock: $want_full)" >&2; return 1
    fi
    echo "$got"
}

if [[ ! -f "$NET_PATH" ]]; then
    for url in "https://tests.stockfishchess.org/api/nn/$NET_NAME" \
               "https://github.com/official-stockfish/networks/raw/master/$NET_NAME"; do
        echo "Downloading $url"
        if curl -sSfL --max-time 300 -o "$NET_PATH.tmp" "$url" && verify "$NET_PATH.tmp" >/dev/null; then
            mv "$NET_PATH.tmp" "$NET_PATH"; break
        fi
        rm -f "$NET_PATH.tmp"
    done
fi
[[ -f "$NET_PATH" ]] || { echo "Could not obtain $NET_NAME" >&2; exit 1; }
echo "Verified $NET_NAME sha256=$(verify "$NET_PATH") bytes=$(stat -c %s "$NET_PATH")"
