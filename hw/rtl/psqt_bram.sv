// psqt_bram.sv - PSQT 가중치 메모리 모델 (M4-RTL, 시뮬레이션용)
//
// ref_eval FTWeights::psqtWeights/threatPsqt 를 int32 로 그대로 유지:
//   레이아웃 (PSQTBIN 덤프 순서와 일치):
//     [0 .. PSQI*8-1]            : main  psqtWeights[f*8 + b]  (f: 0..PSQI-1)
//     [PSQI*8 .. (PSQI+TFF)*8-1] : threatPsqt[f*8 + b]         (f: 0..TFF-1)
//   rd 는 1클럭 조합 읽기 (FTE 를 구동하는 바와 동일한 시뮬 단순화).
//   실제 하드웨어에서는 DDR 로드/브로드캐스트 정책이 이 인터페이스를 대체한다.
module psqt_bram #(
  parameter int PSQI         = 22528,   // main psqt 입력 차원
  parameter int TFF          = 0,       // threat 차원 (small: 0)
  parameter int PSQ_ADDR_W   = 20       // clog2((PSQI + TFF) * 8)
)(
  input  logic                     clk,
  input  logic                     ld_we,
  input  logic [PSQ_ADDR_W-1:0]    ld_addr,
  input  logic [31:0]              ld_data,
  input  logic [PSQ_ADDR_W-1:0]    rd_addr,
  output logic [31:0]              rd_data
);
  localparam int DEPTH = (PSQI + TFF) * 8;
  logic [31:0] mem [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (ld_we)
      mem[ld_addr] <= ld_data;
  end

  assign rd_data = mem[rd_addr];

endmodule