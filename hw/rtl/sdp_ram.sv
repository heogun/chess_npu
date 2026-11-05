// Simple dual-port RAM with registered read, inferred as M10K on Cyclone V.
// Read and write never target one address in the same cycle in this design.
module sdp_ram #(
  parameter int WIDTH = 8,
  parameter int DEPTH = 256
) (
  input  logic                     clk,
  input  logic                     we,
  input  logic [$clog2(DEPTH)-1:0] waddr,
  input  logic [WIDTH-1:0]         wdata,
  input  logic [$clog2(DEPTH)-1:0] raddr,
  output logic [WIDTH-1:0]         rdata
);
  logic [WIDTH-1:0] mem [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
    rdata <= mem[raddr];
  end
endmodule
