// Host-side slot manager for the SF19 NNUE core (ABI 2).
//
// Tracks one search stack, assigns hardware accumulator slots, and turns the official per-ply
// feature changes into descriptors. No Stockfish dependency, so the same logic can serve the
// engine adapter (M7), the testbench and the board harness.
//
// Two planning policies:
//   STACK    walk the search stack to the nearest computed ancestor; a king move on the way is a
//            full refresh. Only evaluated nodes keep a slot.
//   NEAREST  the host remembers the feature set of every valid slot and takes, per perspective,
//            the slot with the cheapest difference (any slot: ancestor, sibling or another
//            branch), or a refresh when that is cheaper. Slots are replaced least recently used.
//            Needs no core change: each perspective already names its own source slot.
//            docs/reports/perf_proposal.md, step 1.
//            Candidates are merged in order of a signature lower bound, so usually only the
//            chosen slot is merged; the choice is the same as in MRU order (boundOrder = false).
#pragma once

#include <algorithm>
#include <cstdint>
#include <map>
#include <vector>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

namespace nnue_ctx {

enum Op : uint32_t { OP_NONE = 0, OP_REFRESH = 1, OP_INCR = 2 };
enum ListKind { PSQ_ADD = 0, PSQ_REMOVE = 1, ACTIVE_ADD = 2, ACTIVE_REMOVE = 3 };

constexpr int  MaxPsqList    = 32;
constexpr int  MaxActiveList = 256;
constexpr int  PsqRowWords   = 256;
constexpr int  ActiveRowWords = 128;
// HalfKAv2_hm index = square/piece offset + king bucket * PS_NB (11 * 64). Every PSQ feature of a
// perspective shares the king bucket, so slots with another bucket have no PSQ feature in common.
constexpr uint16_t PsqBucketStride = 704;

enum Policy { STACK, NEAREST };

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
    uint64_t chainLenMax = 0, stackDepthMax = 0, rowsApplied = 0, slotsWalked = 0, slotsPruned = 0;
};

class Context {
   public:
    Context(uint32_t firstSlot, uint32_t slotCount, Policy policy = STACK) :
        policy_(policy),
        first_(firstSlot),
        slots_(slotCount) {
        for (uint32_t i = 0; i < slotCount; ++i)
            free_.push_back(firstSlot + slotCount - 1 - i), mru_.push_back(i);
        root();
    }

    // New search or new root position: nothing on the stack can be a source any more. NEAREST
    // keeps its slots, which hold whole positions and stay valid across searches.
    void root() {
        for (auto& e : stack_)
            release(e);
        stack_.clear();
        stack_.push_back(Entry{});
        for (auto& p : stack_.back().diff.p)
            p.refresh = true;
    }

    void push(PlyDiff diff) {
        if (policy_ == NEAREST)
            return;
        stack_.push_back(Entry{std::move(diff), -1});
        stats.stackDepthMax = std::max<uint64_t>(stats.stackDepthMax, stack_.size());
    }

    void pop() {
        if (policy_ == NEAREST)
            return;
        release(stack_.back());
        stack_.pop_back();
    }

    // Hardware slot contents are gone (CONTROL bit 4 or a weight base change).
    void invalidate_all() {
        for (auto& e : stack_)
            release(e);
        for (auto& s : slots_)
            s.valid = false;
        ++stats.invalidations;
    }

    // Builds the request for the current top of the stack.
    Request plan(const FullFeatures& full) {
        Request r;
        plan(full, r);
        return r;
    }

    // Same, into a caller-owned request whose vectors keep their capacity between calls, so a
    // steady-state plan does not allocate. The ARM planner cost is on the critical path.
    void plan(const FullFeatures& full, Request& r) {
        r.dst     = 0;
        r.src[0]  = r.src[1] = 0;
        r.op[0]   = r.op[1] = OP_NONE;
        r.evicted = false;
        for (auto& side : r.lists)
            for (auto& l : side)
                l.clear();
        if (policy_ == NEAREST)
            plan_nearest(full, r);
        else
            r = plan_stack(full);
    }

   private:
    Request plan_stack(const FullFeatures& full) {
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

   public:
    // The core finished the request without error.
    void commit() {
        if (policy_ == NEAREST)
        {
            if (pendingDst_ >= 0)
            {
                Slot& s = slots_[size_t(pendingDst_) - first_];
                s.valid = true;
                for (int c = 0; c < 2; ++c)
                {
                    s.f.psq[c].swap(pendingFull_.psq[c]);  // keeps both capacities: no allocation
                    s.f.active[c].swap(pendingFull_.active[c]);
                }
                sigs_[size_t(pendingDst_) - first_] = pendingSig_;
            }
            pendingDst_ = -1;
            return;
        }
        if (pendingDst_ >= 0)
            stack_.back().slot = pendingDst_;
        pendingDst_ = -1;
    }

    // The request was aborted. The destination is invalid in hardware and returns to the pool.
    // NEAREST already marked it invalid when it was chosen.
    void abandon() {
        if (pendingDst_ >= 0 && policy_ == STACK)
            free_.push_back(uint32_t(pendingDst_));
        pendingDst_ = -1;
    }

    Stats stats;
    // NEAREST: how many of the most recently used slots are considered as sources (0 = all).
    uint32_t candidates = 0;
    // NEAREST: merge candidates in order of their signature lower bound (false: MRU order).
    // Both choose the same slots; plan_sim --check compares them.
    bool boundOrder = true;

   private:
    struct Cand {
        uint64_t lb;
        uint32_t n;  // MRU position
    };
    void touch(size_t k) {
        auto it = std::find(mru_.begin(), mru_.end(), uint32_t(k));
        std::rotate(mru_.begin(), it, it + 1);
    }

    // Parity of hashed feature bits. popcount(sig(a) ^ sig(b)) never exceeds the size of the
    // symmetric difference of a and b, so it bounds the row cost from below and prunes slots
    // without walking their lists.
    // 128 bits per kind in 32-bit words (on ARMv7 a variable 64-bit shift and xor take several
    // instructions each). Measured on the Cortex-A9, 128 bits beat 256: the bound is a little
    // weaker (2.23 instead of 1.97 merges per evaluation on the search trace), but the signatures
    // of all slots take half the cache lines, and the scan touches every candidate's signature.
    static constexpr uint32_t SigWords = 4, SigMask = SigWords * 32 - 1;
    struct Sig {
        uint32_t w[2][2][SigWords] = {};  // [perspective][PSQ, active][bits]
        uint16_t kb[2]             = {0xFFFF, 0xFFFF};
    };

    struct Slot {
        bool         valid = false;
        uint64_t     used  = 0;
        FullFeatures f;  // its signature is sigs_[slot], contiguous for the candidate scan
    };

    static Sig signature(const FullFeatures& f) {
        Sig s;
        for (int c = 0; c < 2; ++c)
        {
            for (uint16_t x : f.psq[c])
            {
                const uint32_t h = (uint32_t(x) * 40503u) >> 8 & SigMask;
                s.w[c][0][h >> 5] ^= 1u << (h & 31);
            }
            for (uint16_t x : f.active[c])
            {
                const uint32_t h = (uint32_t(x) * 40503u) >> 8 & SigMask;
                s.w[c][1][h >> 5] ^= 1u << (h & 31);
            }
            s.kb[c] = king_bucket(f.psq[c]);
        }
        return s;
    }

    // popcount(PSQ xor) * PsqRowWords + popcount(active xor) * ActiveRowWords.
    static uint64_t lower_bound(const Sig& a, const Sig& b, int c) {
        static_assert(PsqRowWords == 2 * ActiveRowWords, "lower_bound weights PSQ bits twice");
#if defined(__ARM_NEON)
        // ARMv7 has no scalar popcount. Both kinds are weighted and summed in NEON, so the
        // Cortex-A9 pays one NEON-to-core transfer per candidate instead of four.
        const uint8_t* x = reinterpret_cast<const uint8_t*>(a.w[c]);
        const uint8_t* y = reinterpret_cast<const uint8_t*>(b.w[c]);
        static_assert(SigWords == 4, "one 16-byte vector per kind");
        const uint8x16_t p = vcntq_u8(veorq_u8(vld1q_u8(x), vld1q_u8(y)));            // PSQ, <= 8 per byte
        const uint8x16_t q = vcntq_u8(veorq_u8(vld1q_u8(x + 16), vld1q_u8(y + 16)));  // active
        const uint64x2_t n = vpaddlq_u32(vpaddlq_u16(vpaddlq_u8(vaddq_u8(vaddq_u8(p, p), q))));  // 2p + q <= 24
        return uint64_t(vget_lane_u64(vadd_u64(vget_low_u64(n), vget_high_u64(n)), 0)) * ActiveRowWords;
#else
        uint64_t n = 0;
        for (uint32_t i = 0; i < SigWords; ++i)
            n += 2 * uint64_t(__builtin_popcount(a.w[c][0][i] ^ b.w[c][0][i]))
               + uint64_t(__builtin_popcount(a.w[c][1][i] ^ b.w[c][1][i]));
        return n * ActiveRowWords;
#endif
    }

    // Feature lists that turn one slot into the current position, per kind (PSQ, active).
    struct Diff {
        uint16_t add[2][MaxActiveList + 2], rem[2][MaxActiveList + 2];
        uint16_t nAdd[2], nRem[2];
    };

    // Sorted multiset difference a -> b into d (kind k): what to add to and remove from a to reach
    // b. Returns false when a list would exceed `limit` or the row cost would reach `bound`. The
    // loop is branch-free apart from the bound check: feature order is random, and a mispredicted
    // branch per element made the merge the planner's main cost. Counters are 32-bit: 64-bit
    // compares cost two instructions per element on the Cortex-A9. (Skipping runs of four equal
    // features with one 64-bit compare was measured slower there and is not used.)
    static bool diff_lists(const std::vector<uint16_t>& a, const std::vector<uint16_t>& b, size_t limit,
                           uint64_t rowWords, uint64_t base, uint64_t bound, Diff& d, int k, uint64_t& cost) {
        if (bound <= base)
            return false;
        const uint32_t  na = uint32_t(a.size()), nb = uint32_t(b.size());
        const uint16_t* pa = a.data();
        const uint16_t* pb = b.data();
        uint16_t*       ad = d.add[k];
        uint16_t*       rm = d.rem[k];
        uint32_t        i = 0, j = 0, nAdd = 0, nRem = 0;
        const uint32_t  maxDiff = uint32_t(std::min<uint64_t>((bound - base - 1) / rowWords, 0xFFFFFFFFu));
        while (i < na && j < nb)
        {
            const uint16_t x = pa[i], y = pb[j];
            rm[nRem] = x;
            ad[nAdd] = y;
            nRem += x < y;
            nAdd += y < x;
            i += x <= y;
            j += y <= x;
            if (nAdd + nRem > maxDiff)
                return false;
        }
        if (nRem + (na - i) > limit || nAdd + (nb - j) > limit
            || nAdd + nRem + (na - i) + (nb - j) > maxDiff)
            return false;
        for (; i < na; ++i)
            rm[nRem++] = pa[i];
        for (; j < nb; ++j)
            ad[nAdd++] = pb[j];
        if (nAdd > limit || nRem > limit)
            return false;
        d.nAdd[k] = uint16_t(nAdd);
        d.nRem[k] = uint16_t(nRem);
        cost      = base + uint64_t(nAdd + nRem) * rowWords;
        return true;
    }

    static uint16_t king_bucket(const std::vector<uint16_t>& psq) {
        return psq.empty() ? 0xFFFF : uint16_t(psq[0] / PsqBucketStride);
    }

    void plan_nearest(const FullFeatures& full, Request& r) {
        ++stats.requests;
        ++clock_;

        const Sig cur = signature(full);
        int       best[2] = {-1, -1};
        uint64_t  bestCost[2];
        // The lists of the best candidate so far are kept, so the winner is not merged twice.
        int bestDiff[2] = {0, 1}, spare = 2;
        for (int c = 0; c < 2; ++c)
        {
            // Refresh cost, as the STACK policy counts it: bias row plus every feature row.
            bestCost[c] = uint64_t(PsqRowWords) * (1 + full.psq[c].size())
                        + uint64_t(ActiveRowWords) * full.active[c].size();
            // The candidates are the `scan` most recently used slots. Equal costs go to the most
            // recently used one (lowest MRU position), which is the most likely to stay.
            const size_t scan = candidates ? std::min<size_t>(candidates, mru_.size()) : mru_.size();
            uint32_t     nCand = 0;
            for (size_t n = 0; n < scan; ++n)
            {
                const size_t k = mru_[n];
                const Sig&   g = sigs_[k];
                if (!slots_[k].valid || g.kb[c] != cur.kb[c])
                    continue;
                const uint64_t lb = lower_bound(g, cur, c);
                if (lb >= bestCost[c])
                {
                    ++stats.slotsPruned;
                    continue;
                }
                // Lowest bound first (stable, so MRU order among equal bounds): the first exact
                // cost is usually the minimum, and every later candidate whose bound exceeds it
                // is skipped without a merge.
                uint32_t i = nCand++;
                for (; boundOrder && i > 0 && cand_[i - 1].lb > lb; --i)
                    cand_[i] = cand_[i - 1];
                cand_[i] = {lb, uint32_t(n)};
            }
            uint32_t bestN = 0;
            for (uint32_t i = 0; i < nCand; ++i)
            {
                const uint32_t n = cand_[i].n;
                const size_t   k = mru_[n];
                const Slot&    s = slots_[k];
                const uint64_t bound = bestCost[c] + ((best[c] >= 0 && n < bestN) ? 1 : 0);
                if (cand_[i].lb >= bound)
                {
                    if (boundOrder && cand_[i].lb > bestCost[c])
                    {
                        stats.slotsPruned += nCand - i;
                        break;
                    }
                    ++stats.slotsPruned;
                    continue;
                }
                ++stats.slotsWalked;
                uint64_t cost;
                Diff&    d = diffs_[spare];
                if (!diff_lists(s.f.psq[c], full.psq[c], MaxPsqList, PsqRowWords, 0, bound, d, 0, cost))
                    continue;
                if (!diff_lists(s.f.active[c], full.active[c], MaxActiveList, ActiveRowWords, cost, bound, d, 1, cost))
                    continue;
                best[c]     = int(k);
                bestN       = n;
                bestCost[c] = cost;
                std::swap(bestDiff[c], spare);
            }
        }

        // Both perspectives already in one slot: reuse it as it is.
        if (best[0] >= 0 && best[0] == best[1] && bestCost[0] == 0 && bestCost[1] == 0)
        {
            slots_[size_t(best[0])].used = clock_;
            touch(size_t(best[0]));
            r.dst = first_ + uint32_t(best[0]);
            ++stats.reuse;
            pendingDst_ = -1;
            return;
        }

        for (int c = 0; c < 2; ++c)
        {
            if (best[c] < 0)
            {
                use_full(r, c, full);
                ++stats.refresh;
                stats.rowsApplied += full.psq[c].size() + full.active[c].size();
                continue;
            }
            Slot& s = slots_[size_t(best[c])];
            s.used  = clock_;
            touch(size_t(best[c]));
            r.op[c] = OP_INCR;
            r.src[c] = first_ + uint32_t(best[c]);
            const Diff& d = diffs_[bestDiff[c]];
            r.lists[c][PSQ_ADD].assign(d.add[0], d.add[0] + d.nAdd[0]);
            r.lists[c][PSQ_REMOVE].assign(d.rem[0], d.rem[0] + d.nRem[0]);
            r.lists[c][ACTIVE_ADD].assign(d.add[1], d.add[1] + d.nAdd[1]);
            r.lists[c][ACTIVE_REMOVE].assign(d.rem[1], d.rem[1] + d.nRem[1]);
            ++stats.incremental;
            for (int k = 0; k < 4; ++k)
                stats.rowsApplied += r.lists[c][k].size();
        }

        // Destination: an invalid slot, else the least recently used one that is not a source.
        size_t dst = slots_.size();
        for (size_t k = 0; k < slots_.size(); ++k)
        {
            if (int(k) == best[0] || int(k) == best[1])
                continue;
            if (!slots_[k].valid)
            {
                dst = k;
                break;
            }
            if (dst == slots_.size() || slots_[k].used < slots_[dst].used)
                dst = k;
        }
        if (slots_[dst].valid)
        {
            ++stats.evictions;
            r.evicted = true;
        }
        slots_[dst].valid = false;  // overwritten from now on, also if the request aborts
        slots_[dst].used  = clock_;
        touch(dst);
        r.dst             = first_ + uint32_t(dst);
        pendingDst_       = int(r.dst);
        for (int c = 0; c < 2; ++c)
        {
            pendingFull_.psq[c].assign(full.psq[c].begin(), full.psq[c].end());
            pendingFull_.active[c].assign(full.active[c].begin(), full.active[c].end());
        }
        pendingSig_ = cur;
    }

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

    Policy                policy_;
    uint32_t              first_;
    std::vector<Slot>     slots_;
    uint64_t              clock_ = 0;
    FullFeatures          pendingFull_;
    Sig                   pendingSig_;
    std::vector<Cand>     cand_ = std::vector<Cand>(slots_.size());
    std::vector<Sig>      sigs_ = std::vector<Sig>(slots_.size());
    std::vector<uint32_t> mru_;  // slot indices, most recently used first
    Diff                  diffs_[3];
    std::vector<Entry>    stack_;
    std::vector<uint32_t> free_;
    int                   pendingDst_ = -1;
};

}  // namespace nnue_ctx
