// fc_bram.sv - FC 가중치 메모리 모델 (M3 시뮬레이션용)
//
// FCBIN (ref_eval.cc FCBIN 덤프) 로드. 8 bucket 연속 배치:
//   per bucket: fc0.bias[16] int32, fc0.w[16*pad0] int8,
//               fc1.bias[32] int32, fc1.w[32*32]  int8,
//               fc2.bias[1]  int32, fc2.w[1*32]   int8
// pad0 = % ceil_to_multiple(HD, 16) % (파일 저장 순서 그대로).
// 단일 바이트 리드 포트 — fc_pipe 가 시퀀셜 MAC 로 읽는다.
module fc_bram #(
  parameter int HD     = 1024,
  parameter int ADDR_W = 18
)(
  input  logic              clk,
  input  logic              ld_we,
  input  logic [ADDR_W-1:0] ld_addr,
  input  logic [7:0]        ld_data,
  input  logic [ADDR_W-1:0] rd_addr,
  output logic [7:0]        rd_data
);

  localparam int PAD0 = (HD + 15) / 16 * 16;
  localparam int O_FC0B = 0;
  localparam int O_FC0W = 16 * 4;
  localparam int O_FC1B = O_FC0W + 16 * PAD0;
  localparam int O_FC1W = O_FC1B + 32 * 4;
  localparam int O_FC2B = O_FC1W + 32 * 32;
  localparam int O_FC2W = O_FC2B + 1 * 4;
  localparam int BUCKET = O_FC2W + 32;
  localparam int DEPTH  = 8 * BUCKET;
  localparam int A_W    = $clog2(DEPTH);

  logic [7:0] mem [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (ld_we)
      mem[ld_addr[A_W-1:0]] <= ld_data;
  end

  assign rd_data = mem[rd_addr[A_W-1:0]];

endmodule