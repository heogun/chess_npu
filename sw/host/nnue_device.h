// The SF19 NNUE core on the DE1-SoC as a device: physical windows through /dev/mem, identity
// checks, F2SDRAM port release, weight image load and read-back, and one evaluation at a time by
// descriptor and STATUS polling. Shared by the board harness (sw/board/nnue_board.cpp) and the
// engine adapter (sw/host/engine/fpga_eval.cpp), so both drive the core the same way.
//
// Needs the NNUE FPGA image, U-Boot `bridge enable`, and Linux booted with mem=768M. The weight
// image and descriptors live in physical 0x30000000-0x3FFFFFFF, which Linux does not own then.
// No kernel driver yet: user space with root rights, no IRQ, no DMA API.
#pragma once

#include <fcntl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "nnue_golden.h"

namespace nnue_device {

using namespace nnue_golden;

constexpr uint32_t LW_BRIDGE = 0xFF200000, LW_SPAN = 0x1000;
constexpr uint32_t WIN_BASE = 0x30000000, WIN_BYTES = 0x10000000;
constexpr uint32_t WEIGHT_ADDR = WIN_BASE;               // 4 KiB aligned, as BASE requires
constexpr uint32_t DESC_ADDR   = WIN_BASE + 0x08000000;  // after the 115 MB image; 16 B aligned
// SDRAM controller fpgaportrst (Cyclone V HPS TRM / socal alt_sdr.h): bits 3:0 read data ports,
// 7:4 write data ports, 13:8 command ports. U-Boot releases 0x111 (a 64-bit port); a 128-bit port
// also needs read and write data port 1: 0x133, the Quartus handoff value for that configuration.
constexpr uint32_t SDR_BASE = 0xFFC25000, SDR_FPGAPORTRST = 0x80;
constexpr double   FCLK_HZ     = 100e6;
constexpr uint32_t STATUS_TIMEOUT = 0xFFFFFFFFu;  // run(): the core did not finish in time

inline uint64_t now_ns() {
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return uint64_t(t.tv_sec) * 1000000000ull + uint64_t(t.tv_nsec);
}

class Board {
   public:
    uint32_t csr_read(uint32_t a) const { return csr_[a]; }
    void     csr_write(uint32_t a, uint32_t d) { csr_[a] = d; }

    // Maps the windows, checks the core identity against this build's spec, releases the
    // F2SDRAM ports the bus width needs, writes (if load) and reads back the weight image, and
    // resets the core with every slot invalid. Progress goes to log. Returns "" or the reason.
    std::string open(const char* weightsPath, bool load, std::FILE* log) {
        if (std::string e = window_free(); !e.empty())
            return e;
        fd_ = ::open("/dev/mem", O_RDWR | O_SYNC);
        if (fd_ < 0)
            return "cannot open /dev/mem (root rights needed)";
        void* c = mmap(nullptr, LW_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, LW_BRIDGE);
        void* w = mmap(nullptr, WIN_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, WIN_BASE);
        if (c == MAP_FAILED || w == MAP_FAILED)
            return "mmap of the lightweight bridge or the DDR window failed";
        csr_ = static_cast<volatile uint32_t*>(c);
        win_ = static_cast<volatile uint64_t*>(w);

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
            const uint32_t got = csr_read(i.csr);
            std::fprintf(log, "%-5s 0x%08X %s\n", i.name, got, got == i.want ? "ok" : "MISMATCH");
            if (got != i.want)
                return "core identity does not match this build's spec; wrong FPGA image or bridge disabled";
        }

        // Older images read 0 here (unused CSR): 64-bit.
        bus_ = csr_read(CSR_BUS) == 128 ? 128 : 64;
        void* q = mmap(nullptr, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, SDR_BASE);
        if (q == MAP_FAILED)
            return "mmap of the SDRAM controller failed";
        volatile uint32_t* sdr  = static_cast<volatile uint32_t*>(q);
        const uint32_t     need = bus_ == 128 ? 0x133u : 0x111u;
        const uint32_t     have = sdr[SDR_FPGAPORTRST / 4] & 0x3FFFu;
        if ((have & need) != need)
            sdr[SDR_FPGAPORTRST / 4] = have | need;
        std::fprintf(log, "BUS   %u bits, fpgaportrst 0x%03X -> 0x%03X\n", bus_, have, sdr[SDR_FPGAPORTRST / 4] & 0x3FFFu);
        munmap(q, 0x1000);

        if (std::string e = load_weights(weightsPath, load, log); !e.empty())
            return e;

        csr_write(CSR_CONTROL, CTRL_SOFT_RESET);
        csr_write(CSR_CONTROL, CTRL_CLEAR);
        csr_write(CSR_BASE, WEIGHT_ADDR);  // also invalidates every slot
        csr_write(CSR_DESC, DESC_ADDR);
        return "";
    }

    uint32_t bus_bits() const { return bus_; }

    // Writes the descriptor, starts the core and waits. Returns STATUS, or STATUS_TIMEOUT.
    // hostNs covers descriptor write to result read: communication, synchronisation and
    // retrieval of the output pair.
    uint32_t run(const std::vector<uint64_t>& desc, uint64_t& hostNs, uint64_t timeoutNs = 1000000000ull) {
        volatile uint64_t* d  = win_ + (DESC_ADDR - WIN_BASE) / 8;
        const uint64_t     t0 = now_ns();
        for (size_t i = 0; i < desc.size(); ++i)
            d[i] = desc[i];
        // The core reads the descriptor through the F2SDRAM port, not through the CPU's path.
        asm volatile("dsb sy" ::: "memory");
        csr_write(CSR_CONTROL, CTRL_START);
        uint32_t st;
        while ((st = csr_read(CSR_STATUS)) & 1)
            if (now_ns() - t0 > timeoutNs)
                return STATUS_TIMEOUT;
        outPsqt_ = int32_t(csr_read(CSR_OUT_PSQT));
        outPos_  = int32_t(csr_read(CSR_OUT_POS));
        hostNs   = now_ns() - t0;
        return st;
    }

    // Output pair of the last run(), as read inside the timed region.
    int32_t out_psqt() const { return outPsqt_; }
    int32_t out_pos() const { return outPos_; }

    // STATUS says done without error, and SEQ/CTX echo the descriptor.
    bool finished_ok(uint32_t st, uint32_t seq, uint32_t ctx) const {
        return st != STATUS_TIMEOUT && (st & 2) && !(st & 4) && csr_read(CSR_SEQ) == seq && csr_read(CSR_CTX) == ctx;
    }

   private:
    static std::string window_free() {
        std::FILE* f = std::fopen("/proc/iomem", "r");
        if (!f)
            return "cannot read /proc/iomem";
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
            return "Linux RAM overlaps 0x30000000-0x3FFFFFFF; boot the FPGA image (mem=768M)";
        return "";
    }

    // Copies the image into the window (if load) and reads all of it back.
    std::string load_weights(const char* path, bool load, std::FILE* log) {
        std::FILE* f = std::fopen(path, "rb");
        if (!f)
            return std::string("cannot open weights ") + path;
        std::fseek(f, 0, SEEK_END);
        const long bytes = std::ftell(f);
        std::fseek(f, 0, SEEK_SET);
        if (uint64_t(bytes) != IMAGE_BYTES)
        {
            std::fclose(f);
            return "weights size differs from the spec image size";
        }
        std::vector<uint64_t> buf(1 << 17);  // 1 MiB
        volatile uint64_t*    dst = win_ + (WEIGHT_ADDR - WIN_BASE) / 8;
        const uint64_t        t0  = now_ns();
        uint64_t              off = 0, bad = 0;
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
        std::fprintf(log, "weights: %ld bytes %s and read back in %.1f s, %" PRIu64 " differing words\n", bytes,
                     load ? "written" : "(already present)", double(now_ns() - t0) * 1e-9, bad);
        return bad ? "weight image in DDR differs from the file" : "";
    }

    int                fd_  = -1;
    volatile uint32_t* csr_ = nullptr;
    volatile uint64_t* win_ = nullptr;
    uint32_t           bus_ = 64;
    int32_t            outPsqt_ = 0, outPos_ = 0;
};

}  // namespace nnue_device
