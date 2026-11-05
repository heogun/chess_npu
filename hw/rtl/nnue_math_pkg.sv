// Integer operations with the exact semantics of sf_19 nnue_feature_transformer.h,
// layers/clipped_relu.h, layers/sqr_clipped_relu.h and nnue_architecture.h.
package nnue_math_pkg;

  // clamp<i16>(x, 0, 255)
  function automatic logic [7:0] ft_clamp(input logic signed [15:0] x);
    if (x < 0) return 8'd0;
    if (x > 16'sd255) return 8'd255;
    return x[7:0];
  endfunction

  // unsigned(a * b) / 512. The maximum result is 127.
  function automatic logic [7:0] ft_product(input logic [7:0] a, input logic [7:0] b);
    logic [15:0] p;
    p = 16'(a) * 16'(b);
    return {1'b0, p[15:9]};
  endfunction

  // clamp(x >> shift, 0, 127) with an arithmetic shift
  function automatic logic [7:0] clipped_relu(input logic signed [31:0] x, input int shift);
    logic signed [31:0] s;
    s = x >>> shift;
    if (s < 0) return 8'd0;
    if (s > 32'sd127) return 8'd127;
    return s[7:0];
  endfunction

  // |x| limited to 17 bits. A limited value always squares past the output clamp.
  function automatic logic [16:0] sqr_magnitude(input logic signed [31:0] x);
    logic [31:0] m;
    m = x[31] ? (~x + 32'd1) : x;
    return (m >= 32'd65536) ? 17'h10000 : m[16:0];
  endfunction

  // min(127, (m * m) >> (2 * shift + 7)) where m is the sqr_magnitude output
  function automatic logic [7:0] sqr_from_square(input logic [33:0] square, input int shift);
    logic [33:0] s;
    s = square >> (2 * shift + 7);
    return (s >= 34'd127) ? 8'd127 : s[7:0];
  endfunction

  // C++ signed division by a power of two: truncates toward zero
  function automatic logic signed [31:0] sdiv_pow2_32(input logic signed [31:0] x, input int log2);
    logic signed [32:0] w;
    w = {x[31], x};
    if (x[31]) w = w + ((33'sd1 << log2) - 33'sd1);
    w = w >>> log2;
    return w[31:0];
  endfunction

  function automatic logic signed [63:0] sdiv_pow2_64(input logic signed [63:0] x, input int log2);
    logic signed [63:0] w;
    w = x;
    if (x[63]) w = w + ((64'sd1 << log2) - 64'sd1);
    return w >>> log2;
  endfunction

endpackage
