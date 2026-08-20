/*
 * onboard_verify.cpp - DE1-SoC 온보드 NNUE bit-exact 검증 (small net)
 *
 * 흐름:
 *   1) FTBIN  -> HPS DDR3 0x35000000 : int16 워드 배열 (FPGA DDR 스트림)
 *   2) PSQTBIN -> HPS DDR3 0x34000000 : int32 워드 배열 (FPGA DDR 스트림)
 *   3) FCBIN  -> s_load (0xC0100000) FC 평면 : 8-bit 바이트 스트림
 *   4) FEN x bucket(0..7) 별 REFRESH desc 제출 -> (psqt, positional) 결과 수집
 *   5) 결과를 ref.txt 와 비교해 PASS/FAIL 출력
 *
 * 하드웨어 계약 (nnuehw.h / fpga_top_soc.sv):
 *   - FT/PSQT는 FPGA-to-HPS DDR3 읽기 스트림, FC만 s_load BRAM
 *   - LOAD_ADDR[31:28] 평면 선택: FC 로드에서만 0x1=FC(8b) 사용
 *   - LOAD_DATA 쓰기 후 자동 주소+1 (auto-increment)
 *   - desc: mode=REFRESH, bucket 0..7, side=stm, n_add=cnt0+cnt1,
 *           cnt_main0/1 (threat 필드는 small 에서 0)
 *   - psqt 결과 = (psqtAcc[side]-psqtAcc[side^1])/2  == ref r.psqt[b]
 *   - positional 결과 == ref r.positional[b]
 *   - 비교/출력 시 /16 (SymmetricOutput) 는 모두 동일
 *
 * 빌드 (WSL Ubuntu):
 *   arm-linux-gnueabihf-g++ -O2 -static -std=c++17 -o onboard_verify onboard_verify.cpp
 *
 * 사용: ./onboard_verify <wdir>
 *   <wdir> 에 존재: ft.bin psqt.bin fc.bin                       (small 바이너리)
 *                   ref.txt   -- ref_results_small.txt (기대값)
 *                   case_<name>.feat -- FTLIST 라인
 */
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <array>
#include <fstream>
#include <sstream>
#include <chrono>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <cerrno>

#include "nnuehw.h"

static const uint32_t LW_WINDOW_PHYS = 0xFF200000u;
static const uint32_t LOAD_PHYS      = 0xC0100000u;
static const uint32_t FT_DDR_PHYS    = 0x35000000u;
static const uint32_t PSQ_DDR_PHYS   = 0x34000000u;
static const uint32_t WINDOW_MAP_SIZE= 0x14000u;
static const size_t SMALL_FT_BYTES   = (1u + 22528u) * 128u * sizeof(uint16_t);
static const size_t SMALL_PSQ_BYTES  = 22528u * 8u * sizeof(uint32_t);

static volatile uint32_t *win_  = nullptr;
static volatile uint32_t *load_ = nullptr;
static void *ft_ddr_ = nullptr;
static void *psq_ddr_ = nullptr;

static uint32_t rd(uint32_t off)  { return *nnuehw_csr(win_, off); }
static void     wr(uint32_t off, uint32_t v) { *nnuehw_csr(win_, off) = v; }

struct Case {
    std::string name;
    uint32_t bucket_used = 0;                        /* ref BUCKET n */
    std::vector<uint32_t> feats;                     /* persp0 이어 persp1 */
    std::vector<uint32_t> cnts;                      /* FTLIST cnt0 cnt1 (thr 0) */
    std::array<std::pair<int,int>,8> expect;         /* (psqt/16, positional/16) */
};

static bool map_all() {
    int fd = ::open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { std::perror("open /dev/mem (window)"); return false; }
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

/* FT/PSQT: FPGA-to-HPS DDR 스트림의 계약 주소에 직접 배치. */
static bool ddr_load(void* dst, const void* src, size_t n_bytes) {
    if (!dst || (!src && n_bytes)) return false;
    std::memcpy(dst, src, n_bytes);
    return true;
}

/* FC: s_load FC 평면으로 바이트 스트림 (LOAD_ADDR=0x10000000, 8-bit 래인) */
static bool fc_load(const void* src, size_t n) {
    if (!load_) return false;
    const uint8_t* b = static_cast<const uint8_t*>(src);
    load_[NNUEHW_LOAD_ADDR_REG / 4] = NNUEHW_LOAD_PLANE_FC | 0u;
    for (size_t i = 0; i < n; i++)
        load_[NNUEHW_LOAD_DATA_REG / 4] = b[i];
    return true;
}

static bool file_read(const std::string& path, std::vector<uint8_t>& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    f.seekg(0, std::ios::end);
    size_t sz = (size_t)f.tellg();
    f.seekg(0, std::ios::beg);
    out.resize(sz);
    if (sz) f.read(reinterpret_cast<char*>(out.data()), sz);
    return true;
}

/* ref.txt 한 라인: "startpos|RAWVERIFY 0 p0 q0 ... RAWVERIFY 7 p7 q7 BUCKET 7" */
static bool parse_refline(const std::string& line, Case& c) {
    std::istringstream ss(line);
    std::string tok;
    std::getline(ss, tok, '|');
    c.name = tok;
    for (int b = 0; b < 8; b++) {
        std::string tag;
        int bidx, p, q;
        if (!(ss >> tag >> bidx >> p >> q)) return false;
        if (tag != "RAWVERIFY" || bidx != b) return false;
        c.expect[b] = {p, q};
    }
    std::string tag;
    if (!(ss >> tag >> c.bucket_used)) return false;
    if (tag != "BUCKET") return false;
    return true;
}

/* FTLIST 파일: "FTLIST cnt0 cnt1 f0 f1 ..." (persp0 main, persp1 main) */
static bool parse_ftlist(const std::string& path, Case& c) {
    std::ifstream f(path);
    if (!f) return false;
    std::string line;
    if (!std::getline(f, line)) return false;
    std::istringstream ss(line);
    std::string tag;
    uint32_t cnt0, cnt1;
    if (!(ss >> tag >> cnt0 >> cnt1)) return false;
    if (tag != "FTLIST") return false;
    uint32_t v;
    while (ss >> v) c.feats.push_back(v);
    if (c.feats.size() != (size_t)(cnt0 + cnt1)) return false;
    c.cnts = {cnt0, cnt1};
    return true;
}

/* (FEN, bucket) 요청: feat frame + desc 작성만 (doorbell 은 콜러가) */
static bool submit_bucket(uint32_t seq, const Case& c, uint32_t bucket,
                          uint32_t side, uint32_t ring) {
    if (!win_) return false;
    uint32_t add_frame = ring & NNUEHW_FEAT_MASK;

    uint32_t* dst = nnuehw_feat_frame(const_cast<uint32_t*>(win_), add_frame);
    std::memcpy(dst, c.feats.data(), c.feats.size() * sizeof(uint32_t));

    volatile struct nnuehw_desc* d = reinterpret_cast<volatile struct nnuehw_desc*>(
        const_cast<uint32_t*>(win_) + NNUEHW_DESC_BASE / 4 +
        (ring & NNUEHW_DESC_MASK) * (NNUEHW_DESC_ENTRY_BYTES / 4));
    std::memset(const_cast<struct nnuehw_desc*>(d), 0, sizeof(*d));
    d->magic     = NNUEHW_MAGIC;
    d->mode      = NNUEHW_DESC_MODE_REFRESH;
    d->bucket    = bucket;
    d->side      = side;
    d->n_add     = (uint32_t)c.feats.size();
    d->n_rem     = 0;
    d->add_frame = add_frame;
    d->rem_frame = add_frame;
    d->seq       = seq;
    d->cnt_main0 = c.cnts[0];
    d->cnt_main1 = c.cnts[1];
    d->cnt_thr0  = 0;
    d->cnt_thr1  = 0;
    return true;
}

/* 결과 링에서 seq 를 찾을 때까지 폴링. FPGA 생산자 인덱스는 단조 증가 — rtail 정적 유지 */
static bool poll_seq(uint32_t seq, int& psqt, int& positional, int timeout_ms) {
    if (!win_) return false;
    static uint32_t rtail = 0;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    for (;;) {
        uint32_t h = rd(NNUEHW_CSR_RESULT_HEAD);
        while (rtail != h) {
            const volatile struct nnuehw_result* res =
                reinterpret_cast<const volatile struct nnuehw_result*>(
                    const_cast<uint32_t*>(win_) + NNUEHW_RESULT_BASE / 4 +
                    (rtail & NNUEHW_RESULT_MASK) * (NNUEHW_RESULT_ENTRY_BYTES / 4));
            if (res->seq == seq) {
                psqt = res->psqt;
                positional = res->positional;
                rtail = (rtail + 1) & NNUEHW_RESULT_MASK;
                wr(NNUEHW_CSR_RESULT_TAIL, rtail);
                return true;
            }
            rtail = (rtail + 1) & NNUEHW_RESULT_MASK;
        }
        wr(NNUEHW_CSR_RESULT_TAIL, rtail);
        if (std::chrono::steady_clock::now() >= deadline) return false;
        usleep(1000);
    }
}

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <wdir>\n", argv[0]);
        return 2;
    }
    std::string dir = argv[1];
    std::string sep = dir.empty() || dir[dir.size()-1]=='/' ? "" : "/";

    /* 1) 가중치 파일 (small) */
    std::vector<uint8_t> ftb, psqb, fcb;
    if (!file_read(dir + sep + "ft.bin", ftb) ||
        !file_read(dir + sep + "psqt.bin", psqb) ||
        !file_read(dir + sep + "fc.bin", fcb)) {
        std::fprintf(stderr, "weight file open failed (need ft.bin/psqt.bin/fc.bin)\n");
        return 2;
    }
    std::fprintf(stderr, "ft=%zu psqt=%zu fc=%zu\n", ftb.size(), psqb.size(), fcb.size());
    if (ftb.size() != SMALL_FT_BYTES || psqb.size() != SMALL_PSQ_BYTES) {
        std::fprintf(stderr, "unexpected small-net sizes (ft=%zu/%zu psqt=%zu/%zu)\n",
                     ftb.size(), SMALL_FT_BYTES, psqb.size(), SMALL_PSQ_BYTES);
        return 2;
    }

    /* 2) ref 기대값 + FTLIST 파싱 */
    std::vector<Case> cases;
    {
        std::ifstream rfin(dir + sep + "ref.txt");
        if (!rfin) { std::fprintf(stderr, "ref.txt open failed\n"); return 2; }
        std::string refline;
        while (std::getline(rfin, refline)) {
            if (refline.empty()) continue;
            Case c;
            if (!parse_refline(refline, c)) { std::fprintf(stderr, "bad refline: %s\n", refline.c_str()); return 2; }
            std::string fl = dir + sep + "case_" + c.name + ".feat";
            if (!parse_ftlist(fl, c)) { std::fprintf(stderr, "FTLIST open failed: %s\n", fl.c_str()); return 2; }
            cases.push_back(std::move(c));
        }
    }
    std::fprintf(stderr, "cases=%zu\n", cases.size());
    if (cases.size() * 8 > 64) { std::fprintf(stderr, "too many submissions for ring\n"); return 2; }

    /* 3) 매핑 + 가중치 로드 */
    if (!map_all()) return 2;
    uint32_t ver = rd(NNUEHW_CSR_VERSION);
    std::fprintf(stderr, "window magic = 0x%08X %s\n", ver,
                 ver == NNUEHW_MAGIC ? "[OK]" : "[BAD]");
    if (ver != NNUEHW_MAGIC) return 2;

    {
        int fd = ::open("/dev/mem", O_RDWR | O_SYNC);
        if (fd < 0) { std::perror("open /dev/mem (DDR)"); return 2; }
        ft_ddr_ = mmap(nullptr, ftb.size(), PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, FT_DDR_PHYS);
        if (ft_ddr_ == MAP_FAILED) {
            std::perror("mmap FT DDR"); ::close(fd); ft_ddr_ = nullptr; return 2;
        }
        psq_ddr_ = mmap(nullptr, psqb.size(), PROT_READ | PROT_WRITE,
                        MAP_SHARED, fd, PSQ_DDR_PHYS);
        ::close(fd);
        if (psq_ddr_ == MAP_FAILED) {
            std::perror("mmap PSQT DDR"); psq_ddr_ = nullptr; return 2;
        }
    }
    if (!ddr_load(ft_ddr_, ftb.data(), ftb.size())) {
        std::fprintf(stderr, "FT DDR load FAIL\n"); return 2;
    }
    if (!ddr_load(psq_ddr_, psqb.data(), psqb.size())) {
        std::fprintf(stderr, "PSQT DDR load FAIL\n"); return 2;
    }
    std::fprintf(stderr, "FT/PSQT DDR loaded @0x%08X/0x%08X\n", FT_DDR_PHYS, PSQ_DDR_PHYS);

    if (fcb.size() > (1u << 15)) { std::fprintf(stderr, "FC too large\n"); return 2; }
    if (!fc_load(fcb.data(), fcb.size())) { std::fprintf(stderr, "FC load FAIL\n"); return 2; }
    std::fprintf(stderr, "FC loaded (%zu bytes)\n", fcb.size());

    /* 4) START */
    wr(NNUEHW_CSR_CONTROL, NNUEHW_CTRL_START);
    uint32_t st = rd(NNUEHW_CSR_STATUS);
    std::fprintf(stderr, "status after START = 0x%x (READY=%u BUSY=%u FAULT=%u)\n",
                 st, !!(st & NNUEHW_STAT_READY), !!(st & NNUEHW_STAT_BUSY), !!(st & NNUEHW_STAT_FAULT));

    /* 5) case x bucket 제출 및 비교 (모든 FEN 은 stm=WHITE → side=0) */
    int total = 0, pass = 0;
    for (size_t ci = 0; ci < cases.size(); ci++) {
        const Case& c = cases[ci];
        uint32_t base_ring = (uint32_t)(ci * 8);
        std::fprintf(stdout, "%s|", c.name.c_str());
        bool case_ok = true;
        for (int b = 0; b < 8; b++) {
            uint32_t seq = (uint32_t)(ci * 8 + b) + 1;
            if (!submit_bucket(seq, c, (uint32_t)b, 0, base_ring + (uint32_t)b)) {
                std::fprintf(stderr, "submit FAIL\n");
                return 2;
            }
        }
        *(volatile uint32_t*)(win_ + NNUEHW_CSR_DESC_HEAD / 4) = (base_ring + 8) & NNUEHW_DESC_MASK;
        rd(NNUEHW_CSR_DESC_HEAD); /* bus sync */
        std::fprintf(stderr,
                     "doorbell head=%u tail=%u result=%u status=0x%08X desc0=0x%08X\n",
                     rd(NNUEHW_CSR_DESC_HEAD), rd(NNUEHW_CSR_DESC_TAIL),
                     rd(NNUEHW_CSR_RESULT_HEAD), rd(NNUEHW_CSR_STATUS),
                     rd(NNUEHW_DESC_BASE));
        for (int b = 0; b < 8; b++) {
            uint32_t seq = (uint32_t)(ci * 8 + b) + 1;
            int psqt = 0, pos = 0;
            if (!poll_seq(seq, psqt, pos, 4000)) {
                std::fprintf(stderr,
                             "timeout state: head=%u tail=%u result=%u done=%u status=0x%08X irq=0x%08X\n",
                             rd(NNUEHW_CSR_DESC_HEAD), rd(NNUEHW_CSR_DESC_TAIL),
                             rd(NNUEHW_CSR_RESULT_HEAD), rd(NNUEHW_CSR_DONE),
                             rd(NNUEHW_CSR_STATUS), rd(NNUEHW_CSR_IRQ_STATUS));
                std::fprintf(stdout, "RAWVERIFY %d TIMEOUT ", b);
                case_ok = false;
                total++;
                continue;
            }
            int rp = psqt / 16, rq = pos / 16;
            bool ok = (rp == c.expect[b].first && rq == c.expect[b].second);
            total++;
            if (ok) pass++; else case_ok = false;
            std::fprintf(stdout, "RAWVERIFY %d %d %d [%d,%d] %s ",
                         b, rp, rq, c.expect[b].first, c.expect[b].second,
                         ok ? "OK" : "DIFF");
        }
        std::fprintf(stdout, "BUCKET %u %s\n", c.bucket_used, case_ok ? "PASS" : "FAIL");
        std::fflush(stdout);
    }

    std::fprintf(stdout, "RESULT: %d/%d PASS\n", pass, total);
    std::fflush(stdout);
    return (pass == total && total > 0) ? 0 : 1;
}
