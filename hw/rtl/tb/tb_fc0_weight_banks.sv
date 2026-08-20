`timescale 1ns/1ps

module tb_fc0_weight_banks;
  localparam int HD = 32;
  localparam int OUTPUTS = 4;
  localparam int LANES = 16;

  logic clk = 0;
  always #5 clk = ~clk;
  logic load_valid = 0;
  logic [6:0] load_addr;
  logic signed [7:0] load_data;
  logic [1:0] read_output;
  logic read_chunk;
  logic signed [7:0] read_weight [0:LANES-1];

  fc0_weight_banks #(.HD(HD), .OUTPUTS(OUTPUTS), .LANES(LANES)) dut (.*);

  initial begin
    for (int addr = 0; addr < OUTPUTS * HD; addr++) begin
      @(negedge clk);
      load_addr = addr;
      load_data = addr - 64;
      load_valid = 1;
      @(negedge clk);
      load_valid = 0;
    end

    @(negedge clk);
    read_output = 2;
    read_chunk = 0;
    #1;
    for (int lane = 0; lane < LANES; lane++)
      if (read_weight[lane] != (2 * HD + lane - 64))
        $fatal(1, "bank read mismatch chunk0 lane=%0d value=%0d", lane, read_weight[lane]);

    read_chunk = 1;
    #1;
    for (int lane = 0; lane < LANES; lane++)
      if (read_weight[lane] != (2 * HD + LANES + lane - 64))
        $fatal(1, "bank read mismatch chunk1 lane=%0d value=%0d", lane, read_weight[lane]);

    $display("PASS FC0 %0d-bank layout", LANES);
    $finish;
  end
endmodule
