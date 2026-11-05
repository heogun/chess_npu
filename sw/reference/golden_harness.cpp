// SF19 golden harness (M1/M2).
//
// Links against the unmodified official Stockfish objects and drives the official
// Position / AccumulatorStack / Network code. The official evaluation is the oracle;
// the layer-by-layer replay and the scalar accumulator sum in this file exist only to
// expose intermediate tensors, and every state checks them against the official result.
//
// Commands:
//   spec    <net>                                    JSON of source constants and net header
//   reject  <net> <scratch-dir>                      corrupted nets must be refused
//   export  <net> <out.bin>                          canonical weights (scalar build only)
//   trace   <net> <corpus> --seed S --states N --digest F [--stim F --stim-every K] [--events F]
//   replay  <net> <search.ops> --digest F [--events F --evals-per-root N] [--max-evals N]
//
// `replay` re-executes a search recorded with sw/host/patches/0001-trace-search-ops.patch and
// requires each Eval::evaluate() result to equal the value the official search logged.
//
// Private members are reached by `#define private public` around the official headers.
// Access specifiers do not change layout or mangling, and upstream files stay unchanged.

#include <algorithm>
#include <array>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <tuple>
#include <vector>

#include "attacks.h"
#include "bitboard.h"
#include "evaluate.h"
#include "movegen.h"
#include "position.h"
#include "types.h"

#define private public
#include "nnue/network.h"
#include "nnue/nnue_accumulator.h"
#include "nnue/nnue_architecture.h"
#include "nnue/nnue_feature_transformer.h"
#undef private

using namespace Stockfish;
using namespace Stockfish::Eval::NNUE;

namespace {

#if defined(USE_SSE2) || defined(USE_NEON) || defined(USE_LSX) || defined(USE_RVV)
constexpr bool ScalarBuild = false;
#else
constexpr bool ScalarBuild = true;
#endif

#if defined(USE_AVX2)
constexpr const char* BuildSimd = "avx2";
#elif defined(USE_SSSE3)
constexpr const char* BuildSimd = "ssse3+";
#elif defined(USE_SSE2)
constexpr const char* BuildSimd = "sse2";
#elif defined(USE_NEON)
constexpr const char* BuildSimd = "neon";
#else
constexpr const char* BuildSimd = "scalar";
#endif

constexpr u32 StimMagic = 0x4D495453u;  // "STIM"
constexpr u32 StimVer   = 1;
constexpr u32 DigMagic  = 0x53474944u;  // "DIGS"

constexpr int MaxPsq    = 32;
constexpr int MaxActive = 256;

struct Rng {
    u64 s;
    explicit Rng(u64 seed) :
        s(seed ? seed : 0x9E3779B97F4A7C15ull) {}
    u64 next() {
        s ^= s >> 12;
        s ^= s << 25;
        s ^= s >> 27;
        return s * 0x2545F4914F6CDD1Dull;
    }
    u32 below(u32 n) { return u32((next() >> 32) % n); }
};

u64 fnv(const void* p, usize n, u64 h = 0xCBF29CE484222325ull) {
    const u8* b = static_cast<const u8*>(p);
    for (usize i = 0; i < n; ++i)
    {
        h ^= b[i];
        h *= 0x100000001B3ull;
    }
    return h;
}

// Fixed-size record of everything compared across builds. No build-specific bytes.
struct DigestRec {
    u64 id;
    u64 key;
    u32 move;
    u32 game;
    u16 ply;
    u8  op;
    u8  stm;
    u8  bucket;
    u8  inCheck;
    u16 nFeat;
    i32 outPsqt, outPos, rawPsqt, rawPos, fwd, skip;
    i32 evalOpt0, evalOptN, optN, pad;
    u64 hAcc, hPsqtAcc, hFt, hFc0, hConcat, hFc1, hFc2, hFeat;
};
static_assert(sizeof(DigestRec) == 136);

// Canonical (non-SIMD) tensors for the state under test.
struct Tensors {
    alignas(64) i16 acc[2][L1];  // indexed by Color
    i32 psqtAcc[2][PSQTBuckets];
    alignas(64) u8 ft[L1];
    i32 fc0[L2];
    u8  concat[128];
    i32 fc1[L3];
    i32 fc2;
    i32 fwd, skip, rawPsqt, rawPos;
    i32 outPsqt, outPos;
};

struct Features {
    u16 nPsq[2];
    u16 nActive[2];
    u16 psq[2][MaxPsq];
    u16 active[2][MaxActive];
};

struct StimRec {
    u64 id;
    u32 bucket;
    u32 stm;
    Features f;
    Tensors  t;
};

// Event stream for the incremental hardware path (--events).
enum EventTag : u32 {
    EV_ROOT,
    EV_PUSH,
    EV_POP,
    EV_EVAL
};
constexpr u32 EvMagic = 0x53564E45u;  // "ENVS"

enum Op : u8 {
    OP_ROOT,
    OP_MOVE,
    OP_UNDO,
    OP_NULL,
    OP_UNDO_NULL
};

struct Coverage {
    u64 states = 0, inCheck = 0, castling = 0, enPassant = 0, capture = 0, kingMove = 0;
    u64 mirrorChange = 0, promo[7] = {}, ops[5] = {}, bucket[8] = {}, stm[2] = {};
    u64 maxActive = 0, maxPsq = 0, repetition = 0, pawnPairDelta = 0, threatDelta = 0;
    u64 saturatedFtLow = 0, saturatedFtHigh = 0, pushRefresh = 0, maxDiff = 0;
    i64 minOutPos = INT32_MAX, maxOutPos = INT32_MIN, minOutPsqt = INT32_MAX, maxOutPsqt = INT32_MIN;
};

[[noreturn]] void die(const std::string& m) {
    std::cerr << "FATAL: " << m << std::endl;
    std::exit(1);
}

std::unique_ptr<Network> load_net(const std::string& path) {
    auto     net = std::make_unique<Network>();
    EvalFile ef;
    net->load_external(std::filesystem::path{}, path, ef);
    if (!ef.current.has_value())
        die("network refused: " + path);
    return net;
}

const NetworkArchitecture& arch_of(const Network& n, int b) { return n.network[b]; }

// Reorders a SIMD accumulator back to file order (see FeatureTransformer::permute_weights).
void canonical_acc(const std::array<i16, L1>& in, i16* out) {
    std::array<i16, L1> c = in;
    permute<16>(c, FeatureTransformer::InversePackusEpi16Order);
    std::memcpy(out, c.data(), sizeof(i16) * L1);
}

// Reverses the lane interleave that propagate_pair leaves in the concat buffer.
void canonical_concat(const u8* in, u8* out) {
#if defined(USE_PAIR_ACTIVATIONS)
    for (int block = 0; block < 4; ++block)
        for (int chunk = 0; chunk < 8; ++chunk)
            std::memcpy(out + block * 32 + chunk * 4,
                        in + block * 32 + ((chunk % 2) * 4 + chunk / 2) * 4, 4);
#else
    std::memcpy(out, in, 128);
#endif
}

void collect_features(const Position& pos, Features& f) {
    for (Color c : {WHITE, BLACK})
    {
        const Square ksq = pos.square<KING>(c);
        int          n   = 0;
        Bitboard     bb  = pos.pieces();
        while (bb)
        {
            Square s = pop_lsb(bb);
            if (n >= MaxPsq)
                die("more PSQ features than the fixed slot count");
            f.psq[c][n++] = u16(PSQFeatureSet::make_index(c, s, pos.piece_on(s), ksq));
        }
        f.nPsq[c] = u16(n);
        std::sort(f.psq[c], f.psq[c] + n);

        ThreatFeatureSet::IndexList active;
        ThreatFeatureSet::append_active_indices(c, pos, active);
        PairFeatureSet::append_active_indices(c, pos, active);
        if (active.size() > MaxActive)
            die("more threat/pair features than the fixed slot count");
        f.nActive[c] = u16(active.size());
        for (usize i = 0; i < active.size(); ++i)
            f.active[c][i] = active[i];
        std::sort(f.active[c], f.active[c] + active.size());
    }
}

// Independent scalar refresh from the feature list. Diagnostic only; proves that the
// stimulus handed to RTL is sufficient to rebuild the official accumulator.
void scalar_refresh_check(const Network& net, const Features& f, const Tensors& t) {
    if (!ScalarBuild)
        return;
    const auto& ft = net.featureTransformer;
    for (int c = 0; c < 2; ++c)
    {
        i16 acc[L1];
        i32 psqt[PSQTBuckets] = {};
        std::memcpy(acc, ft.biases.data(), sizeof(acc));
        for (int i = 0; i < f.nPsq[c]; ++i)
        {
            const usize row = f.psq[c][i];
            for (usize j = 0; j < L1; ++j)
                acc[j] = i16(u16(acc[j]) + u16(ft.weights[row * L1 + j]));
            for (usize b = 0; b < PSQTBuckets; ++b)
                psqt[b] = i32(u32(psqt[b]) + u32(ft.psqtWeights[row * PSQTBuckets + b]));
        }
        for (int i = 0; i < f.nActive[c]; ++i)
        {
            const usize row = f.active[c][i];
            for (usize j = 0; j < L1; ++j)
                acc[j] = i16(u16(acc[j]) + u16(i16(ft.threatAndPpWeights[row * L1 + j])));
            for (usize b = 0; b < PSQTBuckets; ++b)
                psqt[b] =
                  i32(u32(psqt[b]) + u32(ft.threatAndPpPsqtWeights[row * PSQTBuckets + b]));
        }
        if (std::memcmp(acc, t.acc[c], sizeof(acc)) || std::memcmp(psqt, t.psqtAcc[c], sizeof(psqt)))
            die("scalar refresh from feature list differs from official accumulator");
    }
}

// Evaluates through the official entry points, then replays the layers to expose tensors.
void capture(const Network&     net,
             const Position&    pos,
             AccumulatorStack&  stack,
             AccumulatorCaches& cache,
             Tensors&           t) {

    const auto [outPsqt, outPos] = net.evaluate(pos, stack, cache);
    const int bucket             = (pos.count<ALL_PIECES>() - 1) / 4;

    alignas(64) u8 ft[FeatureTransformer::BufferSize];
    NNZInfo<L1>    nnz;
    const i32      rawPsqt =
      net.featureTransformer.transform(pos, stack, cache, ft, bucket, nnz);

    const auto& st = stack.latest();
    for (int c = 0; c < 2; ++c)
    {
        canonical_acc(st.accumulation[c], t.acc[c]);
        std::memcpy(t.psqtAcc[c], st.psqtAccumulation[c].data(), sizeof(t.psqtAcc[c]));
    }
    std::memcpy(t.ft, ft, sizeof(t.ft));

    const auto& a = arch_of(net, bucket);
    alignas(64) i32 fc0[ceil_to_multiple<IndexType>(L2, 32)];
    alignas(64) u8  concat[128];
    alignas(64) i32 fc1[ceil_to_multiple<IndexType>(L3, 32)];
    alignas(64) i32 fc2[32];

    a.fc_0.propagate(ft, fc0, nnz);
#if defined(USE_PAIR_ACTIVATIONS)
    a.ac_sqr_0.propagate_pair(fc0, concat, concat + L2);
#else
    a.ac_sqr_0.propagate(fc0, concat);
    a.ac_0.propagate(fc0, concat + L2);
#endif
    a.fc_1.propagate(concat, fc1);
#if defined(USE_PAIR_ACTIVATIONS)
    a.ac_sqr_1.propagate_pair(fc1, concat + L2 * 2, concat + L2 * 2 + L3);
#else
    a.ac_sqr_1.propagate(fc1, concat + L2 * 2);
    a.ac_1.propagate(fc1, concat + L2 * 2 + L3);
#endif
    a.fc_2.propagate(concat, fc2);

    std::memcpy(t.fc0, fc0, sizeof(t.fc0));
    canonical_concat(concat, t.concat);
    std::memcpy(t.fc1, fc1, sizeof(t.fc1));
    t.fc2 = fc2[0];

    t.skip = fc0[L2 - 2] - fc0[L2 - 1];
    t.fwd  = fc2[0] + t.skip;

    constexpr i64 multiplier  = 600 * OutputScale;
    constexpr i64 denominator = i64(HiddenOneVal) * i64(1U << WeightScaleBits) * 2;
    t.rawPos                  = i32((i64(t.fwd) * multiplier) / denominator);
    t.rawPsqt                 = rawPsqt;
    t.outPsqt                 = outPsqt;
    t.outPos                  = outPos;

    if (t.rawPsqt / OutputScale != outPsqt || t.rawPos / OutputScale != outPos)
        die("layer replay differs from official Network::evaluate()");
}

struct ScriptLine {
    std::string              name, fen;
    std::vector<std::string> moves;
};

std::vector<ScriptLine> read_corpus(const std::string& path) {
    std::ifstream in(path);
    if (!in)
        die("cannot open corpus " + path);
    std::vector<ScriptLine> out;
    std::string             line;
    while (std::getline(in, line))
    {
        while (!line.empty() && (line.back() == '\r' || line.back() == ' '))
            line.pop_back();
        if (line.empty() || line[0] == '#')
            continue;
        std::stringstream ss(line);
        ScriptLine        s;
        std::string       moves;
        std::getline(ss, s.name, '|');
        std::getline(ss, s.fen, '|');
        std::getline(ss, moves, '|');
        std::stringstream ms(moves);
        std::string       m;
        while (ms >> m)
            s.moves.push_back(m);
        out.push_back(s);
    }
    if (out.empty())
        die("empty corpus");
    return out;
}

std::vector<Move> sorted_legal(const Position& pos) {
    std::vector<Move> v;
    for (const auto& m : MoveList<LEGAL>(pos))
        v.push_back(Move(m));
    // Generator order is not part of the contract, so traces must not depend on it.
    std::sort(v.begin(), v.end(), [](Move a, Move b) { return a.raw() < b.raw(); });
    return v;
}

std::string uci_of(Move m) {
    const Square from = m.from_sq();
    Square       to   = m.to_sq();
    // Stockfish encodes castling as king-takes-rook; the corpus uses standard UCI.
    if (m.type_of() == CASTLING)
        to = make_square(to > from ? FILE_G : FILE_C, rank_of(from));
    std::string s;
    s += char('a' + file_of(from));
    s += char('1' + rank_of(from));
    s += char('a' + file_of(to));
    s += char('1' + rank_of(to));
    if (m.type_of() == PROMOTION)
        s += " pnbrqk"[m.promotion_type()];
    return s;
}

class Tracer {
   public:
    Tracer(const Network& n,
           u64            seed,
           std::ofstream& dig,
           std::ofstream* stim,
           u64            stimEvery,
           std::ofstream* events = nullptr) :
        net(n),
        rng(seed),
        digest(dig),
        stimOut(stim),
        every(stimEvery),
        evOut(events) {
        inc        = std::make_unique<AccumulatorStack>();
        fresh      = std::make_unique<AccumulatorStack>();
        warm       = std::make_unique<AccumulatorStack>();
        incCache   = std::make_unique<AccumulatorCaches>(net);
        freshCache = std::make_unique<AccumulatorCaches>(net);
        warmCache  = std::make_unique<AccumulatorCaches>(net);
    }

    Coverage cov;
    u64      id = 0;

    // Search replay entry points. Only the operations the search performed are applied.
    void replay_root(const std::string& fen, u32 gameNo) { start(fen, gameNo, false); }
    void replay_move(u16 raw) { do_move(Move(raw), false); }
    void replay_undo() { undo(false); }
    void replay_null() { do_null(false); }
    void replay_undo_null() { undo(false); }
    void replay_eval(int optimism, int value, bool emit) {
        if (Eval::evaluate(net, pos, *inc, *incCache, optimism) != value)
        {
            std::cerr << "fen " << pos.fen() << "\n";
            die("replay differs from the value logged by the official search");
        }
        emitEval = emit;
        record(OP_ROOT, Move::none());
        emitEval = true;
    }

    void start(const std::string& fen, u32 gameNo, bool rec = true) {
        game = gameNo;
        states.clear();
        history.clear();
        states.emplace_back();
        pos.set(fen, false, &states.back());
        if (pos.attackers_to(pos.square<KING>(~pos.side_to_move())) & pos.pieces(pos.side_to_move()))
            die("illegal FEN (side not to move is in check): " + fen);
        inc->reset();
        if (evOut)
            write_tag(EV_ROOT);
        if (rec)
            record(OP_ROOT, Move::none());
    }

    bool apply_uci(const std::string& text) {
        for (Move m : sorted_legal(pos))
            if (uci_of(m) == text)
            {
                do_move(m);
                return true;
            }
        return false;
    }

    void random_walk(u64 limit) {
        for (int step = 0; step < 400 && id < limit; ++step)
        {
            const u32 roll = rng.below(100);
            if (roll < 8 && !history.empty())
            {
                const Move redo = undo();
                if (redo != Move::null() && rng.below(2) == 0 && id < limit)
                    do_move(redo);
                continue;
            }
            if (roll < 12 && !pos.checkers() && !lastWasNull() && history.size() < 200)
            {
                do_null();
                continue;
            }

            auto moves = sorted_legal(pos);
            if (moves.empty() || pos.rule50_count() >= 100 || history.size() >= 200)
                return;

            // Bias toward material changes so that every piece-count bucket is visited.
            std::vector<Move> forcing;
            for (Move m : moves)
                if (pos.capture_stage(m))
                    forcing.push_back(m);
            const auto& pool = (!forcing.empty() && rng.below(100) < 45) ? forcing : moves;
            do_move(pool[rng.below(u32(pool.size()))]);
        }
    }

   private:
    bool lastWasNull() const { return !history.empty() && history.back() == Move::null(); }

    void write_tag(EventTag tag) {
        const u32 v = tag;
        evOut->write(reinterpret_cast<const char*>(&v), sizeof(v));
    }

    static void sorted_multiset_check(const u16* parent, int nParent, const u16* child, int nChild,
                                      const std::vector<u16>& removed, const std::vector<u16>& added) {
        // Adds go first: one official diff may add and remove the same feature.
        std::vector<u16> expect(parent, parent + nParent);
        expect.insert(expect.end(), added.begin(), added.end());
        for (u16 r : removed)
        {
            auto it = std::find(expect.begin(), expect.end(), r);
            if (it == expect.end())
                die("official diff removes a feature neither state has");
            expect.erase(it);
        }
        std::sort(expect.begin(), expect.end());
        if (!std::equal(expect.begin(), expect.end(), child, child + nChild))
            die("parent features plus official diff differ from child features");
    }

    // Official per-ply change lists, checked against the feature sets of both positions.
    void emit_push(const Dirties& d, const Features& parent) {
        auto child = std::make_unique<Features>();
        std::memset(child.get(), 0, sizeof(Features));
        collect_features(pos, *child);

        write_tag(EV_PUSH);
        for (Color c : {WHITE, BLACK})
        {
            const u16 refresh = PSQFeatureSet::requires_refresh(d.dirtyPiece, c) ? 1 : 0;
            cov.pushRefresh += refresh;

            std::vector<u16> lists[4];  // PSQ add, PSQ remove, active add, active remove
            if (!refresh)
            {
                const Square                ksq = pos.square<KING>(c);
                PSQFeatureSet::IndexList    psqRemoved, psqAdded;
                ThreatFeatureSet::IndexList thrRemoved, thrAdded;
                ThreatFeatureSet::append_changed_indices(c, ksq, d.dirtyThreats, thrRemoved, thrAdded);
                PairFeatureSet::append_changed_indices(c, ksq, d.dirtyPawnPairs, thrRemoved, thrAdded);
                PSQFeatureSet::append_changed_indices(c, ksq, d.dirtyPiece, psqRemoved, psqAdded);
                lists[0].assign(psqAdded.begin(), psqAdded.end());
                lists[1].assign(psqRemoved.begin(), psqRemoved.end());
                lists[2].assign(thrAdded.begin(), thrAdded.end());
                lists[3].assign(thrRemoved.begin(), thrRemoved.end());

                sorted_multiset_check(parent.psq[c], parent.nPsq[c], child->psq[c], child->nPsq[c],
                                      lists[1], lists[0]);
                sorted_multiset_check(parent.active[c], parent.nActive[c], child->active[c],
                                      child->nActive[c], lists[3], lists[2]);
                cov.maxDiff = std::max<u64>(cov.maxDiff, lists[2].size() + lists[3].size());
            }

            u16 head[5] = {refresh, u16(lists[0].size()), u16(lists[1].size()), u16(lists[2].size()),
                           u16(lists[3].size())};
            evOut->write(reinterpret_cast<const char*>(head), sizeof(head));
            for (const auto& l : lists)
                evOut->write(reinterpret_cast<const char*>(l.data()),
                             std::streamsize(l.size() * sizeof(u16)));
        }
    }

    void do_move(Move m, bool rec = true) {
        const Piece  moved = pos.moved_piece(m);
        const Square from  = m.from_sq(), to = m.to_sq();
        if (m.type_of() == CASTLING)
            ++cov.castling;
        if (m.type_of() == EN_PASSANT)
            ++cov.enPassant;
        if (m.type_of() == PROMOTION)
            ++cov.promo[m.promotion_type()];
        if (pos.capture(m))
            ++cov.capture;
        if (type_of(moved) == KING)
        {
            ++cov.kingMove;
            if ((int(from) & 4) != (int(to) & 4))
                ++cov.mirrorChange;
        }
        std::unique_ptr<Features> parent;
        if (evOut)
        {
            parent = std::make_unique<Features>();
            std::memset(parent.get(), 0, sizeof(Features));
            collect_features(pos, *parent);
        }
        states.emplace_back();
        Dirties& d = inc->push();
        pos.do_move(m, states.back(), pos.gives_check(m), d, nullptr, nullptr);
        cov.threatDelta += d.dirtyThreats.list.size() ? 1 : 0;
        cov.pawnPairDelta += (d.dirtyPawnPairs.before[WHITE] != d.dirtyPawnPairs.after[WHITE]
                              || d.dirtyPawnPairs.before[BLACK] != d.dirtyPawnPairs.after[BLACK])
                             ? 1
                             : 0;
        history.push_back(m);
        if (evOut)
            emit_push(d, *parent);
        if (rec)
            record(OP_MOVE, m);
    }

    void do_null(bool rec = true) {
        states.emplace_back();
        pos.do_null_move(states.back());
        history.push_back(Move::null());
        if (rec)
            record(OP_NULL, Move::null());
    }

    Move undo(bool rec = true) {
        const Move m = history.back();
        history.pop_back();
        if (m == Move::null())
            pos.undo_null_move();
        else
        {
            pos.undo_move(m);
            inc->pop();
            if (evOut)
                write_tag(EV_POP);
        }
        states.pop_back();
        if (rec)
            record(m == Move::null() ? OP_UNDO_NULL : OP_UNDO, m);
        return m;
    }

    void compare(const Tensors& a, const Tensors& b, const char* what) {
        if (std::memcmp(a.acc, b.acc, sizeof(a.acc)) || std::memcmp(a.psqtAcc, b.psqtAcc, sizeof(a.psqtAcc))
            || std::memcmp(a.ft, b.ft, sizeof(a.ft)) || std::memcmp(a.fc0, b.fc0, sizeof(a.fc0))
            || std::memcmp(a.concat, b.concat, sizeof(a.concat)) || std::memcmp(a.fc1, b.fc1, sizeof(a.fc1))
            || a.fc2 != b.fc2 || a.outPsqt != b.outPsqt || a.outPos != b.outPos)
        {
            std::cerr << "state " << id << " game " << game << " fen " << pos.fen() << "\n";
            die(std::string(what) + " tensors differ");
        }
    }

    void record(Op op, Move m) {
        ++cov.ops[op];

        // Three official update paths must agree on every tensor: incremental along the
        // trace, cold refresh, and Finny-table refresh.
        auto ti = std::make_unique<Tensors>();
        auto tf = std::make_unique<Tensors>();
        auto tw = std::make_unique<Tensors>();
        capture(net, pos, *inc, *incCache, *ti);
        fresh->reset();
        freshCache->clear(net);
        capture(net, pos, *fresh, *freshCache, *tf);
        warm->reset();
        capture(net, pos, *warm, *warmCache, *tw);
        compare(*ti, *tf, "incremental vs cold refresh");
        compare(*tw, *tf, "cached refresh vs cold refresh");

        auto f = std::make_unique<Features>();
        std::memset(f.get(), 0, sizeof(Features));
        collect_features(pos, *f);
        scalar_refresh_check(net, *f, *tf);

        const int bucket = (pos.count<ALL_PIECES>() - 1) / 4;

        DigestRec r{};
        r.id      = id;
        r.key     = pos.key();
        r.move    = m.raw();
        r.game    = game;
        r.ply     = u16(history.size());
        r.op      = op;
        r.stm     = u8(pos.side_to_move());
        r.bucket  = u8(bucket);
        r.inCheck = pos.checkers() ? 1 : 0;
        r.nFeat   = u16(f->nPsq[0] + f->nPsq[1] + f->nActive[0] + f->nActive[1]);
        r.outPsqt = tf->outPsqt;
        r.outPos  = tf->outPos;
        r.rawPsqt = tf->rawPsqt;
        r.rawPos  = tf->rawPos;
        r.fwd     = tf->fwd;
        r.skip    = tf->skip;

        if (!pos.checkers())
        {
            r.optN     = i32(rng.below(4001)) - 2000;
            r.evalOpt0 = Eval::evaluate(net, pos, *inc, *incCache, 0);
            r.evalOptN = Eval::evaluate(net, pos, *inc, *incCache, r.optN);
        }

        r.hAcc     = fnv(tf->acc, sizeof(tf->acc));
        r.hPsqtAcc = fnv(tf->psqtAcc, sizeof(tf->psqtAcc));
        r.hFt      = fnv(tf->ft, sizeof(tf->ft));
        r.hFc0     = fnv(tf->fc0, sizeof(tf->fc0));
        r.hConcat  = fnv(tf->concat, sizeof(tf->concat));
        r.hFc1     = fnv(tf->fc1, sizeof(tf->fc1));
        r.hFc2     = fnv(&tf->fc2, sizeof(tf->fc2));
        r.hFeat    = fnv(f.get(), sizeof(Features));
        digest.write(reinterpret_cast<const char*>(&r), sizeof(r));

        const bool toStim   = stimOut && id % every == 0;
        const bool toEvents = evOut && emitEval;
        if (toStim || toEvents)
        {
            auto s    = std::make_unique<StimRec>();
            s->id     = id;
            s->bucket = u32(bucket);
            s->stm    = u32(pos.side_to_move());
            s->f      = *f;
            s->t      = *tf;
            if (toStim)
                stimOut->write(reinterpret_cast<const char*>(s.get()), sizeof(StimRec));
            if (toEvents)
            {
                write_tag(EV_EVAL);
                evOut->write(reinterpret_cast<const char*>(s.get()), sizeof(StimRec));
            }
        }

        ++cov.states;
        ++cov.bucket[bucket];
        ++cov.stm[pos.side_to_move()];
        cov.inCheck += r.inCheck;
        cov.repetition += pos.is_draw(0) ? 1 : 0;
        cov.maxPsq    = std::max<u64>(cov.maxPsq, std::max(f->nPsq[0], f->nPsq[1]));
        cov.maxActive = std::max<u64>(cov.maxActive, std::max(f->nActive[0], f->nActive[1]));
        for (int c = 0; c < 2; ++c)
            for (usize j = 0; j < L1; ++j)
            {
                cov.saturatedFtLow += tf->acc[c][j] < 0;
                cov.saturatedFtHigh += tf->acc[c][j] > 255;
            }
        cov.minOutPos  = std::min<i64>(cov.minOutPos, tf->outPos);
        cov.maxOutPos  = std::max<i64>(cov.maxOutPos, tf->outPos);
        cov.minOutPsqt = std::min<i64>(cov.minOutPsqt, tf->outPsqt);
        cov.maxOutPsqt = std::max<i64>(cov.maxOutPsqt, tf->outPsqt);
        ++id;
    }

    const Network&                     net;
    Rng                                rng;
    std::ofstream&                     digest;
    std::ofstream*                     stimOut;
    u64                                every;
    std::ofstream*                     evOut;
    bool                               emitEval = true;
    Position                           pos;
    std::deque<StateInfo>              states;
    std::vector<Move>                  history;
    std::unique_ptr<AccumulatorStack>  inc, fresh, warm;
    std::unique_ptr<AccumulatorCaches> incCache, freshCache, warmCache;
    u32                                game = 0;
};

int cmd_spec(const std::string& netPath) {
    std::ifstream in(netPath, std::ios::binary);
    if (!in)
        die("cannot open " + netPath);
    u32 version = 0, hash = 0, descLen = 0;
    in.read(reinterpret_cast<char*>(&version), 4);
    in.read(reinterpret_cast<char*>(&hash), 4);
    in.read(reinterpret_cast<char*>(&descLen), 4);
    std::string desc(descLen, '\0');
    in.read(desc.data(), descLen);
    u32 ftHash = 0;
    in.read(reinterpret_cast<char*>(&ftHash), 4);
    for (auto& ch : desc)
        if (ch == '"' || ch == '\\' || ch < 32)
            ch = ' ';

    load_net(netPath);  // Proves that the official loader accepts this file.

    std::cout << "{\n"
              << "  \"build_simd\": \"" << BuildSimd << "\",\n"
              << "  \"source_version\": " << Version << ",\n"
              << "  \"source_network_hash\": " << Network::hash << ",\n"
              << "  \"source_ft_hash\": " << FeatureTransformer::get_hash_value() << ",\n"
              << "  \"source_arch_hash\": " << NetworkArchitecture::get_hash_value() << ",\n"
              << "  \"file_version\": " << version << ",\n"
              << "  \"file_network_hash\": " << hash << ",\n"
              << "  \"file_ft_hash\": " << ftHash << ",\n"
              << "  \"file_description\": \"" << desc << "\",\n"
              << "  \"L1\": " << L1 << ",\n  \"L2\": " << L2 << ",\n  \"L3\": " << L3 << ",\n"
              << "  \"psqt_buckets\": " << PSQTBuckets << ",\n"
              << "  \"layer_stacks\": " << LayerStacks << ",\n"
              << "  \"output_scale\": " << OutputScale << ",\n"
              << "  \"positional_multiplier\": " << 600 * OutputScale << ",\n"
              << "  \"weight_scale_bits\": " << WeightScaleBits << ",\n"
              << "  \"ft_max_val\": " << FtMaxVal << ",\n"
              << "  \"hidden_one_val\": " << HiddenOneVal << ",\n"
              << "  \"psq_dimensions\": " << PSQFeatureSet::Dimensions << ",\n"
              << "  \"threat_dimensions\": " << ThreatFeatureSet::Dimensions << ",\n"
              << "  \"pair_dimensions\": " << PairFeatureSet::Dimensions << ",\n"
              << "  \"pair_index_base\": " << PairFeatureSet::IndexBase << ",\n"
              << "  \"max_psq_active\": " << PSQFeatureSet::MaxActiveDimensions << ",\n"
              << "  \"max_threat_active\": " << MaxActive << ",\n"
              << "  \"fc0_input_padded\": " << decltype(NetworkArchitecture::fc_0)::PaddedInputDimensions << ",\n"
              << "  \"fc1_input_padded\": " << decltype(NetworkArchitecture::fc_1)::PaddedInputDimensions << ",\n"
              << "  \"fc2_input_padded\": " << decltype(NetworkArchitecture::fc_2)::PaddedInputDimensions << ",\n"
              << "  \"sizeof_stim_rec\": " << sizeof(StimRec) << ",\n"
              << "  \"stim_version\": " << StimVer << "\n"
              << "}\n";
    return 0;
}

// The official loader must refuse each corruption. A refused net is the required result.
int cmd_reject(const std::string& netPath, const std::string& dir) {
    std::ifstream in(netPath, std::ios::binary);
    std::vector<char> data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (data.size() < 64)
        die("net too small");

    struct Case {
        const char*                       name;
        std::function<void(std::vector<char>&)> mutate;
    };
    const std::vector<Case> cases = {
      {"bad_version", [](auto& d) { d[0] ^= 1; }},
      {"bad_network_hash", [](auto& d) { d[4] ^= 1; }},
      {"truncated", [](auto& d) { d.resize(d.size() - 1); }},
      {"trailing_byte", [](auto& d) { d.push_back(0); }},
    };

    int failures = 0;
    for (const auto& c : cases)
    {
        auto copy = data;
        c.mutate(copy);
        const std::string path = dir + "/reject_" + c.name + ".nnue";
        {
            std::ofstream out(path, std::ios::binary);
            out.write(copy.data(), std::streamsize(copy.size()));
        }
        auto     net = std::make_unique<Network>();
        EvalFile ef;
        net->load_external(std::filesystem::path{}, path, ef);
        const bool refused = !ef.current.has_value();
        std::cout << c.name << ": " << (refused ? "refused" : "ACCEPTED") << "\n";
        failures += !refused;
        std::filesystem::remove(path);
    }
    return failures ? 1 : 0;
}

// Canonical weights in file order, for the packer. Only the scalar build stores them unpermuted.
int cmd_export(const std::string& netPath, const std::string& outPath) {
    if (!ScalarBuild)
        die("export requires the scalar build (SIMD builds store permuted weights)");
    auto          net = load_net(netPath);
    std::ofstream out(outPath, std::ios::binary);
    auto          put = [&](const void* p, usize n) {
        out.write(static_cast<const char*>(p), std::streamsize(n));
    };
    const auto& ft = net->featureTransformer;
    put(ft.biases.data(), sizeof(ft.biases));
    put(ft.weights.data(), sizeof(ft.weights));
    put(ft.psqtWeights.data(), sizeof(ft.psqtWeights));
    put(ft.threatAndPpWeights.data(), sizeof(ft.threatAndPpWeights));
    put(ft.threatAndPpPsqtWeights.data(), sizeof(ft.threatAndPpPsqtWeights));
    for (usize b = 0; b < LayerStacks; ++b)
    {
        const auto& a = net->network[b];
        put(a.fc_0.biases, sizeof(a.fc_0.biases));
        put(a.fc_0.weights, sizeof(a.fc_0.weights));
        put(a.fc_1.biases, sizeof(a.fc_1.biases));
        put(a.fc_1.weights, sizeof(a.fc_1.weights));
        put(a.fc_2.biases, sizeof(a.fc_2.biases));
        put(a.fc_2.weights, sizeof(a.fc_2.weights));
    }
    return out.good() ? 0 : 1;
}

void open_events(std::ofstream& events, const std::string& path) {
    if (!ScalarBuild)
        die("event stimulus must come from the scalar build");
    events.open(path, std::ios::binary);
    const u32 head[4] = {EvMagic, StimVer, u32(sizeof(StimRec)), Network::hash};
    events.write(reinterpret_cast<const char*>(head), sizeof(head));
}

// Replays a search log. All evaluations are compared; --evals-per-root limits what reaches
// the event stream to a window from the middle of each search, where the tree is deepest.
int cmd_replay(int argc, char** argv) {
    const std::string netPath = argv[2], opsPath = argv[3];
    std::string       digestPath, eventsPath;
    u64               perRoot = UINT64_MAX, maxEvals = UINT64_MAX;
    for (int i = 4; i + 1 < argc; i += 2)
    {
        const std::string k = argv[i], v = argv[i + 1];
        if (k == "--digest")
            digestPath = v;
        else if (k == "--events")
            eventsPath = v;
        else if (k == "--evals-per-root")
            perRoot = std::stoull(v);
        else if (k == "--max-evals")
            maxEvals = std::stoull(v);
        else
            die("unknown option " + k);
    }
    if (digestPath.empty())
        die("--digest is required");

    std::ifstream in(opsPath, std::ios::binary);
    if (!in)
        die("cannot open " + opsPath);

    struct OpRec {
        i32 type, a, b;
    };

    // First pass: evaluations per search, for the window position.
    std::vector<u64> evalsPerRoot;
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

    auto net = load_net(netPath);

    std::ofstream digest(digestPath, std::ios::binary);
    const u32     dh[4] = {DigMagic, u32(sizeof(DigestRec)), Version, Network::hash};
    digest.write(reinterpret_cast<const char*>(dh), sizeof(dh));

    std::ofstream events;
    if (!eventsPath.empty())
        open_events(events, eventsPath);

    Tracer t(*net, 1, digest, nullptr, 1, events.is_open() ? &events : nullptr);

    OpRec r;
    u32   root = 0;
    u64   evalIndex = 0, windowStart = 0, windowEnd = UINT64_MAX, total = 0, emitted = 0;
    bool  started = false;
    while (total < maxEvals && in.read(reinterpret_cast<char*>(&r), sizeof(r)))
    {
        switch (r.type)
        {
        case 0: {
            std::string fen(usize(r.a), '\0');
            in.read(fen.data(), r.a);
            t.replay_root(fen, root);
            const u64 n = evalsPerRoot[root];
            windowStart = n > perRoot ? (n - perRoot) / 2 : 0;
            windowEnd   = perRoot == UINT64_MAX ? UINT64_MAX : windowStart + perRoot;
            evalIndex   = 0;
            started     = true;
            ++root;
            break;
        }
        case 1:
            t.replay_move(u16(r.a));
            break;
        case 2:
            t.replay_undo();
            break;
        case 3:
            t.replay_null();
            break;
        case 4:
            t.replay_undo_null();
            break;
        case 5: {
            if (!started)
                die("evaluation before the first root");
            const bool emit = evalIndex >= windowStart && evalIndex < windowEnd;
            t.replay_eval(r.a, r.b, emit);
            emitted += emit;
            ++evalIndex;
            ++total;
            break;
        }
        default:
            die("unknown operation in search log");
        }
    }

    const Coverage& c = t.cov;
    std::cout << "{\n  \"simd\": \"" << BuildSimd << "\",\n  \"roots\": " << root
              << ",\n  \"evaluations\": " << c.states << ",\n  \"events_evaluations\": " << emitted
              << ",\n  \"push_refresh_perspectives\": " << c.pushRefresh
              << ",\n  \"max_active_diff_one_ply\": " << c.maxDiff
              << ",\n  \"max_active_features\": " << c.maxActive << ",\n  \"stm\": [" << c.stm[0] << ", "
              << c.stm[1] << "],\n  \"bucket\": [";
    for (int b = 0; b < 8; ++b)
        std::cout << c.bucket[b] << (b < 7 ? ", " : "");
    std::cout << "],\n  \"mismatches\": 0\n}\n";
    return digest.good() ? 0 : 1;
}

int cmd_trace(int argc, char** argv) {
    const std::string netPath = argv[2], corpusPath = argv[3];
    u64               seed = 1, limit = 1000, every = 1;
    std::string       digestPath, stimPath, eventsPath;
    for (int i = 4; i + 1 < argc; i += 2)
    {
        const std::string k = argv[i], v = argv[i + 1];
        if (k == "--seed")
            seed = std::stoull(v);
        else if (k == "--states")
            limit = std::stoull(v);
        else if (k == "--digest")
            digestPath = v;
        else if (k == "--stim")
            stimPath = v;
        else if (k == "--stim-every")
            every = std::stoull(v);
        else if (k == "--events")
            eventsPath = v;
        else
            die("unknown option " + k);
    }
    if (digestPath.empty())
        die("--digest is required");
    if (!stimPath.empty() && !ScalarBuild)
        die("stimulus must come from the scalar build");

    auto net    = load_net(netPath);
    auto corpus = read_corpus(corpusPath);

    std::ofstream digest(digestPath, std::ios::binary);
    const u32     dh[4] = {DigMagic, u32(sizeof(DigestRec)), Version, Network::hash};
    digest.write(reinterpret_cast<const char*>(dh), sizeof(dh));

    std::ofstream stim;
    if (!stimPath.empty())
    {
        stim.open(stimPath, std::ios::binary);
        const u32 sh[4] = {StimMagic, StimVer, u32(sizeof(StimRec)), Network::hash};
        stim.write(reinterpret_cast<const char*>(sh), sizeof(sh));
    }

    std::ofstream events;
    if (!eventsPath.empty())
        open_events(events, eventsPath);

    Tracer t(*net, seed, digest, stim.is_open() ? &stim : nullptr, every,
             events.is_open() ? &events : nullptr);
    u32    game = 0;

    // Scripted lines first, so that the special cases are present at any --states value.
    for (const auto& line : corpus)
    {
        t.start(line.fen, game++);
        for (const auto& m : line.moves)
            if (!t.apply_uci(m))
                die("illegal scripted move " + m + " in " + line.name);
    }
    const u64 scripted = t.id;

    Rng pick(seed ^ 0xA5A5A5A5A5A5A5A5ull);
    while (t.id < limit)
    {
        t.start(corpus[pick.below(u32(corpus.size()))].fen, game++);
        t.random_walk(limit);
    }

    const Coverage& c = t.cov;
    std::cout << "{\n  \"simd\": \"" << BuildSimd << "\",\n  \"seed\": " << seed
              << ",\n  \"states\": " << c.states << ",\n  \"scripted_states\": " << scripted
              << ",\n  \"games\": " << game << ",\n  \"in_check\": " << c.inCheck
              << ",\n  \"castling\": " << c.castling << ",\n  \"en_passant\": " << c.enPassant
              << ",\n  \"capture\": " << c.capture << ",\n  \"king_move\": " << c.kingMove
              << ",\n  \"king_mirror_change\": " << c.mirrorChange
              << ",\n  \"promo_n\": " << c.promo[KNIGHT] << ",\n  \"promo_b\": " << c.promo[BISHOP]
              << ",\n  \"promo_r\": " << c.promo[ROOK] << ",\n  \"promo_q\": " << c.promo[QUEEN]
              << ",\n  \"op_move\": " << c.ops[OP_MOVE] << ",\n  \"op_undo\": " << c.ops[OP_UNDO]
              << ",\n  \"op_null\": " << c.ops[OP_NULL] << ",\n  \"op_undo_null\": " << c.ops[OP_UNDO_NULL]
              << ",\n  \"repetition_or_draw\": " << c.repetition
              << ",\n  \"threat_delta_moves\": " << c.threatDelta
              << ",\n  \"pawn_pair_delta_moves\": " << c.pawnPairDelta
              << ",\n  \"max_psq_features\": " << c.maxPsq
              << ",\n  \"max_active_features\": " << c.maxActive
              << ",\n  \"acc_below_0\": " << c.saturatedFtLow
              << ",\n  \"acc_above_255\": " << c.saturatedFtHigh
              << ",\n  \"out_positional_range\": [" << c.minOutPos << ", " << c.maxOutPos << "]"
              << ",\n  \"out_psqt_range\": [" << c.minOutPsqt << ", " << c.maxOutPsqt << "]"
              << ",\n  \"stm\": [" << c.stm[0] << ", " << c.stm[1] << "]"
              << ",\n  \"bucket\": [";
    for (int b = 0; b < 8; ++b)
        std::cout << c.bucket[b] << (b < 7 ? ", " : "");
    std::cout << "],\n  \"mismatches\": 0\n}\n";
    return digest.good() ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
    Attacks::init();
    Position::init();

    const std::string cmd = argc > 1 ? argv[1] : "";
    if (cmd == "spec" && argc == 3)
        return cmd_spec(argv[2]);
    if (cmd == "reject" && argc == 4)
        return cmd_reject(argv[2], argv[3]);
    if (cmd == "export" && argc == 4)
        return cmd_export(argv[2], argv[3]);
    if (cmd == "trace" && argc >= 4)
        return cmd_trace(argc, argv);
    if (cmd == "replay" && argc >= 4)
        return cmd_replay(argc, argv);

    std::cerr << "usage: golden_harness spec|reject|export|trace|replay ...\n";
    return 2;
}
