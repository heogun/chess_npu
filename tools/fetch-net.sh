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

# The net is 98.5 MB. There is no overall time limit, because a slow link took longer than the old
# 300 s cap. A transfer that stalls below 1 KB/s for 2 minutes is dropped instead, and the next of up
# to 5 attempts resumes the partial file (-C -). The hash check decides; a bad file is discarded.
fetch() {
    local url="$1" try
    for try in 1 2 3 4 5; do
        curl -sSfL --connect-timeout 30 --speed-limit 1024 --speed-time 120 -C - -o "$NET_PATH.tmp" "$url" && return 0
        echo "  attempt $try failed, retrying" >&2
        sleep 5
    done
    return 1
}
if [[ ! -f "$NET_PATH" ]]; then
    for url in "https://tests.stockfishchess.org/api/nn/$NET_NAME" \
               "https://github.com/official-stockfish/networks/raw/master/$NET_NAME"; do
        echo "Downloading $url"
        rm -f "$NET_PATH.tmp"
        if fetch "$url" && verify "$NET_PATH.tmp" >/dev/null; then
            mv "$NET_PATH.tmp" "$NET_PATH"; break
        fi
        rm -f "$NET_PATH.tmp"
    done
fi
[[ -f "$NET_PATH" ]] || { echo "Could not obtain $NET_NAME" >&2; exit 1; }
echo "Verified $NET_NAME sha256=$(verify "$NET_PATH") bytes=$(stat -c %s "$NET_PATH")"
