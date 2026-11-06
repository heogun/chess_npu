// Request-planning model for the NNUE core on the search trace (docs/reports/perf_proposal.md).
//
// Replays golden_harness --events through nnue_ctx::Context, exactly as
// sw/board/nnue_board.cpp --mode events does, and counts the weight rows each planning policy
// makes the core read. The STACK row counts must equal the board's req_psq_row / req_active_row
// counters. Memory cycles use the board's bandwidth bound (psq row 256 beats, active row 128) and
// the gap factor measured on the board. The times are a model, not a measurement.
//
// Usage: plan_sim <search.ev> [--slots N]...   (default 32 64 128 for the NEAREST policy)

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "nnue_golden.h"

using namespace nnue_golden;

namespace {

constexpr double GAP = 891378596.0 / 815103488.0;  // board events run: row_wait / bandwidth bound

void run(const char* path, nnue_ctx::Policy policy, uint32_t slots, uint32_t candidates, bool first) {
    EventCursor cursor(path, 16);
    Context     ctx(0, slots, policy);
    ctx.candidates = candidates;
    auto        rec = std::make_unique<StimRec>();
    uint64_t    evals = 0, psqRows = 0, activeRows = 0, refresh = 0;
    double      planS = 0;
    while (cursor.next_eval(ctx, *rec))
    {
        const auto         t0   = std::chrono::steady_clock::now();
        const FullFeatures full = full_of(rec->f);
        const Request      r    = ctx.plan(full);
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
                "\"host_plan_us_per_eval_x86\": %.2f, \"slots_walked_per_eval\": %.2f, \"slots_pruned_per_eval\": %.2f}",
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
    for (int i = 2; i + 1 < argc; i += 2)
        if (std::string(argv[i]) == "--slots")
            slotCounts.push_back(uint32_t(std::stoul(argv[i + 1])));
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
