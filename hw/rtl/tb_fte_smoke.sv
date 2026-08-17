// tb_fte_smoke.sv - FTE 상태 머신 스모크 테스트 (iverilog)
//
// feature 없는 최소 케이스: bias 만 복사 -> quantize. 기대값:
//   q[j]        = clamp(bias[j]  ,0,254) * clamp(bias[j+64],0,254) >> 9  (j<64)
//   q[64+j]     = 동일 (perspectives 둘 다 같은 bias 로 초기화)
// bias 값: bias[j] = j*3 - 100 (int16 범위 내, 음수/양수/256 초과 혼합)
module tb_fte_smoke;
  localparam int HD = 128;
  localparam int ADDR_W = 22;
  localparam int NF = 22528;

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic       start, stm, use_big;
  logic [31:0] cnt0, cnt1, cntt0, cntt1;
  logic       feat_valid, feat_ready;
  logic [31:0] feat;
  logic [ADDR_W-1:0] wb_addr;
  logic [15:0] wb_data;
  logic       acc_rd_req, acc_wr_we;
  logic [10:0] acc_rd_addr, acc_wr_addr;
  logic [31:0] acc_rd_data, acc_wr_data;
  logic       thr_rd_req, thr_wr_we;
  logic [10:0] thr_rd_addr, thr_wr_addr;
  logic [31:0] thr_rd_data, thr_wr_data;
  logic       q_valid, done;
  logic [7:0] q_index, q_data;

  fte #(.HD(HD), .NF(NF), .ADDR_W(ADDR_W)) u_fte (
    .clk(clk), .rst(rst), .start(start), .use_big(use_big), .stm(stm),
    .cnt0(cnt0), .cnt1(cnt1), .cntt0(cntt0), .cntt1(cntt1),
    .feat_valid(feat_valid), .feat_ready(feat_ready), .feat(feat),
    .wb_addr(wb_addr), .wb_data(wb_data),
    .acc_rd_req(acc_rd_req), .acc_rd_addr(acc_rd_addr), .acc_rd_data(acc_rd_data),
    .acc_wr_we(acc_wr_we), .acc_wr_addr(acc_wr_addr), .acc_wr_data(acc_wr_data),
    .thr_rd_req(thr_rd_req), .thr_rd_addr(thr_rd_addr), .thr_rd_data(thr_rd_data),
    .thr_wr_we(thr_wr_we), .thr_wr_addr(thr_wr_addr), .thr_wr_data(thr_wr_data),
    .q_valid(q_valid), .q_index(q_index), .q_data(q_data), .done(done),
    .dbg_qph(), .dbg_qj(), .dbg_s0q(), .dbg_s1q(),
    .dbg_acc_rd_addr(), .dbg_acc_rd_data(), .dbg_acc_rd_req());

  // weight_bram: bias[0..127] 수동 로드
  logic [ADDR_W-1:0] ld_addr;
  logic [15:0] ld_data;
  logic ld_we;
  weight_bram #(.HD(HD), .NF(NF), .ADDR_W(ADDR_W)) u_wb (
    .clk(clk), .ld_we(ld_we), .ld_addr(ld_addr), .ld_data(ld_data),
    .rd_addr(wb_addr), .rd_data(wb_data)
  );
  accumulator #(.HD(HD)) u_acc (
    .clk(clk),
    .rd_req(acc_rd_req), .rd_addr(acc_rd_addr), .rd_data(acc_rd_data),
    .wr_we(acc_wr_we), .wr_addr(acc_wr_addr), .wr_data(acc_wr_data)
  );
  accumulator #(.HD(HD)) u_thr (
    .clk(clk),
    .rd_req(thr_rd_req), .rd_addr(thr_rd_addr), .rd_data(thr_rd_data),
    .wr_we(thr_wr_we), .wr_addr(thr_wr_addr), .wr_data(thr_wr_data)
  );

  int i;
  logic [7:0] got_q [0:HD-1];
  int got_cnt;
  logic [31:0] exp [0:HD-1];
  int fails;
  initial begin
    use_big = 0; cntt0 = 0; cntt1 = 0;
    // bias 로드: bias[j] = j*3 - 100
    for (i = 0; i < HD; i++) begin
      @(negedge clk);
      ld_we   = 1;
      ld_addr = i;
      ld_data = i*3 - 100;
    end
    @(negedge clk);
    ld_we = 0;

    // 기대값
    for (i = 0; i < HD/2; i++) begin
      int s0, s1;
      s0 = i*3 - 100; s1 = (i+64)*3 - 100;
      if (s0 < 0) s0 = 0; else if (s0 > 254) s0 = 254;
      if (s1 < 0) s1 = 0; else if (s1 > 254) s1 = 254;
      exp[i]     = (s0*s1) >> 9;
      exp[i+64]  = exp[i];
    end

    // 시작 (negedge 기반 자극: 히든 레이스 방지)
    @(negedge clk); rst = 0;
    @(negedge clk); start = 1; stm = 0; cnt0 = 0; cnt1 = 0; feat_valid = 0;
    @(negedge clk); start = 0;

    // q 수집
    got_cnt = 0;
    fails = 0;
    forever begin
      @(posedge clk);
      if (q_valid) begin
        got_q[got_cnt] = q_data;
        if (got_q[got_cnt] != exp[q_index]) begin
          $display("MISMATCH q[%0d] = %0d exp %0d", q_index, q_data, exp[q_index]);
          fails++;
        end
        got_cnt++;
      end
      if (done) begin
        $display("done: q_cnt=%0d fails=%0d", got_cnt, fails);
        $finish;
      end
    end
  end

  initial begin
    #50000;
    $display("TIMEOUT");
    $finish;
  end

`ifdef TRACE
  always @(posedge clk) begin
    if (!rst)
      $display("%0t st=%0d ph=%0d jctr=%0d fcnt=%0d qph=%0d qj=%0d done=%0d wbadr=%0d",
               $time, u_fte.st, u_fte.ph, u_fte.jctr, u_fte.fcnt,
               u_fte.qph, u_fte.qj, done, wb_addr);
  end
`endif
endmodule