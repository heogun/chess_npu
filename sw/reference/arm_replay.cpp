// ARM-only reference timing for the search trace (BENCHMARK.md, "Trace ARM").
//
// Replays the search recorded by sw/host/patches/0001-trace-search-ops.patch through the
// unmodified official Position / AccumulatorStack / AccumulatorCaches / Network code, built with
// the official Makefile flags for the target (armv7-neon on the DE1-SoC). The evaluations that
// golden_harness wrote to the event stream (the same window the FPGA harness runs) are timed
// around Network::evaluate(), which covers the accumulator update and the layers, and their
// (psqt, positional) pair is compared with the golden record. Every logged evaluation is also
// checked through Eval::evaluate() against the value the official search logged, outside the
// timed region.
//
// Modes:
//   search  (default) the search's own accumulator stack and Finny cache, as the engine runs it.
//   cold    each window evaluation from an empty stack and cleared cache: full refresh cost.
//
// Usage: arm_replay <net> <bench.ops> <search.ev> [--mode search|cold] [--evals-per-root N]
//                   [--max-evals N] [--report F]

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include "attacks.h"
#include "evaluate.h"
#include "position.h"
#include "types.h"

#include "nnue/network.h"
#include "nnue/nnue_accumulator.h"

#include "nnue_golden.h"

using namespace Stockfish;
using Stockfish::Eval::NNUE::AccumulatorCaches;
using Stockfish::Eval::NNUE::AccumulatorStack;
using Stockfish::Eval::NNUE::Network;

namespace {

[[noreturn]] void die(const std::string& m) {
    std::fprintf(stderr, "FATAL: %s\n", m.c_str());
    std::exit(1);
}

uint64_t now_ns() {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

struct Series {
    std::vector<double> v;
    void                add(double x) { v.push_back(x); }
    std::string         json() {
        if (v.empty())
            return "{\"count\": 0}";
        std::vector<double> s = v;
        std::sort(s.begin(), s.end());
        double sum = 0;
        for (double x : s)
            sum += x;
        auto at = [&](double q) { return s[std::min(s.size() - 1, size_t(q * double(s.size())))]; };
        char buf[320];
        std::snprintf(buf, sizeof(buf),
                      "{\"count\": %zu, \"unit\": \"us\", \"total_s\": %.4f, \"mean\": %.2f, \"min\": %.2f, "
                      "\"median\": %.2f, \"p95\": %.2f, \"p99\": %.2f, \"max\": %.2f}",
                      s.size(), sum / 1e6, sum / double(s.size()), s.front(), at(0.5), at(0.95), at(0.99),
                      s.back());
        return buf;
    }
};

// Golden pairs of the window evaluations, in stream order.
std::vector<std::pair<int32_t, int32_t>> read_golden(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in || !nnue_golden::read_header(in, nnue_golden::EVENTS_MAGIC))
        die("cannot read events " + path);
    std::vector<std::pair<int32_t, int32_t>> out;
    auto                                     rec = std::make_unique<nnue_golden::StimRec>();
    uint32_t                                 tag;
    while (in.read(reinterpret_cast<char*>(&tag), sizeof(tag)))
    {
        if (tag == nnue_golden::EV_PUSH)
            nnue_golden::EventCursor::read_push(in);
        else if (tag == nnue_golden::EV_EVAL)
        {
            in.read(reinterpret_cast<char*>(rec.get()), sizeof(*rec));
            out.emplace_back(rec->t.outPsqt, rec->t.outPos);
        }
        else if (tag != nnue_golden::EV_ROOT && tag != nnue_golden::EV_POP)
            die("unknown event tag");
    }
    return out;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 4)
    {
        std::printf("usage: arm_replay <net> <bench.ops> <search.ev> [--mode search|cold] "
                    "[--evals-per-root N] [--max-evals N] [--report F]\n");
        return 2;
    }
    std::string mode = "search", reportPath;
    uint64_t    perRoot = 2000, maxEvals = UINT64_MAX;
    for (int i = 4; i + 1 < argc; i += 2)
    {
        const std::string k = argv[i], v = argv[i + 1];
        if (k == "--mode")
            mode = v;
        else if (k == "--evals-per-root")
            perRoot = std::stoull(v);
        else if (k == "--max-evals")
            maxEvals = std::stoull(v);
        else if (k == "--report")
            reportPath = v;
        else
            die("unknown option " + k);
    }
    if (mode != "search" && mode != "cold")
        die("mode must be search or cold");
    const bool cold = mode == "cold";

    Attacks::init();
    Position::init();

    const auto golden = read_golden(argv[3]);

    auto              net = std::make_unique<Network>();
    Eval::NNUE::EvalFile ef;
    net->load_external(std::filesystem::path{}, argv[1], ef);
    if (!ef.current.has_value())
        die("network refused");

    struct OpRec {
        int32_t type, a, b;
    };
    std::ifstream in(argv[2], std::ios::binary);
    if (!in)
        die("cannot open ops");
    std::vector<uint64_t> evalsPerRoot;
    {
        OpRec r;
        while (in.read(reinterpret_cast<char*>(&r), sizeof(r)))
        {
            if (r.type == 0)
            {
                in.seekg(r.a, std::ios::cur);
                evalsPerRoot.push_back(0);
            }
            else if (r.type == 5)
                ++evalsPerRoot.back();
        }
        in.clear();
        in.seekg(0);
    }

    auto stack     = std::make_unique<AccumulatorStack>();
    auto cache     = std::make_unique<AccumulatorCaches>(*net);
    auto coldStack = std::make_unique<AccumulatorStack>();
    auto coldCache = std::make_unique<AccumulatorCaches>(*net);

    Position              pos;
    std::deque<StateInfo> states;
    std::vector<Move>     history;

    // Timer cost: back-to-back reads.
    Series timer;
    for (int i = 0; i < 10000; ++i)
    {
        const uint64_t a = now_ns(), b = now_ns();
        timer.add(double(b - a) / 1000.0);
    }

    Series   evalUs;
    uint64_t roots = 0, evalIndex = 0, windowStart = 0, windowEnd = 0, total = 0, windowEvals = 0;
    uint64_t pairMismatch = 0, valueMismatch = 0, valueChecked = 0;
    int64_t  checksum = 0;
    OpRec    r;
    const uint64_t wallStart = now_ns();
    while (total < maxEvals && in.read(reinterpret_cast<char*>(&r), sizeof(r)))
    {
        switch (r.type)
        {
        case 0: {
            std::string fen(size_t(r.a), '\0');
            in.read(fen.data(), r.a);
            states.clear();
            history.clear();
            states.emplace_back();
            pos.set(fen, false, &states.back());
            stack->reset();
            const uint64_t n = evalsPerRoot[roots];
            windowStart      = n > perRoot ? (n - perRoot) / 2 : 0;
            windowEnd        = windowStart + perRoot;
            evalIndex        = 0;
            ++roots;
            break;
        }
        case 1: {
            const Move m(uint16_t(r.a));
            states.emplace_back();
            auto& d = stack->push();
            pos.do_move(m, states.back(), pos.gives_check(m), d, nullptr, nullptr);
            history.push_back(m);
            break;
        }
        case 3:
            states.emplace_back();
            pos.do_null_move(states.back());
            history.push_back(Move::null());
            break;
        case 2:
        case 4: {
            const Move m = history.back();
            history.pop_back();
            if (m == Move::null())
                pos.undo_null_move();
            else
            {
                pos.undo_move(m);
                stack->pop();
            }
            states.pop_back();
            break;
        }
        case 5: {
            const bool window = evalIndex >= windowStart && evalIndex < windowEnd;
            if (window)
            {
                if (windowEvals >= golden.size())
                    die("more window evaluations than the event stream holds");
                Eval::NNUE::NetworkOutput out{};
                if (cold)
                {
                    coldStack->reset();
                    coldCache->clear(*net);
                    const uint64_t t0 = now_ns();
                    out               = net->evaluate(pos, *coldStack, *coldCache);
                    evalUs.add(double(now_ns() - t0) / 1000.0);
                }
                else
                {
                    const uint64_t t0 = now_ns();
                    out               = net->evaluate(pos, *stack, *cache);
                    evalUs.add(double(now_ns() - t0) / 1000.0);
                }
                const auto [psqt, positional] = out;
                checksum += psqt + positional;
                if (psqt != golden[windowEvals].first || positional != golden[windowEvals].second)
                {
                    if (pairMismatch < 10)
                        std::printf("MISMATCH window eval %llu: got (%d, %d) want (%d, %d)\n",
                                    (unsigned long long) windowEvals, int(psqt), int(positional),
                                    golden[windowEvals].first, golden[windowEvals].second);
                    ++pairMismatch;
                }
                ++windowEvals;
                if (windowEvals % 10000 == 0)
                    std::printf("  %llu window evals, mismatches=%llu\n", (unsigned long long) windowEvals,
                                (unsigned long long) (pairMismatch + valueMismatch));
            }
            // The search's own evaluation keeps the stack and cache in the state the engine had.
            if (!cold || !window)
            {
                ++valueChecked;
                if (Eval::evaluate(*net, pos, *stack, *cache, r.a) != r.b)
                    ++valueMismatch;
            }
            ++evalIndex;
            ++total;
            break;
        }
        default:
            die("unknown operation in search log");
        }
    }
    const double wallS = double(now_ns() - wallStart) / 1e9;
    if (maxEvals == UINT64_MAX && windowEvals != golden.size())
        die("window evaluations differ from the event stream");

    const bool pass = pairMismatch == 0 && valueMismatch == 0 && windowEvals > 0;
    std::string report = "{\n  \"mode\": \"" + mode + "\",\n  \"roots\": " + std::to_string(roots)
                       + ",\n  \"evaluations_replayed\": " + std::to_string(total)
                       + ",\n  \"window_evaluations\": " + std::to_string(windowEvals)
                       + ",\n  \"pair_mismatches\": " + std::to_string(pairMismatch)
                       + ",\n  \"logged_values_checked\": " + std::to_string(valueChecked)
                       + ",\n  \"logged_value_mismatches\": " + std::to_string(valueMismatch)
                       + ",\n  \"checksum\": " + std::to_string(checksum)
                       + ",\n  \"wall_s\": " + std::to_string(wallS)
                       + ",\n  \"timer_us\": " + timer.json() + ",\n  \"eval_us\": " + evalUs.json() + "\n}\n";
    std::printf("%s", report.c_str());
    if (!reportPath.empty())
    {
        std::ofstream rep(reportPath);
        rep << report;
    }
    std::printf("RESULT %s (arm_replay %s, %llu window evaluations, mismatches %llu)\n", pass ? "PASS" : "FAIL",
                mode.c_str(), (unsigned long long) windowEvals,
                (unsigned long long) (pairMismatch + valueMismatch));
    return pass ? 0 : 1;
}
