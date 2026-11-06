// SF19 NNUE core on the DE1-SoC: replays golden stimulus through the real hardware and compares
// the final pair and every intermediate tensor with the official Stockfish results. Uses the same
// record formats, descriptor encoding, request planner and checks as the Verilator testbench
// (sw/host/nnue_golden.h, sw/host/nnue_ctx.h).
//
//   nnue_board <weights.bin> <input> [--mode refresh|events] [--max N] [--tensor-every K]
//              [--no-load] [--report out.json]
//     refresh: <input> is a golden_harness --stim file; every state is a full refresh.
//     events:  <input> is a golden_harness --events file; one context plans each request from the
//              official per-ply changes, as tb_core --mode events --contexts 1 --no-chaos.
//
// Needs the NNUE FPGA image, U-Boot `bridge enable`, and Linux booted with mem=768M. The weight
// image and descriptors live in physical 0x30000000-0x3FFFFFFF, which Linux does not own then.
// Timing: host = descriptor write to result read (communication, synchronisation and retrieval
// included); fpga = CYCLES at 100 MHz; plan = ARM time to plan and encode the request.
#include <fcntl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "nnue_golden.h"

using namespace nnue_golden;

namespace {

constexpr uint32_t LW_BRIDGE = 0xFF200000, LW_SPAN = 0x1000;
constexpr uint32_t WIN_BASE = 0x30000000, WIN_BYTES = 0x10000000;
constexpr uint32_t WEIGHT_ADDR = WIN_BASE;               // 4 KiB aligned, as BASE requires
constexpr uint32_t DESC_ADDR   = WIN_BASE + 0x08000000;  // after the 115 MB image
constexpr double   FCLK_HZ     = 100e6;

volatile uint32_t* csr;
volatile uint64_t* win;

struct BoardDev {
    uint32_t csr_read(uint32_t a) { return csr[a]; }
    void     csr_write(uint32_t a, uint32_t d) { csr[a] = d; }
} dev;

uint64_t now_ns() {
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return uint64_t(t.tv_sec) * 1000000000ull + uint64_t(t.tv_nsec);
}

[[noreturn]] void die(const char* msg) {
    std::printf("FAIL: %s\n", msg);
    std::exit(1);
}

void check_window_free() {
    FILE* f = std::fopen("/proc/iomem", "r");
    if (!f)
        die("cannot read /proc/iomem");
    char line[256];
    bool seen = false, ok = true;
    while (std::fgets(line, sizeof line, f))
    {
        if (line[0] == ' ' || !std::strstr(line, "System RAM"))
            continue;
        unsigned long lo, hi;
        if (std::sscanf(line, "%lx-%lx", &lo, &hi) != 2)
            continue;
        seen = true;
        if (hi >= WIN_BASE && lo < uint64_t(WIN_BASE) + WIN_BYTES)
            ok = false;
    }
    std::fclose(f);
    if (!seen || !ok)
        die("Linux RAM overlaps 0x30000000-0x3FFFFFFF; boot the FPGA image (mem=768M)");
}

void check_identity() {
    const struct {
        const char* name;
        uint32_t    csr, want;
    } ids[] = {{"ID", CSR_ID, CORE_ID},
               {"ABI", CSR_ABI, uint32_t(ABI_VERSION)},
               {"HASH", CSR_HASH, uint32_t(NETWORK_HASH)},
               {"NET", CSR_NET, uint32_t(NET_ID)},
               {"SLOTS", CSR_SLOTS, uint32_t(ACC_SLOTS)}};
    for (const auto& i : ids)
    {
        const uint32_t got = dev.csr_read(i.csr);
        std::printf("%-5s 0x%08X %s\n", i.name, got, got == i.want ? "ok" : "MISMATCH");
        if (got != i.want)
            die("core identity does not match this build's spec; wrong FPGA image or bridge disabled");
    }
}

// Copies the image into the window and reads it back. Returns false on any difference.
bool load_weights(const char* path, bool load) {
    std::FILE* f = std::fopen(path, "rb");
    if (!f)
        die("cannot open weights");
    std::fseek(f, 0, SEEK_END);
    const long bytes = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (uint64_t(bytes) != IMAGE_BYTES)
        die("weights size differs from the spec image size");
    std::vector<uint64_t> buf(1 << 17);  // 1 MiB
    volatile uint64_t*    dst  = win + (WEIGHT_ADDR - WIN_BASE) / 8;
    const uint64_t        t0   = now_ns();
    uint64_t              off  = 0, bad = 0;
    for (size_t n; (n = std::fread(buf.data(), 1, buf.size() * 8, f)) > 0; off += n / 8)
    {
        if (load)
            for (size_t i = 0; i < n / 8; ++i)
                dst[off + i] = buf[i];
        for (size_t i = 0; i < n / 8; ++i)
            bad += dst[off + i] != buf[i];
    }
    std::fclose(f);
    __sync_synchronize();
    std::printf("weights: %ld bytes %s and read back in %.1f s, %" PRIu64 " differing words\n", bytes,
                load ? "written" : "(already present)", double(now_ns() - t0) * 1e-9, bad);
    return bad == 0;
}

std::vector<uint64_t> descWords;

// Writes the descriptor, starts the core and waits. Returns STATUS.
uint32_t run_eval(uint64_t& hostNs) {
    volatile uint64_t* d = win + (DESC_ADDR - WIN_BASE) / 8;
    const uint64_t     t0 = now_ns();
    for (size_t i = 0; i < descWords.size(); ++i)
        d[i] = descWords[i];
    // The core reads the descriptor through the F2SDRAM port, not through the CPU's path.
    asm volatile("dsb sy" ::: "memory");
    dev.csr_write(CSR_CONTROL, CTRL_START);
    uint32_t st;
    while ((st = dev.csr_read(CSR_STATUS)) & 1)
        if (now_ns() - t0 > 1000000000ull)
            die("evaluation did not finish within 1 s");
    // Result retrieval belongs to the host-observed time.
    (void) dev.csr_read(CSR_OUT_PSQT);
    (void) dev.csr_read(CSR_OUT_POS);
    hostNs = now_ns() - t0;
    return st;
}

int64_t     mismatches = 0;
uint64_t    compared   = 0;
std::string lastRequest;

void on_mismatch(const StimRec& s, const char* tensor, int index, int64_t got, int64_t want) {
    if (mismatches < 20)
        std::printf("MISMATCH state=%llu bucket=%u stm=%u tensor=%s index=%d got=%lld want=%lld request: %s\n",
                    (unsigned long long) s.id, s.bucket, s.stm, tensor, index, (long long) got, (long long) want,
                    lastRequest.c_str());
    ++mismatches;
}

struct Series {
    std::vector<uint32_t> host, fpga, plan;
};

std::string pct(std::vector<uint32_t> v, double scale, const char* unit) {
    std::sort(v.begin(), v.end());
    auto at = [&](double p) { return v.empty() ? 0.0 : double(v[size_t(p * double(v.size() - 1))]) * scale; };
    double mean = 0;
    for (uint32_t x : v)
        mean += double(x) * scale;
    mean = v.empty() ? 0 : mean / double(v.size());
    char buf[256];
    std::snprintf(buf, sizeof buf,
                  "{\"count\": %zu, \"unit\": \"%s\", \"mean\": %.2f, \"min\": %.2f, \"median\": %.2f, "
                  "\"p95\": %.2f, \"p99\": %.2f, \"max\": %.2f}",
                  v.size(), unit, mean, at(0), at(0.5), at(0.95), at(0.99), at(1));
    return buf;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 3)
    {
        std::printf("usage: nnue_board weights.bin input [--mode refresh|events] [--max N] [--tensor-every K] "
                    "[--no-load] [--report F]\n");
        return 2;
    }
    uint64_t    maxStates = UINT64_MAX, tensorEvery = 1;
    std::string mode = "refresh", reportPath;
    bool        load = true;
    for (int i = 3; i < argc; ++i)
    {
        const std::string k = argv[i];
        if (k == "--no-load")
            load = false;
        else if (i + 1 >= argc)
            return 2;
        else if (k == "--max")
            maxStates = std::stoull(argv[++i]);
        else if (k == "--tensor-every")
            tensorEvery = std::max<uint64_t>(1, std::stoull(argv[++i]));
        else if (k == "--mode")
            mode = argv[++i];
        else if (k == "--report")
            reportPath = argv[++i];
        else
            return 2;
    }

    check_window_free();
    const int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0)
        die("cannot open /dev/mem");
    void* c = mmap(nullptr, LW_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, LW_BRIDGE);
    void* w = mmap(nullptr, WIN_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, WIN_BASE);
    if (c == MAP_FAILED || w == MAP_FAILED)
        die("mmap failed");
    csr = static_cast<volatile uint32_t*>(c);
    win = static_cast<volatile uint64_t*>(w);

    check_identity();
    if (!load_weights(argv[1], load))
        die("weight image in DDR differs from the file");

    dev.csr_write(CSR_CONTROL, CTRL_SOFT_RESET);
    dev.csr_write(CSR_CONTROL, CTRL_CLEAR);
    dev.csr_write(CSR_BASE, WEIGHT_ADDR);  // also invalidates every slot
    dev.csr_write(CSR_DESC, DESC_ADDR);

    auto     rec = std::make_unique<StimRec>();
    uint64_t states = 0, full = 0, errors = 0, perf[PERF_COUNT] = {}, perfCycles = 0, words = 0;
    Series   all, reuse, incr, refresh;
    uint64_t bucket[8] = {};

    auto finish_eval = [&](const Request& r, uint32_t st, uint32_t seq, uint32_t ctxId, uint64_t hostNs,
                           uint64_t planNs) {
        if (!(st & 2) || (st & 4) || dev.csr_read(CSR_SEQ) != seq || dev.csr_read(CSR_CTX) != ctxId)
        {
            std::printf("ERROR state %llu status=0x%08X err=%u request: %s\n", (unsigned long long) rec->id, st,
                        (st >> 8) & 0xFF, lastRequest.c_str());
            ++errors;
            return false;
        }
        auto fail = [&](const char* n, int i, int64_t got, int64_t want) { on_mismatch(*rec, n, i, got, want); };
        compared += check_outputs(dev, *rec, fail);
        if (states % tensorEvery == 0)
        {
            compared += check_tensors(dev, *rec, fail);
            ++full;
        }
        const uint32_t cyc = dev.csr_read(CSR_CYCLES);
        words += dev.csr_read(CSR_WORDS);
        uint64_t stageSum = 0;
        for (int i = 0; i < PERF_COUNT; ++i)
        {
            dev.csr_write(CSR_PSEL, uint32_t(i));
            const uint32_t v = dev.csr_read(CSR_PDATA);
            perf[i] += v;
            if (i < PERF_STAGES)
                stageSum += v;
        }
        if (stageSum != cyc)
        {
            std::printf("ERROR state %llu: stage counters sum to %llu, CYCLES %u\n", (unsigned long long) rec->id,
                        (unsigned long long) stageSum, cyc);
            ++errors;
        }
        perfCycles += cyc;
        Series* cls = nullptr;
        if (r.op[0] == nnue_ctx::OP_NONE && r.op[1] == nnue_ctx::OP_NONE)
            cls = &reuse;
        else if (r.op[0] == nnue_ctx::OP_INCR && r.op[1] == nnue_ctx::OP_INCR)
            cls = &incr;
        else if (r.op[0] == nnue_ctx::OP_REFRESH && r.op[1] == nnue_ctx::OP_REFRESH)
            cls = &refresh;
        for (Series* s : {&all, cls})
            if (s)
            {
                s->host.push_back(uint32_t(hostNs));
                s->fpga.push_back(cyc);
                s->plan.push_back(uint32_t(planNs));
            }
        ++bucket[rec->bucket & 7];
        ++states;
        if (states % 1000 == 0)
        {
            std::printf("  %llu states, mismatches=%lld errors=%llu\n", (unsigned long long) states,
                        (long long) mismatches, (unsigned long long) errors);
            std::fflush(stdout);
        }
        return true;
    };

    std::unique_ptr<Context> ctx;
    if (mode == "refresh")
    {
        std::ifstream stim(argv[2], std::ios::binary);
        if (!read_header(stim, STIM_MAGIC))
            return 1;
        while (states < maxStates && stim.read(reinterpret_cast<char*>(rec.get()), sizeof(StimRec)))
        {
            const uint64_t t0  = now_ns();
            const uint32_t seq = uint32_t(rec->id), ctxId = uint32_t(states & 0xFFFF);
            const Request  r   = refresh_request(rec->f, uint32_t(states % ACC_SLOTS));
            encode_descriptor(descWords, r, seq, rec->stm, rec->bucket, ctxId);
            const uint64_t planNs = now_ns() - t0;
            uint64_t       hostNs;
            const uint32_t st = run_eval(hostNs);
            if (!finish_eval(r, st, seq, ctxId, hostNs, planNs))
                break;
        }
    }
    else if (mode == "events")
    {
        {
            std::ifstream head(argv[2], std::ios::binary);
            if (!read_header(head, EVENTS_MAGIC))
                return 1;
        }
        EventCursor cursor(argv[2], 16);
        ctx = std::make_unique<Context>(0, uint32_t(ACC_SLOTS));
        while (states < maxStates && cursor.next_eval(*ctx, *rec))
        {
            const uint64_t     t0   = now_ns();
            const FullFeatures fullF = full_of(rec->f);
            Request            r    = ctx->plan(fullF);
            const uint32_t     seq  = uint32_t(states), ctxId = 1;
            encode_descriptor(descWords, r, seq, rec->stm, rec->bucket, ctxId);
            const uint64_t planNs = now_ns() - t0;
            char           buf[160];
            std::snprintf(buf, sizeof buf, "eval=%llu dst=%u op=%u,%u src=%u,%u", (unsigned long long) states, r.dst,
                          r.op[0], r.op[1], r.src[0], r.src[1]);
            lastRequest = buf;
            uint64_t       hostNs;
            const uint32_t st = run_eval(hostNs);
            if (!finish_eval(r, st, seq, ctxId, hostNs, planNs))
                break;
            ctx->commit();
        }
    }
    else
        die("unknown mode");

    std::string out = "{\n  \"mode\": \"" + mode + "\",\n";
    char        buf[512];
    std::snprintf(buf, sizeof buf,
                  "  \"states\": %llu,\n  \"full_tensor_states\": %llu,\n  \"values_compared\": %llu,\n"
                  "  \"mismatches\": %lld,\n  \"errors\": %llu,\n  \"fallbacks\": 0,\n"
                  "  \"mean_words_per_state\": %.1f,\n  \"bucket\": [%llu, %llu, %llu, %llu, %llu, %llu, %llu, %llu],\n",
                  (unsigned long long) states, (unsigned long long) full, (unsigned long long) compared,
                  (long long) mismatches, (unsigned long long) errors, states ? double(words) / double(states) : 0.0,
                  (unsigned long long) bucket[0], (unsigned long long) bucket[1], (unsigned long long) bucket[2],
                  (unsigned long long) bucket[3], (unsigned long long) bucket[4], (unsigned long long) bucket[5],
                  (unsigned long long) bucket[6], (unsigned long long) bucket[7]);
    out += buf;
    if (ctx)
    {
        const auto& s = ctx->stats;
        std::snprintf(buf, sizeof buf,
                      "  \"host_plan\": {\"requests\": %llu, \"reuse\": %llu, \"perspective_refresh\": %llu, "
                      "\"perspective_incremental\": %llu, \"evictions\": %llu, \"cost_refresh\": %llu},\n",
                      (unsigned long long) s.requests, (unsigned long long) s.reuse, (unsigned long long) s.refresh,
                      (unsigned long long) s.incremental, (unsigned long long) s.evictions,
                      (unsigned long long) s.costRefresh);
        out += buf;
    }
    const struct {
        const char* name;
        Series*     s;
    } classes[] = {{"all", &all}, {"reuse_both", &reuse}, {"incremental_both", &incr}, {"refresh_both", &refresh}};
    for (const auto& k : classes)
    {
        out += std::string("  \"") + k.name + "\": {\"host_us\": " + pct(k.s->host, 1e-3, "us")
             + ", \"fpga_us\": " + pct(k.s->fpga, 1e6 / FCLK_HZ, "us") + ", \"plan_us\": " + pct(k.s->plan, 1e-3, "us")
             + "},\n";
    }
    out += "  \"perf_cycles\": " + std::to_string(perfCycles) + ",\n  \"perf\": {";
    for (int i = 0; i < PERF_COUNT; ++i)
        out += std::string(i ? ", " : "") + "\"" + PERF_NAMES[i] + "\": " + std::to_string(perf[i]);
    out += "}\n}\n";
    std::fputs(out.c_str(), stdout);
    if (!reportPath.empty())
    {
        std::FILE* f = std::fopen(reportPath.c_str(), "w");
        if (f)
            std::fputs(out.c_str(), f), std::fclose(f);
    }

    if (mismatches || errors || states == 0)
    {
        std::printf("RESULT FAIL (board)\n");
        return 1;
    }
    std::printf("RESULT PASS (board, %llu states, mismatches 0, errors 0, fallbacks 0)\n", (unsigned long long) states);
    return 0;
}
