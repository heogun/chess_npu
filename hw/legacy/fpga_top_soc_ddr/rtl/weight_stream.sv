// weight_stream.sv - FT 가중치 읽기 포트 (하드웨어: DDR 스트리밍 패스스루)
//
// 온보드 빌드에서 M2 시뮬레이션용 weight_bram(온칩 SRAM) 대신 같은 인터페이스를
// 제공하되 실제 저장소는 ddr_stream(F2H 버스트 읽기) 에 둔다.
//   rd_addr -> ext_addr (페치 요청),  rd_data/rd_ready <- ext_data/ext_ready.
// 시뮬레이션용 weight_bram.sv(온칩 SRAM + rd_ready=1) 와 모듈명이 동일하다.
module weight_bram #(
  parameter int HD        = 128,
  parameter int NF        = 22528,
  parameter int TFF       = 0,
  parameter int ADDR_W    = 22
)(
  input  logic                clk,
  // ---- debug/load port (DDR 경로에서는 미사용) ----
  input  logic                ld_we,
  input  logic [ADDR_W-1:0]   ld_addr,
  input  logic [15:0]         ld_data,
  // ---- FTE read port ----
  input  logic [ADDR_W-1:0]   rd_addr,
  output logic [15:0]         rd_data,
  output logic                rd_ready,
  // ---- DDR 스트림(외부 ddr_stream) ----
  output logic [ADDR_W-1:0]   ext_addr,
  input  logic [15:0]         ext_data,
  input  logic                ext_ready
);

  assign ext_addr = rd_addr;
  assign rd_data  = ext_data;
  assign rd_ready = ext_ready;

endmodule