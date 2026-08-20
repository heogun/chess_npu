// nnue_defs.sv - NNUE NPU 공통 파라미터 (M2)
// ref_eval.cc 의 상수와 1:1 대응. 값 변경 시 검증 하네스도 동기화.
package nnue_defs;

  localparam int HD_SMALL = 128;           // TransformedFeatureDimensionsSmall
  localparam int HD_BIG   = 1024;          // TransformedFeatureDimensionsBig
  localparam int HDH_SMALL = HD_SMALL / 2;
  localparam int HDH_BIG   = HD_BIG / 2;

  localparam int PSQ_IN_SMALL = 22528;     // HalfKAv2_hm 특징 차원 (small)
  localparam int THR_IN_SMALL = 0;         // small 은 threat 없음
  localparam int TOTAL_IN_SMALL = PSQ_IN_SMALL;

  localparam int PSQ_IN_BIG = 22528;       // HalfKAv2_hm 특징 차원 (big)
  localparam int THR_IN_BIG   = 79856;     // FullThreats 특징 차원 (big)
  localparam int TOTAL_IN_BIG = PSQ_IN_BIG + THR_IN_BIG;

  localparam int NPERSP = 2;               // perspective {stm, ~stm}
  localparam int NBUCKETS = 8;             // LayerStacks

  // accumulator read/write: row(perspective)<<8 | index(j) — j<HD<=1024 이므로 10bit
  localparam int ACC_ADDR_W = 11;

endpackage