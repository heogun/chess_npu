// top_fc.sv - FC 파이프라인 전체 (M3 시뮬레이션용 래퍼)
//  fc_bram (FCBIN 가중치) + fc_pipe (시퀀셜 MAC)
module top_fc #(
  parameter int HD     = 1024,
  parameter int ADDR_W = 18
)(
  input  logic              clk,
  input  logic              rst,

  input  logic              start,
  input  logic [2:0]        bucket,

  // q (FT 출력) 로드 포트
  input  logic              q_we,
  input  logic [$clog2(HD)-1:0] q_addr,
  input  logic [7:0]        q_data,

  // FCBIN 가중치 로드 포트
  input  logic              ld_we,
  input  logic [ADDR_W-1:0] ld_addr,
  input  logic [7:0]        ld_data,

  output logic              done,
  output logic [31:0]       result,
  output logic [31:0]       fwd_out
);

  logic [ADDR_W-1:0] fc_rd_addr;
  logic [7:0]        fc_rd_data;

  fc_bram #(.HD(HD), .ADDR_W(ADDR_W)) u_bram (
    .clk     (clk),
    .ld_we   (ld_we),
    .ld_addr (ld_addr),
    .ld_data (ld_data),
    .rd_addr (fc_rd_addr),
    .rd_data (fc_rd_data)
  );

  fc_pipe #(.HD(HD), .ADDR_W(ADDR_W)) u_pipe (
    .clk       (clk),
    .rst       (rst),
    .start     (start),
    .bucket    (bucket),
    .q_we      (q_we),
    .q_addr    (q_addr),
    .q_data    (q_data),
    .fc_rd_addr(fc_rd_addr),
    .fc_rd_data(fc_rd_data),
    .done      (done),
    .result    (result),
    .fwd_out   (fwd_out)
  );

endmodule