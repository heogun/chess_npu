#!/usr/bin/env python3
"""Convert `perf script --show-mmap-events` output into profile_classify.py input.

Each sample of the stockfish binary becomes a count at its ELF virtual address, so that the same
DWARF classification applies. Samples outside the binary are reported as libraries.
Usage: perf_to_insn.py <perf.script> <binary> <out.txt>
"""
import collections
import re
import subprocess
import sys

MMAP = re.compile(r"\[0x([0-9a-f]+)\(0x([0-9a-f]+)\) @ (?:0x)?([0-9a-f]+) .*\]: r-xp (\S+)")
SAMPLE = re.compile(r"^\s*([0-9a-f]+) (.*)\((.*)\)\s*$")


def load_segments(binary):
    """Returns (file offset, virtual address, size) of each LOAD segment."""
    text = subprocess.run(["readelf", "-lW", binary], capture_output=True, text=True, check=True).stdout
    return [(int(m[0], 16), int(m[1], 16), int(m[2], 16))
            for m in re.findall(r"LOAD\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+(0x[0-9a-f]+)", text)]


def main(script, binary, out):
    segments = load_segments(binary)
    base = None
    counts, libs = collections.Counter(), collections.Counter()
    with open(script, errors="replace") as f:
        for line in f:
            if "PERF_RECORD_MMAP" in line:
                m = MMAP.search(line)
                if m and m.group(4) == binary:
                    base = (int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16))
                continue
            m = SAMPLE.match(line)
            if not m:
                continue
            ip = int(m.group(1), 16)
            if base and base[0] <= ip < base[0] + base[1]:
                offset = ip - base[0] + base[2]
                for off, vaddr, size in segments:
                    if off <= offset < off + size:
                        counts[offset - off + vaddr] += 1
                        break
            else:
                libs[m.group(3).rsplit("/", 1)[-1]] += 1

    with open(out, "w") as f:
        for addr, n in counts.items():
            f.write(f"{addr:x} {n} ?\n")
    total = sum(counts.values()) + sum(libs.values())
    print(f"samples {total}, in binary {sum(counts.values())}, outside {dict(libs.most_common(5))}")


if __name__ == "__main__":
    main(*sys.argv[1:])
