// Arithmetic unit test: compares nnue_math_pkg with the C++ expressions from sf_19.
// Small domains are exhaustive; 32/64-bit domains use a dense window, boundaries and random.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "Vnnue_math_unit.h"

namespace {
Vnnue_math_unit* dut;
uint64_t         checks = 0;

void fail(const char* what, long long input, long long got, long long want) {
    std::printf("FAIL %s input=%lld got=%lld want=%lld\n", what, input, got, want);
    std::exit(1);
}

#define CHECK(name, input, got, want)                                \
    do {                                                             \
        ++checks;                                                    \
        if ((long long) (got) != (long long) (want))                 \
            fail(name, (long long) (input), (long long) (got), (long long) (want)); \
    } while (0)

void check_i32(int32_t x) {
    dut->i32_in = uint32_t(x);
    dut->eval();
    const long long sq = (long long) x * x;
    CHECK("clip7", x, dut->clip7_out, std::clamp(x >> 7, 0, 127));
    CHECK("clip6", x, dut->clip6_out, std::clamp(x >> 6, 0, 127));
    CHECK("sqr7", x, dut->sqr7_out, std::min(127ll, sq >> (2 * 7 + 7)));
    CHECK("sqr6", x, dut->sqr6_out, std::min(127ll, sq >> (2 * 6 + 7)));
    CHECK("div2", x, int32_t(dut->div2_out), x / 2);
    CHECK("div16", x, int32_t(dut->div16_out), x / 16);
}

void check_i64(int64_t x) {
    dut->i64_in = uint64_t(x);
    dut->eval();
    CHECK("div16384", x, int64_t(dut->div16384_out), x / 16384);
}
}  // namespace

int main() {
    dut = new Vnnue_math_unit;

    for (int x = -32768; x <= 32767; ++x)
    {
        dut->i16_in = uint16_t(int16_t(x));
        dut->eval();
        CHECK("ft_clamp", x, dut->clamp_out, std::clamp(x, 0, 255));
    }
    for (int a = 0; a < 256; ++a)
        for (int b = 0; b < 256; ++b)
        {
            dut->a = uint8_t(a);
            dut->b = uint8_t(b);
            dut->eval();
            CHECK("ft_product", a * 256 + b, dut->product_out, unsigned(a * b) / 512);
        }

    for (int x = -300000; x <= 300000; ++x)
        check_i32(x);
    const int32_t edges[] = {INT32_MIN, INT32_MIN + 1, INT32_MAX, INT32_MAX - 1, 65535, 65536, 65537,
                             -65535, -65536, -65537, 32767, 32768, -32768, -32769, 46340, 46341};
    for (int32_t e : edges)
        check_i32(e);

    uint64_t s = 0x123456789ABCDEFull;
    auto     next = [&] {
        s ^= s >> 12;
        s ^= s << 25;
        s ^= s >> 27;
        return s * 0x2545F4914F6CDD1Dull;
    };
    for (int i = 0; i < 5000000; ++i)
        check_i32(int32_t(next()));

    for (int64_t x = -200000; x <= 200000; ++x)
        check_i64(x);
    // The positional product is a 32-bit value times 9600, so 46 bits bound the real domain.
    for (int i = 0; i < 5000000; ++i)
        check_i64(int64_t(next()) >> 18);

    std::printf("PASS arithmetic checks=%llu mismatches=0\n", (unsigned long long) checks);
    delete dut;
    return 0;
}
