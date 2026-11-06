// Host side of the F2SDRAM and CSR measurement (hw/quartus/board). Runs on the DE1-SoC under Linux
// booted with mem=768M, after U-Boot has run `bridge enable`. Talks to mem_probe through /dev/mem.
//
//   probe [csr|verify|sweep|all]   (default all)
//
// Correctness is the gate: the window is written with the pattern and read back sequentially and
// at random. If any read beat mismatches, the program reports BAD and does not report speed.
// Cycle counts come from the 100 MHz fabric clock; the program checks that rate against
// CLOCK_MONOTONIC before using it.
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define LW_BRIDGE 0xFF200000u
#define LW_SPAN 0x1000u
#define PROBE_ID 0x4D505231u

// The test window is the top quarter of the 1 GiB HPS SDRAM, which mem=768M keeps from Linux.
#define WIN_BYTE 0x30000000u
#define WIN_BYTES 0x10000000u
// Probe addresses count port beats: 8 bytes on a 64-bit port, 16 on a 128-bit one.
static uint32_t beat = 8;
#define WIN_WORD (WIN_BYTE / beat)
#define WIN_MASK (WIN_BYTES / beat - 1u)

// SDRAM controller FPGA port reset control (fpgaportrst, Cyclone V HPS TRM / socal alt_sdr.h):
// bits 3:0 read data ports, 7:4 write data ports, 13:8 command ports; 1 releases the port.
#define SDR_BASE 0xFFC25000u
#define SDR_FPGAPORTRST 0x80u

enum {
    R_ID = 0, R_CTRL, R_STATUS, R_BASE, R_MASK, R_BURST, R_MAX_OUT, R_COUNT, R_CYC_LO, R_CYC_HI,
    R_WAIT, R_BEATS, R_LAT_LO, R_LAT_HI, R_LAT_MIN, R_LAT_MAX, R_BAD, R_SEED, R_FREE, R_ISSUED,
    R_BAD_WORD, R_SCRATCH, R_WIDTH, R_HIST = 64
};
enum { MODE_SEQ_READ = 0, MODE_RAND_READ = 1, MODE_SEQ_WRITE = 2 };

static volatile uint32_t *csr;
static const double FCLK = 100e6;

static uint32_t rd(int r) { return csr[r]; }
static void wr(int r, uint32_t v) { csr[r] = v; }

static double now_s(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static void die(const char *msg) {
    fprintf(stderr, "FAIL: %s\n", msg);
    exit(1);
}

// Linux must not own any RAM inside the window.
static void check_window_free(void) {
    FILE *f = fopen("/proc/iomem", "r");
    if (!f) die("cannot read /proc/iomem");
    char line[256];
    int ok = 1, seen = 0;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == ' ' || !strstr(line, "System RAM")) continue;
        unsigned long lo, hi;
        if (sscanf(line, "%lx-%lx", &lo, &hi) != 2) continue;
        seen = 1;
        printf("iomem: System RAM %08lx-%08lx\n", lo, hi);
        if (hi >= WIN_BYTE && lo < WIN_BYTE + WIN_BYTES) ok = 0;
    }
    fclose(f);
    if (!seen) die("no System RAM line in /proc/iomem");
    if (!ok) die("Linux RAM overlaps the test window; boot with mem=768M");
}

struct result {
    uint64_t cycles, lat_sum;
    uint32_t wait, beats, lat_min, lat_max, bad, issued, bad_word;
    uint32_t hist[64];
    double host_s;
};

static int run(int mode, int verify, uint32_t burst, uint32_t max_out, uint32_t count, uint32_t seed,
               struct result *r) {
    if (rd(R_STATUS) & 1) die("probe busy before start");
    wr(R_BASE, WIN_WORD);
    wr(R_MASK, WIN_MASK);
    wr(R_BURST, burst);
    wr(R_MAX_OUT, max_out);
    wr(R_COUNT, count);
    wr(R_SEED, seed);
    const double t0 = now_s();
    wr(R_CTRL, 1u | ((uint32_t)mode << 2) | (verify ? 16u : 0u));
    uint32_t st;
    // A 256 MiB pass takes well under a second; 10 s means the port is stuck.
    while (((st = rd(R_STATUS)) & 3u) != 2u) {
        if (now_s() - t0 > 10.0) {
            wr(R_CTRL, 2u);  // abort
            fprintf(stderr, "timeout: status %u issued %u beats %u\n", st, rd(R_ISSUED), rd(R_BEATS));
            return -1;
        }
    }
    r->host_s = now_s() - t0;
    r->cycles = rd(R_CYC_LO) | ((uint64_t)rd(R_CYC_HI) << 32);
    r->lat_sum = rd(R_LAT_LO) | ((uint64_t)rd(R_LAT_HI) << 32);
    r->wait = rd(R_WAIT);
    r->beats = rd(R_BEATS);
    r->lat_min = rd(R_LAT_MIN);
    r->lat_max = rd(R_LAT_MAX);
    r->bad = rd(R_BAD);
    r->issued = rd(R_ISSUED);
    r->bad_word = rd(R_BAD_WORD);
    for (int i = 0; i < 64; i++) r->hist[i] = rd(R_HIST + i);
    if (r->issued != count) {
        fprintf(stderr, "issued %u of %u\n", r->issued, count);
        return -1;
    }
    if (r->beats != count * burst) {
        fprintf(stderr, "beats %u, expected %u\n", r->beats, count * burst);
        return -1;
    }
    return 0;
}

static double mbps(const struct result *r) { return r->beats * (double)beat / (r->cycles / FCLK) / 1e6; }

static void csr_test(void) {
    const uint32_t id = rd(R_ID);
    printf("ID %08x %s\n", id, id == PROBE_ID ? "ok" : "WRONG");
    if (id != PROBE_ID) die("probe ID mismatch; is the FPGA loaded and the bridge enabled?");
    int bad = 0;
    for (uint32_t i = 0; i < 1000; i++) {
        const uint32_t v = i * 0x9E3779B9u;
        wr(R_SCRATCH, v);
        if (rd(R_SCRATCH) != v) bad++;
    }
    printf("SCRATCH write/read 1000: %d mismatches\n", bad);
    if (bad) die("scratch mismatch");

    // Fabric clock rate against the ARM clock.
    const uint32_t f0 = rd(R_FREE);
    const double t0 = now_s();
    usleep(500000);
    const uint32_t f1 = rd(R_FREE);
    const double t1 = now_s();
    const double mhz = (uint32_t)(f1 - f0) / (t1 - t0) / 1e6;
    printf("fabric clock %.3f MHz (expected 100)\n", mhz);
    if (mhz < 99.0 || mhz > 101.0) die("fabric clock not 100 MHz; cycle-based numbers would be wrong");

    const int n = 100000;
    double t = now_s();
    for (int i = 0; i < n; i++) (void)rd(R_ID);
    const double read_ns = (now_s() - t) / n * 1e9;
    t = now_s();
    for (int i = 0; i < n; i++) wr(R_SCRATCH, (uint32_t)i);
    const double write_ns = (now_s() - t) / n * 1e9;
    t = now_s();
    for (int i = 0; i < n; i++) {
        wr(R_SCRATCH, (uint32_t)i);
        (void)rd(R_SCRATCH);
    }
    const double wr_rd_ns = (now_s() - t) / n * 1e9;
    printf("CSR read round trip   %.1f ns (mean of %d)\n", read_ns, n);
    printf("CSR write (posted)    %.1f ns (mean of %d)\n", write_ns, n);
    printf("CSR write+read        %.1f ns (mean of %d)\n", wr_rd_ns, n);
}

static void print_hist(const struct result *r) {
    printf("  latency histogram, 4 cycles (40 ns) per bin, last bin >= 252 cycles:\n");
    for (int i = 0; i < 64; i++)
        if (r->hist[i]) printf("    %3d-%3d cycles: %u\n", i * 4, i * 4 + 3, r->hist[i]);
}

// Returns 0 when the whole window reads back correctly.
static int verify_test(uint32_t seed) {
    struct result r;
    const uint32_t burst = 16, count = (WIN_MASK + 1) / burst;
    printf("write %u MiB at 0x%08x, burst %u\n", WIN_BYTES >> 20, WIN_BYTE, burst);
    if (run(MODE_SEQ_WRITE, 0, burst, 1, count, seed, &r)) die("write run failed");
    printf("  %.1f MB/s, %" PRIu64 " cycles, waitrequest %u cycles\n", mbps(&r), r.cycles, r.wait);
    int fail = 0;
    if (run(MODE_SEQ_READ, 1, burst, 8, count, seed, &r)) die("sequential read run failed");
    printf("sequential verify read: BAD %u", r.bad);
    if (r.bad) { printf(", first at byte 0x%08" PRIx64, (uint64_t)r.bad_word * beat); fail = 1; }
    printf("\n");
    // SEED sets both the data pattern and the LFSR start, so it must equal the write seed.
    if (run(MODE_RAND_READ, 1, 1, 8, 1u << 20, seed, &r)) die("random read run failed");
    printf("random verify read (1M beats): BAD %u\n", r.bad);
    if (r.bad) fail = 1;
    return fail;
}

static void sweep(uint32_t seed) {
    static const uint32_t bursts[] = {1, 2, 4, 8, 16};
    static const uint32_t outs[] = {1, 2, 4, 8, 16, 32};
    printf("\nCSV mode,burst,max_out,count,MBps,lat_min_ns,lat_mean_ns,lat_max_ns,wait_cycles,bad,host_ms\n");
    for (int mode = MODE_SEQ_READ; mode <= MODE_SEQ_WRITE; mode++) {
        for (unsigned b = 0; b < sizeof bursts / sizeof *bursts; b++) {
            for (unsigned o = 0; o < sizeof outs / sizeof *outs; o++) {
                if (mode == MODE_SEQ_WRITE && o) break;  // max_out applies to reads only
                const uint32_t burst = bursts[b], out = outs[o];
                // About 64 MiB per point.
                const uint32_t count = (64u << 20) / beat / burst;
                struct result r;
                // Writes rewrite the same pattern, so the window stays verifiable.
                if (run(mode, mode != MODE_SEQ_WRITE, burst, out, count, seed, &r)) die("sweep run failed");
                if (r.bad) {
                    printf("BAD %u at mode %d burst %u out %u: speed not reported\n", r.bad, mode, burst, out);
                    exit(1);
                }
                const char *name = mode == 0 ? "seq_read" : mode == 1 ? "rand_read" : "seq_write";
                if (mode == MODE_SEQ_WRITE)
                    printf("CSV %s,%u,-,%u,%.1f,-,-,-,%u,0,%.1f\n", name, burst, count, mbps(&r), r.wait,
                           r.host_s * 1e3);
                else
                    printf("CSV %s,%u,%u,%u,%.1f,%.0f,%.1f,%.0f,%u,0,%.1f\n", name, burst, out, count, mbps(&r),
                           r.lat_min * 10.0, (double)r.lat_sum / count * 10.0, r.lat_max * 10.0, r.wait,
                           r.host_s * 1e3);
                if ((burst == 1 && out == 1) || (burst == 16 && out == 32)) {
                    printf("  %s burst %u out %u\n", name, burst, out);
                    if (mode != MODE_SEQ_WRITE) print_hist(&r);
                }
            }
        }
    }
}

// probe [all|csr|verify] [--portrst VALUE]
//   --portrst writes fpgaportrst before testing, e.g. 0x133 for a 128-bit port (command port 0,
//   read and write data ports 0 and 1) when the boot loader released only 0x111.
int main(int argc, char **argv) {
    const char *what = "all";
    long portrst = -1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--portrst") && i + 1 < argc) portrst = strtol(argv[++i], NULL, 0);
        else what = argv[i];
    }
    const uint32_t seed = 0xA5A51234u;
    check_window_free();
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    void *p = mmap(NULL, LW_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, LW_BRIDGE);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }
    csr = (volatile uint32_t *)p;
    void *q = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, SDR_BASE);
    if (q == MAP_FAILED) { perror("mmap sdr"); return 1; }
    volatile uint32_t *sdr = (volatile uint32_t *)q;
    printf("fpgaportrst 0x%03x", sdr[SDR_FPGAPORTRST / 4] & 0x3fffu);
    if (portrst >= 0) {
        sdr[SDR_FPGAPORTRST / 4] = (uint32_t)portrst;
        printf(" -> wrote 0x%03lx, now 0x%03x", portrst, sdr[SDR_FPGAPORTRST / 4] & 0x3fffu);
    }
    printf("\n");

    csr_test();
    const uint32_t width = rd(R_WIDTH);
    beat = width == 128 ? 16 : 8;
    printf("port width %u bits (WIDTH register 0x%08x), %u bytes per beat\n", beat * 8, width, beat);
    if (!strcmp(what, "csr")) return 0;
    if (verify_test(seed)) {
        printf("RESULT: FAIL, read-back mismatches; no speed reported\n");
        return 1;
    }
    printf("RESULT: verify PASS (BAD 0)\n");
    if (!strcmp(what, "verify")) return 0;
    sweep(seed);
    printf("RESULT: sweep done, all runs BAD 0\n");
    return 0;
}
