`timescale 1ns/1ps

module tb_ft_delta_engine;
  localparam int HD = 4;
  logic clk = 0;
  always #5 clk = ~clk;

  logic rst = 1, start = 0, start_refresh = 0;
  logic ready, feature_valid = 0, feature_ready;
  logic [31:0] feature_index = 0;
  logic feature_add = 1;
  logic mem_req, mem_valid = 0;
  logic [7:0] mem_base_addr;
  logic signed [15:0] mem_data [0:HD-1];
  logic signed [31:0] accumulator [0:HD-1];

  ft_delta_engine #(.HD(HD), .ADDR_W(8)) dut (.*);

  always_ff @(posedge clk) begin
    mem_valid <= mem_req;
    for (int i = 0; i < HD; i++) begin
      if (mem_base_addr == 0)
        mem_data[i] <= 10 + i;
      else
        mem_data[i] <= 1 + i;
    end
  end

  initial begin
    for (int i = 0; i < HD; i++) mem_data[i] = 0;
    repeat (2) @(posedge clk);
    rst = 0;
    @(negedge clk); start = 1; start_refresh = 1;
    @(negedge clk); start = 0;
    wait (feature_ready);
    @(negedge clk); feature_index = 2; feature_add = 1; feature_valid = 1;
    @(negedge clk); feature_valid = 0;
    repeat (3) @(posedge clk);
    if (accumulator[0] != 11 || accumulator[1] != 13 ||
        accumulator[2] != 15 || accumulator[3] != 17)
      $fatal(1, "FT refresh mismatch: %0d %0d %0d %0d",
             accumulator[0], accumulator[1], accumulator[2], accumulator[3]);
    $display("PASS Stockfish FT delta layout, feature address=%0d", mem_base_addr);
    $finish;
  end
endmodule
