#!/usr/bin/env python3
"""Generate the SF19 spec outputs and the DDR weight image from one source of truth.

Input:  JSON from `golden_harness spec` and canonical weights from `golden_harness export`.
Output: nnue_spec.json, hw/rtl/generated/nnue_spec_pkg.sv, sw/host/generated/nnue_spec.h,
        and weights.bin (with --weights).

Dimensions are never typed here; everything derives from the harness JSON. The only
literals are this project's own choices: DDR bus width, ABI version, descriptor format.
"""
import argparse
import hashlib
import json
import pathlib
import struct

ABI_VERSION = 2
ACC_SLOTS = 32  # on-chip accumulator slots, see docs/reports/M5_incremental.md
DESC_HEADER_WORDS = 6
BUS_BYTES = 8  # F2SDRAM data width selected in docs/reports/M3_resources.md
DESC_MAGIC = 0x4E4E5546  # "FUNN" when read as little-endian bytes
PAGE = 4096


def align(value, boundary):
    return (value + boundary - 1) // boundary * boundary


def build_layout(s):
    l1, l2, l3 = s["L1"], s["L2"], s["L3"]
    n_psq = s["psq_dimensions"]
    n_active = s["threat_dimensions"] + s["pair_dimensions"]
    pb = s["psqt_buckets"]
    pad0, pad1, pad2 = s["fc0_input_padded"], s["fc1_input_padded"], s["fc2_input_padded"]

    # Rows are aligned to the bus so that each read starts on a word.
    psq_row = l1 * 2
    active_row = l1
    psqt_row = pb * 4

    # FC weights are transposed to one column per input, so zero inputs cost no reads.
    fc0_col = align(l2, BUS_BYTES)
    fc1_col = align(l3, BUS_BYTES)
    fc0_cols = pad0
    fc1_cols = pad1
    fc2_bytes = align(pad2, BUS_BYTES)

    fc_bias_bytes = align(4 * (l2 + l3 + 1), BUS_BYTES)
    stack_bytes = align(fc_bias_bytes + fc0_col * fc0_cols + fc1_col * fc1_cols + fc2_bytes, PAGE)

    offsets = {}
    cursor = 0

    def section(name, size):
        nonlocal cursor
        offsets[name] = cursor
        cursor = align(cursor + size, PAGE)

    section("ft_bias", psq_row)
    section("psq_weights", psq_row * n_psq)
    section("psq_psqt", psqt_row * n_psq)
    section("active_weights", active_row * n_active)
    section("active_psqt", psqt_row * n_active)
    section("stacks", stack_bytes * s["layer_stacks"])

    return {
        "bus_bytes": BUS_BYTES,
        "psq_row_bytes": psq_row,
        "active_row_bytes": active_row,
        "psqt_row_bytes": psqt_row,
        "fc0_col_bytes": fc0_col,
        "fc1_col_bytes": fc1_col,
        "fc2_bytes": fc2_bytes,
        "fc_bias_bytes": fc_bias_bytes,
        "stack_stride_bytes": stack_bytes,
        "stack_fc0_offset": fc_bias_bytes,
        "stack_fc1_offset": fc_bias_bytes + fc0_col * fc0_cols,
        "stack_fc2_offset": fc_bias_bytes + fc0_col * fc0_cols + fc1_col * fc1_cols,
        "image_bytes": cursor,
        "offsets": offsets,
    }


def pack_weights(s, layout, raw_path, out_path):
    """Pack canonical weights into the DDR image and return its SHA-256."""
    l1, l2, l3 = s["L1"], s["L2"], s["L3"]
    n_psq = s["psq_dimensions"]
    n_active = s["threat_dimensions"] + s["pair_dimensions"]
    pb = s["psqt_buckets"]
    pad0, pad1, pad2 = s["fc0_input_padded"], s["fc1_input_padded"], s["fc2_input_padded"]

    image = bytearray(layout["image_bytes"])
    off = layout["offsets"]
    with open(raw_path, "rb") as raw:
        def take(n):
            data = raw.read(n)
            if len(data) != n:
                raise SystemExit(f"weight export ended early, wanted {n} bytes")
            return data

        def put(at, data):
            image[at:at + len(data)] = data

        put(off["ft_bias"], take(l1 * 2))
        put(off["psq_weights"], take(l1 * 2 * n_psq))
        put(off["psq_psqt"], take(pb * 4 * n_psq))
        put(off["active_weights"], take(l1 * n_active))
        put(off["active_psqt"], take(pb * 4 * n_active))

        for b in range(s["layer_stacks"]):
            base = off["stacks"] + b * layout["stack_stride_bytes"]
            fc0_bias = take(4 * l2)
            fc0_w = take(l2 * pad0)
            fc1_bias = take(4 * l3)
            fc1_w = take(l3 * pad1)
            fc2_bias = take(4)
            fc2_w = take(pad2)

            put(base, fc0_bias + fc1_bias + fc2_bias)

            # The file stores weights row-major per output; the image stores input columns.
            at = base + layout["stack_fc0_offset"]
            for col in range(pad0):
                put(at + col * layout["fc0_col_bytes"], fc0_w[col::pad0])
            at = base + layout["stack_fc1_offset"]
            for col in range(pad1):
                put(at + col * layout["fc1_col_bytes"], fc1_w[col::pad1])
            put(base + layout["stack_fc2_offset"], fc2_w)

        if raw.read(1):
            raise SystemExit("weight export has trailing bytes")

    with open(out_path, "wb") as out:
        out.write(image)
    return hashlib.sha256(image).hexdigest()


def constants(s, layout, net_id):
    """Ordered (name, value) pairs shared verbatim by the SV package and the C++ header."""
    off = layout["offsets"]
    return [
        ("ABI_VERSION", ABI_VERSION),
        ("DESC_MAGIC", DESC_MAGIC),
        ("ACC_SLOTS", ACC_SLOTS),
        ("DESC_HEADER_WORDS", DESC_HEADER_WORDS),
        ("NETWORK_HASH", s["source_network_hash"]),
        ("NET_ID", net_id),
        ("L1", s["L1"]),
        ("L2", s["L2"]),
        ("L3", s["L3"]),
        ("PSQT_BUCKETS", s["psqt_buckets"]),
        ("LAYER_STACKS", s["layer_stacks"]),
        ("OUTPUT_SCALE", s["output_scale"]),
        ("WEIGHT_SCALE_BITS", s["weight_scale_bits"]),
        ("FT_MAX_VAL", s["ft_max_val"]),
        ("HIDDEN_ONE_VAL", s["hidden_one_val"]),
        ("MAX_PSQ_ACTIVE", s["max_psq_active"]),
        ("MAX_THREAT_ACTIVE", s["max_threat_active"]),
        ("PSQ_DIMENSIONS", s["psq_dimensions"]),
        ("ACTIVE_DIMENSIONS", s["threat_dimensions"] + s["pair_dimensions"]),
        ("POSITIONAL_MULTIPLIER", s["positional_multiplier"]),
        ("POSITIONAL_DIVISOR", s["hidden_one_val"] * (1 << s["weight_scale_bits"]) * 2),
        ("FC2_INPUTS", s["fc2_input_padded"]),
        ("FC1_INPUTS", s["fc1_input_padded"]),
        ("BUS_BYTES", layout["bus_bytes"]),
        ("PSQ_ROW_BYTES", layout["psq_row_bytes"]),
        ("ACTIVE_ROW_BYTES", layout["active_row_bytes"]),
        ("PSQT_ROW_BYTES", layout["psqt_row_bytes"]),
        ("FC0_COL_BYTES", layout["fc0_col_bytes"]),
        ("FC1_COL_BYTES", layout["fc1_col_bytes"]),
        ("FC2_BYTES", layout["fc2_bytes"]),
        ("FC_BIAS_BYTES", layout["fc_bias_bytes"]),
        ("STACK_STRIDE_BYTES", layout["stack_stride_bytes"]),
        ("STACK_FC0_OFFSET", layout["stack_fc0_offset"]),
        ("STACK_FC1_OFFSET", layout["stack_fc1_offset"]),
        ("STACK_FC2_OFFSET", layout["stack_fc2_offset"]),
        ("OFF_FT_BIAS", off["ft_bias"]),
        ("OFF_PSQ_WEIGHTS", off["psq_weights"]),
        ("OFF_PSQ_PSQT", off["psq_psqt"]),
        ("OFF_ACTIVE_WEIGHTS", off["active_weights"]),
        ("OFF_ACTIVE_PSQT", off["active_psqt"]),
        ("OFF_STACKS", off["stacks"]),
        ("IMAGE_BYTES", layout["image_bytes"]),
    ]


NOTICE = "Generated by tools/gen_spec.py from the sf_19 harness output. Do not edit."


def write_sv(path, items):
    lines = [f"// {NOTICE}", "package nnue_spec_pkg;"]
    lines += [f"  localparam logic [63:0] {name} = 64'h{value:016X};  // {value}" for name, value in items]
    lines += ["endpackage", ""]
    write_text(path, "\n".join(lines))


def write_h(path, items):
    lines = [f"// {NOTICE}", "#pragma once", "#include <cstdint>", "namespace nnue_spec {"]
    lines += [f"constexpr std::uint64_t {name} = 0x{value:X}ull;  // {value}" for name, value in items]
    lines += ["}  // namespace nnue_spec", ""]
    write_text(path, "\n".join(lines))


def write_text(path, text):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="\n") as f:
        f.write(text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", required=True, help="golden_harness spec JSON")
    ap.add_argument("--lock", required=True, help="config/stockfish.lock.json")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--out-json", required=True)
    ap.add_argument("--raw-weights")
    ap.add_argument("--weights")
    args = ap.parse_args()

    s = json.load(open(args.spec))
    lock = json.load(open(args.lock))

    if s["file_version"] != s["source_version"] or int(lock["evaluation_file_version"], 16) != s["source_version"]:
        raise SystemExit("version mismatch between source, net file and lock file")
    if s["file_network_hash"] != s["source_network_hash"]:
        raise SystemExit("network hash mismatch between source and net file")
    if s["file_ft_hash"] != s["source_ft_hash"]:
        raise SystemExit("feature transformer hash mismatch between source and net file")

    layout = build_layout(s)
    # The first 32 bits of the net's SHA-256 identify it to the hardware.
    net_id = struct.unpack(">I", bytes.fromhex(lock["network_sha256"][:8]))[0]

    result = {"lock": lock, "source": s, "abi_version": ABI_VERSION, "net_id": net_id, "layout": layout}
    if args.weights:
        result["image_sha256"] = pack_weights(s, layout, args.raw_weights, args.weights)

    write_text(args.out_json, json.dumps(result, indent=2) + "\n")
    items = constants(s, layout, net_id)
    write_sv(pathlib.Path(args.repo) / "hw/rtl/generated/nnue_spec_pkg.sv", items)
    write_h(pathlib.Path(args.repo) / "sw/host/generated/nnue_spec.h", items)
    print(f"layout image_bytes={layout['image_bytes']} net_id=0x{net_id:08X}", result.get("image_sha256", ""))


if __name__ == "__main__":
    main()
