// tb_fte_big.cpp - big net transform 검증 (Verilator, 배치)
//  FTBIN(big: bias+main+threat weights) 을 1회 로드 후 매니페스트의 각 FEN 을
//  순차 실행, q[0..HD-1] 를 FTDMP 참조와 대조.
//  인자: <FTBIN> <MANIFEST>
//  MANIFEST 한 줄: <stm> <FTLIST> <THREATLIST> <FTDMP>
#include "Vtop_fte.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <cstdlib>
#include <cstring>

static uint64_t tick = 0;
static VerilatedVcdC* tfp = nullptr;

static void cycle(Vtop_fte* top) {
  top->clk = 0; top->eval();
  top->clk = 1; top->eval();
  tick++;
  if (tfp) tfp->dump(tick);
}

static void negedge(Vtop_fte* top) {
  top->clk = 0; top->eval();
  if (tfp) tfp->dump(tick);
}

static std::vector<int16_t> read_file(const char* path, size_t expect_words) {
  FILE* f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "open fail: %s\n", path); exit(1); }
  std::vector<int16_t> v(expect_words);
  size_t got = fread(v.data(), 2, expect_words, f);
  fclose(f);
  if (got != expect_words) {
    fprintf(stderr, "read %s: %zu/%zu words\n", path, got, expect_words);
    exit(1);
  }
  return v;
}

static int parse_intlist(FILE* fp, int& n0, int& n1,
                         std::vector<uint32_t>& a, std::vector<uint32_t>& b) {
  char tag[16];
  if (fscanf(fp, " %15s %d %d", tag, &n0, &n1) != 3) return 0;
  a.resize(n0); b.resize(n1);
  for (auto& v : a) if (fscanf(fp, " %u", &v) != 1) return 0;
  for (auto& v : b) if (fscanf(fp, " %u", &v) != 1) return 0;
  return 1;
}

int main(int argc, char** argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <FTBIN> <MANIFEST>\n", argv[0]);
    return 1;
  }
  const int HD = 1024, NF = 22528, TFF = 79856;
  const size_t FTBIN_WORDS = size_t(HD) + size_t(NF + TFF) * HD;

  Verilated::commandArgs(argc, argv);
  Verilated::traceEverOn(true);
  Vtop_fte* top = new Vtop_fte;
  if (const char* vcd = getenv("VCD")) {
    tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open(vcd);
  }

  top->rst = 1; top->start = 0; top->use_big = 1; top->stm = 0;
  top->cnt0 = 0; top->cnt1 = 0; top->cntt0 = 0; top->cntt1 = 0;
  top->feat_valid = 0; top->feat = 0;
  top->ld_we = 0; top->ld_addr = 0; top->ld_data = 0;
  for (int i = 0; i < 8; i++) cycle(top);
  top->rst = 0;

  // ---- 1) FTBIN 로드 (1회; addr: bias, main f = HD + f*HD, thr 는 이어서) ----
  auto bin = read_file(argv[1], FTBIN_WORDS);
  negedge(top);
  for (size_t i = 0; i < FTBIN_WORDS; i++) {
    top->ld_we = 1;
    top->ld_addr = i;
    top->ld_data = bin[i];
    top->clk = 1; top->eval(); tick++;
    top->clk = 0; top->eval(); tick++;
  }
  top->ld_we = 0;
  printf("[load] %zu words done (%lu cycles)\n", FTBIN_WORDS, (unsigned long)tick);

  // ---- 2) 매니페스트 실행 ----
  FILE* mf = fopen(argv[2], "r");
  if (!mf) { fprintf(stderr, "open fail: %s\n", argv[2]); return 1; }
  char ftl[512], thrl[512], ftd[512], stmc;
  int total = 0, fails = 0;
  while (fscanf(mf, " %c %511s %511s %511s", &stmc, ftl, thrl, ftd) == 4) {
    total++;
    std::vector<uint32_t> f0, f1, t0, t1;
    int n0, n1, nt0, nt1;
    int hd = 0;
    {
      FILE* fp = fopen(ftl, "r");
      if (!fp) { fprintf(stderr, "open fail: %s\n", ftl); return 1; }
      if (!parse_intlist(fp, n0, n1, f0, f1)) { fprintf(stderr, "FTLIST parse fail: %s\n", ftl); return 1; }
      fclose(fp);
    }
    {
      FILE* fp = fopen(thrl, "r");
      if (!fp) { fprintf(stderr, "open fail: %s\n", thrl); return 1; }
      if (!parse_intlist(fp, nt0, nt1, t0, t1)) { fprintf(stderr, "THREATLIST parse fail: %s\n", thrl); return 1; }
      fclose(fp);
    }
    fprintf(stderr, "[feat] n0=%d n1=%d t0=%d t1=%d\n", n0, n1, nt0, nt1);

    // ---- FEN 별 리셋 + feature 푸시 + start ----
    top->rst = 1;
    for (int i = 0; i < 4; i++) cycle(top);
    top->rst = 0;
    top->feat_valid = 0; top->feat = 0;
    for (int i = 0; i < 4; i++) cycle(top);
    negedge(top);
    auto push = [&](const std::vector<uint32_t>& v) {
      for (auto x : v) {
        top->feat_valid = 1; top->feat = x;
        top->clk = 1; top->eval(); tick++;
        top->clk = 0; top->eval(); tick++;
      }
    };
    push(f0); push(f1); push(t0); push(t1);
    top->feat_valid = 0;
    top->stm = (stmc == 'b');
    top->cnt0 = n0; top->cnt1 = n1; top->cntt0 = nt0; top->cntt1 = nt1;
    top->start = 1; top->clk = 1; top->eval(); tick++; top->start = 0; top->clk = 0; top->eval(); tick++;

    std::vector<int> q(HD, -1);
    uint64_t timeout = tick + 40000000;
    while (!top->done && tick < timeout) {
      if (top->q_valid) {
        int idx = top->q_index;
        if (idx < 0 || idx >= HD) { fprintf(stderr, "bad q_index %d\n", idx); return 1; }
        q[idx] = top->q_data;
      }
      cycle(top);
    }
    if (top->done) cycle(top);
    int miss = 0;
    for (int i = 0; i < HD; i++)
      if (q[i] < 0) miss++;

    FILE* fd = fopen(ftd, "r");
    if (!fd) { fprintf(stderr, "open fail: %s\n", ftd); return 1; }
    if (fscanf(fd, " FTDMP %d", &hd) != 1 || hd != HD) { fprintf(stderr, "FTDMP header parse fail\n"); return 1; }
    int ff = 0;
    for (int i = 0; i < HD; i++) {
      int exp = -1;
      if (fscanf(fd, " %d", &exp) != 1) { fprintf(stderr, "FTDMP body parse fail\n"); return 1; }
      if (exp != q[i]) {
        if (ff < 10) fprintf(stderr, "MISMATCH q[%d] got=%d exp=%d\n", i, q[i], exp);
        ff++;
      }
    }
    fclose(fd);
    if (ff || miss) {
      fails++;
      fprintf(stderr, "FEN FAIL: miss=%d mism=%d\n", miss, ff);
    } else {
      printf("PASS %s\n", ftl);
    }
    if (const char* rq = getenv("RTLQ")) {
      FILE* f = fopen(rq, "w");
      if (f) {
        fprintf(f, "FTDMP %d", HD);
        for (int i = 0; i < HD; ++i) fprintf(f, " %d", q[i]);
        fprintf(f, "\n");
        fclose(f);
      }
    }
    if (const char* da = getenv("DUMPACC")) {
      FILE* f = fopen(da, "w");
      if (f) {
        for (int i = 0; i < 2 * HD; ++i) {
          top->dbg_rd_req = 1;
          top->dbg_rd_addr = i;
          cycle(top);
          fprintf(f, "%d %d %d\n", i, (int32_t)top->dbg_acc_rd2_data, (int32_t)top->dbg_thr_rd2_data);
        }
        top->dbg_rd_req = 0;
        fclose(f);
      }
    }
  }
  fclose(mf);
  printf("RESULT: %s total=%d fails=%d (%lu cycles)\n", fails ? "FAIL" : "PASS", total, fails, (unsigned long)tick);
  if (tfp) tfp->close();
  return fails ? 1 : 0;
}