// tb_fc.cpp - FC 파이프라인 검증 (Verilator)
//  FCBIN 가중치 1회 로드 + q(FTDMP) 1회 로드 후, 8개 bucket 순차 실행.
//  각 bucket 의 result(=POS) 와 fwd_out(=FWDOUT) 을 FCDUMP 참조와 대조.
//  인자: <FCBIN> <FTDMP> <FCDUMP>
//    FTDMP: "FTDMP <HD> <q0> ... <qN-1>"
//    FCDUMP: "B <b> FC0RAW ... FC1IN ... FC1RAW ... FC1ACT ... FC2RAW <v> FWDOUT <w> POS <p>"
#include "Vtop_fc.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <cstdlib>
#include <cstring>

static uint64_t tick = 0;
static VerilatedVcdC* tfp = nullptr;

static void cycle(Vtop_fc* top) {
  top->clk = 0; top->eval();
  top->clk = 1; top->eval();
  tick++;
  if (tfp) tfp->dump(tick);
}

static void negedge(Vtop_fc* top) {
  top->clk = 0; top->eval();
  if (tfp) tfp->dump(tick);
}

static void load_bytes(Vtop_fc* top, const char* path) {
  FILE* f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "open fail: %s\n", path); exit(1); }
  int c, addr = 0;
  while ((c = fgetc(f)) != EOF) {
    top->ld_we = 1; top->ld_addr = addr; top->ld_data = c & 0xFF;
    top->clk = 1; top->eval(); tick++;
    top->clk = 0; top->eval(); tick++;
    addr++;
  }
  fclose(f);
  top->ld_we = 0;
  fprintf(stderr, "FCBIN %s: %d bytes loaded\n", path, addr);
}

int main(int argc, char** argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: %s <FCBIN> <FTDMP> <FCDUMP>\n", argv[0]);
    return 1;
  }

  Verilated::commandArgs(argc, argv);
  Verilated::traceEverOn(true);
  Vtop_fc* top = new Vtop_fc;
  if (const char* vcd = getenv("VCD")) {
    tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open(vcd);
  }

  top->rst = 1; top->start = 0; top->bucket = 0;
  top->q_we = 0; top->q_addr = 0; top->q_data = 0;
  top->ld_we = 0; top->ld_addr = 0; top->ld_data = 0;
  for (int i = 0; i < 8; i++) cycle(top);
  top->rst = 0;
  negedge(top);

    load_bytes(top, argv[1]);

    char tag[16]; int HD;
  FILE* fq = fopen(argv[2], "r");
  if (!fq) { fprintf(stderr, "open fail: %s\n", argv[2]); exit(1); }
  if (fscanf(fq, " %15s %d", tag, &HD) != 2) { fprintf(stderr, "FTDMP parse fail\n"); exit(1); }
  std::vector<int> q(HD);
  for (int i = 0; i < HD; i++)
    if (fscanf(fq, " %d", &q[i]) != 1) { fprintf(stderr, "FTDMP data fail\n"); exit(1); }
  fclose(fq);
  negedge(top);
  for (int i = 0; i < HD; i++) {
    top->q_we = 1; top->q_addr = i; top->q_data = q[i] & 0xFF;
    top->clk = 1; top->eval(); tick++;
    top->clk = 0; top->eval(); tick++;
  }
  top->q_we = 0;
  fprintf(stderr, "FTDMP %s: HD=%d q loaded\n", argv[2], HD);

    struct Ref { int fc2raw, fwdout, pos; };
  std::vector<Ref> ref(8);
  FILE* fr = fopen(argv[3], "r");
  if (!fr) { fprintf(stderr, "open fail: %s\n", argv[3]); exit(1); }
  for (int b = 0; b < 8; b++) {
    int rb, x;
    if (fscanf(fr, " B %d FC0RAW", &rb) != 1) { fprintf(stderr, "FCDUMP B%d parse fail\n", b); exit(1); }
    for (int i = 0; i < 16; i++) fscanf(fr, " %d", &x);
    char fc1in[16];
    fscanf(fr, " %15s", fc1in);   // FC1IN
    for (int i = 0; i < 30; i++) fscanf(fr, " %d", &x);
    char fc1raw[16];
    fscanf(fr, " %15s", fc1raw);  // FC1RAW
    for (int i = 0; i < 32; i++) fscanf(fr, " %d", &x);
    char fc1act[16];
    fscanf(fr, " %15s", fc1act);  // FC1ACT
    for (int i = 0; i < 32; i++) fscanf(fr, " %d", &x);
    char fc2raw[16], fwd[16], pos[16];
    fscanf(fr, " %15s %d %15s %d %15s %d", fc2raw, &ref[b].fc2raw, fwd, &ref[b].fwdout, pos, &ref[b].pos);
  }
  fclose(fr);

    int fail = 0;
  for (int b = 0; b < 8; b++) {
    top->bucket = b;
    for (int i = 0; i < 4; i++) cycle(top);
    top->start = 1;
    cycle(top);
    top->start = 0;
        int timeout = 1000000;
    while (!top->done && timeout-- > 0) cycle(top);
    if (!top->done) { fprintf(stderr, "B%d timeout\n", b); fail++; continue; }
            int r = (int)top->result;
    int fw = (int)top->fwd_out;
    int ok = (r == ref[b].pos) && (fw == ref[b].fwdout);
    fprintf(stderr, "B%d result=%d ref=%d fwd=%d reffwd=%d %s\n",
            b, r, ref[b].pos, fw, ref[b].fwdout, ok ? "OK" : "FAIL");
    if (!ok) fail++;
        cycle(top);
  }

  fprintf(stderr, "%s\n", fail ? "FC FAIL" : "FC ALL PASS");
  return fail ? 1 : 0;
}