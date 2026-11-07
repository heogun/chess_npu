#!/usr/bin/env python3
"""Compare golden digest files record by record. Exit 1 on the first difference.

The optimism draw and key are part of the record, so a trace that diverged is also
reported. A shorter file is compared over its common prefix and the count is printed.
"""
import os
import struct
import sys

HEADER = 16
FIELDS = ("id key move game ply op stm bucket inCheck nFeat outPsqt outPos rawPsqt rawPos fwd skip "
          "evalOpt0 evalOptN optN pad hAcc hPsqtAcc hFt hFc0 hConcat hFc1 hFc2 hFeat").split()
REC = struct.Struct("<QQIIHBBBBH" + "i" * 10 + "Q" * 8)


def main(paths):
    files = [open(p, "rb") for p in paths]
    heads = [f.read(HEADER) for f in files]
    if len(set(heads)) != 1:
        sys.exit("FAIL: digest headers differ")
    magic, rec_size, version, net_hash = struct.unpack("<IIII", heads[0])
    if rec_size != REC.size:
        sys.exit(f"FAIL: record size {rec_size}, parser {REC.size}")

    compared = 0
    while True:
        blocks = [f.read(rec_size) for f in files]
        if any(len(b) < rec_size for b in blocks):
            break
        if len(set(blocks)) != 1:
            rows = [dict(zip(FIELDS, REC.unpack(b))) for b in blocks]
            for name in FIELDS:
                values = [r[name] for r in rows]
                if len(set(values)) != 1:
                    print(f"FAIL state {rows[0]['id']}: {name} = {values}")
            sys.exit(1)
        compared += 1

    counts = {p.rsplit("/", 1)[-1]: (os.path.getsize(p) - HEADER) // rec_size for p in paths}
    print(f"PASS version=0x{version:08X} hash=0x{net_hash:08X} compared_states={compared} mismatches=0")
    print("states per file:", counts)


if __name__ == "__main__":
    main(sys.argv[1:])
