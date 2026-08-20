// DE1-SoC FC MAC primitive.
//
// One cycle consumes LANES signed 8x8 products and accumulates them into one
// signed result. A caller supplies banked BRAM data in lane order. The module
// intentionally contains no network dimensions or address arithmetic so the
// same primitive can serve FC0, FC1, and FC2.
module parallel_mac #(
  parameter int LANES = 16,
  parameter int ACC_W = 40
) (
  input  logic                  clk,
  input  logic                  rst,
  input  logic                  start,
  input  logic                  valid,
  input  logic                  last,
  input  logic signed [7:0]     input_data [0:LANES-1],
  input  logic signed [7:0]     weight_data[0:LANES-1],
  input  logic signed [ACC_W-1:0] bias,
  output logic                  ready,
  output logic                  done,
  output logic signed [ACC_W-1:0] result
);

  logic active;
  logic signed [ACC_W-1:0] sum;
  logic signed [ACC_W-1:0] products [0:LANES-1];
  logic signed [ACC_W-1:0] tree_sum;

  always_comb begin
    tree_sum = '0;
    for (int lane = 0; lane < LANES; lane++)
      tree_sum += products[lane];
  end

  always_comb begin
    for (int lane = 0; lane < LANES; lane++)
      products[lane] = $signed(input_data[lane]) * $signed(weight_data[lane]);
  end

  assign ready = !active;

  always_ff @(posedge clk) begin
    if (rst) begin
      active <= 1'b0;
      sum    <= '0;
      done   <= 1'b0;
      result <= '0;
    end else begin
      done <= 1'b0;
      if (start && ready) begin
        active <= 1'b1;
        sum    <= bias;
      end else if (active && valid) begin
        if (last) begin
          result <= sum + tree_sum;
          active <= 1'b0;
          done   <= 1'b1;
        end else begin
          sum <= sum + tree_sum;
        end
      end
    end
  end
endmodule
