// DE1-SoC FC0 weight banking.
//
// The Stockfish 18 FC0 local layout is output-major:
//   local_addr = output_index * HD + input_index
//
// LANES independent banks map input_index % LANES to a bank. A read of one
// output/chunk returns LANES signed int8 weights in one cycle, allowing the
// FC engine to issue LANES MACs without a multi-read BRAM conflict.
module fc0_weight_banks #(
  parameter int HD = 128,
  parameter int OUTPUTS = 16,
  parameter int LANES = 16,
  parameter int ADDR_W = $clog2(OUTPUTS * HD)
) (
  input logic clk,
  input logic load_valid,
  input logic [ADDR_W-1:0] load_addr,
  input logic signed [7:0] load_data,
  input logic [$clog2(OUTPUTS)-1:0] read_output,
  input logic [$clog2(HD / LANES)-1:0] read_chunk,
  output logic signed [7:0] read_weight [0:LANES-1]
);

  localparam int CHUNKS = HD / LANES;
  localparam int BANK_DEPTH = OUTPUTS * CHUNKS;

  (* ramstyle = "M10K" *)
  logic signed [7:0] bank_mem [0:LANES-1][0:BANK_DEPTH-1];

  always_ff @(posedge clk) begin
    if (load_valid) begin
      bank_mem[load_addr % LANES][load_addr / LANES] <= load_data;
    end
  end

  always_comb begin
    for (int lane = 0; lane < LANES; lane++) begin
      read_weight[lane] = bank_mem[lane][read_output * CHUNKS + read_chunk];
    end
  end
endmodule
