// featgen.cc - FEN -> active feature 리스트 생성기 (ARM HPS 온보드용)
//
// ref_eval.cc 의 collect_active() 와 정확히 동일한 인덱스 산출 로직을 standalone
// 제공. M4 이후 ARM 이 FEN/보드 상태에서 FTE 가 소비할 feature 스트림을 만든다.
//
//   사용: ./featgen <net.nnue> "<FEN>"
//   출력(파일 + stdout): FTLIST <cnt0> <cnt1> <feat0...> <feat1...>
//                        (big 넷이면 추가) THREATLIST <cntT0> <cntT1> <thr0...> <thr1...>
//   net 파일은 big/small 검출에만 사용 (크기 > 20MB => big).
//
// 빌드: g++ -O2 -std=c++17 -o featgen featgen.cc

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

enum Color : int { WHITE = 0, BLACK = 1 };
enum PieceType : int { NO_PIECE_TYPE = 0, PAWN = 1, KNIGHT, BISHOP, ROOK, QUEEN, KING,
                       PIECE_TYPE_NB = 8, PIECE_TYPE_NB2 = 6 };
enum Piece : int { NO_PIECE = 0, W_PAWN = 1, W_KNIGHT, W_BISHOP, W_ROOK, W_QUEEN, W_KING,
                   B_PAWN = 9, B_KNIGHT, B_BISHOP, B_ROOK, B_QUEEN, B_KING, PIECE_NB = 16 };

constexpr int SQUARE_NB = 64;
constexpr int SQ_A8 = 56;
constexpr int PSQTBuckets = 8;
constexpr int PSQInputDim = 22528;
constexpr int ThrInputDim = 79856;
constexpr int TransformedFeatureDimensionsBig = 1024;

static inline int file_of(int s) { return s & 7; }
static inline int rank_of(int s) { return s >> 3; }
static constexpr int make_square(int f, int r) { return r * 8 + f; }
static constexpr Piece make_piece(Color c, PieceType pt) { return Piece(pt + 8 * c); }
static constexpr PieceType type_of(Piece p) { return PieceType(p & 7); }
static constexpr Color color_of(Piece p) { return Color(p >> 3); }

static constexpr int PS_NB = 11 * SQUARE_NB;

static constexpr int KB_RAW[SQUARE_NB] = {
    28, 29, 30, 31, 31, 30, 29, 28,  24, 25, 26, 27, 27, 26, 25, 24,
    20, 21, 22, 23, 23, 22, 21, 20,  16, 17, 18, 19, 19, 18, 17, 16,
    12, 13, 14, 15, 15, 14, 13, 12,   8,  9, 10, 11, 11, 10,  9,  8,
     4,  5,  6,  7,  7,  6,  5,  4,   0,  1,  2,  3,  3,  2,  1,  0};

static constexpr int ORT_RAW[SQUARE_NB] = {
    7, 7, 7, 7, 0, 0, 0, 0,  7, 7, 7, 7, 0, 0, 0, 0,  7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,  7, 7, 7, 7, 0, 0, 0, 0,  7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,  7, 7, 7, 7, 0, 0, 0, 0};

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

static constexpr int numValidTargets[16] = {0, 6, 12, 10, 10, 12, 8, 0,
                                            0, 6, 12, 10, 10, 12, 8, 0};
static constexpr int FT_MAP[6][6] = {
    {0, 1, -1, 2, -1, -1}, {0, 1, 2, 3, 4, 5}, {0, 1, 2, 3, -1, 4},
    {0, 1, 2, 3, -1, 4},   {0, 1, 2, 3, 4, 5}, {0, 1, 2, 3, -1, -1}};
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

static std::uint64_t attacks_bb(PieceType pt, int s, std::uint64_t occupied) {
    if (pt == KNIGHT || pt == KING) return PseudoAttacks[pt][s];
    std::uint64_t r = 0;
    const int     dirs[8][2] = {{1, 1}, {1, -1}, {-1, 1}, {-1, -1}, {1, 0}, {-1, 0}, {0, 1}, {0, -1}};
    int           fromDi = 0, toDi = 0;
    if (pt == QUEEN) { fromDi = 0; toDi = 8; }
    else if (pt == BISHOP) { fromDi = 0; toDi = 4; }
    else { fromDi = 4; toDi = 8; }
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

    for (int p = 0; p < 16; ++p)
        for (int s = 0; s < SQUARE_NB; ++s) {
            std::uint64_t at = piece_pseudo_attacks(Piece(p), s);
            for (int t = 0; t < SQUARE_NB; ++t)
                st.index_lut2[p][s][t] =
                  (std::uint8_t)__builtin_popcountll(((1ULL << t) - 1) & at);
        }

    const Piece AllPieces[12] = {W_PAWN, W_KNIGHT, W_BISHOP, W_ROOK, W_QUEEN, W_KING,
                                 B_PAWN, B_KNIGHT, B_BISHOP, B_ROOK, B_QUEEN, B_KING};
    long cumulativeOffset = 0;
    for (int i = 0; i < 12; ++i) {
        Piece p = AllPieces[i];
        long  cp = 0;
        for (int from = 0; from < SQUARE_NB; ++from) {
            st.offsets[p][from] = cp;
            if (type_of(p) != PAWN || (from >= 8 && from <= 55))
                cp += __builtin_popcountll(piece_pseudo_attacks(p, from));
        }
        st.cumulativePiece[p] = cp;
        st.cumulative[p] = cumulativeOffset;
        cumulativeOffset += numValidTargets[p] * cp;
    }

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

struct Position {
    std::array<Piece, SQUARE_NB> square{};
    std::array<int, 2>           kingSq{ -1, -1 };
    Color                        stm = WHITE;
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

static void collect_active(const Position& pos, std::vector<std::vector<int>>& activeP,
                           std::vector<std::vector<int>>& activeT) {
    for (int persp = 0; persp < 2; ++persp) {
        int ksq = pos.kingSq[persp];
        for (int s = 0; s < SQUARE_NB; ++s)
            if (pos.square[s] != NO_PIECE)
                activeP[persp].push_back(halfka_index(Color(persp), s, pos.square[s], ksq));

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
                        at = PawnAttacks[c][from] & occupied;
                    else
                        at = attacks_bb(pt, from, occupied) & occupied;
                    while (at) {
                        int  to      = __builtin_ctzll(at);
                        at &= at - 1;
                        Piece attacked = pos.square[to];
                        long  index    = full_threats_index(Color(persp), attacker, from, to,
                                                            attacked, ksq);
                        if (index < ThrInputDim)
                            activeT[persp].push_back((int)index);
                    }
                }
            }
        }
    }
}

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <net.nnue> \"<FEN>\" [out.txt]\n", argv[0]);
        return 1;
    }
    std::ifstream f(argv[1], std::ios::binary);
    if (!f) { fprintf(stderr, "open fail: %s\n", argv[1]); return 1; }
    f.seekg(0, std::ios::end);
    std::streamoff sz = f.tellg();
    f.close();
    bool big = (sz > 20'000'000);

    Position pos;
    if (!parse_fen(argv[2], pos)) { fprintf(stderr, "bad FEN\n"); return 1; }

    init_attacks();
    if (big) g_ft = init_full_threats();

    std::vector<std::vector<int>> ap(2), at(2);
    collect_active(pos, ap, at);

    FILE* out = stdout;
    FILE* fp  = nullptr;
    if (argc >= 4) {
        fp = fopen(argv[3], "w");
        if (!fp) { perror(argv[3]); return 1; }
        out = fp;
    }

    fprintf(out, "FTLIST %zu %zu", ap[0].size(), ap[1].size());
    for (auto v : ap[0]) fprintf(out, " %d", v);
    for (auto v : ap[1]) fprintf(out, " %d", v);
    fprintf(out, "\n");
    if (big) {
        fprintf(out, "THREATLIST %zu %zu", at[0].size(), at[1].size());
        for (auto v : at[0]) fprintf(out, " %d", v);
        for (auto v : at[1]) fprintf(out, " %d", v);
        fprintf(out, "\n");
    }
    fprintf(stderr, "big=%d n0=%zu n1=%zu%s\n", big, ap[0].size(), ap[1].size(),
            big ? " (with threats)" : "");
    if (fp) fclose(fp);
    return 0;
}