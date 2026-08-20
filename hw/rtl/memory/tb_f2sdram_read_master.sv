`timescale 1ns/1ps

module tb_f2sdram_read_master;
  logic clk = 0;
  always #5 clk = ~clk;

  logic rst = 1;
  logic cmd_valid = 0;
  logic cmd_ready;
  logic [28:0] cmd_address = 0;
  logic [7:0] cmd_beats = 0;
  logic mem_read, mem_waitrequest = 0, mem_readdatavalid = 0;
  logic [28:0] mem_address;
  logic [7:0] mem_burstcount;
  logic [63:0] mem_readdata = 0;
  logic rsp_valid, rsp_ready = 1, rsp_last, rsp_error, busy;
  logic [63:0] rsp_data;

  f2sdram_read_master #(.TIMEOUT_CYCLES(16)) dut (.*);

  initial begin
    repeat (2) @(posedge clk);
    rst <= 0;
    @(posedge clk);
    cmd_address <= 29'h123;
    cmd_beats <= 2;
    cmd_valid <= 1;
    @(posedge clk);
    while (!cmd_ready) @(posedge clk);
    cmd_valid <= 0;
    while (!mem_read) @(posedge clk);
    @(posedge clk);
    mem_readdata <= 64'h1111;
    mem_readdatavalid <= 1;
    @(posedge clk);
    mem_readdatavalid <= 0;
    while (!mem_read && !busy) @(posedge clk);
    @(posedge clk);
    mem_readdata <= 64'h2222;
    mem_readdatavalid <= 1;
    @(posedge clk);
    mem_readdatavalid <= 0;
    repeat (2) @(posedge clk);
    if (rsp_error || busy) $fatal(1, "read master did not complete");
    $display("PASS f2sdram read master");
    $finish;
  end
endmodule
