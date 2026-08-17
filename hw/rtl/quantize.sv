// quantize.sv - FT quantize 유닛 (1쌍 s0/s1 당)
//
// ref_eval.cc transform() #else 경로:
//   small: s0 = clamp(acc[p][j],   0, 127*2),  q = (s0*s1) >> 9
//   big:   s0 = clamp(acc[p][j] + thr[p][j], 0, 255)
// 정수 나눗셈 /512 는 s>=0 이므로 논리 시프트 >>9 와 동일.
module quantize (
  input  logic        use_big,
  input  logic [31:0] s0,
  input  logic [31:0] s1,
  output logic [7:0]  q
);
  logic [31:0] c0, c1;

  always_comb begin
    if (use_big) begin
      c0 = ($signed(s0) > 32'sd255) ? 32'sd255 : ($signed(s0) < 32'sd0) ? 32'sd0 : s0;
      c1 = ($signed(s1) > 32'sd255) ? 32'sd255 : ($signed(s1) < 32'sd0) ? 32'sd0 : s1;
    end else begin
      c0 = ($signed(s0) > 32'sd254) ? 32'sd254 : ($signed(s0) < 32'sd0) ? 32'sd0 : s0;
      c1 = ($signed(s1) > 32'sd254) ? 32'sd254 : ($signed(s1) < 32'sd0) ? 32'sd0 : s1;
    end
  end

  logic [31:0] prod;
  always_comb prod = c0 * c1;
  always_comb q    = prod[16:9];

endmodule