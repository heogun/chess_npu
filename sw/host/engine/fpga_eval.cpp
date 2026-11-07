// Engine adapter for the SF19 NNUE core; see fpga_eval.h. Copied into src/nnue/ of the private
// build copy by tools/build-stockfish.sh (FPGA=1) together with the shared host headers.
#include "fpga_eval.h"

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../position.h"
#include "nnue_accumulator.h"
#include "nnue_architecture.h"
#include "nnue_feature_transformer.h"

#include "nnue_ctx.h"
#include "nnue_golden.h"
#if defined(__arm__)
    #include "nnue_device.h"
#endif

namespace Stockfish::Eval::NNUE::Fpga {
namespace {

enum Mode { CPU, PLAN, HW, COMPARE };

// The weight image and the core were generated from this network architecture.
static_assert((FeatureTransformer::get_hash_value() ^ NetworkArchitecture::get_hash_value())
                == u32(nnue_spec::NETWORK_HASH),
              "engine network architecture differs from the generated spec");

u64 now_ns() {
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return u64(t.tv_sec) * 1000000000ull + u64(t.tv_nsec);
}

[[noreturn]] void fatal(const std::string& m);

// SF_NNUE_PLANNER: sw (default) plans on the ARM (NEAREST, 16 candidates); hw lets the core
// choose the sources (needs an image with the hardware planner, CSR CAPS bit 1).
nnue_ctx::Policy planner_from_env() {
    const char* p = std::getenv("SF_NNUE_PLANNER");
    const std::string s = p ? p : "sw";
    if (s != "sw" && s != "hw")
        fatal("SF_NNUE_PLANNER must be sw or hw, not " + s);
    return s == "hw" ? nnue_ctx::HWPLAN : nnue_ctx::NEAREST;
}

[[noreturn]] void fatal(const std::string& m) {
    std::fprintf(stderr, "FATAL fpga_eval: %s\n", m.c_str());
    std::fflush(stderr);
    std::_Exit(1);
}

struct Stat {
    u64 n = 0, sum = 0, max = 0;
    void add(u64 v) { ++n, sum += v, max = std::max(max, v); }
    double mean_us() const { return n ? double(sum) / double(n) * 1e-3 : 0.0; }
};

class Adapter {
   public:
    Adapter() {
        const char* m = std::getenv("SF_NNUE_MODE");
        const std::string s = m ? m : "cpu";
        mode_ = s == "hw" ? HW : s == "compare" ? COMPARE : s == "plan" ? PLAN : CPU;
        if (s != "cpu" && s != "hw" && s != "compare" && s != "plan")
            fatal("SF_NNUE_MODE must be cpu, plan, hw or compare, not " + s);
        const char* t = std::getenv("SF_NNUE_TIMING");
        timing_       = t && std::string(t) == "1";
        if (mode_ != CPU)
        {
            open();  // before any search: the weight read-back takes seconds
            std::atexit([] { instance().report(); });
        }
    }

    static Adapter& instance() {
        static Adapter a;
        return a;
    }

    Mode mode() const { return mode_; }

    NetworkOutput evaluate(const Network& network, const Position& pos, AccumulatorStack& accumulators,
                           AccumulatorCaches& caches) {
        std::call_once(owner_flag_, [this] { owner_ = std::this_thread::get_id(); });
        if (std::this_thread::get_id() != owner_)
            fatal("the hardware path supports one search thread (set Threads to 1)");

        const u64 t0 = timing_ ? now_ns() : 0;
        collect(pos);
        const u64 t1 = timing_ ? now_ns() : 0;
        ctx_.plan(full_, req_);
        const u32 seq    = u32(++evals_);
        const u32 stm    = u32(pos.side_to_move());
        const u32 bucket = u32((pos.count<ALL_PIECES>() - 1) / 4);
        nnue_golden::encode_descriptor(desc_, req_, seq, stm, bucket, CtxId);
        const u64 t2 = timing_ ? now_ns() : 0;
        if (timing_)
            featureNs_.add(t1 - t0), planNs_.add(t2 - t1);

        if (mode_ == PLAN)
        {
            ctx_.commit();  // as if the core had finished: keeps the planner's state realistic
            return network.evaluate(pos, accumulators, caches);
        }

        NetworkOutput out = run(seq, pos);
        if (mode_ == COMPARE)
        {
            const NetworkOutput cpu = network.evaluate(pos, accumulators, caches);
            if (cpu != out)
            {
                ++mismatches_;
                fatal("pair differs at evaluation " + std::to_string(evals_) + ": fpga (" + std::to_string(std::get<0>(out))
                      + ", " + std::to_string(std::get<1>(out)) + "), official (" + std::to_string(std::get<0>(cpu)) + ", "
                      + std::to_string(std::get<1>(cpu)) + "), fen " + pos.fen());
            }
            ++compared_;
        }
        return out;
    }

    void report() const {
        static const char* names[] = {"cpu", "plan", "hw", "compare"};
        std::fprintf(stderr, "fpga_eval: planner %s\n", hwPlan_ ? "hw (core)" : "sw (ARM, NEAREST 16)");
        std::fprintf(stderr,
                     "fpga_eval: mode %s, evaluations %" PRIu64 ", compared %" PRIu64 ", mismatches %" PRIu64
                     ", errors %" PRIu64 ", fallbacks 0\n",
                     names[mode_], evals_, compared_, mismatches_, errors_);
        const auto& s = ctx_.stats;
        if (hwPlan_)
            std::fprintf(stderr,
                         "fpga_eval: core plan: perspective refresh %" PRIu64 ", incremental %" PRIu64
                         " (rows are counted by the core, not here)\n",
                         s.refresh, s.incremental);
        else
            std::fprintf(stderr,
                     "fpga_eval: plan reuse %" PRIu64 ", perspective refresh %" PRIu64 ", incremental %" PRIu64
                     ", rows %" PRIu64 " (%.2f per evaluation)\n",
                     s.reuse, s.refresh, s.incremental, s.rowsApplied + s.refresh,
                     evals_ ? double(s.rowsApplied + s.refresh) / double(evals_) : 0.0);
        if (timing_)
            std::fprintf(stderr,
                         "fpga_eval: mean us per evaluation: features %.2f, plan+encode %.2f, host %.2f "
                         "(max %.1f, %.1f, %.1f)\n",
                         featureNs_.mean_us(), planNs_.mean_us(), hostNs_.mean_us(), featureNs_.max * 1e-3,
                         planNs_.max * 1e-3, hostNs_.max * 1e-3);
        std::fflush(stderr);
    }

   private:
    static constexpr u32 CtxId = 1;

    void open() {
        ctx_.candidates = 16;
        if (mode_ == PLAN)
            return;
#if defined(__arm__)
        const char* w    = std::getenv("SF_NNUE_WEIGHTS");
        const char* l    = std::getenv("SF_NNUE_LOAD");
        const bool  load = !(l && std::string(l) == "0");
        if (const std::string e = board_.open(w ? w : "/usr/share/chess-npu/weights.bin", load, stderr); !e.empty())
            fatal(e);
        if (hwPlan_ && !(board_.csr_read(nnue_golden::CSR_CAPS) & nnue_golden::CAPS_HW_PLAN))
            fatal("SF_NNUE_PLANNER=hw needs an FPGA image with the hardware planner");
#else
        fatal("no NNUE core on this platform; SF_NNUE_MODE=hw and compare need the DE1-SoC build");
#endif
    }

    NetworkOutput run(u32 seq, const Position& pos) {
#if defined(__arm__)
        u64       hostNs;
        const u32 st = board_.run(desc_, hostNs);
        if (!board_.finished_ok(st, seq, CtxId))
        {
            ++errors_;
            char buf[200];
            std::snprintf(buf, sizeof buf, "core error at evaluation %" PRIu64 ": status 0x%08X dst %u op %u,%u src %u,%u",
                          evals_, st, req_.dst, req_.op[0], req_.op[1], req_.src[0], req_.src[1]);
            fatal(std::string(buf) + ", fen " + pos.fen());
        }
        if (timing_)
            hostNs_.add(hostNs);
        if (hwPlan_)
            ctx_.commit_plan(board_.csr_read(nnue_golden::CSR_PLAN));
        else
            ctx_.commit();
        return {Value(board_.out_psqt()), Value(board_.out_pos())};
#else
        (void) seq, (void) pos;
        fatal("no NNUE core on this platform");
#endif
    }

    // Active feature indices of both perspectives, sorted, as the planner and the core expect.
    void collect(const Position& pos) {
        for (Color c : {WHITE, BLACK})
        {
            const Square ksq = pos.square<KING>(c);
            auto&        psq = full_.psq[c];
            psq.clear();
            for (Bitboard bb = pos.pieces(); bb;)
            {
                const Square s = pop_lsb(bb);
                psq.push_back(u16(PSQFeatureSet::make_index(c, s, pos.piece_on(s), ksq)));
            }
            std::sort(psq.begin(), psq.end());

            ThreatFeatureSet::IndexList active;
            ThreatFeatureSet::append_active_indices(c, pos, active);
            PairFeatureSet::append_active_indices(c, pos, active);
            auto& a = full_.active[c];
            a.assign(active.begin(), active.end());
            std::sort(a.begin(), a.end());
            if (psq.size() > size_t(nnue_ctx::MaxPsqList) || a.size() > size_t(nnue_ctx::MaxActiveList))
                fatal("more features than a descriptor list holds");
        }
    }

    Mode                   mode_   = CPU;
    bool                   timing_ = false;
    std::once_flag         owner_flag_;
    std::thread::id        owner_;
    // Read once: getenv() on every evaluation cost measurable bench speed.
    const bool             hwPlan_ = planner_from_env() == nnue_ctx::HWPLAN;
    nnue_ctx::Context      ctx_{0, u32(nnue_spec::ACC_SLOTS), hwPlan_ ? nnue_ctx::HWPLAN : nnue_ctx::NEAREST};
    nnue_ctx::FullFeatures full_;
    nnue_ctx::Request      req_;
    std::vector<u64>       desc_;
    u64                    evals_ = 0, compared_ = 0, mismatches_ = 0, errors_ = 0;
    Stat                   featureNs_, planNs_, hostNs_;
#if defined(__arm__)
    nnue_device::Board board_;
#endif
};

// The device is opened while the program starts, not inside the first timed search.
[[maybe_unused]] const bool started = (Adapter::instance(), true);

}  // namespace

bool enabled() {
    static const bool on = Adapter::instance().mode() != CPU;
    return on;
}

NetworkOutput evaluate(const Network& network, const Position& pos, AccumulatorStack& accumulators,
                       AccumulatorCaches& caches) {
    return Adapter::instance().evaluate(network, pos, accumulators, caches);
}

}  // namespace Stockfish::Eval::NNUE::Fpga
