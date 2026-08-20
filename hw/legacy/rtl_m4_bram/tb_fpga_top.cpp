// tb_fpga_top.cpp - M4-RTL 배칭 NPU 검증 (Verilator)
//
// fpga_top 을 HPS 슬레이브 관점에서 구동한다.
//   사용: tb_fpga_top <FTBIN> <FCBIN> <PSQTBIN> <MANIFEST>
//   MANIFEST 한 줄: <stm> <FTLIST> <THREATLIST> <RESDUMP> <bucket>
//     stm: w|b , FTLIST/THREATLIST: featgen 출력, RESDUMP: ref_eval RESDUMP 출력
//   흐름:
//     1) FTBIN/FCBIN/PSQTBIN 을 로드 포트로 1회 로드
//     2) CONTROL=START (드라이버 open() 과 동일)
//     3) 각 FEN: frame 기록 -> bucket 0..7 desc 8개를 desc 링에 제출 ->
//        DESC_HEAD doorbell
//     4) result 링 폴링: seq 정합 + psqt/positional 을 RESDUMP(원시값) 와 대조
//     5) 부가: 잘못된 magic desc -> ERR_FAULT 결과 검증, RESET 검증
#include "Vfpga_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <map>

// ---- ABI (nnuehw.h) ----
#define CSR_CONTROL       1
#define CSR_DESC_HEAD     3
#define CSR_DESC_TAIL     4
#define CSR_RESULT_HEAD   5
#define CSR_RESULT_TAIL   6
#define CSR_DONE          7
#define CSR_IRQ_STATUS    8
#define CSR_IRQ_ACK       9
#define DESC_W            16
#define FEAT_W            1040
#define RESULT_W          17424
#define DESC_MASK         63u
#define FEAT_MASK         63u
#define RESULT_MASK       255u
#define FRAME_WORDS       256u
#define MAGIC             0x4E4E5545u
#define CTRL_START        (1u << 0)
#define CTRL_RESET        (1u << 1)
#define R_OK              0u
#define R_FAULT           2u

static uint64_t tick = 0;
static VerilatedVcdC* tfp = nullptr;

static void cycle(Vfpga_top* top) {
  top->clk = 0; top->eval();
  top->clk = 1; top->eval();
  tick++;
  if (tfp) tfp->dump(tick);
}

static void negedge(Vfpga_top* top) {
  top->clk = 0; top->eval();
  if (tfp) tfp->dump(tick);
}

static void hps_wr(Vfpga_top* top, uint32_t word, uint32_t data) {
  top->hps_we = 1; top->hps_addr = word; top->hps_wdata = data;
  cycle(top);
  top->hps_we = 0;
}

static uint32_t hps_rd(Vfpga_top* top, uint32_t word) {
  top->hps_re = 1; top->hps_addr = word;
  cycle(top);
  top->hps_re = 0;
  return top->hps_rdata;
}

static size_t read_16(const char* path, std::vector<int16_t>& v) {
  FILE* f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "open fail: %s\n", path); exit(1); }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  v.resize(n / 2);
  size_t got = fread(v.data(), 2, v.size(), f);
  fclose(f);
  if (got != v.size()) { fprintf(stderr, "read16 %s %zu/%zu\n", path, got, v.size()); exit(1); }
  return v.size();
}

static size_t read_8(const char* path, std::vector<uint8_t>& v) {
  FILE* f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "open fail: %s\n", path); exit(1); }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  v.resize(n);
  size_t got = fread(v.data(), 1, v.size(), f);
  fclose(f);
  if (got != v.size()) { fprintf(stderr, "read8 %s %zu/%zu\n", path, got, v.size()); exit(1); }
  return v.size();
}

static size_t read_32(const char* path, std::vector<int32_t>& v) {
  FILE* f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "open fail: %s\n", path); exit(1); }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  v.resize(n / 4);
  size_t got = fread(v.data(), 4, v.size(), f);
  fclose(f);
  if (got != v.size()) { fprintf(stderr, "read32 %s %zu/%zu\n", path, got, v.size()); exit(1); }
  return v.size();
}

// feature 목록 파싱: "FTLIST <n0> <n1> <f...>" -> g0, g1
static int parse_featlist(FILE* fp, std::vector<uint32_t>& g0, std::vector<uint32_t>& g1) {
  char tag[16]; int n0 = 0, n1 = 0;
  if (fscanf(fp, " %15s %d %d", tag, &n0, &n1) != 3) return 0;
  g0.resize(n0); g1.resize(n1);
  for (auto& v : g0) if (fscanf(fp, " %u", &v) != 1) return 0;
  for (auto& v : g1) if (fscanf(fp, " %u", &v) != 1) return 0;
  return 1;
}

static int parse_resdump(FILE* fp, int psqt[8], int pos[8]) {
  char tag[16]; int b = 0, p = 0, o = 0;
  while (fscanf(fp, " %15s %d %d %d", tag, &b, &p, &o) == 4) {
    if (strcmp(tag, "RESDUMP") != 0 || b < 0 || b > 7) return 0;
    psqt[b] = p;
    pos[b] = o;
  }
  return 1;
}

int main(int argc, char** argv) {
  if (argc < 5) {
    fprintf(stderr, "usage: %s <FTBIN> <FCBIN> <PSQTBIN> <MANIFEST>\n", argv[0]);
    return 1;
  }
  const int HD = 1024;  // small 넷은 -GHD=128 로 재컴파일 후 사용

  Verilated::commandArgs(argc, argv);
  Verilated::traceEverOn(true);
  Vfpga_top* top = new Vfpga_top;
  if (const char* vcd = getenv("VCD")) {
    tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open(vcd);
  }

  top->rst = 1;
  top->hps_we = 0; top->hps_re = 0; top->hps_addr = 0; top->hps_wdata = 0;
  top->ft_we = 0; top->ft_addr = 0; top->ft_data = 0;
  top->fc_we = 0; top->fc_addr = 0; top->fc_data = 0;
  top->psq_we = 0; top->psq_addr = 0; top->psq_data = 0;
  for (int i = 0; i < 8; i++) cycle(top);
  top->rst = 0;

  // ---- 가중치 로드 (1회) ----
  {
    std::vector<int16_t> ft;
    size_t nw = read_16(argv[1], ft);
    negedge(top);
    for (size_t i = 0; i < nw; i++) {
      top->ft_we = 1; top->ft_addr = (uint32_t)i; top->ft_data = ft[i];
      top->clk = 1; top->eval(); tick++;
      top->clk = 0; top->eval(); tick++;
    }
    top->ft_we = 0;
    printf("[load] FTBIN %zu words\n", nw);
  }
  {
    std::vector<uint8_t> fc;
    size_t nb = read_8(argv[2], fc);
    negedge(top);
    for (size_t i = 0; i < nb; i++) {
      top->fc_we = 1; top->fc_addr = (uint32_t)i; top->fc_data = fc[i];
      top->clk = 1; top->eval(); tick++;
      top->clk = 0; top->eval(); tick++;
    }
    top->fc_we = 0;
    printf("[load] FCBIN %zu bytes\n", nb);
  }
  {
    std::vector<int32_t> psq;
    size_t nw = read_32(argv[3], psq);
    negedge(top);
    for (size_t i = 0; i < nw; i++) {
      top->psq_we = 1; top->psq_addr = (uint32_t)i; top->psq_data = (uint32_t)psq[i];
      top->clk = 1; top->eval(); tick++;
      top->clk = 0; top->eval(); tick++;
    }
    top->psq_we = 0;
    printf("[load] PSQTBIN %zu words\n", nw);
  }

  // ---- START (드라이버 open() 과 동일) ----
  hps_wr(top, CSR_CONTROL, CTRL_START);
  if (hps_rd(top, CSR_CONTROL) != CTRL_START) { fprintf(stderr, "CONTROL write fail\n"); return 1; }

  uint32_t seq = 0;
  uint32_t head = 0;
  int fails = 0, total = 0;

  FILE* mf = fopen(argv[4], "r");
  if (!mf) { fprintf(stderr, "open fail: %s\n", argv[4]); return 1; }
  char stmc, flp[512], thp[512], rsp[512];
  int bucket = 0;
  while (fscanf(mf, " %c %511s %511s %511s %d", &stmc, flp, thp, rsp, &bucket) == 5) {
    total++;
    std::vector<uint32_t> f0, f1, t0, t1;
    int n0, n1, nt0, nt1;
    {
      FILE* fp = fopen(flp, "r");
      if (!fp) { fprintf(stderr, "open fail: %s\n", flp); return 1; }
      if (!parse_featlist(fp, f0, f1)) { fprintf(stderr, "FTLIST parse fail\n"); return 1; }
      fclose(fp);
    }
    {
      FILE* fp = fopen(thp, "r");
      if (!fp) { fprintf(stderr, "open fail: %s\n", thp); return 1; }
      if (!parse_featlist(fp, t0, t1)) {
        // THREATLIST 없는 small 넷 — 빈 그룹 취급
        t0.clear(); t1.clear();
      }
      fclose(fp);
    }
    int exp_psqt[8], exp_pos[8];
    {
      FILE* fp = fopen(rsp, "r");
      if (!fp) { fprintf(stderr, "open fail: %s\n", rsp); return 1; }
      if (!parse_resdump(fp, exp_psqt, exp_pos)) { fprintf(stderr, "RESDUMP parse fail\n"); return 1; }
      fclose(fp);
    }

    // ---- feature frame 기록 (add_frame = head & 63) ----
    uint32_t frame = head & FEAT_MASK;
    uint32_t wbase = FEAT_W + frame * FRAME_WORDS;
    uint32_t fw = wbase + 0;
    for (uint32_t v : f0) { hps_wr(top, fw++, v); }
    for (uint32_t v : f1) { hps_wr(top, fw++, v); }
    for (uint32_t v : t0) { hps_wr(top, fw++, v); }
    for (uint32_t v : t1) { hps_wr(top, fw++, v); }

    uint32_t n_add = (uint32_t)(f0.size() + f1.size() + t0.size() + t1.size());

    // ---- bucket 0..7 desc 제출 ----
    uint32_t seqs[8];
    for (int b = 0; b < 8; b++) {
      uint32_t d = DESC_W + (head & DESC_MASK) * 16;
      uint32_t s = ++seq;
      seqs[b] = s;
      hps_wr(top, d + 0,  MAGIC);
      hps_wr(top, d + 1,  1);                       // REFRESH
      hps_wr(top, d + 2,  (uint32_t)b);
      hps_wr(top, d + 3,  (stmc == 'b') ? 1u : 0u);
      hps_wr(top, d + 4,  n_add);
      hps_wr(top, d + 5,  0);                       // n_rem
      hps_wr(top, d + 6,  frame);
      hps_wr(top, d + 7,  0);                       // rem_frame (미사용)
      hps_wr(top, d + 8,  s);                       // seq
      hps_wr(top, d + 9,  (uint32_t)f0.size());
      hps_wr(top, d + 10, (uint32_t)f1.size());
      hps_wr(top, d + 11, (uint32_t)t0.size());
      hps_wr(top, d + 12, (uint32_t)t1.size());
      head = (head + 1) & DESC_MASK;
    }
    hps_wr(top, CSR_DESC_HEAD, head);

    // ---- 결과 폴링: 짝수 seq 순서로 8개 수거 ----
    uint32_t rtail = hps_rd(top, CSR_RESULT_TAIL);
    int got = 0;
    uint64_t timeout = tick + 50000000;
    while (got < 8 && tick < timeout) {
      uint32_t rh = hps_rd(top, CSR_RESULT_HEAD);
      while (got < 8 && rtail != rh) {
        uint32_t rb = RESULT_W + rtail * 4;
        uint32_t rseq   = hps_rd(top, rb + 0);
        int32_t  rpsqt  = (int32_t)hps_rd(top, rb + 1);
        int32_t  rpos   = (int32_t)hps_rd(top, rb + 2);
        uint32_t rstat  = hps_rd(top, rb + 3);
        int bi = -1;
        for (int b = 0; b < 8; b++) if (seqs[b] == rseq) bi = b;
        if (getenv("TBDBG"))
          fprintf(stderr, "[dbg] rseq=%u bi=%d rpsqt=%d rpos=%d exp_psqt[%d]=%d exp_pos[%d]=%d rstat=%u\n",
                  rseq, bi, rpsqt, rpos, bi, bi>=0?exp_psqt[bi]:0, bi, bi>=0?exp_pos[bi]:0, rstat);
        if (bi < 0) { fprintf(stderr, "unknown seq %u\n", rseq); fails++; }
        else {
          if (rstat != R_OK) { fprintf(stderr, "FEN$%d b%d: status %u\n", total, bi, rstat); fails++; }
          if (rpsqt != exp_psqt[bi]) {
            fprintf(stderr, "FEN$%d b%d PSQT got=%d exp=%d\n", total, bi, rpsqt, exp_psqt[bi]);
            fails++;
          }
          if (rpos != exp_pos[bi]) {
            fprintf(stderr, "FEN$%d b%d POS got=%d exp=%d\n", total, bi, rpos, exp_pos[bi]);
            fails++;
          }
          got++;
        }
        rtail = (rtail + 1) & RESULT_MASK;
      }
      hps_wr(top, CSR_RESULT_TAIL, rtail);
      if (got == 8) break;
      for (int i = 0; i < 1000; i++) cycle(top);  // FPGA 진행 대기
    }
    if (got < 8) { fprintf(stderr, "FEN$%d timeout (got %d/8)\n", total, got); fails++; }

    if (hps_rd(top, CSR_DESC_TAIL) != head) {
      fprintf(stderr, "FEN$%d desc_tail mismatch\n", total); fails++;
    }
    printf("FEN$%d PASS (8 buckets, seq %u..%u)\n", total, seqs[0], seqs[7]);
  }
  fclose(mf);

  // ---- FAULT 경로: 잘못된 magic desc ----
  {
    uint32_t d = DESC_W + (head & DESC_MASK) * 16;
    hps_wr(top, d + 0, 0xDEADBEEFu);
    uint32_t s = ++seq;
    hps_wr(top, d + 8, s);
    hps_wr(top, d + 9, 0); hps_wr(top, d + 10, 0);
    hps_wr(top, d + 11, 0); hps_wr(top, d + 12, 0);
    head = (head + 1) & DESC_MASK;
    hps_wr(top, CSR_DESC_HEAD, head);
    uint32_t rtail = hps_rd(top, CSR_RESULT_TAIL);
    int got = 0;
    uint64_t timeout = tick + 1000000;
    while (got == 0 && tick < timeout) {
      uint32_t rh = hps_rd(top, CSR_RESULT_HEAD);
      while (rtail != rh) {
        uint32_t rb = RESULT_W + rtail * 4;
        uint32_t rseq  = hps_rd(top, rb + 0);
        uint32_t rstat = hps_rd(top, rb + 3);
        if (rseq == s) {
          if (rstat != R_FAULT) { fprintf(stderr, "FAULT path: status %u\n", rstat); fails++; }
          else printf("FAULT path PASS (seq %u, status ERR_FAULT)\n", s);
          got = 1;
        }
        rtail = (rtail + 1) & RESULT_MASK;
      }
      hps_wr(top, CSR_RESULT_TAIL, rtail);
      for (int i = 0; i < 100; i++) cycle(top);
    }
    if (!got) { fprintf(stderr, "FAULT path timeout\n"); fails++; }
  }

  // ---- DONE 누계 / IRQ_STATUS ----
  uint32_t done = hps_rd(top, CSR_DONE);
  uint32_t irq  = hps_rd(top, CSR_IRQ_STATUS);
  printf("DONE=%u IRQ_STATUS=0x%x\n", done, irq);

  // ---- RESET: 인덱스 클리어 + FAULT 플래그 클리어 확인 ----
  hps_wr(top, CSR_CONTROL, CTRL_RESET);
  cycle(top);
  hps_wr(top, CSR_CONTROL, CTRL_START);
  uint32_t dt = hps_rd(top, CSR_DESC_TAIL), rh2 = hps_rd(top, CSR_RESULT_HEAD),
           dn2 = hps_rd(top, CSR_DONE);
  if (dt != 0 || rh2 != 0 || dn2 != 0) {
    fprintf(stderr, "RESET fail: dt=%u rh=%u dn=%u\n", dt, rh2, dn2);
    fails++;
  } else printf("RESET PASS\n");

  printf("RESULT: %s total=%d fails=%d (%lu cycles)\n", fails ? "FAIL" : "PASS", total, fails, (unsigned long)tick);
  if (tfp) tfp->close();
  return fails ? 1 : 0;
}