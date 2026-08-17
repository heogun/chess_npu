// idx_check.cc - SF 실제 헤더로 HalfKA/FullThreats makes_index 계산 (ground truth)
#include <cstdio>
#include "nnue/features/half_ka_v2_hm.h"
#include "nnue/features/full_threats.h"
using namespace Stockfish;
using namespace Stockfish::Eval::NNUE::Features;

int main() {
    // k7/8/8/8/8/8/8/1K6 w : W K b1(1), B K a8(56)
    printf("make_index(WHITE, b1, W_KING, b1) = %u\n",
           unsigned(HalfKAv2_hm::make_index(WHITE, SQ_B1, W_KING, SQ_B1)));
    printf("make_index(BLACK, a8, B_KING, a8) = %u\n",
           unsigned(HalfKAv2_hm::make_index(BLACK, SQ_A8, B_KING, SQ_A8)));
    // startpos 예: a1 룩 (백 persp), e1 킹
    printf("make_index(WHITE, a1, W_ROOK, e1) = %u\n",
           unsigned(HalfKAv2_hm::make_index(WHITE, SQ_A1, W_ROOK, SQ_E1)));
    printf("make_index(BLACK, a8, B_ROOK, e8) = %u\n",
           unsigned(HalfKAv2_hm::make_index(BLACK, SQ_A8, B_ROOK, SQ_E8)));
    printf("FullThreats Dimensions = %u\n", unsigned(FullThreats::Dimensions));
    printf("HalfKA Dimensions = %u\n", unsigned(HalfKAv2_hm::Dimensions));
    return 0;
}