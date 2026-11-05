// Exposes nnue_math_pkg functions as combinational ports for tb_math.cpp.
module nnue_math_unit
  import nnue_math_pkg::*;
(
  input  logic signed [15:0] i16_in,
  input  logic [7:0]         a,
  input  logic [7:0]         b,
  input  logic signed [31:0] i32_in,
  input  logic signed [63:0] i64_in,
  output logic [7:0]         clamp_out,
  output logic [7:0]         product_out,
  output logic [7:0]         clip7_out,
  output logic [7:0]         clip6_out,
  output logic [7:0]         sqr7_out,
  output logic [7:0]         sqr6_out,
  output logic signed [31:0] div2_out,
  output logic signed [31:0] div16_out,
  output logic signed [63:0] div16384_out
);
  logic [16:0] mag;
  logic [33:0] square;

  always_comb begin
    clamp_out    = ft_clamp(i16_in);
    product_out  = ft_product(a, b);
    clip7_out    = clipped_relu(i32_in, 7);
    clip6_out    = clipped_relu(i32_in, 6);
    mag          = sqr_magnitude(i32_in);
    square       = 34'(mag) * 34'(mag);
    sqr7_out     = sqr_from_square(square, 7);
    sqr6_out     = sqr_from_square(square, 6);
    div2_out     = sdiv_pow2_32(i32_in, 1);
    div16_out    = sdiv_pow2_32(i32_in, 4);
    div16384_out = sdiv_pow2_64(i64_in, 14);
  end
endmodule
