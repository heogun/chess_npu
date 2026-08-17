/*
 * ref_eval.cc - SF18 NNUE 스칼라 리퍼런스 평가 (HW bit-exact 검증용)
 *
 * 소스 재현 근거 (전부 실소스 확정):
 *   - src/nnue/network.cpp        : trace_evaluate = (psqt/16, positional/16), bucket=(n-1)/4
 *   - nnue_feature_transformer.h  : transform() #else 스칼라 경로
 *                                    small: clamp(acc,0,254), (s0*s1)/512  (biases/weights 는
 *                                            read_parameters 에서 scale_weights(true) 로 x2)
 *                                    big:   clamp(acc+thr,0,255), (s0*s1)/512
 *                                    psqt = (psqtAcc[stm]-psqtAcc[~stm] [+thrPsqt]/2)
 *   - nnue_architecture.h         : propagate() fc 체인, fwdOut = fc0_out[15]*9600/8128
 *   - layers/sqr_clipped_relu.h   : min(127, x*x >> 19)
 *   - layers/clipped_relu.h       : clamp(x >> 6, 0, 127)
 *   - affine_transform_sparse_input.h : fc_0 는 SSSE3 빌드에서 get_weight_index = scrambled
 *                                    (ChunkSize=4). 단 fc_0 는 in==padded==128 이라
 *                                    순열이 상쇄되어 파일은 자연 순서임이 확인됨
 *   - affine_transform.h          : fc_1/fc_2 자연 순서 (ENABLE_SEQ_OPT 미정의)
 *   - features/half_ka_v2_hm.h    : KingBuckets/OrientTBL/PieceSquareIndex 원본
 *   - features/full_threats.*     : FullThreats 특징 인덱스 (big 전용)
 *   - nnue_accumulator.cpp        : threat 어큐뮬레이터 bias 없음(0 초기화)
 *
 * 빌드: g++ -O2 -std=c++17 -o ref_eval ref_eval.cc
 * 사용: ./ref_eval <net.nnue> "<FEN>"
 * 출력: RAWVERIFY <bucket> <psqt/16> <positional/16>  (SF trace 패치와 동일 포맷)
 */

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// 상수 (types.h / nnue_architecture.h 재현)
// ---------------------------------------------------------------------------

enum Color : int { WHITE = 0, BLACK = 1 };
enum PieceType : int { NO_PIECE_TYPE = 0, PAWN = 1, KNIGHT, BISHOP, ROOK, QUEEN, KING,
                       PIECE_TYPE_NB = 8, PIECE_TYPE_NB2 = 6 };
enum Piece : int { NO_PIECE = 0, W_PAWN = 1, W_KNIGHT, W_BISHOP, W_ROOK, W_QUEEN, W_KING,
                   B_PAWN = 9, B_KNIGHT, B_BISHOP, B_ROOK, B_QUEEN, B_KING, PIECE_NB = 16 };

constexpr int SQUARE_NB = 64;
constexpr int SQ_A8 = 56;
constexpr int PSQTBuckets = 8;
constexpr int LayerStacks = 8;
constexpr int MaxSimdWidth = 32;
constexpr int OutputScale = 16;
constexpr int WeightScaleBits = 6;
constexpr int TransformedFeatureDimensionsBig = 1024;
constexpr int TransformedFeatureDimensionsSmall = 128;
constexpr int L2 = 15, L3 = 32;
constexpr int PSQInputDim = 22528;
constexpr int ThrInputDim = 79856;

static inline int ceil_to_multiple(int n, int base) { return (n + base - 1) / base * base; }
static inline int file_of(int s) { return s & 7; }
static inline int rank_of(int s) { return s >> 3; }
static constexpr int make_square(int f, int r) { return r * 8 + f; }
static constexpr Piece make_piece(Color c, PieceType pt) { return Piece(pt + 8 * c); }
static constexpr PieceType type_of(Piece p) { return PieceType(p & 7); }
static constexpr Color color_of(Piece p) { return Color(p >> 3); }

// ---------------------------------------------------------------------------
// 파일 파싱 (M1 로더 로직 재사용)
// ---------------------------------------------------------------------------

struct ByteStream {
    const std::uint8_t* data;
    size_t              size;
    size_t              pos = 0;
    bool                read(void* out, size_t n) {
        if (pos + n > size) return false;
        std::memcpy(out, data + pos, n);
        pos += n;
        return true;
    }
    template<typename T> bool readLE(T& v) {
        static_assert(std::is_trivially_copyable_v<T>);
        if (pos + sizeof(T) > size) return false;
        std::memcpy(&v, data + pos, sizeof(T));
        pos += sizeof(T);
        return true;
    }
};

static constexpr const char* Leb128Magic = "COMPRESSED_LEB128";
static constexpr size_t      Leb128MagicN = 17;

static bool read_leb_value(ByteStream& s, std::int32_t& out) {
    std::int32_t result = 0;
    int          shift  = 0;
    std::uint8_t byte;
    while (true) {
        if (!s.read(&byte, 1)) return false;
        result |= (byte & 0x7f) << (shift % 32);
        shift += 7;
        if ((byte & 0x80) == 0) break;
    }
    out = (shift >= 32 || (byte & 0x40) == 0) ? result : result | ~((1 << shift) - 1);
    return true;
}

struct LebBlock {
    ByteStream&   s;
    std::uint32_t bytes_left;
    LebBlock(ByteStream& s_, const char* what) : s(s_), bytes_left(0) {
        char magic[Leb128MagicN];
        if (!s.read(magic, Leb128MagicN) || std::memcmp(magic, Leb128Magic, Leb128MagicN) != 0) {
            fprintf(stderr, "[%s] bad magic at %zu\n", what, s_.pos);
            return;
        }
        s.readLE(bytes_left);
    }
    bool ok() const { return bytes_left != 0; }
    template<typename T>
    bool consume(T* out, size_t count) {
        for (size_t i = 0; i < count; ++i) {
            std::int32_t v;
            if (!read_leb_value(s, v)) return false;
            out[i] = static_cast<T>(v);
        }
        return true;
    }
};

// FC 레이어. weights = 자연 행렬 [outDim][paddedIn] (행 = 출력 뉴런).
struct LayerWeights {
    std::vector<std::int32_t> biases;
    std::vector<std::int8_t>  weights;
    int inDim, outDim, paddedIn;
};

struct FTWeights {
    std::vector<std::int16_t> biases;        // [HD]
    std::vector<std::int16_t> weights;       // [HD * PSQInputDim], small 는 로드시 x2 스케일
    std::vector<std::int8_t>  threatWeights; // [HD * ThrInputDim], big
    std::vector<std::int32_t> psqtWeights;   // [PSQInputDim * 8]
    std::vector<std::int32_t> threatPsqt;    // [ThrInputDim * 8], big
    int                       hd;
    bool                      useThreats;
};

struct NetFile {
    std::vector<LayerWeights> fc0, fc1, fc2;
    FTWeights                 ft;
};

static bool parse_file(const std::string& path, NetFile& net) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::vector<std::uint8_t> buf((std::istreambuf_iterator<char>(f)),
                                  std::istreambuf_iterator<char>());
    ByteStream s{buf.data(), buf.size()};

    std::uint32_t fileVersion, fileHash, descLen;
    if (!s.readLE(fileVersion) || !s.readLE(fileHash) || !s.readLE(descLen)) return false;
    std::string desc(descLen, '\0');
    if (!s.read(desc.data(), descLen)) return false;

    bool useThreats = (buf.size() > 20'000'000);
    int  HD         = useThreats ? TransformedFeatureDimensionsBig : TransformedFeatureDimensionsSmall;
    net.ft.useThreats = useThreats;
    net.ft.hd         = HD;

    std::uint32_t ftHash = 0;
    if (!s.readLE(ftHash)) return false;

    {
        LebBlock blk(s, "biases");
        net.ft.biases.resize(HD);
        if (!blk.consume(net.ft.biases.data(), HD)) return false;
    }
    if (useThreats) {
        net.ft.threatWeights.resize(size_t(HD) * ThrInputDim);
        if (!s.read(net.ft.threatWeights.data(), net.ft.threatWeights.size())) return false;
    }
    {
        LebBlock blk(s, "ft_weights");
        net.ft.weights.resize(size_t(HD) * PSQInputDim);
        if (!blk.consume(net.ft.weights.data(), net.ft.weights.size())) return false;
    }
    // FC 계층 (dense 레이어도 파일에 PaddedInputDimensions 개 저장, nnue affine_transform.h)
    auto read_layer = [&](LayerWeights& lw, int inDim, int outDim) -> bool {
        lw.inDim = inDim;
        lw.outDim = outDim;
        lw.paddedIn = ceil_to_multiple(inDim, MaxSimdWidth);
        lw.biases.resize(lw.outDim);
        lw.weights.resize(size_t(lw.outDim) * lw.paddedIn);
        if (!s.read(lw.biases.data(), lw.biases.size() * 4)) return false;
        std::vector<std::int8_t> raw(lw.weights.size());
        if (!s.read(raw.data(), raw.size())) return false;
        for (size_t p = 0; p < raw.size(); ++p) lw.weights[p] = raw[p];
        return true;
    };

    // psqt 블록: big = threatPsqt(79856*8) 먼저, small = psqtWeights(22528*8)
    {
        LebBlock blk(s, "psqt");
        if (useThreats) {
            net.ft.threatPsqt.resize(size_t(ThrInputDim) * PSQTBuckets);
            net.ft.psqtWeights.resize(size_t(PSQInputDim) * PSQTBuckets);
            if (!blk.consume(net.ft.threatPsqt.data(), net.ft.threatPsqt.size())) return false;
            if (!blk.consume(net.ft.psqtWeights.data(), net.ft.psqtWeights.size())) return false;
        } else {
            net.ft.psqtWeights.resize(size_t(PSQInputDim) * PSQTBuckets);
            if (!blk.consume(net.ft.psqtWeights.data(), net.ft.psqtWeights.size())) return false;
        }
    }

    for (int i = 0; i < LayerStacks; ++i) {
        std::uint32_t stackHash = 0;
        if (!s.readLE(stackHash)) return false;
        LayerWeights a, b, c;
        if (!read_layer(a, HD, L2 + 1)) return false;
        if (!read_layer(b, L2 * 2, L3)) return false;
        if (!read_layer(c, L3, 1)) return false;
        net.fc0.push_back(std::move(a));
        net.fc1.push_back(std::move(b));
        net.fc2.push_back(std::move(c));
    }

    // small 넷만: read_parameters 의 scale_weights(true) 와 동일하게 FT bias/weight x2
    if (!useThreats) {
        for (auto& b : net.ft.biases) b *= 2;
        for (auto& w : net.ft.weights) w *= 2;
    }
    return s.pos == s.size;
}

// ---------------------------------------------------------------------------
// HalfKAv2_hm (half_ka_v2_hm.h 원본 테이블)
// ---------------------------------------------------------------------------

constexpr int PS_NB = 11 * SQUARE_NB;

// KingBuckets 의 v 값 (/PS_NB). half_ka_v2_hm.h lines 84-93 와 동일.
static constexpr int KB_RAW[SQUARE_NB] = {
    28, 29, 30, 31, 31, 30, 29, 28,  24, 25, 26, 27, 27, 26, 25, 24,
    20, 21, 22, 23, 23, 22, 21, 20,  16, 17, 18, 19, 19, 18, 17, 16,
    12, 13, 14, 15, 15, 14, 13, 12,   8,  9, 10, 11, 11, 10,  9,  8,
     4,  5,  6,  7,  7,  6,  5,  4,   0,  1,  2,  3,  3,  2,  1,  0};

// OrientTBL: SQ_A1=0, SQ_H1=7. a~d 파일 = 7, e~h 파일 = 0 (lines 100-109).
static constexpr int ORT_RAW[SQUARE_NB] = {
    7, 7, 7, 7, 0, 0, 0, 0,  7, 7, 7, 7, 0, 0, 0, 0,  7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,  7, 7, 7, 7, 0, 0, 0, 0,  7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,  7, 7, 7, 7, 0, 0, 0, 0};

// PieceSquareIndex[Color][Piece]: PS_* = {0, 0, 2*64, 4*64, 6*64, 8*64, 10*64, 0,
//                                         0, 1*64, 3*64, 5*64, 7*64, 9*64, 10*64, 0}
// (White 관점: W_KNIGHT=2*64, W_BISHOP=4*64, ..., B_KNIGHT=3*64, ...)
static constexpr int PSI[2][16] = {
    {0, 0, 2 * 64, 4 * 64, 6 * 64, 8 * 64, 10 * 64, 0,
     0, 1 * 64, 3 * 64, 5 * 64, 7 * 64, 9 * 64, 10 * 64, 0},
    {0, 1 * 64, 3 * 64, 5 * 64, 7 * 64, 9 * 64, 10 * 64, 0,
     0, 0, 2 * 64, 4 * 64, 6 * 64, 8 * 64, 10 * 64, 0},
};

static inline int halfka_index(Color perspective, int s, Piece pc, int ksq) {
    const int flip = 56 * perspective;
    return (s ^ ORT_RAW[ksq] ^ flip) + PSI[perspective][pc] + KB_RAW[ksq ^ flip] * PS_NB;
}

// ---------------------------------------------------------------------------
// FullThreats (full_threats.{h,cpp} 재현) — big 전용
// ---------------------------------------------------------------------------

static constexpr int numValidTargets[16] = {0, 6, 12, 10, 10, 12, 8, 0,
                                            0, 6, 12, 10, 10, 12, 8, 0};
static constexpr int FT_MAP[6][6] = {
    {0, 1, -1, 2, -1, -1}, {0, 1, 2, 3, 4, 5}, {0, 1, 2, 3, -1, 4},
    {0, 1, 2, 3, -1, 4},   {0, 1, 2, 3, 4, 5}, {0, 1, 2, 3, -1, -1}};
// full_threats.h OrientTBL: SQ_A1(0) 4개, SQ_H1(7) 4개 (lines 57-66) — 여기는 a~d=0, e~h=7
static constexpr int FT_ORT[SQUARE_NB] = {
    0, 0, 0, 0, 7, 7, 7, 7,  0, 0, 0, 0, 7, 7, 7, 7,  0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,  0, 0, 0, 0, 7, 7, 7, 7,  0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,  0, 0, 0, 0, 7, 7, 7, 7};

static std::array<std::array<std::uint64_t, SQUARE_NB>, 7> PseudoAttacks;
static std::array<std::array<std::uint64_t, SQUARE_NB>, 2> PawnAttacks;

static inline std::uint64_t sq_bb(int s) { return 1ULL << s; }

static std::uint64_t pawn_attacks(bool white, int s) {
    std::uint64_t r = 0;
    if (white) {
        if (file_of(s) > 0 && rank_of(s) < 7) r |= sq_bb(s + 7);
        if (file_of(s) < 7 && rank_of(s) < 7) r |= sq_bb(s + 9);
    } else {
        if (file_of(s) > 0 && rank_of(s) > 0) r |= sq_bb(s - 9);
        if (file_of(s) < 7 && rank_of(s) > 0) r |= sq_bb(s - 7);
    }
    return r;
}

static void init_attacks() {
    static bool done = false;
    if (done) return;
    done = true;
    const int kd[8][2] = {{1, 2}, {2, 1}, {2, -1}, {1, -2}, {-1, -2}, {-2, -1}, {-2, 1}, {-1, 2}};
    const int dirs[8][2] = {{1, 1}, {1, -1}, {-1, 1}, {-1, -1}, {1, 0}, {-1, 0}, {0, 1}, {0, -1}};
    for (int s = 0; s < SQUARE_NB; ++s) {
        PawnAttacks[WHITE][s] = pawn_attacks(true, s);
        PawnAttacks[BLACK][s] = pawn_attacks(false, s);
        std::uint64_t n = 0, k = 0;
        for (auto& d : kd) {
            int f = file_of(s) + d[0], r = rank_of(s) + d[1];
            if (f >= 0 && f < 8 && r >= 0 && r < 8) n |= sq_bb(make_square(f, r));
        }
        for (int df = -1; df <= 1; ++df) for (int dr = -1; dr <= 1; ++dr) {
            if (!df && !dr) continue;
            int f = file_of(s) + df, r = rank_of(s) + dr;
            if (f >= 0 && f < 8 && r >= 0 && r < 8) k |= sq_bb(make_square(f, r));
        }
        std::uint64_t bb = 0, rk = 0;
        for (int di = 0; di < 4; ++di) {
            for (int f = file_of(s) + dirs[di][0], r = rank_of(s) + dirs[di][1];
                 f >= 0 && f < 8 && r >= 0 && r < 8; f += dirs[di][0], r += dirs[di][1])
                bb |= sq_bb(make_square(f, r));
        }
        for (int di = 4; di < 8; ++di) {
            for (int f = file_of(s) + dirs[di][0], r = rank_of(s) + dirs[di][1];
                 f >= 0 && f < 8 && r >= 0 && r < 8; f += dirs[di][0], r += dirs[di][1])
                rk |= sq_bb(make_square(f, r));
        }
        PseudoAttacks[KNIGHT][s] = n;
        PseudoAttacks[BISHOP][s] = bb;
        PseudoAttacks[ROOK][s]   = rk;
        PseudoAttacks[QUEEN][s]  = bb | rk;
        PseudoAttacks[KING][s]   = k;
    }
}

// 슬라이더 실공격 (occupied 에 막힘, 막는 칸 포함)
static std::uint64_t attacks_bb(PieceType pt, int s, std::uint64_t occupied) {
    if (pt == KNIGHT || pt == KING) return PseudoAttacks[pt][s];
    std::uint64_t r = 0;
    const int     dirs[8][2] = {{1, 1}, {1, -1}, {-1, 1}, {-1, -1}, {1, 0}, {-1, 0}, {0, 1}, {0, -1}};
    int           fromDi = 0, toDi = 0;
    if (pt == QUEEN) { fromDi = 0; toDi = 8; }
    else if (pt == BISHOP) { fromDi = 0; toDi = 4; }
    else { fromDi = 4; toDi = 8; }  // ROOK: 직교만
    for (int di = fromDi; di < toDi; ++di) {
        int f = file_of(s) + dirs[di][0], rr = rank_of(s) + dirs[di][1];
        while (f >= 0 && f < 8 && rr >= 0 && rr < 8) {
            std::uint64_t x = sq_bb(make_square(f, rr));
            r |= x;
            if (occupied & x) break;
            f += dirs[di][0]; rr += dirs[di][1];
        }
    }
    return r;
}

struct FTStats {
    std::array<std::array<std::array<std::uint8_t, SQUARE_NB>, SQUARE_NB>, 16> index_lut2;
    std::array<std::array<long, SQUARE_NB>, 16>                                offsets;
    std::array<std::array<long, 2>, 16 * 16>                                   index_lut1;
    std::array<long, 16>                                                       cumulativePiece, cumulative;
};

static std::uint64_t piece_pseudo_attacks(Piece p, int from) {
    PieceType pt = type_of(p);
    if (pt == PAWN) return PawnAttacks[color_of(p)][from];
    return PseudoAttacks[pt][from];
}

static FTStats init_full_threats() {
    FTStats st;
    st.cumulativePiece.fill(0);
    st.cumulative.fill(0);

    // index_lut2: popcount(((1<<to)-1) & attacks)
    for (int p = 0; p < 16; ++p)
        for (int s = 0; s < SQUARE_NB; ++s) {
            std::uint64_t at = piece_pseudo_attacks(Piece(p), s);
            for (int t = 0; t < SQUARE_NB; ++t)
                st.index_lut2[p][s][t] =
                  (std::uint8_t)__builtin_popcountll(((1ULL << t) - 1) & at);
        }

    // offsets: a2..h7 의 폰만 누적 (full_threats.cpp init_threat_offsets 와 동일)
    const Piece AllPieces[12] = {W_PAWN, W_KNIGHT, W_BISHOP, W_ROOK, W_QUEEN, W_KING,
                                 B_PAWN, B_KNIGHT, B_BISHOP, B_ROOK, B_QUEEN, B_KING};
    long cumulativeOffset = 0;
    for (int i = 0; i < 12; ++i) {
        Piece p = AllPieces[i];
        long  cp = 0;
        for (int from = 0; from < SQUARE_NB; ++from) {
            st.offsets[p][from] = cp;
            if (type_of(p) != PAWN || (from >= 8 && from <= 55))  // SQ_A2..SQ_H7
                cp += __builtin_popcountll(piece_pseudo_attacks(p, from));
        }
        st.cumulativePiece[p] = cp;
        st.cumulative[p] = cumulativeOffset;
        cumulativeOffset += numValidTargets[p] * cp;
    }

    // index_lut1 (full_threats.cpp init_index_luts 와 동일)
    for (int i = 0; i < 12; ++i) {
        Piece attacker = AllPieces[i];
        for (int j = 0; j < 12; ++j) {
            Piece    attacked = AllPieces[j];
            bool     enemy    = (attacker ^ attacked) == 8;
            PieceType at = type_of(attacker), ad = type_of(attacked);
            int      map       = FT_MAP[at - 1][ad - 1];
            bool     semi_excl = at == ad && (enemy || at != PAWN);
            long     feature   = st.cumulative[attacker]
                              + (color_of(attacked) * (numValidTargets[attacker] / 2) + map)
                                  * st.cumulativePiece[attacker];
            bool excluded = map < 0;
            long D        = ThrInputDim;
            st.index_lut1[attacker * 16 + attacked][0] = excluded ? D : feature;
            st.index_lut1[attacker * 16 + attacked][1] =
              (excluded || semi_excl) ? D : feature;
        }
    }
    return st;
}

static FTStats g_ft;

static inline long full_threats_index(Color perspective, Piece attacker, int from, int to,
                                      Piece attacked, int ksq) {
    int  orientation   = FT_ORT[ksq] ^ (56 * perspective);
    int  from_oriented = from ^ orientation;
    int  to_oriented   = to ^ orientation;
    int  swap          = 8 * perspective;
    int  attacker_oriented = attacker ^ swap;
    int  attacked_oriented = attacked ^ swap;
    long lut1 = g_ft.index_lut1[attacker_oriented * 16 + attacked_oriented][from_oriented < to_oriented];
    return lut1 + g_ft.offsets[attacker_oriented][from_oriented]
         + g_ft.index_lut2[attacker_oriented][from_oriented][to_oriented];
}

// ---------------------------------------------------------------------------
// 포지션 (FEN 파싱)
// ---------------------------------------------------------------------------

struct Position {
    std::array<Piece, SQUARE_NB> square{};
    std::array<int, 2>           kingSq{ -1, -1 };
    Color                        stm = WHITE;
    int  countPieces() const {
        int c = 0;
        for (auto p : square) if (p != NO_PIECE) ++c;
        return c;
    }
};

static bool parse_fen(const std::string& fen, Position& pos) {
    std::string board;
    size_t      i = 0;
    while (i < fen.size() && fen[i] != ' ') board += fen[i++];
    int sq = SQ_A8;
    for (char ch : board) {
        if (ch == '/') { sq -= 16; continue; }
        if (isdigit(ch)) { sq += (ch - '0'); continue; }
        Piece p = NO_PIECE;
        switch (ch) {
            case 'P': p = W_PAWN; break; case 'N': p = W_KNIGHT; break;
            case 'B': p = W_BISHOP; break; case 'R': p = W_ROOK; break;
            case 'Q': p = W_QUEEN; break; case 'K': p = W_KING; break;
            case 'p': p = B_PAWN; break; case 'n': p = B_KNIGHT; break;
            case 'b': p = B_BISHOP; break; case 'r': p = B_ROOK; break;
            case 'q': p = B_QUEEN; break; case 'k': p = B_KING; break;
            default: return false;
        }
        pos.square[sq] = p;
        if (type_of(p) == KING) pos.kingSq[color_of(p)] = sq;
        ++sq;
    }
    while (i < fen.size() && fen[i] == ' ') ++i;
    if (i < fen.size()) pos.stm = (fen[i] == 'b') ? BLACK : WHITE;
    return true;
}

// ---------------------------------------------------------------------------
// 평가
// ---------------------------------------------------------------------------

struct TraceResult {
    std::array<int, LayerStacks> psqt, positional;
};

static void collect_active(const Position& pos, std::vector<std::vector<int>>& activeP,
                           std::vector<std::vector<int>>& activeT) {
    for (int persp = 0; persp < 2; ++persp) {
        int ksq = pos.kingSq[persp];
        for (int s = 0; s < SQUARE_NB; ++s)
            if (pos.square[s] != NO_PIECE)
                activeP[persp].push_back(halfka_index(Color(persp), s, pos.square[s], ksq));

        // FullThreats::append_active_indices 재현 (full_threats.cpp 221-285)
        std::uint64_t occupied = 0;
        for (int s = 0; s < SQUARE_NB; ++s) if (pos.square[s] != NO_PIECE) occupied |= 1ULL << s;
        for (int color = 0; color < 2; ++color) {
            for (int pti = PAWN; pti <= KING; ++pti) {
                PieceType pt = PieceType(pti);
                Color    c        = Color(persp ^ color);
                Piece    attacker = make_piece(c, pt);
                std::uint64_t bb = 0;
                for (int s = 0; s < SQUARE_NB; ++s)
                    if (pos.square[s] == attacker) bb |= 1ULL << s;
                while (bb) {
                    int  from = __builtin_ctzll(bb);
                    bb &= bb - 1;
                    std::uint64_t at;
                    if (pt == PAWN)
                        at = PawnAttacks[c][from] & occupied;      // 실제 캡처만
                    else
                        at = attacks_bb(pt, from, occupied) & occupied;
                    while (at) {
                        int  to      = __builtin_ctzll(at);
                        at &= at - 1;
                        Piece attacked = pos.square[to];
                        long  index    = full_threats_index(Color(persp), attacker, from, to,
                                                            attacked, ksq);
                        if (index < ThrInputDim) {
                            activeT[persp].push_back((int)index);
                            if (getenv("REF_DEBUG"))
                                fprintf(stderr, "THR2 %d %d %d %d %d %d\n", persp, (int)attacker,
                                        from, to, (int)attacked, (int)index);
                        }
                    }
                }
            }
        }
    }
}

static TraceResult evaluate(const NetFile& net, const Position& pos) {
    const FTWeights& ft = net.ft;
    const int        HD = ft.hd;
    const bool       big = ft.useThreats;

    std::vector<std::vector<int>> activeP(2), activeT(2);
    collect_active(pos, activeP, activeT);

    // 어큐뮬레이터 (bias 는 main 만; threat 는 0 초기화)
    std::array<std::vector<std::int64_t>, 2> acc, thrAcc;
    std::array<std::vector<std::int64_t>, 2> psqtAcc, thrPsqt;
    for (int p = 0; p < 2; ++p) {
        acc[p].assign(HD, 0);
        thrAcc[p].assign(HD, 0);
        psqtAcc[p].assign(PSQTBuckets, 0);
        thrPsqt[p].assign(PSQTBuckets, 0);
        for (int j = 0; j < HD; ++j) acc[p][j] = ft.biases[j];
        for (int f : activeP[p]) {
            for (int j = 0; j < HD; ++j) acc[p][j] += ft.weights[size_t(f) * HD + j];
            for (int b = 0; b < PSQTBuckets; ++b) psqtAcc[p][b] += ft.psqtWeights[size_t(f) * 8 + b];
        }
        if (big) {
            for (int f : activeT[p]) {
                for (int j = 0; j < HD; ++j) thrAcc[p][j] += ft.threatWeights[size_t(f) * HD + j];
                for (int b = 0; b < PSQTBuckets; ++b)
                    thrPsqt[p][b] += ft.threatPsqt[size_t(f) * 8 + b];
            }
        }
    }

    // transform(): psqt + quantize (#else 스칼라 경로, /512 는 양쪽 동일)
    TraceResult out{};
    std::vector<std::int32_t> q(HD);   // q[(HD/2)*p + j] = perspective p 의 출력
    const bool dbg = getenv("REF_DEBUG") != nullptr;
    if (dbg) {
        fprintf(stderr, "activeP[0]:"); for (auto f : activeP[0]) fprintf(stderr, " %d", f); fprintf(stderr, "\n");
        fprintf(stderr, "activeP[1]:"); for (auto f : activeP[1]) fprintf(stderr, " %d", f); fprintf(stderr, "\n");
        fprintf(stderr, "activeT[0]:"); for (auto f : activeT[0]) fprintf(stderr, " %d", f); fprintf(stderr, "\n");
        fprintf(stderr, "activeT[1]:"); for (auto f : activeT[1]) fprintf(stderr, " %d", f); fprintf(stderr, "\n");
        fprintf(stderr, "psqtAcc[0][0]=%lld psqtAcc[1][0]=%lld\n", (long long)psqtAcc[0][0], (long long)psqtAcc[1][0]);
    }
    for (int bucket = 0; bucket < LayerStacks; ++bucket) {
        std::int64_t psqt = psqtAcc[pos.stm][bucket] - psqtAcc[pos.stm ^ 1][bucket];
        if (big)
            psqt = (psqt + thrPsqt[pos.stm][bucket] - thrPsqt[pos.stm ^ 1][bucket]) / 2;
        else
            psqt /= 2;
        out.psqt[bucket] = (int)psqt;
        if (dbg) fprintf(stderr, "bucket=%d psqtAcc stm=%d:opp=%d (%lld,%lld) out=%d\n",
                         bucket, pos.stm, pos.stm ^ 1,
                         (long long)psqtAcc[pos.stm][bucket], (long long)psqtAcc[pos.stm ^ 1][bucket],
                         out.psqt[bucket]);

        for (int p = 0; p < 2; ++p) {
            const int persp   = (p == 0) ? pos.stm : pos.stm ^ 1;  // SF perspectives = {stm, ~stm}
            const int off     = (HD / 2) * p;
            for (int j = 0; j < HD / 2; ++j) {
                std::int64_t s0 = acc[persp][j], s1 = acc[persp][j + HD / 2];
                if (big) {
                    s0 = std::clamp<std::int64_t>(s0 + thrAcc[persp][j], 0, 255);
                    s1 = std::clamp<std::int64_t>(s1 + thrAcc[persp][j + HD / 2], 0, 255);
                } else {
                    s0 = std::clamp<std::int64_t>(s0, 0, 127 * 2);
                    s1 = std::clamp<std::int64_t>(s1, 0, 127 * 2);
                }
                q[off + j] = (std::int32_t)((s0 * s1) / 512);
            }
        }
        if (bucket == 0) {
            if (dbg) {
                fprintf(stderr, "FTDMP %d", HD);
                for (int i = 0; i < HD; ++i) fprintf(stderr, " %d", q[i]);
                fprintf(stderr, "\n");
            }
            if (const char* fd = getenv("FTDMPD")) {
                FILE* f = fopen(fd, "w");
                if (f) {
                    fprintf(f, "FTDMP %d", HD);
                    for (int i = 0; i < HD; ++i) fprintf(f, " %d", q[i]);
                    fprintf(f, "\n");
                    fclose(f);
                }
            }
            if (const char* fn = getenv("FTDMPN")) {
                FILE* f = fopen(fn, "w");
                if (f) {
                    fprintf(f, "FTDMP %d", HD);
                    for (int p = 0; p < 2; ++p) {
                        const int persp = (p == 0) ? pos.stm : pos.stm ^ 1;
                        const int off   = (HD / 2) * p;
                        for (int j = 0; j < HD / 2; ++j)
                            fprintf(f, " %d",
                                    (int)(((long long)std::clamp<std::int64_t>(acc[persp][j], 0, 255)
                                            * std::clamp<std::int64_t>(acc[persp][j + HD / 2], 0, 255)) >> 9));
                    }
                    fprintf(f, "\n");
                    fclose(f);
                }
            }
            if (const char* an = getenv("ACCDBG")) {
                FILE* f = fopen(an, "w");
                if (f) {
                    for (int p = 0; p < 2; ++p) {
                        const int persp = (p == 0) ? pos.stm : pos.stm ^ 1;
                        fprintf(f, "ACC %d", persp);
                        for (int j = 0; j < HD; ++j) fprintf(f, " %lld", (long long)acc[persp][j]);
                        fprintf(f, " THR");
                        for (int j = 0; j < HD; ++j) fprintf(f, " %lld", (long long)thrAcc[persp][j]);
                        fprintf(f, "\n");
                    }
                    fclose(f);
                }
            }
        }

        // fc_0 (자연 행렬, 희소 입력과 동일 결과)
        const LayerWeights& f0 = net.fc0[bucket];
        std::array<std::int32_t, 16> fc0_out{};
        for (int j = 0; j < f0.outDim; ++j) {
            std::int64_t v = f0.biases[j];
            for (int i = 0; i < f0.paddedIn; ++i)
                v += (std::int64_t)q[i] * f0.weights[size_t(j) * f0.paddedIn + i];
            fc0_out[j] = (std::int32_t)v;
        }

        // ac_sqr_0(<<19) + ac_0(>>6), fc_1 (nnue_architecture.h propagate 순서)
        std::array<std::uint8_t, 32> ac_sqr_0{}, ac_1{};
        std::array<std::uint8_t, 16> ac_0{};
        for (int i = 0; i < 16; ++i) {
            ac_sqr_0[i] = (std::uint8_t)std::min(127ll, ((long long)fc0_out[i] * fc0_out[i]) >> (2 * WeightScaleBits + 7));
            ac_0[i]     = (std::uint8_t)std::clamp(fc0_out[i] >> WeightScaleBits, 0, 127);
        }
        for (int i = 0; i < L2; ++i) ac_sqr_0[L2 + i] = ac_0[i];

        const LayerWeights& f1 = net.fc1[bucket];
        std::array<std::int32_t, 32> fc1_out{};
        for (int j = 0; j < f1.outDim; ++j) {
            std::int64_t v = f1.biases[j];
            for (int i = 0; i < f1.paddedIn; ++i)
                v += (std::int64_t)ac_sqr_0[i] * f1.weights[size_t(j) * f1.paddedIn + i];
            fc1_out[j] = (std::int32_t)v;
        }
        for (int i = 0; i < 32; ++i)
            ac_1[i] = (std::uint8_t)std::clamp(fc1_out[i] >> WeightScaleBits, 0, 127);

        const LayerWeights& f2 = net.fc2[bucket];
        std::int64_t v2 = f2.biases[0];
        for (int i = 0; i < f2.paddedIn; ++i)
            v2 += (std::int64_t)ac_1[i] * f2.weights[size_t(0) * f2.paddedIn + i];

        std::int32_t fwdOut = fc0_out[L2] * (600 * OutputScale) / (127 * (1 << WeightScaleBits));
        out.positional[bucket] = (int)(v2 + fwdOut);
        if (const char* fdmp = getenv("FCDUMP")) {
            FILE* f = (bucket == 0) ? fopen(fdmp, "w") : fopen(fdmp, "a");
            if (f) {
                fprintf(f, "B %d", bucket);
                fprintf(f, " FC0RAW"); for (int i = 0; i < 16; ++i) fprintf(f, " %d", (int)fc0_out[i]);
                fprintf(f, " FC1IN"); for (int i = 0; i < 30; ++i) fprintf(f, " %d", (int)ac_sqr_0[i]);
                fprintf(f, " FC1RAW"); for (int i = 0; i < 32; ++i) fprintf(f, " %d", (int)fc1_out[i]);
                fprintf(f, " FC1ACT"); for (int i = 0; i < 32; ++i) fprintf(f, " %d", (int)ac_1[i]);
                fprintf(f, " FC2RAW %d FWDOUT %d POS %d\n", (int)v2, (int)fwdOut, out.positional[bucket]);
                fclose(f);
            }
        }
        if (dbg && bucket == 0) {
            fprintf(stderr, "FC0RAW"); for (int i = 0; i < 16; ++i) fprintf(stderr, " %d", (int)fc0_out[i]);
            fprintf(stderr, " FC1IN"); for (int i = 0; i < 30; ++i) fprintf(stderr, " %d", (int)ac_sqr_0[i]);
            fprintf(stderr, " FC1RAW"); for (int i = 0; i < 32; ++i) fprintf(stderr, " %d", (int)fc1_out[i]);
            fprintf(stderr, " FC1ACT"); for (int i = 0; i < 32; ++i) fprintf(stderr, " %d", (int)ac_1[i]);
            fprintf(stderr, " FC2RAW %d FWDOUT %d\n", (int)v2, (int)fwdOut);
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <net.nnue> \"<FEN>\"\n", argv[0]);
        return 1;
    }

    // FTBIN: FT bias+weights 바이너리 덤프 후 종료 (RTL weight_bram 로딩용)
    //   small layout: [biases(HD) int16][weights(HD*PSQInputDim) int16] (x2 스케일 반영)
    //   big   layout: [biases(HD) int16][weights(HD*PSQInputDim) int16]
    //                 [threatWeights(HD*ThrInputDim) int16] (int8 원본 부호확장)
    if (const char* fb = getenv("FTBIN")) {
        NetFile nd;
        if (!parse_file(argv[1], nd)) return 1;
        FILE* f = fopen(fb, "wb");
        if (!f) { perror(fb); return 1; }
        const FTWeights& ft = nd.ft;
        fwrite(ft.biases.data(), sizeof(int16_t), ft.hd, f);
        fwrite(ft.weights.data(), sizeof(int16_t), ft.weights.size(), f);
        long tw = 0;
        if (ft.useThreats) {
            tw = (long)ft.threatWeights.size();
            for (std::int8_t v : ft.threatWeights) {
                std::int16_t s = v;
                fwrite(&s, sizeof(int16_t), 1, f);
            }
        }
        fclose(f);
        fprintf(stderr, "FTBIN %s: hd=%d psq=%zu thr=%ld\n", fb, ft.hd,
                ft.weights.size() / ft.hd, tw);
        return 0;
    }

    // FCBIN: FC 가중치 바이너리 덤프 후 종료 (RTL FC 파이프라인 로딩용)
    //   8 bucket 연속. 각 bucket:
    //     fc0: bias[16] int32, weights[16*paddedIn] int8
    //     fc1: bias[32] int32, weights[32*32] int8   (입력 30 -> padded 32)
    //     fc2: bias[1]  int32, weights[1*32]  int8   (입력 32 -> padded 32)
    //   weights 파일 저장은 이미 paddedIn 반영 (read_layer 참조).
    if (const char* cb = getenv("FCBIN")) {
        NetFile nd;
        if (!parse_file(argv[1], nd)) return 1;
        FILE* f = fopen(cb, "wb");
        if (!f) { perror(cb); return 1; }
        for (int b = 0; b < LayerStacks; ++b) {
            const LayerWeights& f0 = nd.fc0[b];
            const LayerWeights& f1 = nd.fc1[b];
            const LayerWeights& f2 = nd.fc2[b];
            fwrite(f0.biases.data(), 4, f0.outDim, f);
            fwrite(f0.weights.data(), 1, f0.weights.size(), f);
            fwrite(f1.biases.data(), 4, f1.outDim, f);
            fwrite(f1.weights.data(), 1, f1.weights.size(), f);
            fwrite(f2.biases.data(), 4, f2.outDim, f);
            fwrite(f2.weights.data(), 1, f2.weights.size(), f);
        }
        fclose(f);
        const LayerWeights& f0 = nd.fc0[0];
        fprintf(stderr, "FCBIN %s: fc0[%dx%d] fc1[%dx%d] fc2[%dx%d] x%d\n", cb,
                f0.outDim, f0.paddedIn, nd.fc1[0].outDim, nd.fc1[0].paddedIn,
                nd.fc2[0].outDim, nd.fc2[0].paddedIn, LayerStacks);
        return 0;
    }

    // PSQTBIN: psqt 가중치 바이너리 덤프 후 종료 (RTL psqt_bram 로딩용)
    //   layout: [psqtWeights(PSQInputDim*8) int32][threatPsqt(ThrInputDim*8) int32]
    //   (main 먼저; 원본 nnue 파일은 big 의 경우 threat 가 먼저 나옴 — 재구성)
    if (const char* pb = getenv("PSQTBIN")) {
        NetFile nd;
        if (!parse_file(argv[1], nd)) return 1;
        FILE* f = fopen(pb, "wb");
        if (!f) { perror(pb); return 1; }
        const FTWeights& ft = nd.ft;
        fwrite(ft.psqtWeights.data(), sizeof(int32_t), ft.psqtWeights.size(), f);
        long tw = 0;
        if (ft.useThreats) {
            tw = (long)ft.threatPsqt.size();
            fwrite(ft.threatPsqt.data(), sizeof(int32_t), ft.threatPsqt.size(), f);
        }
        fclose(f);
        fprintf(stderr, "PSQTBIN %s: main=%zu thr=%ld\n", pb,
                ft.psqtWeights.size() / PSQTBuckets, tw);
        return 0;
    }

    // FEATLIST: active feature 리스트 덤프 후 종료 (RTL feature 스트림 생성용)
    //   출력: FTLIST <cnt0> <cnt1> <feat0...> <feat1...>
    if (const char* fl = getenv("FEATLIST")) {
        NetFile nd;
        if (!parse_file(argv[1], nd)) return 1;
        init_attacks();
        g_ft = init_full_threats();
        Position pp;
        if (!parse_fen(argv[2], pp)) return 1;
        std::vector<std::vector<int>> ap(2), at(2);
        collect_active(pp, ap, at);
        FILE* f = fopen(fl, "w");
        if (!f) { perror(fl); return 1; }
        fprintf(f, "FTLIST %zu %zu", ap[0].size(), ap[1].size());
        for (auto v : ap[0]) fprintf(f, " %d", v);
        for (auto v : ap[1]) fprintf(f, " %d", v);
        fprintf(f, "\n");
        fclose(f);
        return 0;
    }

    NetFile net;
    if (!parse_file(argv[1], net)) {
        fprintf(stderr, "parse failed: %s\n", argv[1]);
        return 1;
    }
    init_attacks();
    g_ft = init_full_threats();

    Position pos;
    if (!parse_fen(argv[2], pos)) {
        fprintf(stderr, "bad FEN: %s\n", argv[2]);
        return 1;
    }

    int bucket = (pos.countPieces() - 1) / 4;
    if (getenv("REF_DEBUG")) {
        int idxW1 = (1 ^ 7) + PSI[WHITE][W_KING] + KB_RAW[1] * PS_NB;
        int idxW2 = (56 ^ 7) + PSI[WHITE][B_KING] + KB_RAW[1] * PS_NB;
        int idxB1 = (1 ^ 7 ^ 56) + PSI[BLACK][W_KING] + KB_RAW[0] * PS_NB;
        int idxB2 = (56 ^ 7 ^ 56) + PSI[BLACK][B_KING] + KB_RAW[0] * PS_NB;
        fprintf(stderr, "W=%d,%d B=%d,%d\n", idxW1, idxW2, idxB1, idxB2);
        const auto& p = net.ft.psqtWeights;
        int wf = p[idxW1 * 8 + 0] + p[idxW2 * 8 + 0], bf = p[idxB1 * 8 + 0] + p[idxB2 * 8 + 0];
        int wm = p[0 * PSQInputDim + idxW1] + p[0 * PSQInputDim + idxW2];
        int bm = p[0 * PSQInputDim + idxB1] + p[0 * PSQInputDim + idxB2];
        fprintf(stderr, "[f][8]: (W-B)/2=%d  [8][f]: (W-B)/2=%d  SF=7\n", (wf - bf) / 2, (wm - bm) / 2);
    }
    auto r = evaluate(net, pos);
    if (const char* rd = getenv("RESDUMP")) {
        FILE* f = fopen(rd, "w");
        if (f) {
            for (int b = 0; b < LayerStacks; ++b)
                fprintf(f, "RESDUMP %d %d %d\n", b, r.psqt[b], r.positional[b]);
            fclose(f);
        }
    }
    for (int b = 0; b < LayerStacks; ++b)
        printf("RAWVERIFY %d %d %d\n", b, r.psqt[b] / OutputScale, r.positional[b] / OutputScale);
    printf("BUCKET %d\n", bucket);
    return 0;
}