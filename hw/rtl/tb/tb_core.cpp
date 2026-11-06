// Full-core testbench: replays golden stimulus through CSR and memory-master ports and
// compares every tensor with the official Stockfish results recorded by golden_harness.
//
// Usage: tb_core <weights.bin> <input> [--mode refresh|events] [--max N] [--seed S]
//                [--tensor-every K] [--contexts K] [--policy stack|nearest] [--candidates K]
//                [--no-negative] [--no-chaos] [--report out.json]
//   refresh: <input> is a --stim file. Every state is a full refresh on both perspectives.
//   events:  <input> is an --events file. sw/host/nnue_ctx.h plans each request from the
//            official per-ply changes, so the accumulators build on earlier hardware state.
//            --policy picks the planner (nnue_ctx::Policy); --candidates limits NEAREST's scan.
// A run is a simulation result. It does not establish correctness on the DE1-SoC.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include "Vnnue_core.h"
#include "generated_spec.h"
#include "nnue_ctx.h"
#include "nnue_golden.h"

using namespace nnue_spec;
using namespace nnue_golden;
using nnue_ctx::Context;
using nnue_ctx::FullFeatures;
using nnue_ctx::PlyDiff;
using nnue_ctx::Request;

namespace {

constexpr uint32_t WEIGHT_BASE = 0x10000000;
constexpr uint32_t DESC_ADDR   = 0x0F000000;
constexpr uint32_t WATCHDOG    = 4000;  // Matches -GWATCHDOG_CYCLES in the build.

// Memory model: in-order reads with configurable stalls and latency.
struct Mem {
    std::vector<uint64_t> weights;
    std::vector<uint64_t> desc;
    uint32_t              waitPct = 0, stallPct = 0, minLat = 1, maxLat = 1;
    bool                  hang = false;  // Accept nothing and return nothing.
    // Avalon-MM requires a command held under waitrequest to stay until it is accepted, so a
    // soft reset can be followed by one accept of the aborted run's last command. Its data is
    // discarded by the core, but its address belongs to the old descriptor, which the host may
    // already have replaced by a shorter one. That one accept reads like real memory: whatever is
    // there, without the descriptor bound.
    bool                  staleAccept = false;

    // The value is captured when the read is accepted. The range check therefore applies to
    // what the core asked for, and a later descriptor change cannot affect reads in flight.
    struct Pending {
        uint64_t data;
        uint64_t readyAt;
    };
    std::deque<Pending> queue;

    uint64_t read(uint32_t addr, bool stale = false) const {
        if (addr >= WEIGHT_BASE)
        {
            const uint64_t i = (addr - WEIGHT_BASE) / 8;
            if (i >= weights.size())
            {
                std::printf("FAIL memory read past image: 0x%08X\n", addr);
                std::exit(1);
            }
            return weights[i];
        }
        const uint64_t i = (addr - DESC_ADDR) / 8;
        if (stale && addr >= DESC_ADDR && i >= desc.size())
            return 0;
        if (addr < DESC_ADDR || i >= desc.size())
        {
            std::printf("FAIL memory read outside descriptor: 0x%08X\n", addr);
            std::exit(1);
        }
        return desc[i];
    }
};

Vnnue_core* dut;
Mem         mem;
uint64_t    simTime = 0;
uint64_t    rngState;

uint32_t rnd(uint32_t n) {
    rngState ^= rngState >> 12;
    rngState ^= rngState << 25;
    rngState ^= rngState >> 27;
    return uint32_t((rngState * 0x2545F4914F6CDD1Dull) >> 32) % n;
}

// One clock. Inputs change after the falling edge, as if driven from registers.
void tick() {
    dut->clk = 0;

    dut->m_readdatavalid = 0;
    if (!mem.hang && !mem.queue.empty() && mem.queue.front().readyAt <= simTime
        && rnd(100) >= mem.stallPct)
    {
        dut->m_readdata      = mem.queue.front().data;
        dut->m_readdatavalid = 1;
        mem.queue.pop_front();
    }
    dut->m_waitrequest = mem.hang || rnd(100) < mem.waitPct;
    dut->eval();

    if (dut->m_read && !dut->m_waitrequest)
    {
        if (dut->m_address & 7)
        {
            std::printf("FAIL unaligned master address 0x%08X\n", dut->m_address);
            std::exit(1);
        }
        const uint32_t lat = mem.minLat + rnd(mem.maxLat - mem.minLat + 1);
        for (uint32_t i = 0; i < dut->m_burstcount; ++i)
            mem.queue.push_back({mem.read(dut->m_address + i * 8, mem.staleAccept), simTime + lat + i});
        mem.staleAccept = false;
    }

    dut->clk = 1;
    dut->eval();
    ++simTime;
}

void csr_write(uint32_t addr, uint32_t data) {
    if (addr == CSR_CONTROL && (data & CTRL_SOFT_RESET) && dut->m_read)
        mem.staleAccept = true;
    dut->csr_address   = addr;
    dut->csr_write     = 1;
    dut->csr_writedata = data;
    tick();
    dut->csr_write = 0;
}

uint32_t csr_read(uint32_t addr) {
    dut->csr_address = addr;
    dut->csr_read    = 1;
    dut->eval();
    while (dut->csr_waitrequest)
    {
        tick();
        dut->eval();
    }
    tick();
    dut->csr_read = 0;
    dut->eval();
    return dut->csr_readdata;
}

// Device view of the simulated core for the shared checks in nnue_golden.h.
struct SimDev {
    uint32_t csr_read(uint32_t a) { return ::csr_read(a); }
    void     csr_write(uint32_t a, uint32_t d) { ::csr_write(a, d); }
} simDev;

uint32_t tensor_read(uint32_t tensor, uint32_t index) { return nnue_golden::tensor_read(simDev, tensor, index); }


void put_descriptor(const Request& r, uint32_t seq, uint32_t stm, uint32_t bucket, uint32_t ctx) {
    encode_descriptor(mem.desc, r, seq, stm, bucket, ctx);
}


Request reuse_request(uint32_t slot) {
    Request r;
    r.dst = slot;
    return r;
}

Request incr_request(uint32_t dst, uint32_t src) {
    Request r;
    r.dst = dst;
    for (int c = 0; c < 2; ++c)
    {
        r.op[c]  = nnue_ctx::OP_INCR;
        r.src[c] = src;
    }
    return r;
}

void hw_reset() {
    dut->rst = 1;
    mem.queue.clear();
    for (int i = 0; i < 4; ++i)
        tick();
    dut->rst = 0;
    tick();
    csr_write(CSR_BASE, WEIGHT_BASE);
    csr_write(CSR_DESC, DESC_ADDR);
}

// Runs one evaluation, returning STATUS. A bound far above any legal run catches hangs.
uint32_t run_eval(uint64_t limit = 40000000) {
    csr_write(CSR_CONTROL, CTRL_START);
    for (uint64_t i = 0; i < limit; ++i)
    {
        tick();
        if (!(i & 0x3F) || dut->irq)
        {
            const uint32_t st = csr_read(CSR_STATUS);
            if (!(st & 1))
                return st;
        }
    }
    std::printf("FAIL evaluation did not finish in %llu cycles\n", (unsigned long long) limit);
    std::exit(1);
}

int64_t     mismatches = 0;
uint64_t    compared   = 0;
std::string lastRequest;  // Printed with a mismatch, so a failure names the operation behind it.
std::string lastAbort;

void note_request(const Request& r, uint64_t evalIndex, uint32_t ctxId) {
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "eval=%llu ctx=%u dst=%u op=%u,%u src=%u,%u W=%zu,%zu,%zu,%zu B=%zu,%zu,%zu,%zu",
                  (unsigned long long) evalIndex, ctxId, r.dst, r.op[0], r.op[1], r.src[0], r.src[1],
                  r.lists[0][0].size(), r.lists[0][1].size(), r.lists[0][2].size(), r.lists[0][3].size(),
                  r.lists[1][0].size(), r.lists[1][1].size(), r.lists[1][2].size(), r.lists[1][3].size());
    lastRequest = buf;
}

void report_first(const StimRec& s, const char* tensor, int index, int64_t got, int64_t want) {
    std::printf("MISMATCH state=%llu bucket=%u stm=%u tensor=%s index=%d got=%lld want=%lld\n",
                (unsigned long long) s.id, s.bucket, s.stm, tensor, index, (long long) got, (long long) want);
    std::printf("  request: %s\n", lastRequest.c_str());
    std::printf("  %s\n", lastAbort.c_str());
    ++mismatches;
    if (!std::getenv("TB_KEEP_GOING"))  // Debug aid; any mismatch still fails the run.
        std::exit(1);
}

bool outputs_match(const StimRec& s) {
    return int32_t(csr_read(CSR_OUT_PSQT)) == s.t.outPsqt && int32_t(csr_read(CSR_OUT_POS)) == s.t.outPos;
}

void check_outputs(const StimRec& s) {
    compared += nnue_golden::check_outputs(simDev, s, [&](const char* n, int i, int64_t got, int64_t want) {
        report_first(s, n, i, got, want);
    });
}

void check_tensors(const StimRec& s) {
    compared += nnue_golden::check_tensors(simDev, s, [&](const char* n, int i, int64_t got, int64_t want) {
        report_first(s, n, i, got, want);
    });
}

struct NegResult {
    const char* name;
    bool        ok;
};
std::vector<NegResult> negatives;

void expect(const char* name, bool ok) {
    negatives.push_back({name, ok});
    std::printf("  %-38s %s\n", name, ok ? "PASS" : "FAIL");
}

uint32_t err_of(uint32_t st) { return (st >> 8) & 0xFF; }
bool     has_err(uint32_t st, uint32_t code) { return (st & 4) && (st & 2) && err_of(st) == code; }
bool     ok_status(uint32_t st) { return (st & 2) && !(st & 4); }

uint32_t run_request(const Request& r, const StimRec& s, uint32_t ctx, uint32_t seq = 1) {
    put_descriptor(r, seq, s.stm, s.bucket, ctx);
    return run_eval();
}

// Confirms that a failure left no state behind: the next clean run must match golden.
void good_run_after(const StimRec& s, const char* name) {
    put_descriptor(refresh_request(s.f, 0), 77, s.stm, s.bucket, 3);
    const uint32_t st = run_eval();
    expect(name, ok_status(st) && outputs_match(s) && csr_read(CSR_SEQ) == 77 && csr_read(CSR_CTX) == 3);
}

void set_profile(uint32_t profile) {
    switch (profile)
    {
    case 0: mem.waitPct = 0;  mem.stallPct = 0;  mem.minLat = 1;  mem.maxLat = 1;   break;
    case 1: mem.waitPct = 10; mem.stallPct = 5;  mem.minLat = 4;  mem.maxLat = 12;  break;
    case 2: mem.waitPct = 40; mem.stallPct = 30; mem.minLat = 8;  mem.maxLat = 40;  break;
    default: mem.waitPct = 75; mem.stallPct = 60; mem.minLat = 1; mem.maxLat = 120; break;
    }
}

void negative_tests(const StimRec& s) {
    std::printf("negative and system tests:\n");

    expect("csr_id", csr_read(CSR_ID) == 0x4E4E5545);
    expect("csr_abi", csr_read(CSR_ABI) == ABI_VERSION);
    expect("csr_network_hash", csr_read(CSR_HASH) == uint32_t(NETWORK_HASH));
    expect("csr_net_id", csr_read(CSR_NET) == uint32_t(NET_ID));
    expect("csr_slots", csr_read(CSR_SLOTS) == ACC_SLOTS);

    const Request full = refresh_request(s.f, 0);

    struct Bad {
        const char* name;
        int         word;
        uint64_t    xorMask;
        uint32_t    code;
    };
    const Bad bad[] = {
      {"reject_bad_magic", 0, 0x1ull, ERR_MAGIC},
      {"reject_old_abi", 0, 3ull << 32, ERR_ABI},
      {"reject_reserved_header", 0, 1ull << 48, ERR_RESERVED},
      {"reject_bad_network_hash", 1, 0x1ull, ERR_HASH},
      {"reject_bad_net_id", 1, 1ull << 32, ERR_NET},
      {"reject_reserved_stm", 2, 1ull << 33, ERR_RESERVED},
      {"reject_reserved_bucket", 2, 1ull << 43, ERR_RESERVED},
      {"reject_reserved_slot_word", 3, 1ull << 28, ERR_RESERVED},
    };
    for (const auto& b : bad)
    {
        put_descriptor(full, 1, s.stm, s.bucket, 0);
        mem.desc[size_t(b.word)] ^= b.xorMask;
        expect(b.name, has_err(run_eval(), b.code));
    }

    // Counts beyond the fixed slots must not reach the feature memory.
    put_descriptor(full, 1, s.stm, s.bucket, 0);
    mem.desc[4] = (mem.desc[4] & ~0xFFFFull) | 33;
    expect("reject_too_many_psq", has_err(run_eval(), ERR_RANGE));
    put_descriptor(full, 1, s.stm, s.bucket, 0);
    mem.desc[5] = (mem.desc[5] & ~(0xFFFFull << 32)) | (257ull << 32);
    expect("reject_too_many_active", has_err(run_eval(), ERR_RANGE));

    // An out-of-range feature must fail before a wild memory read.
    {
        Request r = refresh_request(s.f, 0);
        r.lists[0][nnue_ctx::PSQ_ADD] = {uint16_t(PSQ_DIMENSIONS)};
        expect("reject_psq_feature_range", has_err(run_request(r, s, 0), ERR_RANGE));
        r = refresh_request(s.f, 0);
        r.lists[0][nnue_ctx::ACTIVE_ADD] = {uint16_t(ACTIVE_DIMENSIONS)};
        expect("reject_active_feature_range", has_err(run_request(r, s, 0), ERR_RANGE));
    }

    csr_write(CSR_DESC, DESC_ADDR + 4);
    expect("reject_unaligned_descriptor", has_err(run_eval(), ERR_ALIGN));
    csr_write(CSR_DESC, DESC_ADDR);
    csr_write(CSR_BASE, WEIGHT_BASE + 8);
    expect("reject_unaligned_weight_base", has_err(run_eval(), ERR_ALIGN));
    csr_write(CSR_BASE, WEIGHT_BASE);

    good_run_after(s, "clean_run_after_rejections");

    // ---- Slot table ----
    csr_write(CSR_CONTROL, CTRL_INVALIDATE);
    const uint32_t A = 1, B = 2;  // context IDs

    expect("reuse_invalid_slot_rejected", has_err(run_request(reuse_request(5), s, A), ERR_SLOT));
    expect("refresh_builds_slot", ok_status(run_request(refresh_request(s.f, 0), s, A)) && outputs_match(s));
    expect("reuse_valid_slot", ok_status(run_request(reuse_request(0), s, A)) && outputs_match(s));
    check_tensors(s);
    expect("reuse_other_context_rejected", has_err(run_request(reuse_request(0), s, B), ERR_SLOT));
    expect("incr_copy_only", ok_status(run_request(incr_request(1, 0), s, A)) && outputs_match(s));
    check_tensors(s);
    expect("incr_from_self_rejected", has_err(run_request(incr_request(0, 0), s, A), ERR_SLOT));
    expect("incr_from_invalid_rejected", has_err(run_request(incr_request(1, 7), s, A), ERR_SLOT));
    expect("incr_other_context_rejected", has_err(run_request(incr_request(2, 0), s, B), ERR_SLOT));
    {
        Request r = reuse_request(0);
        r.op[0]   = 3;
        expect("reject_op3", has_err(run_request(r, s, A), ERR_RANGE));
        expect("reject_dst_range", has_err(run_request(reuse_request(32), s, A), ERR_RANGE));
        r        = incr_request(1, 0);
        r.src[1] = 32;
        expect("reject_src_range", has_err(run_request(r, s, A), ERR_RANGE));
        r = refresh_request(s.f, 3);
        r.lists[0][nnue_ctx::PSQ_REMOVE] = {1};
        expect("reject_remove_on_refresh", has_err(run_request(r, s, A), ERR_RANGE));
        r = reuse_request(0);
        r.lists[1][nnue_ctx::ACTIVE_ADD] = {1};
        expect("reject_list_on_reuse", has_err(run_request(r, s, A), ERR_RANGE));

        // Adding and removing one feature exercises subtraction and must restore the state.
        r = incr_request(2, 0);
        for (int c = 0; c < 2; ++c)
        {
            r.lists[c][nnue_ctx::PSQ_ADD]       = {10, 22527};
            r.lists[c][nnue_ctx::PSQ_REMOVE]    = {10, 22527};
            r.lists[c][nnue_ctx::ACTIVE_ADD]    = {11, 64367};
            r.lists[c][nnue_ctx::ACTIVE_REMOVE] = {11, 64367};
        }
        expect("add_then_remove_restores", ok_status(run_request(r, s, A)) && outputs_match(s));
        check_tensors(s);

        // Each perspective takes its own operation.
        r       = reuse_request(2);
        Request m = refresh_request(s.f, 2);
        m.op[1] = nnue_ctx::OP_NONE;
        m.lists[1][nnue_ctx::PSQ_ADD].clear();
        m.lists[1][nnue_ctx::ACTIVE_ADD].clear();
        expect("mixed_refresh_and_reuse", ok_status(run_request(m, s, A)) && outputs_match(s));
        check_tensors(s);
    }

    // A slot that another context overwrote can no longer be used by its former owner.
    expect("overwrite_by_other_context", ok_status(run_request(refresh_request(s.f, 6), s, B)));
    expect("former_owner_rejected", ok_status(run_request(refresh_request(s.f, 6), s, A))
                                      && has_err(run_request(reuse_request(6), s, B), ERR_SLOT));

    // Interrupted requests must not leave a usable destination.
    {
        Request r = refresh_request(s.f, 9);
        r.lists[1][nnue_ctx::PSQ_ADD][0] = uint16_t(PSQ_DIMENSIONS);
        expect("failed_run_fails", has_err(run_request(r, s, A), ERR_RANGE));
        expect("failed_run_leaves_invalid", has_err(run_request(reuse_request(9), s, A), ERR_SLOT));

        put_descriptor(refresh_request(s.f, 10), 1, s.stm, s.bucket, A);
        csr_write(CSR_CONTROL, CTRL_START);
        for (int i = 0; i < 400; ++i)
            tick();
        csr_write(CSR_CONTROL, CTRL_SOFT_RESET);
        tick();
        expect("soft_reset_leaves_invalid", has_err(run_request(reuse_request(10), s, A), ERR_SLOT));
    }

    // No mode from an aborted run may leak into the next one. A sweep of abort points covers
    // every phase of a refresh; the follow-up uses both add and remove on both row types.
    {
        Request probe = incr_request(13, 12);
        for (int c = 0; c < 2; ++c)
        {
            probe.lists[c][nnue_ctx::PSQ_ADD]       = {10};
            probe.lists[c][nnue_ctx::PSQ_REMOVE]    = {10};
            probe.lists[c][nnue_ctx::ACTIVE_ADD]    = {11};
            probe.lists[c][nnue_ctx::ACTIVE_REMOVE] = {11};
        }
        bool ok = ok_status(run_request(refresh_request(s.f, 12), s, A));
        for (uint32_t profile : {0u, 3u})
        {
            set_profile(profile);
            for (uint32_t delay = 1; delay < (profile ? 12000u : 3000u); delay += (profile ? 37u : 13u))
            {
                put_descriptor(refresh_request(s.f, 14), 1, s.stm, s.bucket, A);
                csr_write(CSR_CONTROL, CTRL_START);
                for (uint32_t i = 0; i < delay; ++i)
                    tick();
                csr_write(CSR_CONTROL, CTRL_SOFT_RESET);
                tick();
                const uint32_t st = run_request(probe, s, A);

                // Final outputs alone can hide a wrong accumulator, so sample the tensor too.
                bool same = ok_status(st) && outputs_match(s);
                for (uint32_t j = 0; same && j < 2048; j += 61)
                    same = int32_t(tensor_read(0, j)) == s.t.acc[j / 1024][j % 1024];
                if (!same)
                {
                    std::printf("  abort sweep: profile %u delay %u status=0x%08X\n", profile, delay, st);
                    ok = false;
                    break;
                }
            }
        }
        set_profile(0);
        expect("abort_sweep_then_incremental", ok);

        // A watchdog timeout can also end a run during a bias read.
        ok = true;
        for (uint32_t delay : {90u, 170u, 300u, 600u, 900u})
        {
            put_descriptor(refresh_request(s.f, 14), 1, s.stm, s.bucket, A);
            csr_write(CSR_CONTROL, CTRL_START);
            for (uint32_t i = 0; i < delay; ++i)
                tick();
            mem.hang = true;
            for (uint32_t i = 0; i < WATCHDOG + 16; ++i)
                tick();
            ok = ok && has_err(csr_read(CSR_STATUS), ERR_TIMEOUT);
            mem.hang = false;
            ok = ok && ok_status(run_request(probe, s, A)) && outputs_match(s);
            for (uint32_t j = 0; ok && j < 2048; j += 61)
                ok = int32_t(tensor_read(0, j)) == s.t.acc[j / 1024][j % 1024];
        }
        expect("timeout_sweep_then_incremental", ok);

        Request bad = refresh_request(s.f, 14);
        bad.lists[1][nnue_ctx::PSQ_ADD][0] = uint16_t(PSQ_DIMENSIONS);
        ok = has_err(run_request(bad, s, A), ERR_RANGE);
        ok = ok && ok_status(run_request(probe, s, A)) && outputs_match(s);
        for (uint32_t j = 0; ok && j < 2048; j += 61)
            ok = int32_t(tensor_read(0, j)) == s.t.acc[j / 1024][j % 1024];
        expect("failed_run_then_incremental", ok);
    }

    // Invalidation paths.
    expect("slot_ready_for_invalidate", ok_status(run_request(refresh_request(s.f, 4), s, A)));
    csr_write(CSR_CONTROL, CTRL_INVALIDATE);
    expect("invalidate_all_clears", has_err(run_request(reuse_request(4), s, A), ERR_SLOT));
    expect("slot_ready_for_base_change", ok_status(run_request(refresh_request(s.f, 4), s, A)));
    csr_write(CSR_BASE, WEIGHT_BASE);
    expect("weight_base_write_clears", has_err(run_request(reuse_request(4), s, A), ERR_SLOT));

    // Every slot holds its own state: fill all, then read back in reverse order.
    {
        bool ok = true;
        for (uint32_t i = 0; i < ACC_SLOTS; ++i)
            ok = ok && ok_status(run_request(refresh_request(s.f, i), s, A));
        for (uint32_t i = ACC_SLOTS; i-- > 0;)
            ok = ok && ok_status(run_request(reuse_request(i), s, A)) && outputs_match(s);
        expect("all_slots_hold_state", ok);
    }

    good_run_after(s, "clean_run_after_slot_tests");

    // IRQ follows done only while enabled, and clears with done.
    csr_write(CSR_CONTROL, CTRL_CLEAR);
    expect("irq_low_when_disabled", dut->irq == 0);
    csr_write(CSR_CONTROL, CTRL_IRQ_EN | CTRL_START);
    {
        bool     fired = false;
        uint64_t guard = 0;
        while (!fired && guard++ < 40000000)
        {
            tick();
            fired = dut->irq;
        }
        expect("irq_fires_on_done", fired);
        csr_write(CSR_CONTROL, CTRL_IRQ_EN | CTRL_CLEAR);
        tick();
        expect("irq_clears_with_done", dut->irq == 0);
        csr_write(CSR_CONTROL, 0);
    }

    // A second start while busy must not disturb the run in progress.
    put_descriptor(refresh_request(s.f, 0), 88, s.stm, s.bucket, 0);
    csr_write(CSR_CONTROL, CTRL_START);
    for (int i = 0; i < 200; ++i)
        tick();
    csr_write(CSR_CONTROL, CTRL_START);
    {
        uint32_t st;
        uint64_t guard = 0;
        do
        {
            for (int i = 0; i < 64; ++i)
                tick();
            st = csr_read(CSR_STATUS);
        } while ((st & 1) && guard++ < 1000000);
        expect("start_while_busy_ignored", ok_status(st) && outputs_match(s) && csr_read(CSR_SEQ) == 88);
    }

    // Soft reset at many points in a run, with reads in flight and under stalls.
    {
        const uint32_t keepWait = mem.waitPct, keepStall = mem.stallPct, keepMin = mem.minLat, keepMax = mem.maxLat;
        mem.waitPct = 30, mem.stallPct = 30, mem.minLat = 5, mem.maxLat = 40;
        bool ok = true;
        for (int delay : {3, 11, 37, 101, 503, 1009, 5003, 20011})
        {
            put_descriptor(refresh_request(s.f, 0), 5, s.stm, s.bucket, 0);
            csr_write(CSR_CONTROL, CTRL_START);
            for (int i = 0; i < delay; ++i)
                tick();
            csr_write(CSR_CONTROL, CTRL_SOFT_RESET);
            tick();
            const uint32_t st = csr_read(CSR_STATUS);
            ok = ok && !(st & 1) && !(st & 2);

            put_descriptor(refresh_request(s.f, 0), uint32_t(1000 + delay), s.stm, s.bucket, 0);
            const uint32_t st2 = run_eval();
            ok = ok && ok_status(st2) && outputs_match(s) && csr_read(CSR_SEQ) == uint32_t(1000 + delay);
            check_tensors(s);
        }
        expect("soft_reset_in_flight_then_clean", ok);
        mem.waitPct = keepWait, mem.stallPct = keepStall, mem.minLat = keepMin, mem.maxLat = keepMax;
    }

    // Memory stops answering: watchdog fires. Stale words must then be discarded.
    {
        put_descriptor(refresh_request(s.f, 0), 6, s.stm, s.bucket, 0);
        csr_write(CSR_CONTROL, CTRL_START);
        for (int i = 0; i < 300; ++i)
            tick();
        mem.hang = true;
        for (uint32_t i = 0; i < WATCHDOG + 16; ++i)
            tick();
        const uint32_t st = csr_read(CSR_STATUS);
        expect("watchdog_timeout_reported", has_err(st, ERR_TIMEOUT) && !(st & 1));

        // A new run during the hang must also time out rather than proceed.
        csr_write(CSR_CONTROL, CTRL_START);
        for (uint32_t i = 0; i < WATCHDOG + 16; ++i)
            tick();
        expect("start_during_hang_times_out", has_err(csr_read(CSR_STATUS), ERR_TIMEOUT));

        mem.hang = false;
        for (int i = 0; i < 2000; ++i)
            tick();
        good_run_after(s, "clean_run_after_timeout");
        check_tensors(s);
    }

    // Hardware reset in the middle of a run.
    put_descriptor(refresh_request(s.f, 0), 7, s.stm, s.bucket, 0);
    csr_write(CSR_CONTROL, CTRL_START);
    for (int i = 0; i < 700; ++i)
        tick();
    hw_reset();
    expect("hw_reset_clears_status", (csr_read(CSR_STATUS) & 0x7) == 0);
    good_run_after(s, "clean_run_after_hw_reset");
}

struct Totals {
    uint64_t states = 0, full = 0, words = 0, chaosInvalidate = 0, chaosAbort = 0;
    uint64_t perf[PERF_COUNT] = {}, perfCycles = 0;
    uint64_t bucket[8] = {}, stm[2] = {}, profile[4] = {};
    std::vector<uint32_t> ideal, idealReuse, idealIncr, idealRefresh, wordsIncr;
};

void account(Totals& t, const StimRec& rec, const Request& r, uint32_t profile, uint64_t tensorEvery) {
    if (t.states % tensorEvery == 0)
    {
        check_tensors(rec);
        ++t.full;
    }
    check_outputs(rec);

    const uint32_t cyc   = csr_read(CSR_CYCLES);
    const uint32_t words = csr_read(CSR_WORDS);
    t.words += words;

    // Every non-idle cycle belongs to exactly one stage counter.
    uint64_t stageSum = 0;
    for (int i = 0; i < PERF_COUNT; ++i)
    {
        csr_write(CSR_PSEL, uint32_t(i));
        const uint32_t v = csr_read(CSR_PDATA);
        t.perf[i] += v;
        if (i < PERF_STAGES)
            stageSum += v;
    }
    t.perfCycles += cyc;
    if (stageSum != cyc)
    {
        std::printf("FAIL state %llu: stage counters sum to %llu, CYCLES %u\n", (unsigned long long) rec.id,
                    (unsigned long long) stageSum, cyc);
        std::exit(1);
    }
    if (profile == 0)
    {
        t.ideal.push_back(cyc);
        if (r.op[0] == nnue_ctx::OP_NONE && r.op[1] == nnue_ctx::OP_NONE)
            t.idealReuse.push_back(cyc);
        else if (r.op[0] == nnue_ctx::OP_INCR && r.op[1] == nnue_ctx::OP_INCR)
            t.idealIncr.push_back(cyc), t.wordsIncr.push_back(words);
        else if (r.op[0] == nnue_ctx::OP_REFRESH && r.op[1] == nnue_ctx::OP_REFRESH)
            t.idealRefresh.push_back(cyc);
    }
    ++t.bucket[rec.bucket];
    ++t.stm[rec.stm];
    ++t.profile[profile];
    ++t.states;
    if (t.states % 500 == 0)
    {
        std::printf("  %llu states, mismatches=0\n", (unsigned long long) t.states);
        std::fflush(stdout);
    }
}

std::string percentiles(std::vector<uint32_t>& v) {
    std::sort(v.begin(), v.end());
    const auto pct = [&](double p) { return v.empty() ? 0u : v[size_t(p * double(v.size() - 1))]; };
    char       buf[160];
    std::snprintf(buf, sizeof(buf), "{\"count\": %zu, \"min\": %u, \"median\": %u, \"p95\": %u, \"p99\": %u, \"max\": %u}",
                  v.size(), pct(0), pct(0.5), pct(0.95), pct(0.99), pct(1));
    return buf;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 3)
    {
        std::printf("usage: tb_core weights.bin input [--mode refresh|events] [--max N] [--seed S] "
                    "[--tensor-every K] [--contexts K] [--policy stack|nearest] [--candidates K] [--no-negative] "
                    "[--no-chaos] [--report F]\n");
        return 2;
    }
    uint64_t    maxStates = UINT64_MAX, tensorEvery = 1, seed = 1;
    uint32_t    contexts = 1, candidates = 0;
    std::string reportPath, mode = "refresh", policyName = "stack";
    bool        skipNegative = false, chaos = true;
    for (int i = 3; i < argc; ++i)
    {
        const std::string k = argv[i];
        if (k == "--no-negative")
            skipNegative = true;
        else if (k == "--no-chaos")
            chaos = false;
        else if (i + 1 >= argc)
            return 2;
        else if (k == "--max")
            maxStates = std::stoull(argv[++i]);
        else if (k == "--seed")
            seed = std::stoull(argv[++i]);
        else if (k == "--tensor-every")
            tensorEvery = std::stoull(argv[++i]);
        else if (k == "--report")
            reportPath = argv[++i];
        else if (k == "--mode")
            mode = argv[++i];
        else if (k == "--contexts")
            contexts = uint32_t(std::stoul(argv[++i]));
        else if (k == "--policy")
            policyName = argv[++i];
        else if (k == "--candidates")
            candidates = uint32_t(std::stoul(argv[++i]));
        else
            return 2;
    }
    if (policyName != "stack" && policyName != "nearest")
        return 2;
    const nnue_ctx::Policy policy = policyName == "nearest" ? nnue_ctx::NEAREST : nnue_ctx::STACK;
    rngState = seed * 0x9E3779B97F4A7C15ull + 1;

    {
        std::ifstream in(argv[1], std::ios::binary | std::ios::ate);
        if (!in)
            return 3;
        const auto bytes = size_t(in.tellg());
        if (bytes != IMAGE_BYTES)
        {
            std::printf("FAIL image size %zu, spec %llu\n", bytes, (unsigned long long) IMAGE_BYTES);
            return 1;
        }
        mem.weights.resize(bytes / 8);
        in.seekg(0);
        in.read(reinterpret_cast<char*>(mem.weights.data()), std::streamsize(bytes));
    }

    dut = new Vnnue_core;
    dut->csr_read = dut->csr_write = 0;
    hw_reset();

    auto   rec = std::make_unique<StimRec>();
    Totals t;
    std::vector<std::unique_ptr<Context>> ctxs;

    if (mode == "refresh")
    {
        std::ifstream stim(argv[2], std::ios::binary);
        if (!read_header(stim, 0x4D495453u))
            return 1;
        while (t.states < maxStates && stim.read(reinterpret_cast<char*>(rec.get()), sizeof(StimRec)))
        {
            if (t.states == 0 && !skipNegative)
            {
                negative_tests(*rec);
                hw_reset();
            }
            const uint32_t profile = uint32_t(t.states % 4);
            set_profile(profile);

            const uint32_t seq = uint32_t(rec->id);
            const Request  r   = refresh_request(rec->f, uint32_t(t.states % ACC_SLOTS));
            put_descriptor(r, seq, rec->stm, rec->bucket, uint32_t(t.states & 0xFFFF));
            const uint32_t st = run_eval();
            if (!ok_status(st) || csr_read(CSR_SEQ) != seq)
            {
                std::printf("FAIL state %llu status=0x%08X\n", (unsigned long long) rec->id, st);
                return 1;
            }
            account(t, *rec, r, profile, tensorEvery);
        }
    }
    else if (mode == "events")
    {
        {
            std::ifstream head(argv[2], std::ios::binary);
            if (!read_header(head, 0x53564E45u))
                return 1;
        }
        const auto roots = scan_roots(argv[2]);
        std::printf("event stream: %zu roots, %u context(s), policy %s\n", roots.size(), contexts,
                    policyName.c_str());

        std::vector<std::unique_ptr<EventCursor>> cursors;
        const uint32_t slotsEach = uint32_t(ACC_SLOTS) / contexts;
        for (uint32_t k = 0; k < contexts; ++k)
        {
            cursors.push_back(std::make_unique<EventCursor>(argv[2], roots[roots.size() * k / contexts]));
            ctxs.push_back(std::make_unique<Context>(k * slotsEach, slotsEach, policy));
            ctxs.back()->candidates = candidates;
        }

        uint32_t cur = 0;
        while (t.states < maxStates && cursors[cur]->next_eval(*ctxs[cur], *rec))
        {
            Context&       ctx     = *ctxs[cur];
            const uint32_t ctxId   = cur + 1;
            const uint32_t profile = uint32_t(t.states % 4);
            set_profile(profile);

            if (chaos && t.states && t.states % 997 == 0)
            {
                csr_write(CSR_CONTROL, CTRL_INVALIDATE);
                for (auto& c : ctxs)
                    c->invalidate_all();
                ++t.chaosInvalidate;
            }

            FullFeatures full = full_of(rec->f);
            Request      r    = ctx.plan(full);
            const uint32_t seq = uint32_t(t.states);

            // Abort some requests in flight; the retry must not depend on what the abort left.
            if (chaos && t.states && t.states % 1511 == 0)
            {
                put_descriptor(r, seq, rec->stm, rec->bucket, ctxId);
                csr_write(CSR_CONTROL, CTRL_START);
                const uint32_t delay = 20 + rnd(4000);
                for (uint32_t i = 0; i < delay; ++i)
                    tick();
                const uint32_t stBefore = csr_read(CSR_STATUS);
                const uint32_t firstDst = r.dst;
                const uint32_t firstOp0 = r.op[0], firstOp1 = r.op[1], firstSrc0 = r.src[0], firstSrc1 = r.src[1];
                csr_write(CSR_CONTROL, CTRL_SOFT_RESET);
                tick();
                ctx.abandon();
                ++t.chaosAbort;
                r = ctx.plan(full);
                char note[200];
                std::snprintf(note, sizeof(note),
                              "abort delay=%u status_before=0x%X queue=%zu first dst=%u op=%u,%u src=%u,%u", delay, stBefore,
                              mem.queue.size(), firstDst, firstOp0, firstOp1, firstSrc0, firstSrc1);
                lastAbort = note;
            }

            note_request(r, t.states, ctxId);
            put_descriptor(r, seq, rec->stm, rec->bucket, ctxId);
            const uint32_t st = run_eval();
            if (!ok_status(st) || csr_read(CSR_SEQ) != seq || csr_read(CSR_CTX) != ctxId)
            {
                std::printf("FAIL eval %llu state %llu status=0x%08X err=%u dst=%u ops=%u,%u src=%u,%u\n",
                            (unsigned long long) t.states, (unsigned long long) rec->id, st, err_of(st), r.dst,
                            r.op[0], r.op[1], r.src[0], r.src[1]);
                return 1;
            }
            ctx.commit();
            account(t, *rec, r, profile, tensorEvery);
            cur = (cur + 1) % contexts;
        }
    }
    else
    {
        std::printf("unknown mode %s\n", mode.c_str());
        return 2;
    }

    bool allNegative = true;
    for (const auto& n : negatives)
        allNegative = allNegative && n.ok;

    nnue_ctx::Stats sum;
    for (const auto& c : ctxs)
    {
        const auto& s = c->stats;
        sum.requests += s.requests;
        sum.reuse += s.reuse;
        sum.refresh += s.refresh;
        sum.incremental += s.incremental;
        sum.evictions += s.evictions;
        sum.overflowRefresh += s.overflowRefresh;
        sum.costRefresh += s.costRefresh;
        sum.invalidations += s.invalidations;
        sum.cancelledFeatures += s.cancelledFeatures;
        sum.rowsApplied += s.rowsApplied;
        sum.chainLenMax = std::max(sum.chainLenMax, s.chainLenMax);
        sum.stackDepthMax = std::max(sum.stackDepthMax, s.stackDepthMax);
    }

    std::vector<uint32_t> words = t.wordsIncr;
    std::string out;
    char        buf[1800];
    std::snprintf(buf, sizeof(buf),
                  "{\n  \"mode\": \"%s\",\n  \"contexts\": %u,\n  \"states\": %llu,\n  \"full_tensor_states\": %llu,\n"
                  "  \"values_compared\": %llu,\n  \"mismatches\": %lld,\n  \"negative_tests\": %zu,\n"
                  "  \"negative_tests_pass\": %s,\n"
                  "  \"bucket\": [%llu, %llu, %llu, %llu, %llu, %llu, %llu, %llu],\n  \"stm\": [%llu, %llu],\n"
                  "  \"stall_profile_states\": [%llu, %llu, %llu, %llu],\n"
                  "  \"mean_words_per_state\": %.1f,\n  \"sim_cycles\": %llu,\n"
                  "  \"chaos_invalidations\": %llu,\n  \"chaos_aborts\": %llu,\n"
                  "  \"host\": {\"requests\": %llu, \"reuse\": %llu, \"perspective_refresh\": %llu, "
                  "\"perspective_incremental\": %llu, \"evictions\": %llu, \"overflow_refresh\": %llu, "
                  "\"cost_refresh\": %llu, \"cancelled_features\": %llu, \"chain_len_max\": %llu, "
                  "\"stack_depth_max\": %llu},\n",
                  mode.c_str(), contexts, (unsigned long long) t.states, (unsigned long long) t.full,
                  (unsigned long long) compared, (long long) mismatches, negatives.size(),
                  allNegative ? "true" : "false", (unsigned long long) t.bucket[0], (unsigned long long) t.bucket[1],
                  (unsigned long long) t.bucket[2], (unsigned long long) t.bucket[3], (unsigned long long) t.bucket[4],
                  (unsigned long long) t.bucket[5], (unsigned long long) t.bucket[6], (unsigned long long) t.bucket[7],
                  (unsigned long long) t.stm[0], (unsigned long long) t.stm[1], (unsigned long long) t.profile[0],
                  (unsigned long long) t.profile[1], (unsigned long long) t.profile[2], (unsigned long long) t.profile[3],
                  t.states ? double(t.words) / double(t.states) : 0.0, (unsigned long long) simTime,
                  (unsigned long long) t.chaosInvalidate, (unsigned long long) t.chaosAbort,
                  (unsigned long long) sum.requests, (unsigned long long) sum.reuse, (unsigned long long) sum.refresh,
                  (unsigned long long) sum.incremental, (unsigned long long) sum.evictions,
                  (unsigned long long) sum.overflowRefresh, (unsigned long long) sum.costRefresh,
                  (unsigned long long) sum.cancelledFeatures, (unsigned long long) sum.chainLenMax,
                  (unsigned long long) sum.stackDepthMax);
    out += buf;
    out += "  \"ideal_mem_cycles\": " + percentiles(t.ideal) + ",\n";
    out += "  \"ideal_cycles_reuse_both\": " + percentiles(t.idealReuse) + ",\n";
    out += "  \"ideal_cycles_incremental_both\": " + percentiles(t.idealIncr) + ",\n";
    out += "  \"ideal_cycles_refresh_both\": " + percentiles(t.idealRefresh) + ",\n";
    out += "  \"words_incremental_both\": " + percentiles(words) + ",\n";
    out += "  \"perf_cycles\": " + std::to_string(t.perfCycles) + ",\n  \"perf\": {";
    for (int i = 0; i < PERF_COUNT; ++i)
        out += std::string(i ? ", " : "") + "\"" + PERF_NAMES[i] + "\": " + std::to_string(t.perf[i]);
    out += "}\n}\n";
    std::fputs(out.c_str(), stdout);
    if (!reportPath.empty())
    {
        std::ofstream report(reportPath);
        report << out;
    }

    delete dut;
    if (mismatches || !allNegative || t.states == 0)
    {
        std::printf("RESULT FAIL\n");
        return 1;
    }
    std::printf("RESULT PASS (simulation only)\n");
    return 0;
}
