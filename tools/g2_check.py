#!/usr/bin/env python3
"""Stockfish 18 small-net golden regression for the DE1-SoC data assets."""

from pathlib import Path
import re
import struct
import sys
import os

HD = 128
NF = 22528
FC0_OUT = 16
FC_BUCKET = 3300
PSQ_BUCKETS = 8


def i16_file(path):
    data = path.read_bytes()
    return list(struct.unpack("<%dh" % (len(data) // 2), data))


def i32_file(path):
    data = path.read_bytes()
    return list(struct.unpack("<%di" % (len(data) // 4), data))


def i8(value):
    return value - 256 if value >= 128 else value


def trunc_div(value, divisor):
    return value // divisor if value >= 0 else -((-value) // divisor)


def s32(value):
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value & 0x80000000 else value


def clamp(value, lo, hi):
    return max(lo, min(hi, value))


def parse_ref(path):
    expected = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        name, payload = line.split("|", 1)
        values = {}
        tokens = payload.split()
        for i in range(0, 8):
            base = i * 4
            assert tokens[base] == "RAWVERIFY"
            values[int(tokens[base + 1])] = (int(tokens[base + 2]), int(tokens[base + 3]))
        expected[name] = values
    return expected


def parse_features(path):
    tokens = path.read_text().split()
    assert tokens[0] == "FTLIST"
    n0, n1 = int(tokens[1]), int(tokens[2])
    values = [int(v) for v in tokens[3:]]
    assert len(values) == n0 + n1
    assert all(0 <= v < NF for v in values)
    return values[:n0], values[n0:]


def evaluate(ft, fc, psqt, group0, group1, bucket):
    bias = ft[:HD]
    accum = []
    for group in (group0, group1):
        a = bias[:]
        for feature in group:
            base = HD + feature * HD
            a = [x + ft[base + lane] for lane, x in enumerate(a)]
        accum.append(a)

    q = []
    for perspective in accum:
        for j in range(HD // 2):
            s0 = clamp(perspective[j], 0, 254)
            s1 = clamp(perspective[HD // 2 + j], 0, 254)
            q.append((s0 * s1) >> 9)

    fc_base = bucket * FC_BUCKET
    fc0_bias = [struct.unpack_from("<i", bytes(fc), fc_base + j * 4)[0] for j in range(16)]
    fc0_wbase = fc_base + 64
    fc0 = []
    for j in range(16):
        total = fc0_bias[j]
        for i in range(HD):
            total += q[i] * i8(fc[fc0_wbase + j * HD + i])
        fc0.append(total)

    fcin = [min(127, (v * v) >> 19) for v in fc0[:15]]
    fcin += [clamp(v >> 6, 0, 127) for v in fc0[:15]]
    fcin += [0, 0]
    if os.getenv("G2_DEBUG") and bucket == 0:
        print("DEBUG FC1IN", fcin)

    fc1_bbase = fc_base + 2112
    fc1_wbase = fc_base + 2240
    fc1 = []
    for j in range(32):
        total = struct.unpack_from("<i", bytes(fc), fc1_bbase + j * 4)[0]
        for i in range(32):
            total += fcin[i] * i8(fc[fc1_wbase + j * 32 + i])
        fc1.append(total)

    fc2_bbase = fc_base + 3264
    fc2_wbase = fc_base + 3268
    positional = struct.unpack_from("<i", bytes(fc), fc2_bbase)[0]
    for i in range(32):
        positional += clamp(fc1[i] >> 6, 0, 127) * i8(fc[fc2_wbase + i])
    positional += trunc_div(s32(fc0[15] * 9600), 8128)

    if os.getenv("G2_DEBUG") and bucket == 0:
        print("DEBUG FC0", fc0)

    psq0 = sum(psqt[feature * 8 + bucket] for feature in group0)
    psq1 = sum(psqt[feature * 8 + bucket] for feature in group1)
    psqt_raw = trunc_div(psq0 - psq1, 2)
    return trunc_div(psqt_raw, 16), trunc_div(positional, 16)


def main(root):
    root = Path(root)
    ft = i16_file(root / "ft.bin")
    fc = list((root / "fc.bin").read_bytes())
    psqt = i32_file(root / "psqt.bin")
    expected = parse_ref(root / "ref.txt")
    failures = []
    for name, results in expected.items():
        group0, group1 = parse_features(root / ("case_" + name + ".feat"))
        for bucket in range(8):
            actual = evaluate(ft, fc, psqt, group0, group1, bucket)
            if actual != results[bucket]:
                failures.append((name, bucket, actual, results[bucket]))
    if failures:
        for failure in failures:
            print("FAIL", failure)
        return 1
    print("PASS G2 Stockfish 18 small-net golden regression")
    print("cases=%d buckets=%d" % (len(expected), len(expected) * 8))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "hw/sdimage/nnue_test"))
