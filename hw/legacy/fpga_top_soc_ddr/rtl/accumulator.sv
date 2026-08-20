// accumulator.sv - FT 어큐뮬레이터 [2 persp][HD] int32
//
// ref_eval.cc: acc[p].assign(HD, 0) 후 bias 를 먼저 복사하고, active feature
// 열을 add/sub 하는 순서와 동일. FTE 가 read-modify-write 로 구동한다.
//
// 주소: {perspective(1bit), index(ACC_ADDR_W-1)..0} 로 펼쳐 확장
module accumulator #(
  parameter int HD = 128
)(
  input  logic              clk,
  // ---- read port (2-cycle: ack 다음 clk 에 rd_data) ----
  input  logic              rd_req,
  input  logic [10:0]       rd_addr,
  output logic [31:0]       rd_data,
  // ---- 2nd read port (TB 디버그 덤프용) ----
  input  logic              rd2_req,
  input  logic [10:0]       rd2_addr,
  output logic [31:0]       rd2_data,
  // ---- write port ----
  input  logic              wr_we,
  input  logic [10:0]       wr_addr,
  input  logic [31:0]       wr_data
);

  localparam int DEPTH = 2 * HD;
  localparam int AW    = $clog2(DEPTH);
  logic [31:0] acc [0:DEPTH-1];

  logic [31:0] rd_q, rd2_q;

  always_ff @(posedge clk) begin
    if (wr_we)
      acc[wr_addr[AW-1:0]] <= wr_data;
    rd_q <= acc[rd_addr[AW-1:0]];   // 무조건 등록 리드 (블록 RAM 추론)
    if (rd2_req)
      rd2_q <= acc[rd2_addr[AW-1:0]];
  end

  assign rd_data  = rd_q;
  assign rd2_data = rd2_q;

endmodule