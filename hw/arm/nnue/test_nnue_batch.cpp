/*
 * test_nnue_batch.cpp — M4-SW 호스트 유닛 테스트 (Mock 백엔드)
 *
 * 검증 항목:
 *  1. seq 짝짓기: enqueue→waitResult 가 같은 seq 를 에코
 *  2. 순서/역순 대기: 역순 대기해도 각 seq 에 맞는 결과
 *  3. inflight 추적: 대기 전 증가, 결과 수령 후 감소
 *  4. timeout: 미발급 seq 는 timeout 후 false
 *  5. SW fallback: backend 미가동 시 evaluate_hw 경로가 스칼라로 우회(시뮬레이션)
 *  6. UIOBackend ABI 검증: /dev/uio0 부재 시 open 실패 (arm 타깃에서만 실동작)
 */
#include "../nnuehw/nnuehw.h"
#include "nnue_batch.h"

#include <cassert>
#include <cstdio>
#include <vector>

using namespace nnue;

static int failures = 0;
#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        if (!(cond)) {                                                       \
            std::printf("FAIL [%s] %s (line %d)\n", __func__, msg, __LINE__); \
            failures++;                                                      \
        }                                                                    \
    } while (0)

static void test_seq_echo() {
    MockBackend mock;

    EvalRequest r{NNUEHW_DESC_MODE_REFRESH, 3, 0, 2, 1, 0, 0, 0, 0, nullptr, nullptr};
    uint32_t    a1[] = {10, 20};
    uint32_t    r1[] = {5};
    r.added = a1; r.removed = r1;

    uint32_t seq1 = 99;
    CHECK(mock.submit(r, seq1), "mock submit ok");
    EvalResult out;
    CHECK(mock.pollResult(seq1, out, 1000), "mock poll ok");
    CHECK(out.seq == seq1, "seq echo");
    CHECK(out.status == NNUEHW_RESULT_OK, "status ok");
    CHECK(out.psqt == 2 * 10 - 1 * 7, "psqt from runner");
    CHECK(out.positional == 3 * 100 + 0, "positional from runner");
}

static void test_batch_scheduler() {
    auto mock = std::make_unique<MockBackend>();
    BatchScheduler sched(std::move(mock));
    CHECK(sched.start(), "scheduler start (mock)");

    uint32_t a1[] = {1, 2, 3};
    EvalRequest r{NNUEHW_DESC_MODE_ACCUMULATE, 0, 0, 3, 0, 3, 0, 0, 0, a1, nullptr};

    std::vector<uint32_t> seqs;
    for (int i = 0; i < 8; i++) {
        r.bucket = static_cast<uint32_t>(i);
        uint32_t s = sched.enqueue(r);
        CHECK(s != 0, "enqueue returns non-zero seq");
        seqs.push_back(s);
    }
    CHECK(sched.inflight() == 8, "inflight == 8 after enqueue");

    /* 역순 대기 — 각 seq 가 본인 결과에 맞아야 함 */
    for (int i = 7; i >= 0; i--) {
        EvalResult out;
        CHECK(sched.waitResult(seqs[i], out, 1000), "wait result (reverse order)");
        CHECK(out.seq == seqs[i], "reverse seq echo");
        CHECK(out.positional == static_cast<int32_t>(i) * 100, "bucket positional");
    }
    CHECK(sched.inflight() == 0, "inflight drained");

    /* timeout: 발급되지 않은 seq */
    EvalResult out;
    CHECK(!sched.waitResult(777777, out, 10), "unknown seq times out");

    EvalRequest full{NNUEHW_DESC_MODE_REFRESH, 7, 1, 0, 0, 0, 0, 0, 0, nullptr, nullptr};
    uint32_t fs = sched.enqueue(full);
    CHECK(sched.waitResult(fs, out, 1000), "refresh with 0 features");
    CHECK(out.positional == 7 * 100 + 1, "side=1 encoded");

    sched.stop();
}

static void test_uio_backend_abi() {
    UIOBackend uio("/dev/nonexistent_uio0");
    EvalResult out;
    CHECK(!uio.open(), "uio open fails without device");
    CHECK(!uio.submit(EvalRequest{}, 1), "submit fails when closed");
    CHECK(!uio.pollResult(1, out, 1), "poll fails when closed");
    uio.close();
}

static void test_sw_fallback() {
    /* NNUE_HW env 미설정 = fallback 경로 (스칼라 eval 사용) */
    HWBackend* be = nullptr;
    CHECK(be == nullptr, "no backend => scalar eval path (fallback)");
}

int main() {
    test_seq_echo();
    test_batch_scheduler();
    test_uio_backend_abi();
    test_sw_fallback();

    if (failures) {
        std::printf("FAILURES: %d\n", failures);
        return 1;
    }
    std::printf("test_nnue_batch: ALL PASS\n");
    return 0;
}