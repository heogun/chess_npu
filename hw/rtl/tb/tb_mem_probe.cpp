// Simulation test of mem_probe against a memory model with random stalls and read latency.
// Checks run counts, latency accounting, pattern writes, read verification and mismatch detection.
#include <cstdint>
#include <cstdio>
#include <deque>
#include <map>
#include <random>

#include "Vmem_probe.h"
#include "verilated.h"

namespace {
Vmem_probe* dut;
std::mt19937 rng(12345);
std::map<uint64_t, uint64_t> mem;

struct Burst { uint64_t addr; int beats; uint64_t ready; uint64_t accepted; bool first; };
std::deque<Burst> reads;
uint64_t now = 0;
int wr_left = 0;
uint64_t wr_addr = 0;
int stall_pct = 30;
uint64_t min_latency = 10;
int failures = 0;

// Expected read latency statistics for the current run. A command accepted at the edge of tick a
// and a first beat presented after the edge of tick t (sampled at edge t+1) give latency t+1-a.
uint64_t exp_sum, exp_count;
uint32_t exp_min, exp_max, exp_hist[64];

void expect_reset() {
    exp_sum = exp_count = 0;
    exp_min = 0xFFFFFFFF;
    exp_max = 0;
    for (auto& h : exp_hist) h = 0;
}

void check(bool ok, const char* what) {
    if (!ok) { printf("FAIL: %s\n", what); failures++; }
}

uint64_t pattern(uint64_t w, uint32_t s) {
    uint64_t lo = static_cast<uint32_t>(w) ^ s;
    uint64_t hi = static_cast<uint32_t>(~static_cast<uint32_t>(w)) ^ s;
    return (hi << 32) | lo;
}

void tick() {
    // Outputs of this cycle were settled by the previous eval, and inputs are stable up to the edge.
    const bool accepted = !dut->m_waitrequest;
    if (accepted && dut->m_read) {
        reads.push_back({dut->m_address, dut->m_burstcount, now + min_latency + rng() % 20, now, true});
    }
    if (accepted && dut->m_write) {
        if (wr_left == 0) { wr_left = dut->m_burstcount; wr_addr = dut->m_address; }
        mem[wr_addr++] = dut->m_writedata;
        wr_left--;
    }
    dut->clk = 1; dut->eval();
    dut->clk = 0;
    dut->m_readdatavalid = 0;
    if (!reads.empty() && reads.front().ready <= now) {
        auto& b = reads.front();
        dut->m_readdata = mem.count(b.addr) ? mem[b.addr] : 0;
        dut->m_readdatavalid = 1;
        if (b.first) {
            const uint32_t lat = static_cast<uint32_t>(now + 1 - b.accepted);
            exp_sum += lat;
            exp_count++;
            if (lat < exp_min) exp_min = lat;
            if (lat > exp_max) exp_max = lat;
            exp_hist[lat >= 256 ? 63 : lat >> 2]++;
            b.first = false;
        }
        b.addr++;
        if (--b.beats == 0) reads.pop_front();
    }
    dut->m_waitrequest = (rng() % 100) < static_cast<unsigned>(stall_pct);
    dut->csr_write = 0;
    dut->csr_read = 0;
    dut->eval();
    now++;
}

void csr_wr(int word, uint32_t v) {
    dut->csr_address = word * 4;
    dut->csr_writedata = v;
    dut->csr_write = 1;
    dut->eval();
    tick();
}

uint32_t csr_rd(int word) {
    dut->csr_address = word * 4;
    dut->csr_read = 1;
    dut->eval();
    tick();
    dut->eval();
    return dut->csr_readdata;
}

struct Result { uint64_t latency_sum; uint32_t beats, bad, lat_min, lat_max, issued, hist_total; };

Result run(int mode, bool verify, uint32_t base, uint32_t mask, int burst, int max_out, uint32_t count, uint32_t seed) {
    csr_wr(3, base); csr_wr(4, mask); csr_wr(5, burst); csr_wr(6, max_out); csr_wr(7, count); csr_wr(17, seed);
    expect_reset();
    csr_wr(1, 1u | (static_cast<uint32_t>(mode) << 2) | (verify ? 16u : 0u));
    for (uint64_t i = 0; i < 20000000; i++) {
        tick();
        if (i % 64 == 0 && (csr_rd(2) & 3) == 2) break;
    }
    check((csr_rd(2) & 3) == 2, "run finishes");
    for (int i = 0; i < 40; i++) tick();
    Result r{};
    r.latency_sum = csr_rd(12) | (static_cast<uint64_t>(csr_rd(13)) << 32);
    r.beats = csr_rd(11);
    r.bad = csr_rd(16);
    r.lat_min = csr_rd(14);
    r.lat_max = csr_rd(15);
    r.issued = csr_rd(19);
    bool hist_ok = true;
    for (int i = 0; i < 64; i++) {
        const uint32_t h = csr_rd(64 + i);
        r.hist_total += h;
        if (mode != 2 && h != exp_hist[i]) hist_ok = false;
    }
    if (mode != 2) {
        // Exact match with the model, not only bounds.
        check(r.latency_sum == exp_sum, "latency sum exact");
        check(r.lat_min == exp_min && r.lat_max == exp_max, "latency min/max exact");
        check(hist_ok, "histogram bins exact");
    }
    return r;
}
}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vmem_probe;
    dut->rst = 1;
    for (int i = 0; i < 10; i++) tick();
    dut->rst = 0;
    tick();

    check(csr_rd(0) == 0x4D505231, "ID");
    csr_wr(21, 0x12345678);
    check(csr_rd(21) == 0x12345678, "scratch");

    const uint32_t seed = 0xA5A51234, base = 0x100000;

    for (int burst : {1, 4, 8, 16}) {
        mem.clear();
        // The writes fill the whole window, so random reads only see written words.
        const uint32_t n = 2048, mask = n * burst - 1;
        Result w = run(2, false, base, mask, burst, 1, n, seed);
        check(w.issued == n, "write issued");
        check(w.beats == n * burst, "write beats");
        bool ok = true;
        for (uint32_t i = 0; i < n * burst; i++) {
            const uint64_t a = base + (i & mask);
            if (mem[a] != pattern(a, seed)) { ok = false; break; }
        }
        check(ok, "write pattern in memory");

        for (int out : {1, 2, 8, 32}) {
            for (int mode : {0, 1}) {
                Result r = run(mode, true, base, mask, burst, out, n, seed);
                check(r.issued == n, "read issued");
                check(r.beats == n * burst, "read beats");
                check(r.bad == 0, "no mismatch");
                check(r.hist_total == n, "histogram total");
                check(r.lat_min >= min_latency && r.lat_min <= r.lat_max, "latency bounds");
                check(r.latency_sum >= n * static_cast<uint64_t>(r.lat_min) &&
                      r.latency_sum <= n * static_cast<uint64_t>(r.lat_max), "latency sum");
                printf("burst %2d out %2d mode %d: lat min %u max %u mean %.1f\n", burst, out, mode, r.lat_min,
                       r.lat_max, static_cast<double>(r.latency_sum) / n);
            }
        }
    }

    // A single flipped bit must be counted and located.
    mem.clear();
    run(2, false, base, 0xFF, 1, 1, 256, seed);
    mem[base + 77] ^= 1;
    Result r = run(0, true, base, 0xFF, 1, 4, 256, seed);
    check(r.bad == 1, "one mismatch counted");
    check(csr_rd(20) == base + 77, "mismatch address");

    // With waitrequest always low, latency still has its model minimum.
    stall_pct = 0;
    r = run(0, true, base, 0xFF, 1, 1, 200, seed);
    check(r.lat_min >= min_latency, "latency without stalls");

    printf(failures ? "FAILED: %d\n" : "PASS\n", failures);
    return failures ? 1 : 0;
}
