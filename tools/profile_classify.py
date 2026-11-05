#!/usr/bin/env python3
"""Attribute per-address QEMU profile data to engine components.

Addresses are resolved with DWARF inline information, because LTO inlines most of the NNUE and
Position code. The innermost frame matching a rule decides the category. The baseline run is
subtracted per address, which removes net load and table clears, including calls into libc.

Cycle figures come from an assumed cost model, printed with the results. They are estimates of
where time would go on a Cortex-A9, not measurements of one.
"""
import argparse
import collections
import json
import re
import subprocess

RULES = [
    ("nnue_fc", r"AffineTransform|ClippedReLU|SqrClippedReLU|NetworkArchitecture::propagate|affine_transform"),
    ("nnue_ft_output", r"FeatureTransformer::transform|transform_perspective"),
    ("nnue_feature_index", r"FullThreats::|PP_3Wide::|HalfKAv2_hm::"),
    ("nnue_accumulator", r"update_accumulator|apply_combined|apply_psq|apply_threat|apply_psqt|AccumulatorStack::|"
                         r"AccumulatorCaches|load_tile|store_tile|get_changed_pieces|Eval::NNUE::"),
    ("eval_wrapper", r"Eval::evaluate|Search::Worker::evaluate"),
    ("position_threats", r"update_piece_threats|Position::update_threats|DirtyThreats|DirtyThreat"),
    ("position_do_undo", r"Position::do_move|Position::undo_move|Position::do_null_move|Position::undo_null_move|"
                         r"Position::put_piece|Position::remove_piece|Position::move_piece|Position::swap_piece|"
                         r"Position::do_castling|Position::set_check_info|Position::update_slider"),
    ("movegen", r"Stockfish::generate|generate_|MoveList"),
    ("movepick", r"MovePicker|partial_insertion_sort"),
    ("see", r"Position::see_ge"),
    ("position_queries", r"Position::legal|Position::pseudo_legal|Position::gives_check|Position::attackers_to|"
                         r"Position::slider_blockers|Position::is_draw|Position::is_repetition|"
                         r"Position::upcoming_repetition|Position::key"),
    ("tt", r"TranspositionTable|TTEntry|TTWriter|TTData"),
    ("history", r"History|update_all_stats|update_quiet|update_continuation|update_correction|correction_value|"
                r"StatsEntry|SharedHistories"),
    ("search_core", r"Search::Worker::|Search::SearchManager|Search::"),
]
COMPILED = [(name, re.compile(pattern)) for name, pattern in RULES]
GROUPS = {
    "nnue_total": {"nnue_fc", "nnue_ft_output", "nnue_feature_index", "nnue_accumulator", "eval_wrapper"},
    "nnue_arithmetic": {"nnue_fc", "nnue_ft_output", "nnue_accumulator"},
    "threat_related": {"nnue_feature_index", "position_threats"},
}
# Assumed costs in cycles: base CPI, L1 miss that hits L2, L2 miss.
SCENARIOS = {"low": (1.0, 10, 60), "mid": (1.3, 20, 120), "high": (1.6, 30, 200)}
LOAD = re.compile(r"^(ldr|ldm|pop|vld|vldr|vldm|vpop|tbb|tbh)")
STORE = re.compile(r"^(str|stm|push|vst|vstr|vstm|vpush)")


def read_insns(path):
    counts, disas = collections.Counter(), {}
    with open(path) as f:
        for line in f:
            addr, count, text = line.rstrip("\n").split(" ", 2)
            a = int(addr, 16)
            counts[a] += int(count)
            disas[a] = text
    return counts, disas


CACHE_LINE = re.compile(r"^0x([0-9a-f]+)(?: \(.*\))?, (\d+), ")


def read_cache(path):
    sections = {"data": collections.Counter(), "fetch": collections.Counter(), "l2": collections.Counter()}
    totals, current = None, None
    with open(path) as f:
        lines = iter(f)
        for line in lines:
            if line.startswith("core #"):
                totals = next(lines).split()
            elif line.startswith("address, data"):
                current = sections["data"]
            elif line.startswith("address, fetch"):
                current = sections["fetch"]
            elif line.startswith("address, L2"):
                current = sections["l2"]
            elif current is not None:
                m = CACHE_LINE.match(line)
                if m:
                    current[int(m.group(1), 16)] += int(m.group(2))
    return sections, totals


def minus(a, b):
    return collections.Counter({k: v - b.get(k, 0) for k, v in a.items() if v - b.get(k, 0) > 0})


def resolve(tool, binary, addresses):
    """Returns addr -> list of demangled function names, innermost first."""
    proc = subprocess.run([tool, "-a", "-f", "-i", "-C", "-e", binary],
                          input="\n".join(hex(a) for a in addresses) + "\n",
                          capture_output=True, text=True, check=True)
    chains, current = {}, None
    lines = proc.stdout.splitlines()
    i = 0
    while i < len(lines):
        if lines[i].startswith("0x"):
            current = int(lines[i], 16)
            chains[current] = []
            i += 1
        else:
            chains[current].append(lines[i])
            i += 2
    return chains


def classify(chain):
    for frame in chain:
        for name, pattern in COMPILED:
            if pattern.search(frame):
                return name
    if chain and chain[0] != "??":
        return "other"
    return "no_debug_info"


def short(frame):
    return re.sub(r"\(.*", "", frame)[:60]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    ap.add_argument("--insn", required=True)
    ap.add_argument("--cache", help="omit for sample data such as x86 perf")
    ap.add_argument("--addr2line", default="arm-linux-gnueabihf-addr2line")
    ap.add_argument("--base-insn")
    ap.add_argument("--base-cache")
    ap.add_argument("--nodes", type=int, default=0)
    ap.add_argument("--json")
    args = ap.parse_args()

    insn, disas = read_insns(args.insn)
    cache = {"data": collections.Counter(), "fetch": collections.Counter(), "l2": collections.Counter()}
    totals = None
    if args.cache:
        cache, totals = read_cache(args.cache)
    if args.base_insn:
        base, _ = read_insns(args.base_insn)
        insn = minus(insn, base)
    if args.base_cache:
        base_cache, _ = read_cache(args.base_cache)
        for k in cache:
            cache[k] = minus(cache[k], base_cache[k])

    addresses = sorted(set(insn) | set(cache["data"]) | set(cache["fetch"]) | set(cache["l2"]))
    chains = resolve(args.addr2line, args.binary, addresses)

    cat = collections.defaultdict(collections.Counter)
    func = collections.Counter()
    other = collections.Counter()
    unresolved_symbols = collections.Counter()
    for a in addresses:
        chain = chains.get(a, [])
        name = classify(chain)
        n = insn.get(a, 0)
        c = cat[name]
        c["insn"] += n
        text = disas.get(a, "")
        if LOAD.match(text):
            c["loads"] += n
        elif STORE.match(text):
            c["stores"] += n
        c["l1d"] += cache["data"].get(a, 0)
        c["l1i"] += cache["fetch"].get(a, 0)
        c["l2"] += cache["l2"].get(a, 0)
        if chain:
            func[short(chain[0])] += n
            if name in ("other", "no_debug_info"):
                other[short(chain[0])] += n

    def cycles(c, scenario):
        cpi, l2hit, mem = SCENARIOS[scenario]
        hits = max(c["l1d"] + c["l1i"] - c["l2"], 0)
        return c["insn"] * cpi + hits * l2hit + c["l2"] * mem

    total_insn = sum(c["insn"] for c in cat.values())
    total_cycles = {s: sum(cycles(c, s) for c in cat.values()) for s in SCENARIOS}

    print(f"instructions after baseline: {total_insn:,}" + (f"  per node: {total_insn / args.nodes:,.0f}" if args.nodes else ""))
    print(f"{'category':22} {'insn%':>6} {'low%':>6} {'mid%':>6} {'high%':>6} {'load%':>6} {'L1d/kI':>7} {'L2/kI':>7}")
    rows = {}
    for name, c in sorted(cat.items(), key=lambda kv: -kv[1]["insn"]):
        row = {"insn": c["insn"], "insn_share": c["insn"] / total_insn, "loads": c["loads"], "stores": c["stores"],
               "l1d_miss": c["l1d"], "l1i_miss": c["l1i"], "l2_miss": c["l2"]}
        for s in SCENARIOS:
            row[f"time_share_{s}"] = cycles(c, s) / total_cycles[s]
        rows[name] = row
        k = max(c["insn"], 1) / 1000
        print(f"{name:22} {row['insn_share']*100:6.1f} {row['time_share_low']*100:6.1f} {row['time_share_mid']*100:6.1f} "
              f"{row['time_share_high']*100:6.1f} {c['loads']/max(c['insn'],1)*100:6.1f} {c['l1d']/k:7.1f} {c['l2']/k:7.2f}")

    groups = {}
    print()
    for name, members in GROUPS.items():
        g = {"insn_share": sum(rows[m]["insn_share"] for m in members if m in rows)}
        for s in SCENARIOS:
            g[f"time_share_{s}"] = sum(rows[m][f"time_share_{s}"] for m in members if m in rows)
        g["speedup_limit_mid"] = 1 / max(1 - g["time_share_mid"], 1e-9)
        groups[name] = g
        print(f"{name:18} insn {g['insn_share']*100:5.1f}%  time low/mid/high {g['time_share_low']*100:5.1f}/"
              f"{g['time_share_mid']*100:5.1f}/{g['time_share_high']*100:5.1f}%  limit(mid) {g['speedup_limit_mid']:.2f}x")

    print("\ntop functions by instructions (innermost inline frame):")
    for f, n in func.most_common(25):
        print(f"  {n/total_insn*100:5.1f}%  {f}")
    print("\nlargest unclassified:")
    for f, n in other.most_common(10):
        print(f"  {n/total_insn*100:5.1f}%  {f}")

    if args.json:
        json.dump({"total_insn": total_insn, "nodes": args.nodes, "scenarios": SCENARIOS, "categories": rows, "groups": groups,
                   "raw_cache_totals": totals}, open(args.json, "w"), indent=2)


if __name__ == "__main__":
    main()
