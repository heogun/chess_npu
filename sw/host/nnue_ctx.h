// Host-side slot manager for the SF19 NNUE core (ABI 2).
//
// Tracks one search stack, assigns hardware accumulator slots, and turns the official per-ply
// feature changes into descriptors. No Stockfish dependency, so the same logic can serve the
// engine adapter (M7) and the testbench. Exercised in simulation only so far.
#pragma once

#include <algorithm>
#include <cstdint>
#include <map>
#include <vector>

namespace nnue_ctx {

enum Op : uint32_t { OP_NONE = 0, OP_REFRESH = 1, OP_INCR = 2 };
enum ListKind { PSQ_ADD = 0, PSQ_REMOVE = 1, ACTIVE_ADD = 2, ACTIVE_REMOVE = 3 };

constexpr int  MaxPsqList    = 32;
constexpr int  MaxActiveList = 256;
constexpr int  PsqRowWords   = 256;
constexpr int  ActiveRowWords = 128;

struct PerspectiveDiff {
    bool                  refresh = false;
    std::vector<uint16_t> lists[4];
};

struct PlyDiff {
    PerspectiveDiff p[2];  // WHITE, BLACK
};

struct FullFeatures {
    std::vector<uint16_t> psq[2];
    std::vector<uint16_t> active[2];
};

struct Request {
    uint32_t              dst = 0;
    uint32_t              src[2] = {0, 0};
    uint32_t              op[2] = {OP_NONE, OP_NONE};
    std::vector<uint16_t> lists[2][4];
    bool                  evicted = false;
};

struct Stats {
    uint64_t requests = 0, reuse = 0, refresh = 0, incremental = 0, evictions = 0;
    uint64_t overflowRefresh = 0, costRefresh = 0, invalidations = 0, cancelledFeatures = 0;
    uint64_t chainLenMax = 0, stackDepthMax = 0, rowsApplied = 0;
};

class Context {
   public:
    Context(uint32_t firstSlot, uint32_t slotCount) {
        for (uint32_t i = 0; i < slotCount; ++i)
            free_.push_back(firstSlot + slotCount - 1 - i);
        root();
    }

    // New search or new root position: nothing on the stack can be a source any more.
    void root() {
        for (auto& e : stack_)
            release(e);
        stack_.clear();
        stack_.push_back(Entry{});
        for (auto& p : stack_.back().diff.p)
            p.refresh = true;
    }

    void push(PlyDiff diff) {
        stack_.push_back(Entry{std::move(diff), -1});
        stats.stackDepthMax = std::max<uint64_t>(stats.stackDepthMax, stack_.size());
    }

    void pop() {
        release(stack_.back());
        stack_.pop_back();
    }

    // Hardware slot contents are gone (CONTROL bit 4 or a weight base change).
    void invalidate_all() {
        for (auto& e : stack_)
            release(e);
        ++stats.invalidations;
    }

    // Builds the request for the current top of the stack.
    Request plan(const FullFeatures& full) {
        Request r;
        ++stats.requests;
        Entry& top = stack_.back();

        if (top.slot >= 0)
        {
            r.dst = uint32_t(top.slot);
            ++stats.reuse;
            pendingDst_ = -1;
            return r;
        }

        int srcEntry[2];
        for (int c = 0; c < 2; ++c)
            srcEntry[c] = plan_perspective(r, c, full);

        // Sources must survive allocation of the destination.
        std::vector<int> keep;
        for (int c = 0; c < 2; ++c)
            if (r.op[c] == OP_INCR)
                keep.push_back(int(r.src[c]));

        if (free_.empty())
        {
            evict(keep);
            r.evicted = true;
        }
        r.dst = free_.back();
        free_.pop_back();
        pendingDst_ = int(r.dst);
        (void) srcEntry;
        return r;
    }

    // The core finished the request without error.
    void commit() {
        if (pendingDst_ >= 0)
            stack_.back().slot = pendingDst_;
        pendingDst_ = -1;
    }

    // The request was aborted. The destination is invalid in hardware and returns to the pool.
    void abandon() {
        if (pendingDst_ >= 0)
            free_.push_back(uint32_t(pendingDst_));
        pendingDst_ = -1;
    }

    Stats stats;

   private:
    struct Entry {
        PlyDiff diff;
        int     slot = -1;
    };

    void release(Entry& e) {
        if (e.slot >= 0)
            free_.push_back(uint32_t(e.slot));
        e.slot = -1;
    }

    // The shallowest entry is the least likely to be needed soon as a nearby source.
    void evict(const std::vector<int>& keep) {
        for (auto& e : stack_)
            if (e.slot >= 0 && std::find(keep.begin(), keep.end(), e.slot) == keep.end())
            {
                release(e);
                ++stats.evictions;
                return;
            }
    }

    static void use_full(Request& r, int c, const FullFeatures& full) {
        r.op[c]                = OP_REFRESH;
        r.lists[c][PSQ_ADD]    = full.psq[c];
        r.lists[c][ACTIVE_ADD] = full.active[c];
        r.lists[c][PSQ_REMOVE].clear();
        r.lists[c][ACTIVE_REMOVE].clear();
    }

    int plan_perspective(Request& r, int c, const FullFeatures& full) {
        // Walk toward the root: the first refresh boundary or computed slot ends the chain.
        int source = -1;
        for (int i = int(stack_.size()) - 1; i >= 0; --i)
        {
            if (stack_[size_t(i)].diff.p[c].refresh)
                break;
            if (i > 0 && stack_[size_t(i) - 1].slot >= 0)
            {
                source = i - 1;
                break;
            }
        }
        if (source < 0)
        {
            use_full(r, c, full);
            ++stats.refresh;
            stats.rowsApplied += full.psq[c].size() + full.active[c].size();
            return -1;
        }

        // Add and remove of one feature along the chain cancel, as the accumulator is a sum.
        std::map<uint16_t, int> net[2];  // PSQ, active
        uint64_t raw = 0;
        for (size_t i = size_t(source) + 1; i < stack_.size(); ++i)
        {
            const PerspectiveDiff& d = stack_[i].diff.p[c];
            for (int k = 0; k < 2; ++k)
            {
                for (uint16_t f : d.lists[k * 2])
                    ++net[k][f], ++raw;
                for (uint16_t f : d.lists[k * 2 + 1])
                    --net[k][f], ++raw;
            }
        }
        stats.chainLenMax = std::max<uint64_t>(stats.chainLenMax, stack_.size() - size_t(source) - 1);

        std::vector<uint16_t> lists[4];
        uint64_t              kept = 0;
        for (int k = 0; k < 2; ++k)
            for (const auto& [f, n] : net[k])
            {
                for (int a = 0; a < n; ++a)
                    lists[k * 2].push_back(f), ++kept;
                for (int a = 0; a < -n; ++a)
                    lists[k * 2 + 1].push_back(f), ++kept;
            }
        stats.cancelledFeatures += raw - kept;

        const bool overflow = lists[PSQ_ADD].size() > MaxPsqList || lists[PSQ_REMOVE].size() > MaxPsqList
                           || lists[ACTIVE_ADD].size() > MaxActiveList
                           || lists[ACTIVE_REMOVE].size() > MaxActiveList;

        const uint64_t incWords = (lists[PSQ_ADD].size() + lists[PSQ_REMOVE].size()) * PsqRowWords
                                + (lists[ACTIVE_ADD].size() + lists[ACTIVE_REMOVE].size()) * ActiveRowWords;
        const uint64_t refreshWords =
          PsqRowWords + full.psq[c].size() * PsqRowWords + full.active[c].size() * ActiveRowWords;

        if (overflow || incWords >= refreshWords)
        {
            stats.overflowRefresh += overflow;
            stats.costRefresh += !overflow;
            use_full(r, c, full);
            ++stats.refresh;
            stats.rowsApplied += full.psq[c].size() + full.active[c].size();
            return -1;
        }

        r.op[c]  = OP_INCR;
        r.src[c] = uint32_t(stack_[size_t(source)].slot);
        for (int k = 0; k < 4; ++k)
            r.lists[c][k] = std::move(lists[k]);
        ++stats.incremental;
        stats.rowsApplied += kept;
        return source;
    }

    std::vector<Entry>    stack_;
    std::vector<uint32_t> free_;
    int                   pendingDst_ = -1;
};

}  // namespace nnue_ctx
