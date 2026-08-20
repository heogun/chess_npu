/*
 * devmem_smoke.cpp — /dev/mem G2 게이트 1차 검증 (DE1-SoC)
 *
 * FPGA(main.bit) 로드 후 실행:
 *   1. lw bridge 창 (0xFF200000) 에서 CSR_VERSION == NNUEHW_MAGIC 확인
 *   2. CONTROL START/RESET 왕복
 *   3. s_load (0xC0100000) LOAD_ADDR/LOAD_DATA 왕복 (요청 → 결과는 G2 게이트 2차에서)
 *   4. 진행: 전체 창 4KB 단위 읽기 테스트 (desc/feat 영역 0..0x14000)
 *
 * 합격 판정(rc=0): CSR_VERSION 에서 NNUEHW_MAGIC(0x4E4E5545) 가 읽히고
 *                     STATUS READY/FAULT bit 가 유효하며 UTC 버스 hang 이 없을 것.
 *
 * 사용: ./devmem_smoke          (기본 창 기본 확인만)
 *       ./devmem_smoke --full   (창 전 구간 read sweep)
 */
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <cerrno>

#include "nnuehw.h"

// <linux/*> 없는 비커널 경로에서 struct nnuehw_desc 를 위한 assert 는
// nnuehw.h 의 사용자 공간 브랜치(assert.h) 로 처리됨.

static volatile uint32_t *win_   = nullptr;
static volatile uint32_t *load_  = nullptr;

#define LW_WINDOW_PHYS   0xFF200000u
#define LOAD_PHYS        0xC0100000u
#define WINDOW_MAP_SIZE  0x14000u

static bool map_all() {
    int fd = ::open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { std::perror("open /dev/mem"); return false; }
    void* p = mmap(nullptr, WINDOW_MAP_SIZE, PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, LW_WINDOW_PHYS);
    if (p == MAP_FAILED) { std::perror("mmap window"); ::close(fd); return false; }
    win_ = static_cast<volatile uint32_t*>(p);
    ::close(fd);

    fd = ::open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { std::perror("open /dev/mem (s_load)"); return false; }
    void* lp = mmap(nullptr, 0x100, PROT_READ | PROT_WRITE,
                    MAP_SHARED, fd, LOAD_PHYS);
    if (lp == MAP_FAILED) { std::perror("mmap s_load"); ::close(fd); return false; }
    load_ = static_cast<volatile uint32_t*>(lp);
    ::close(fd);
    return true;
}

static uint32_t rd(uint32_t off)  { return *nnuehw_csr(win_, off); }
static void     wr(uint32_t off, uint32_t v) { *nnuehw_csr(win_, off) = v; }

static const char* rs(uint32_t st) {
    if (st == 0) return "IDLE";
    if (st & NNUEHW_STAT_READY) return "READY";
    if (st & NNUEHW_STAT_FAULT) return "FAULT";
    return "?";
}

int main(int argc, char** argv) {
    bool full = argc > 1 && std::strcmp(argv[1], "--full") == 0;

    if (!map_all()) return 2;

    uint32_t ver = rd(NNUEHW_CSR_VERSION);
    uint32_t ctl = rd(NNUEHW_CSR_CONTROL);
    uint32_t st  = rd(NNUEHW_CSR_STATUS);
    uint32_t dh  = rd(NNUEHW_CSR_DESC_HEAD);
    uint32_t dt  = rd(NNUEHW_CSR_DESC_TAIL);
    uint32_t rh  = rd(NNUEHW_CSR_RESULT_HEAD);
    uint32_t rt  = rd(NNUEHW_CSR_RESULT_TAIL);
    uint32_t done= rd(NNUEHW_CSR_DONE);
    uint32_t irq = rd(NNUEHW_CSR_IRQ_STATUS);

    std::printf("CSR_VERSION   = 0x%08X%s\n", ver,
                ver == NNUEHW_MAGIC ? "  [OK NNUE]" : "  [BAD]");
    std::printf("CSR_CONTROL   = 0x%08X (START=%u IRQ_EN=%u)\n",
                ctl, !!(ctl & NNUEHW_CTRL_START), !!(ctl & NNUEHW_CTRL_IRQ_EN));
    std::printf("CSR_STATUS    = 0x%08X (%s) BUSY=%u FAULT=%u\n",
                st, rs(st), !!(st & NNUEHW_STAT_BUSY), !!(st & NNUEHW_STAT_FAULT));
    std::printf("DESC_HEAD/TAIL= %u / %u\n", dh, dt);
    std::printf("RESULT_HEAD/T = %u / %u\n", rh, rt);
    std::printf("DONE          = %u\n", done);
    std::printf("IRQ_STATUS    = 0x%08X (RESULT_AVAIL=%u FAULT=%u)\n",
                irq, !!(irq & NNUEHW_IRQ_RESULT_AVAIL), !!(irq & NNUEHW_IRQ_FAULT));

    /* CONTROL 왕복: START set → clear */
    wr(NNUEHW_CSR_CONTROL, ctl | NNUEHW_CTRL_START);
    uint32_t c1 = rd(NNUEHW_CSR_CONTROL);
    wr(NNUEHW_CSR_CONTROL, ctl & ~NNUEHW_CTRL_START);
    uint32_t c2 = rd(NNUEHW_CSR_CONTROL);
    std::printf("CONTROL rw    : %s\n", (c1 & NNUEHW_CTRL_START) && !(c2 & NNUEHW_CTRL_START)
                 ? "OK" : "BAD");

    int bad = 0;
    if (full) {
        /* 창 전 구간 read sweep — bus hang 감지 (4 바이트 stride, MMIO) */
        for (uint32_t off = 0x100; off < WINDOW_MAP_SIZE; off += 4) {
            volatile uint32_t v = *nnuehw_csr(win_, off);
            (void)v;  // readback 만 수행; hang 시 커널에서 watchdog/재부팅
        }
        std::printf("window sweep  : 0x100..0x%X done\n", WINDOW_MAP_SIZE);
    }

    /* s_load 왕복: LOAD_ADDR 쓰기/읽기 불가는 RTL 상 read 0 → 쓰기 후 진행만 확인 */
    if (load_) {
        load_[NNUEHW_LOAD_ADDR_REG / 4] = NNUEHW_LOAD_PLANE_FT | 0u;
        load_[NNUEHW_LOAD_DATA_REG / 4] = 0xCAFE0000u | 0x0001u;
        load_[NNUEHW_LOAD_ADDR_REG / 4] = NNUEHW_LOAD_PLANE_FC | 0u;
        load_[NNUEHW_LOAD_DATA_REG / 4] = 0x00000042u;
        load_[NNUEHW_LOAD_ADDR_REG / 4] = NNUEHW_LOAD_PLANE_PSQT | 0u;
        load_[NNUEHW_LOAD_DATA_REG / 4] = 0x12345678u;
        std::printf("s_load rw     : FT/FC/PSQT addr/data written\n");
    }

    /* 결과 판정 (1차 게이트) */
    bool pass = (ver == NNUEHW_MAGIC) && (st != 0xFFFFFFFFu) && bad == 0;
    std::printf(pass ? "DEVSMOKE: PASS\n" : "DEVSMOKE: FAIL\n");
    return pass ? 0 : 1;
}