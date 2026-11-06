// Request-planning model for the NNUE core on the search trace (docs/reports/perf_proposal.md).
//
// Replays golden_harness --events through nnue_ctx::Context, exactly as
// sw/board/nnue_board.cpp --mode events does, and counts the weight rows each planning policy
// makes the core read. The STACK row counts must equal the board's req_psq_row / req_active_row
// counters. Memory cycles use the board's bandwidth bound (psq row 256 beats, active row 128) and
// the gap factor measured on the board. The times are a model, not a measurement.
//
// The planning time covers what nnue_board times as plan_us: feature conversion, planning and
// descriptor encoding, on whatever machine runs this (x86, or the Cortex-A9 on the board).
//
// Usage: plan_sim <search.ev> [--slots N]... [--only K]
//   default: STACK, NEAREST with 32/64/128 slots, NEAREST 32 slots with 4/8/16 candidates
//   --only K: NEAREST, 32 slots, K candidates only (0 = all), e.g. for profiling
//   --preload-mb M: read the first M MB of events into memory first, so the timed planning is
//     not interleaved with file reads (SD card DMA on the board). Fewer evaluations are replayed.

#include <chrono>
#include <fstream>
#include <sstream>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "nnue_golden.h"

using namespace nnue_golden;

namespace {

constexpr double GAP = 891378596.0 / 815103488.0;  // board events run: row_wait / bandwidth bound
size_t           g_preloadBytes = 0;

void run(const char* path, nnue_ctx::Policy policy, uint32_t slots, uint32_t candidates, bool first) {
    std::unique_ptr<EventCursor>        file;
    std::unique_ptr<std::istringstream> mem;
    if (g_preloadBytes)
    {
        std::ifstream in(path, std::ios::binary);
        in.seekg(16);
        std::string buf(g_preloadBytes, '\0');
        in.read(&buf[0], std::streamsize(buf.size()));
        buf.resize(size_t(in.gcount()));
        mem  = std::make_unique<std::istringstream>(std::move(buf));
        file = std::make_unique<EventCursor>(*mem);
    }
    else
        file = std::make_unique<EventCursor>(path, 16);
    EventCursor& cursor = *file;
    Context      ctx(0, slots, policy);
    ctx.candidates = candidates;
    auto        rec = std::make_unique<StimRec>();
    uint64_t    evals = 0, psqRows = 0, activeRows = 0, refresh = 0;
    double      planS = 0;
    std::vector<uint64_t> desc;
    FullFeatures          full;
    Request               r;
    while (cursor.next_eval(ctx, *rec))
    {
        const auto t0 = std::chrono::steady_clock::now();
        full_of(rec->f, full);
        ctx.plan(full, r);
        encode_descriptor(desc, r, uint32_t(evals), rec->stm, rec->bucket, 1);
        planS += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        ++evals;
        for (int c = 0; c < 2; ++c)
        {
            if (r.op[c] == nnue_ctx::OP_REFRESH)
                ++refresh, ++psqRows;  // bias row
            psqRows += r.lists[c][0].size() + r.lists[c][1].size();
            activeRows += r.lists[c][2].size() + r.lists[c][3].size();
        }
        ctx.commit();
    }
    const auto&  s   = ctx.stats;
    const double cyc = GAP * double(psqRows * 256 + activeRows * 128) / double(evals);
    std::printf("%s  {\"policy\": \"%s\", \"slots\": %u, \"candidates\": %u, \"evals\": %llu, \"perspective_refresh\": %llu, "
                "\"perspective_incremental\": %llu, \"reuse\": %llu, \"evictions\": %llu, \"psq_rows\": %llu, "
                "\"active_rows\": %llu, \"rows_per_eval\": %.2f, \"row_wait_us_per_eval\": %.2f, "
                "\"plan_us_per_eval\": %.2f, \"slots_walked_per_eval\": %.2f, \"slots_pruned_per_eval\": %.2f}",
                first ? "" : ",\n", policy == nnue_ctx::STACK ? "stack" : "nearest", slots, candidates,
                (unsigned long long) evals, (unsigned long long) refresh, (unsigned long long) s.incremental,
                (unsigned long long) s.reuse, (unsigned long long) s.evictions, (unsigned long long) psqRows,
                (unsigned long long) activeRows, double(psqRows + activeRows) / double(evals), cyc / 100.0,
                planS * 1e6 / double(evals), double(s.slotsWalked) / double(evals), double(s.slotsPruned) / double(evals));
    std::fflush(stdout);
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2)
    {
        std::printf("usage: plan_sim <search.ev> [--slots N]...\n");
        return 2;
    }
    {
        std::ifstream head(argv[1], std::ios::binary);
        if (!read_header(head, EVENTS_MAGIC))
            return 1;
    }
    std::vector<uint32_t> slotCounts;
    int                   only = -1;
    for (int i = 2; i + 1 < argc; i += 2)
        if (std::string(argv[i]) == "--slots")
            slotCounts.push_back(uint32_t(std::stoul(argv[i + 1])));
        else if (std::string(argv[i]) == "--only")
            only = std::stoi(argv[i + 1]);
        else if (std::string(argv[i]) == "--preload-mb")
            g_preloadBytes = size_t(std::stoul(argv[i + 1])) << 20;
    if (only >= 0)
    {
        std::printf("[\n");
        run(argv[1], nnue_ctx::NEAREST, 32, uint32_t(only), true);
        std::printf("\n]\n");
        return 0;
    }
    if (slotCounts.empty())
        slotCounts = {32, 64, 128};

    std::printf("[\n");
    run(argv[1], nnue_ctx::STACK, 32, 0, true);
    for (uint32_t n : slotCounts)
        run(argv[1], nnue_ctx::NEAREST, n, 0, false);
    for (uint32_t k : {4u, 8u, 16u})
        run(argv[1], nnue_ctx::NEAREST, 32, k, false);
    std::printf("\n]\n");
    return 0;
}
