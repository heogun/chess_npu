`timescale 1ns/1ps

module tb_compute_primitives;
  localparam int LANES = 4;

  logic clk = 0;
  always #5 clk = ~clk;

  logic rst = 1;

  logic clear;
  logic delta_valid;
  logic delta_add;
  logic delta_ready;
  logic signed [15:0] delta_data [0:LANES-1];
  logic signed [31:0] delta_value[0:LANES-1];

  delta_accumulator #(.LANES(LANES)) u_delta (
    .clk(clk), .rst(rst), .clear(clear),
    .update_valid(delta_valid), .update_add(delta_add),
    .update_data(delta_data), .update_ready(delta_ready),
    .value(delta_value)
  );

  logic mac_start, mac_valid, mac_last, mac_ready, mac_done;
  logic signed [7:0] mac_input [0:LANES-1];
  logic signed [7:0] mac_weight[0:LANES-1];
  logic signed [39:0] mac_bias;
  logic signed [39:0] mac_result;

  parallel_mac #(.LANES(LANES)) u_mac (
    .clk(clk), .rst(rst), .start(mac_start), .valid(mac_valid),
    .last(mac_last), .input_data(mac_input), .weight_data(mac_weight),
    .bias(mac_bias), .ready(mac_ready), .done(mac_done), .result(mac_result)
  );

  initial begin
    clear = 0;
    delta_valid = 0;
    delta_add = 1;
    mac_start = 0;
    mac_valid = 0;
    mac_last = 0;
    mac_bias = 0;
    for (int i = 0; i < LANES; i++) begin
      delta_data[i] = 0;
      mac_input[i] = 0;
      mac_weight[i] = 0;
    end

    repeat (2) @(posedge clk);
    rst = 0;

    clear = 1;
    @(posedge clk);
    clear = 0;
    delta_data[0] = 1;
    delta_data[1] = -2;
    delta_data[2] = 3;
    delta_data[3] = -4;
    delta_valid = 1;
    delta_add = 1;
    @(posedge clk);
    delta_valid = 0;
    @(posedge clk);
    if (delta_value[0] != 1 || delta_value[1] != -2 ||
        delta_value[2] != 3 || delta_value[3] != -4)
      $fatal(1, "delta add mismatch");

    delta_valid = 1;
    delta_add = 0;
    @(posedge clk);
    delta_valid = 0;
    @(posedge clk);
    for (int i = 0; i < LANES; i++)
      if (delta_value[i] != 0) $fatal(1, "delta remove mismatch");

    mac_bias = 10;
    mac_input[0] = 1; mac_weight[0] = 2;
    mac_input[1] = 2; mac_weight[1] = 3;
    mac_input[2] = 3; mac_weight[2] = 4;
    mac_input[3] = 4; mac_weight[3] = 5;
    @(negedge clk);
    mac_start = 1;
    @(negedge clk);
    mac_start = 0;
    mac_valid = 1;
    mac_last = 1;
    @(posedge clk);
    #1;
    if (!mac_done || mac_result != 50)
      $fatal(1, "parallel MAC mismatch: done=%0d result=%0d", mac_done, mac_result);
    mac_valid = 0;
    mac_last = 0;

    $display("PASS compute primitives");
    $finish;
  end
endmodule
