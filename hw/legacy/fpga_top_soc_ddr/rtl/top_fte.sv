// top_fte.sv - M2 실데이터 검증용 래퍼 (small/big 공통)
// fte + weight_bram + main/thr accumulator + quantize 를 연결. TB 가 FTBIN/feature
// 리스트를 로드하고 q[] 스트림을 C++ 참조(ref_eval FTDMP)와 대조한다.
module top_fte #(
  parameter int HD     = 128,
  parameter int NF     = 22528,
  parameter int TFF    = 0,
  parameter int ADDR_W = 22,
  parameter int FMAX   = 4096
)(
  input  logic              clk,
  input  logic              rst,

  input  logic              start,
  input  logic              use_big,
  input  logic              stm,
  input  logic [31:0]       cnt0,
  input  logic [31:0]       cnt1,
  input  logic [31:0]       cntt0,
  input  logic [31:0]       cntt1,

  input  logic              feat_valid,
  output logic              feat_ready,
  input  logic [31:0]       feat,

  input  logic              ld_we,
  input  logic [ADDR_W-1:0] ld_addr,
  input  logic [15:0]       ld_data,

  // ---- FT 가중치 읽기 (외부 DDR 스트림 패스스루) ----
  output logic [ADDR_W-1:0] wb_ext_addr,
  input  logic [15:0]       wb_ext_data,
  input  logic              wb_ext_ready,

  output logic              q_valid,
  output logic [$clog2(HD)-1:0] q_index,
  output logic [7:0]        q_data,
  output logic              done,

  // ---- 디버그: quantize 파이프라인 관찰 ----
  output logic [1:0]        dbg_qph,
  output logic [$clog2(HD/2)-1:0] dbg_qj,
  output logic [31:0]       dbg_s0q,
  output logic [31:0]       dbg_s1q,
  output logic [10:0]       dbg_acc_rd_addr,
  output logic [31:0]       dbg_acc_rd_data,
  output logic              dbg_acc_rd_req,

  // ---- 디버그: 어큐뮬레이터 셀 덤프 (TB 구동) ----
  input  logic              dbg_rd_req,
  input  logic [10:0]       dbg_rd_addr,
  output logic [31:0]       dbg_acc_rd2_data,
  output logic [31:0]       dbg_thr_rd2_data
);

  logic [ADDR_W-1:0] wb_addr;
  logic [15:0]       wb_data;
  logic              wb_ready;
  logic [ADDR_W-1:0] wb_ext_addr_q;
  logic [15:0]       wb_ext_data_q;
  logic              wb_ext_ready_q;
  logic              acc_rd_req;
  logic [10:0]       acc_rd_addr;
  logic [31:0]       acc_rd_data;
  logic              acc_wr_we;
  logic [10:0]       acc_wr_addr;
  logic [31:0]       acc_wr_data;
  logic              thr_rd_req;
  logic [10:0]       thr_rd_addr;
  logic [31:0]       thr_rd_data;
  logic              thr_wr_we;
  logic [10:0]       thr_wr_addr;
  logic [31:0]       thr_wr_data;
  logic [1:0]        d_qph;
  logic [$clog2(HD/2)-1:0] d_qj;
  logic [31:0]       d_s0q, d_s1q;
  logic [10:0]       d_rd_addr;
  logic [31:0]       d_rd_data;
  logic              d_rd_req;

  weight_bram #(.HD(HD), .NF(NF), .TFF(TFF), .ADDR_W(ADDR_W)) u_wb (
    .clk(clk), .ld_we(ld_we), .ld_addr(ld_addr), .ld_data(ld_data),
    .rd_addr(wb_addr), .rd_data(wb_data), .rd_ready(wb_ready),
    .ext_addr(wb_ext_addr_q), .ext_data(wb_ext_data_q), .ext_ready(wb_ext_ready_q));

  assign wb_ext_addr = wb_ext_addr_q;
  assign wb_ext_data_q = wb_ext_data;
  assign wb_ext_ready_q = wb_ext_ready;

  accumulator #(.HD(HD)) u_acc (
    .clk(clk),
    .rd_req(acc_rd_req), .rd_addr(acc_rd_addr), .rd_data(acc_rd_data),
    .rd2_req(dbg_rd_req), .rd2_addr(dbg_rd_addr), .rd2_data(dbg_acc_rd2_data),
    .wr_we(acc_wr_we), .wr_addr(acc_wr_addr), .wr_data(acc_wr_data));

  accumulator #(.HD(HD)) u_thr (
    .clk(clk),
    .rd_req(thr_rd_req), .rd_addr(thr_rd_addr), .rd_data(thr_rd_data),
    .rd2_req(dbg_rd_req), .rd2_addr(dbg_rd_addr), .rd2_data(dbg_thr_rd2_data),
    .wr_we(thr_wr_we), .wr_addr(thr_wr_addr), .wr_data(thr_wr_data));

  fte #(.HD(HD), .NF(NF), .TFF(TFF), .ADDR_W(ADDR_W), .FMAX(FMAX)) u_fte (
    .clk(clk), .rst(rst),
    .start(start), .use_big(use_big), .stm(stm),
    .cnt0(cnt0), .cnt1(cnt1), .cntt0(cntt0), .cntt1(cntt1),
    .feat_valid(feat_valid), .feat_ready(feat_ready), .feat(feat),
    .wb_addr(wb_addr), .wb_data(wb_data), .wb_ready(wb_ready),
    .acc_rd_req(acc_rd_req), .acc_rd_addr(acc_rd_addr), .acc_rd_data(acc_rd_data),
    .acc_wr_we(acc_wr_we), .acc_wr_addr(acc_wr_addr), .acc_wr_data(acc_wr_data),
    .thr_rd_req(thr_rd_req), .thr_rd_addr(thr_rd_addr), .thr_rd_data(thr_rd_data),
    .thr_wr_we(thr_wr_we), .thr_wr_addr(thr_wr_addr), .thr_wr_data(thr_wr_data),
    .q_valid(q_valid), .q_index(q_index), .q_data(q_data),
    .done(done),
    .dbg_qph(d_qph), .dbg_qj(d_qj), .dbg_s0q(d_s0q), .dbg_s1q(d_s1q),
    .dbg_acc_rd_addr(d_rd_addr), .dbg_acc_rd_data(d_rd_data),
    .dbg_acc_rd_req(d_rd_req));

  assign dbg_qph = d_qph;
  assign dbg_qj  = d_qj;
  assign dbg_s0q = d_s0q;
  assign dbg_s1q = d_s1q;
  assign dbg_acc_rd_addr = d_rd_addr;
  assign dbg_acc_rd_data = d_rd_data;
  assign dbg_acc_rd_req  = d_rd_req;

endmodule