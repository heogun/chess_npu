// SF19 NNUE core on the DE1-SoC: replays golden stimulus through the real hardware and compares
// the final pair and every intermediate tensor with the official Stockfish results. Uses the same
// record formats, descriptor encoding, request planner and checks as the Verilator testbench
// (sw/host/nnue_golden.h, sw/host/nnue_ctx.h).
//
//   nnue_board <weights.bin> <input> [--mode refresh|events] [--max N] [--tensor-every K]
//              [--no-load] [--policy stack|nearest|hw] [--candidates K] [--mru-order] [--report out.json]
//     refresh: <input> is a golden_harness --stim file; every state is a full refresh.
//     events:  <input> is a golden_harness --events file; one context plans each request from the
//              official per-ply changes, as tb_core --mode events --contexts 1 --no-chaos.
//              --policy and --candidates select the planner as in tb_core (hw: the core
//              chooses the sources; needs an image with HW_PLAN). --mru-order merges
//              NEAREST candidates in MRU order instead of lower-bound order (same requests).
//
// Device access, window layout and requirements: sw/host/nnue_device.h.
// Timing: host = descriptor write to result read (communication, synchronisation and retrieval
// included); fpga = CYCLES at 100 MHz; plan = ARM time to plan and encode the request.
#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "nnue_device.h"

using namespace nnue_golden;
using nnue_device::FCLK_HZ;
using nnue_device::now_ns;

namespace {

nnue_device::Board dev;

[[noreturn]] void die(const char* msg) {
    std::printf("FAIL: %s\n", msg);
    std::exit(1);
}

std::vector<uint64_t> descWords;

// Writes the descriptor, starts the core and waits. Returns STATUS.
uint32_t run_eval(uint64_t& hostNs) {
    const uint32_t st = dev.run(descWords, hostNs);
    if (st == nnue_device::STATUS_TIMEOUT)
        die("evaluation did not finish within 1 s");
    return st;
}

int64_t     mismatches = 0;
uint64_t    compared   = 0;
std::string lastRequest;

void on_mismatch(const StimRec& s, const char* tensor, int index, int64_t got, int64_t want) {
    if (mismatches < 20)
        std::printf("MISMATCH state=%llu bucket=%u stm=%u tensor=%s index=%d got=%lld want=%lld request: %s\n",
                    (unsigned long long) s.id, s.bucket, s.stm, tensor, index, (long long) got, (long long) want,
                    lastRequest.c_str());
    ++mismatches;
}

struct Series {
    std::vector<uint32_t> host, fpga, plan;
};

std::string pct(std::vector<uint32_t> v, double scale, const char* unit) {
    std::sort(v.begin(), v.end());
    auto at = [&](double p) { return v.empty() ? 0.0 : double(v[size_t(p * double(v.size() - 1))]) * scale; };
    double mean = 0;
    for (uint32_t x : v)
        mean += double(x) * scale;
    mean = v.empty() ? 0 : mean / double(v.size());
    char buf[256];
    std::snprintf(buf, sizeof buf,
                  "{\"count\": %zu, \"unit\": \"%s\", \"mean\": %.2f, \"min\": %.2f, \"median\": %.2f, "
                  "\"p95\": %.2f, \"p99\": %.2f, \"max\": %.2f}",
                  v.size(), unit, mean, at(0), at(0.5), at(0.95), at(0.99), at(1));
    return buf;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 3)
    {
        std::printf("usage: nnue_board weights.bin input [--mode refresh|events] [--max N] [--tensor-every K] "
                    "[--no-load] [--policy stack|nearest|hw] [--candidates K] [--mru-order] [--report F]\n");
        return 2;
    }
    uint64_t    maxStates = UINT64_MAX, tensorEvery = 1;
    std::string mode = "refresh", reportPath, policyName = "stack";
    uint32_t    candidates = 0;
    bool        load = true, mruOrder = false;
    for (int i = 3; i < argc; ++i)
    {
        const std::string k = argv[i];
        if (k == "--no-load")
            load = false;
        else if (k == "--mru-order")
            mruOrder = true;
        else if (i + 1 >= argc)
            return 2;
        else if (k == "--max")
            maxStates = std::stoull(argv[++i]);
        else if (k == "--tensor-every")
            tensorEvery = std::max<uint64_t>(1, std::stoull(argv[++i]));
        else if (k == "--mode")
            mode = argv[++i];
        else if (k == "--report")
            reportPath = argv[++i];
        else if (k == "--policy")
            policyName = argv[++i];
        else if (k == "--candidates")
            candidates = uint32_t(std::stoul(argv[++i]));
        else
            return 2;
    }
    if (policyName != "stack" && policyName != "nearest" && policyName != "hw")
        return 2;

    if (const std::string e = dev.open(argv[1], load, stdout); !e.empty())
        die(e.c_str());

    auto     rec = std::make_unique<StimRec>();
    uint64_t states = 0, full = 0, errors = 0, perf[PERF_COUNT] = {}, perfCycles = 0, words = 0;
    Series   all, reuse, incr, refresh;
    uint64_t bucket[8] = {};

    auto finish_eval = [&](const Request& r, uint32_t st, uint32_t seq, uint32_t ctxId, uint64_t hostNs,
                           uint64_t planNs) {
        if (!(st & 2) || (st & 4) || dev.csr_read(CSR_SEQ) != seq || dev.csr_read(CSR_CTX) != ctxId)
        {
            std::printf("ERROR state %llu status=0x%08X err=%u request: %s\n", (unsigned long long) rec->id, st,
                        (st >> 8) & 0xFF, lastRequest.c_str());
            ++errors;
            return false;
        }
        auto fail = [&](const char* n, int i, int64_t got, int64_t want) { on_mismatch(*rec, n, i, got, want); };
        compared += check_outputs(dev, *rec, fail);
        if (states % tensorEvery == 0)
        {
            compared += check_tensors(dev, *rec, fail);
            ++full;
        }
        const uint32_t cyc = dev.csr_read(CSR_CYCLES);
        words += dev.csr_read(CSR_WORDS);
        uint64_t stageSum = 0;
        for (int i = 0; i < PERF_COUNT; ++i)
        {
            dev.csr_write(CSR_PSEL, uint32_t(i));
            const uint32_t v = dev.csr_read(CSR_PDATA);
            perf[i] += v;
            if (i < PERF_STAGES)
                stageSum += v;
        }
        if (stageSum != cyc)
        {
            std::printf("ERROR state %llu: stage counters sum to %llu, CYCLES %u\n", (unsigned long long) rec->id,
                        (unsigned long long) stageSum, cyc);
            ++errors;
        }
        perfCycles += cyc;
        Series* cls = nullptr;
        if (r.op[0] == nnue_ctx::OP_NONE && r.op[1] == nnue_ctx::OP_NONE)
            cls = &reuse;
        else if (r.op[0] == nnue_ctx::OP_INCR && r.op[1] == nnue_ctx::OP_INCR)
            cls = &incr;
        else if (r.op[0] == nnue_ctx::OP_REFRESH && r.op[1] == nnue_ctx::OP_REFRESH)
            cls = &refresh;
        for (Series* s : {&all, cls})
            if (s)
            {
                s->host.push_back(uint32_t(hostNs));
                s->fpga.push_back(cyc);
                s->plan.push_back(uint32_t(planNs));
            }
        ++bucket[rec->bucket & 7];
        ++states;
        if (states % 1000 == 0)
        {
            std::printf("  %llu states, mismatches=%lld errors=%llu\n", (unsigned long long) states,
                        (long long) mismatches, (unsigned long long) errors);
            std::fflush(stdout);
        }
        return true;
    };

    std::unique_ptr<Context> ctx;
    if (mode == "refresh")
    {
        std::ifstream stim(argv[2], std::ios::binary);
        if (!read_header(stim, STIM_MAGIC))
            return 1;
        while (states < maxStates && stim.read(reinterpret_cast<char*>(rec.get()), sizeof(StimRec)))
        {
            const uint64_t t0  = now_ns();
            const uint32_t seq = uint32_t(rec->id), ctxId = uint32_t(states & 0xFFFF);
            const Request  r   = refresh_request(rec->f, uint32_t(states % ACC_SLOTS));
            encode_descriptor(descWords, r, seq, rec->stm, rec->bucket, ctxId);
            const uint64_t planNs = now_ns() - t0;
            uint64_t       hostNs;
            const uint32_t st = run_eval(hostNs);
            if (!finish_eval(r, st, seq, ctxId, hostNs, planNs))
                break;
        }
    }
    else if (mode == "events")
    {
        {
            std::ifstream head(argv[2], std::ios::binary);
            if (!read_header(head, EVENTS_MAGIC))
                return 1;
        }
        EventCursor cursor(argv[2], 16);
        ctx = std::make_unique<Context>(0, uint32_t(ACC_SLOTS),
                                        policyName == "nearest" ? nnue_ctx::NEAREST
                                        : policyName == "hw"    ? nnue_ctx::HWPLAN
                                                                  : nnue_ctx::STACK);
        if (policyName == "hw" && !(dev.csr_read(CSR_CAPS) & CAPS_HW_PLAN))
            die("--policy hw needs an image with the hardware planner (CSR CAPS bit 1)");
        ctx->candidates = candidates;
        ctx->boundOrder = !mruOrder;
        FullFeatures fullF;
        Request      r;
        while (states < maxStates && cursor.next_eval(*ctx, *rec))
        {
            const uint64_t t0 = now_ns();
            full_of(rec->f, fullF);
            ctx->plan(fullF, r);
            const uint32_t     seq  = uint32_t(states), ctxId = 1;
            encode_descriptor(descWords, r, seq, rec->stm, rec->bucket, ctxId);
            const uint64_t planNs = now_ns() - t0;
            char           buf[160];
            std::snprintf(buf, sizeof buf, "eval=%llu dst=%u op=%u,%u src=%u,%u", (unsigned long long) states, r.dst,
                          r.op[0], r.op[1], r.src[0], r.src[1]);
            lastRequest = buf;
            uint64_t       hostNs;
            const uint32_t st = run_eval(hostNs);
            if (!finish_eval(r, st, seq, ctxId, hostNs, planNs))
                break;
            if (policyName == "hw")
                ctx->commit_plan(dev.csr_read(CSR_PLAN));
            else
                ctx->commit();
        }
    }
    else
        die("unknown mode");

    std::string out = "{\n  \"mode\": \"" + mode + "\",\n";
    char        buf[512];
    std::snprintf(buf, sizeof buf,
                  "  \"states\": %llu,\n  \"full_tensor_states\": %llu,\n  \"values_compared\": %llu,\n"
                  "  \"mismatches\": %lld,\n  \"errors\": %llu,\n  \"fallbacks\": 0,\n"
                  "  \"mean_words_per_state\": %.1f,\n  \"bucket\": [%llu, %llu, %llu, %llu, %llu, %llu, %llu, %llu],\n",
                  (unsigned long long) states, (unsigned long long) full, (unsigned long long) compared,
                  (long long) mismatches, (unsigned long long) errors, states ? double(words) / double(states) : 0.0,
                  (unsigned long long) bucket[0], (unsigned long long) bucket[1], (unsigned long long) bucket[2],
                  (unsigned long long) bucket[3], (unsigned long long) bucket[4], (unsigned long long) bucket[5],
                  (unsigned long long) bucket[6], (unsigned long long) bucket[7]);
    out += buf;
    if (ctx)
    {
        const auto& s = ctx->stats;
        std::snprintf(buf, sizeof buf,
                      "  \"host_plan\": {\"policy\": \"%s\", \"candidates\": %u, \"order\": \"%s\", \"requests\": %llu, \"reuse\": %llu, \"perspective_refresh\": %llu, "
                      "\"perspective_incremental\": %llu, \"evictions\": %llu, \"cost_refresh\": %llu},\n",
                      policyName.c_str(), candidates, mruOrder ? "mru" : "bound", (unsigned long long) s.requests, (unsigned long long) s.reuse, (unsigned long long) s.refresh,
                      (unsigned long long) s.incremental, (unsigned long long) s.evictions,
                      (unsigned long long) s.costRefresh);
        out += buf;
    }
    const struct {
        const char* name;
        Series*     s;
    } classes[] = {{"all", &all}, {"reuse_both", &reuse}, {"incremental_both", &incr}, {"refresh_both", &refresh}};
    for (const auto& k : classes)
    {
        out += std::string("  \"") + k.name + "\": {\"host_us\": " + pct(k.s->host, 1e-3, "us")
             + ", \"fpga_us\": " + pct(k.s->fpga, 1e6 / FCLK_HZ, "us") + ", \"plan_us\": " + pct(k.s->plan, 1e-3, "us")
             + "},\n";
    }
    out += "  \"perf_cycles\": " + std::to_string(perfCycles) + ",\n  \"perf\": {";
    for (int i = 0; i < PERF_COUNT; ++i)
        out += std::string(i ? ", " : "") + "\"" + PERF_NAMES[i] + "\": " + std::to_string(perf[i]);
    out += "}\n}\n";
    std::fputs(out.c_str(), stdout);
    if (!reportPath.empty())
    {
        std::FILE* f = std::fopen(reportPath.c_str(), "w");
        if (f)
            std::fputs(out.c_str(), f), std::fclose(f);
    }

    if (mismatches || errors || states == 0)
    {
        std::printf("RESULT FAIL (board)\n");
        return 1;
    }
    std::printf("RESULT PASS (board, %llu states, mismatches 0, errors 0, fallbacks 0)\n", (unsigned long long) states);
    return 0;
}
