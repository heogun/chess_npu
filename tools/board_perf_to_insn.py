#!/usr/bin/env python3
"""Convert a board `perf script -F ip,dso | sort | uniq -c` histogram for profile_classify.py.

Input lines are "<count> <ip> <dso>". Samples outside the stockfish binary are counted and reported.
The binary is static and not PIE, so sample addresses are ELF virtual addresses.
Usage: board_perf_to_insn.py <hist.gz> <out.txt>
"""
import collections
import gzip
import sys


def main(hist, out):
    counts = collections.Counter()
    other = collections.Counter()
    with gzip.open(hist, "rt", errors="replace") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 3:
                continue
            n, ip, dso = int(parts[0]), int(parts[1], 16), parts[2]
            if "stockfish" in dso:
                counts[ip] += n
            else:
                other[dso] += n
    with open(out, "w") as f:
        for ip, n in counts.items():
            f.write(f"{ip:x} {n} ?\n")
    print(f"samples in stockfish {sum(counts.values())}, outside {sum(other.values())} {dict(other.most_common(4))}")


if __name__ == "__main__":
    main(*sys.argv[1:])
