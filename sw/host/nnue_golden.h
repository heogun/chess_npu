// Golden stimulus formats, descriptor encoding and tensor comparison, shared by the Verilator
// testbench (hw/rtl/tb/tb_core.cpp) and the DE1-SoC harness (sw/board/nnue_board.cpp), so both
// replay the same records and apply the same checks. Formats are written by
// sw/reference/golden_harness.cpp; the CSR and descriptor layout is in docs/reports/M3_resources.md.
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

#include "generated_spec.h"
#include "nnue_ctx.h"

namespace nnue_golden {

using namespace nnue_spec;
using nnue_ctx::Context;
using nnue_ctx::FullFeatures;
using nnue_ctx::PlyDiff;
using nnue_ctx::Request;

enum Csr : uint32_t {
    CSR_ID = 0, CSR_ABI, CSR_HASH, CSR_NET, CSR_CONTROL, CSR_STATUS, CSR_DESC, CSR_BASE, CSR_SEQ,
    CSR_OUT_PSQT, CSR_OUT_POS, CSR_RAW_PSQT, CSR_RAW_POS, CSR_CYCLES, CSR_WAITS, CSR_WORDS,
    CSR_TSEL, CSR_TDATA, CSR_CTX, CSR_SLOTS, CSR_PSEL, CSR_PDATA
};

enum Err : uint32_t { ERR_NONE, ERR_MAGIC, ERR_ABI, ERR_HASH, ERR_NET, ERR_RANGE, ERR_RESERVED, ERR_TIMEOUT, ERR_ALIGN, ERR_SLOT };

constexpr uint32_t CTRL_START = 1, CTRL_SOFT_RESET = 2, CTRL_IRQ_EN = 4, CTRL_CLEAR = 8, CTRL_INVALIDATE = 16;
constexpr uint32_t CORE_ID = 0x4E4E5545;  // "NNUE"

// Profile counters behind PSEL/PDATA; see nnue_core.sv. 0..PERF_STAGES-1 sum to CYCLES.
constexpr int PERF_STAGES = 12, PERF_COUNT = 21;
inline const char* const PERF_NAMES[PERF_COUNT] = {
    "desc", "row_wait", "psqt_wait", "acc_other", "ft", "fc_bias", "fc0_scan", "fc0_col_wait",
    "activation", "fc1", "fc2", "final", "req_header", "req_features", "req_psq_row", "req_active_row",
    "req_psqt", "req_fc_bias", "req_fc0_col", "req_fc2", "req_fc1_col"};

enum EventTag : uint32_t { EV_ROOT, EV_PUSH, EV_POP, EV_EVAL };
constexpr uint32_t STIM_MAGIC = 0x4D495453u, EVENTS_MAGIC = 0x53564E45u;

// Must match StimRec in sw/reference/golden_harness.cpp; checked through the file header size.
struct Features {
    uint16_t nPsq[2], nActive[2];
    uint16_t psq[2][32];
    uint16_t active[2][256];
};

struct Tensors {
    alignas(64) int16_t acc[2][1024];
    int32_t psqtAcc[2][8];
    alignas(64) uint8_t ft[1024];
    int32_t fc0[32];
    uint8_t concat[128];
    int32_t fc1[32];
    int32_t fc2;
    int32_t fwd, skip, rawPsqt, rawPos;
    int32_t outPsqt, outPos;
};

struct StimRec {
    uint64_t id;
    uint32_t bucket;
    uint32_t stm;
    Features f;
    Tensors  t;
};

inline bool read_header(std::istream& in, uint32_t magic) {
    uint32_t head[4];
    in.read(reinterpret_cast<char*>(head), sizeof(head));
    if (!in || head[0] != magic || head[1] != 1 || head[2] != sizeof(StimRec) || head[3] != uint32_t(NETWORK_HASH))
    {
        std::printf("FAIL input header: magic=%08X ver=%u size=%u (expected %zu) hash=%08X\n", head[0], head[1], head[2],
                    sizeof(StimRec), head[3]);
        return false;
    }
    return true;
}

inline FullFeatures full_of(const Features& f) {
    FullFeatures out;
    for (int c = 0; c < 2; ++c)
    {
        out.psq[c].assign(f.psq[c], f.psq[c] + f.nPsq[c]);
        out.active[c].assign(f.active[c], f.active[c] + f.nActive[c]);
    }
    return out;
}

inline Request refresh_request(const Features& f, uint32_t dst) {
    const FullFeatures full = full_of(f);
    Request            r;
    r.dst = dst;
    for (int c = 0; c < 2; ++c)
    {
        r.op[c]                          = nnue_ctx::OP_REFRESH;
        r.lists[c][nnue_ctx::PSQ_ADD]    = full.psq[c];
        r.lists[c][nnue_ctx::ACTIVE_ADD] = full.active[c];
    }
    return r;
}

// Descriptor words (ABI 2) for one request.
inline void encode_descriptor(std::vector<uint64_t>& d, const Request& r, uint32_t seq, uint32_t stm, uint32_t bucket,
                              uint32_t ctx) {
    d.assign(DESC_HEADER_WORDS, 0);
    d[0] = uint64_t(uint32_t(DESC_MAGIC)) | (uint64_t(ABI_VERSION) << 32);
    d[1] = uint64_t(uint32_t(NETWORK_HASH)) | (uint64_t(uint32_t(NET_ID)) << 32);
    d[2] = uint64_t(seq) | (uint64_t(stm) << 32) | (uint64_t(bucket) << 40) | (uint64_t(ctx) << 48);
    d[3] = uint64_t(r.dst) | (uint64_t(r.src[0]) << 8) | (uint64_t(r.src[1]) << 16) | (uint64_t(r.op[0]) << 24)
         | (uint64_t(r.op[1]) << 26);

    std::vector<uint16_t> all;
    for (int c = 0; c < 2; ++c)
    {
        uint64_t counts = 0;
        for (int k = 0; k < 4; ++k)
        {
            counts |= uint64_t(r.lists[c][k].size()) << (16 * k);
            all.insert(all.end(), r.lists[c][k].begin(), r.lists[c][k].end());
        }
        d[size_t(4 + c)] = counts;
    }
    for (size_t i = 0; i < all.size(); i += 4)
    {
        uint64_t w = 0;
        for (size_t k = 0; k < 4 && i + k < all.size(); ++k)
            w |= uint64_t(all[i + k]) << (16 * k);
        d.push_back(w);
    }
}

// Sequential reader of an event stream produced by golden_harness --events.
class EventCursor {
   public:
    EventCursor(const std::string& path, std::streamoff offset) :
        in_(path, std::ios::binary) {
        in_.seekg(offset);
    }

    // Applies events to ctx until the next evaluation. Returns false at the end of the stream.
    bool next_eval(Context& ctx, StimRec& rec) {
        uint32_t tag;
        while (in_.read(reinterpret_cast<char*>(&tag), sizeof(tag)))
        {
            switch (tag)
            {
            case EV_ROOT:
                ctx.root();
                break;
            case EV_POP:
                ctx.pop();
                break;
            case EV_PUSH:
                ctx.push(read_push(in_));
                break;
            case EV_EVAL:
                in_.read(reinterpret_cast<char*>(&rec), sizeof(StimRec));
                return bool(in_);
            default:
                std::printf("FAIL unknown event tag %u\n", tag);
                std::exit(1);
            }
        }
        return false;
    }

    static PlyDiff read_push(std::istream& in) {
        PlyDiff d;
        for (auto& p : d.p)
        {
            uint16_t head[5];
            in.read(reinterpret_cast<char*>(head), sizeof(head));
            p.refresh = head[0] != 0;
            for (int k = 0; k < 4; ++k)
            {
                p.lists[k].resize(head[k + 1]);
                in.read(reinterpret_cast<char*>(p.lists[k].data()), std::streamsize(head[k + 1] * 2));
            }
        }
        return d;
    }

   private:
    std::ifstream in_;
};

// Offsets of EV_ROOT events, so that contexts can start in different searches.
inline std::vector<std::streamoff> scan_roots(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    in.seekg(16);
    std::vector<std::streamoff> roots;
    uint32_t                    tag;
    for (;;)
    {
        const std::streamoff at = in.tellg();
        if (!in.read(reinterpret_cast<char*>(&tag), sizeof(tag)))
            break;
        if (tag == EV_ROOT)
            roots.push_back(at);
        else if (tag == EV_PUSH)
            EventCursor::read_push(in);
        else if (tag == EV_EVAL)
            in.seekg(sizeof(StimRec), std::ios::cur);
    }
    return roots;
}

// Device access: Dev provides uint32_t csr_read(uint32_t) and void csr_write(uint32_t, uint32_t).
template <class Dev>
uint32_t tensor_read(Dev& dev, uint32_t tensor, uint32_t index) {
    dev.csr_write(CSR_TSEL, (tensor << 28) | index);
    return dev.csr_read(CSR_TDATA);
}

// Final pair and pre-division values. Returns the number of values compared; Fail is called as
// fail(name, index, got, want) for each mismatch.
template <class Dev, class Fail>
uint64_t check_outputs(Dev& dev, const StimRec& s, Fail&& fail) {
    const Tensors& t = s.t;
    const struct {
        const char* name;
        uint32_t    csr;
        int32_t     want;
    } fields[] = {{"out_psqt", CSR_OUT_PSQT, t.outPsqt},
                  {"out_pos", CSR_OUT_POS, t.outPos},
                  {"raw_psqt", CSR_RAW_PSQT, t.rawPsqt},
                  {"raw_pos", CSR_RAW_POS, t.rawPos}};
    for (const auto& f : fields)
    {
        const int32_t got = int32_t(dev.csr_read(f.csr));
        if (got != f.want)
            fail(f.name, 0, got, f.want);
    }
    return 4;
}

// Every intermediate tensor through the TSEL/TDATA port. The core must be idle.
template <class Dev, class Fail>
uint64_t check_tensors(Dev& dev, const StimRec& s, Fail&& fail) {
    const Tensors& t   = s.t;
    auto           cmp = [&](uint32_t tensor, uint32_t index, int32_t want, const char* name, int at) {
        const int32_t got = int32_t(tensor_read(dev, tensor, index));
        if (got != want)
            fail(name, at, got, want);
    };
    for (int c = 0; c < 2; ++c)
        for (int j = 0; j < 1024; ++j)
            cmp(0, uint32_t(c * 1024 + j), t.acc[c][j], c ? "acc_black" : "acc_white", j);
    for (int c = 0; c < 2; ++c)
        for (int j = 0; j < 8; ++j)
            cmp(1, uint32_t(c * 8 + j), t.psqtAcc[c][j], c ? "psqt_black" : "psqt_white", j);
    for (int j = 0; j < 1024; ++j)
        cmp(2, uint32_t(j), t.ft[j], "ft", j);
    for (int j = 0; j < 32; ++j)
        cmp(3, uint32_t(j), t.fc0[j], "fc0", j);
    for (int j = 0; j < 128; ++j)
        cmp(4, uint32_t(j), t.concat[j], "concat", j);
    for (int j = 0; j < 32; ++j)
        cmp(5, uint32_t(j), t.fc1[j], "fc1", j);
    cmp(6, 0, t.fc2, "fc2", 0);
    cmp(7, 0, t.fwd, "fwd", 0);
    cmp(8, 0, t.skip, "skip", 0);
    return 2048 + 16 + 1024 + 32 + 128 + 32 + 3;
}

}  // namespace nnue_golden
