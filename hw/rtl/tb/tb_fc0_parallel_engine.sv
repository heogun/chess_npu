`timescale 1ns/1ps

module tb_fc0_parallel_engine;
  localparam int HD = 32;
  localparam int OUTPUTS = 4;
  localparam int LANES = 16;

  logic clk = 0;
  always #5 clk = ~clk;
  logic rst = 1;
  logic q_load_valid = 0;
  logic [$clog2(HD)-1:0] q_load_addr;
  logic [7:0] q_load_data;
  logic weight_load_valid = 0;
  logic [$clog2(OUTPUTS * HD)-1:0] weight_load_addr;
  logic signed [7:0] weight_load_data;
  logic bias_load_valid = 0;
  logic [$clog2(OUTPUTS)-1:0] bias_load_addr;
  logic signed [31:0] bias_load_data;
  logic start = 0, ready, done;
  logic signed [39:0] result [0:OUTPUTS-1];

  fc0_parallel_engine #(.HD(HD), .OUTPUTS(OUTPUTS), .LANES(LANES)) dut (.*);

  initial begin
    repeat (2) @(posedge clk);
    rst = 0;

    for (int i = 0; i < HD; i++) begin
      @(negedge clk);
      q_load_addr = i;
      q_load_data = i + 1;
      q_load_valid = 1;
      @(negedge clk);
      q_load_valid = 0;
    end

    for (int o = 0; o < OUTPUTS; o++) begin
      @(negedge clk);
      bias_load_addr = o;
      bias_load_data = o * 10;
      bias_load_valid = 1;
      @(negedge clk);
      bias_load_valid = 0;
      for (int i = 0; i < HD; i++) begin
        @(negedge clk);
        weight_load_addr = o * HD + i;
        weight_load_data = 1;
        weight_load_valid = 1;
        @(negedge clk);
        weight_load_valid = 0;
      end
    end

    @(negedge clk);
    start = 1;
    @(negedge clk);
    start = 0;
    wait (done);
    #1;
    for (int o = 0; o < OUTPUTS; o++) begin
      if (result[o] != (o * 10 + (HD * (HD + 1)) / 2))
        $fatal(1, "FC0 output mismatch o=%0d value=%0d", o, result[o]);
    end
    $display("PASS FC0 parallel engine");
    $finish;
  end
endmodule
