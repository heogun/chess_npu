// tb_fte_full.cpp - M2 실데이터 검증 (Verilator)
//  1) FTBIN(스칼라 x2 스케일 적용본)을 weight_bram 에 로드
//  2) FTLIST(active feature 리스트)를 FIFO 로 푸시 후 start
//  3) q[0..HD-1] 스트림을 FTDMP 참조와 대조
// 인자: <FTBIN> <FTLIST> <FTDMP>
#include "Vtop_fte.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <cstdlib>

static uint64_t tick = 0;

static void cycle(Vtop_fte* top) {
  top->clk = 0; top->eval();
  top->clk = 1; top->eval();
  tick++;
}

static void negedge(Vtop_fte* top) {
  top->clk = 0; top->eval();
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

int main(int argc, char** argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: %s <FTBIN> <FTLIST> <FTDMP>\n", argv[0]);
    return 1;
  }
  const int HD = 128, NF = 22528;
  const size_t FTBIN_WORDS = size_t(HD) + size_t(NF) * HD;

  Verilated::commandArgs(argc, argv);
  Vtop_fte* top = new Vtop_fte;

  top->rst = 1; top->start = 0; top->stm = 0;
  top->cnt0 = 0; top->cnt1 = 0;
  top->feat_valid = 0; top->feat = 0;
  top->ld_we = 0; top->ld_addr = 0; top->ld_data = 0;
  for (int i = 0; i < 8; i++) cycle(top);
  top->rst = 0;

  // ---- 1) FTBIN 로드 (addr: bias HD, feature f = HD + f*HD) ----
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

  // ---- 2) FTLIST 파싱: "FTLIST <n0> <n1> <feat0...> <feat1...>" ----
  FILE* fl = fopen(argv[2], "r");
  if (!fl) { fprintf(stderr, "open fail: %s\n", argv[2]); return 1; }
  int n0 = 0, n1 = 0;
  if (fscanf(fl, " FTLIST %d %d", &n0, &n1) != 2) {
    fprintf(stderr, "FTLIST header parse fail\n"); return 1;
  }
  std::vector<uint32_t> f0(n0), f1(n1);
  for (auto& v : f0) if (fscanf(fl, " %u", &v) != 1) return 1;
  for (auto& v : f1) if (fscanf(fl, " %u", &v) != 1) return 1;
  fclose(fl);
  printf("[feat] n0=%d n1=%d\n", n0, n1);

  // ---- 3) feature 푸시 + start ----
  negedge(top);
  for (auto v : f0) { top->feat_valid = 1; top->feat = v; top->clk = 1; top->eval(); tick++; top->clk = 0; top->eval(); tick++; }
  for (auto v : f1) { top->feat_valid = 1; top->feat = v; top->clk = 1; top->eval(); tick++; top->clk = 0; top->eval(); tick++; }
  top->feat_valid = 0;
  if (argc >= 5) top->stm = (argv[4][0] == 'b'); else top->stm = 0;
  top->cnt0 = n0; top->cnt1 = n1;
  top->start = 1; top->clk = 1; top->eval(); tick++; top->start = 0; top->clk = 0; top->eval(); tick++;

  // ---- 4) done 대기 + q 수집 ----
  std::vector<int> q(HD, -1);
  uint64_t timeout = tick + 1000000;
  while (!top->done && tick < timeout) {
    if (top->q_valid) {
      int idx = top->q_index;
      if (idx < 0 || idx >= HD) { fprintf(stderr, "bad q_index %d\n", idx); return 1; }
      q[idx] = top->q_data;
    }
    cycle(top);
  }
  if (top->done) cycle(top);
  for (int i = 0; i < HD; i++)
    if (q[i] < 0) { fprintf(stderr, "missing q[%d]\n", i); return 1; }

  // ---- 5) FTDMP 대조 ----
  FILE* fd = fopen(argv[3], "r");
  if (!fd) { fprintf(stderr, "open fail: %s\n", argv[3]); return 1; }
  int hd = 0, fails = 0;
  if (fscanf(fd, " FTDMP %d", &hd) != 1 || hd != HD) { fprintf(stderr, "FTDMP header parse fail\n"); return 1; }
  for (int i = 0; i < HD; i++) {
    int exp = -1;
    if (fscanf(fd, " %d", &exp) != 1) { fprintf(stderr, "FTDMP body parse fail\n"); return 1; }
    if (exp != q[i]) {
      if (fails < 10) fprintf(stderr, "MISMATCH q[%d] got=%d exp=%d\n", i, q[i], exp);
      fails++;
    }
  }
  fclose(fd);
  if (const char* rq = getenv("RTLQ")) {
    FILE* f = fopen(rq, "w");
    if (f) {
      fprintf(f, "FTDMP %d", HD);
      for (int i = 0; i < HD; i++) fprintf(f, " %d", q[i]);
      fprintf(f, "\n");
      fclose(f);
    }
  }
  printf("%s: hd=%d fails=%d (%lu cycles)\n", fails ? "FAIL" : "PASS", hd, fails, (unsigned long)tick);
  return fails ? 1 : 0;
}
