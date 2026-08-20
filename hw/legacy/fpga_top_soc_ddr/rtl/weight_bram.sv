// weight_bram.sv - FT 가중치 메모리 모델 (M2 시뮬레이션용)
//
// 실제 하드웨어에서는 DDR3 스트리밍 컨트롤러가 이 인터페이스를 대체하므로
// 이 모듈은 시뮬레이션 전용 메모리 모델이다. FTE 는 rd_* 인터페이스만 사용.
//
// 데이터 배치: 자연 순서 그대로. feature f 의 weight 열(column) =
//   addr = f * HD, 부터 HD 개의 int16 값.
//   (small: 파일 로드 시 x2 스케일된 값이 저장된 바이너리에서 직접 로드)
//
// rd 인터페이스: 1클럭 조합 읽기 (시뮬 단순화). DDR 모델로 교체 시
// request/response 파이프라인으로 바꾸면 됨 — FTE 쪽 상태 머신은
// rd_valid 와 별도 완료 기다림이 없도록 설계(아래).
module weight_bram #(
  parameter int HD        = 128,          // 열 길이 (int16 워드 수)
  parameter int NF        = 22528,        // 특징 수
  parameter int TFF       = 0,            // threat 특징 수 (big; 0 이면 threat 영역 없음)
  parameter int ADDR_W    = 22            // log2(HD + (NF+TFF)*HD)
)(
  input  logic              clk,
  // ---- debug/load port : TB 가 바이너리에서 16bit 워드 로드 ----
  input  logic              ld_we,
  input  logic [ADDR_W-1:0] ld_addr,
  input  logic [15:0]       ld_data,
  // ---- FTE read port (조합) ----
  input  logic [ADDR_W-1:0] rd_addr,
  output logic [15:0]       rd_data,
  output logic              rd_ready,
  // ---- 외부 DDR 스트림 패스스루 (온보드용; 시뮬에서는 무시) ----
  output logic [ADDR_W-1:0] ext_addr,
  input  logic [15:0]       ext_data,
  input  logic              ext_ready
);

  localparam int DEPTH = HD + (NF + TFF) * HD;
  logic [15:0] mem [0:DEPTH-1];

  assign rd_ready = 1'b1;
  assign ext_addr = rd_addr;   // 시뮬에서 ext 포트는 사용 안 함

  always_ff @(posedge clk) begin
    if (ld_we)
      mem[ld_addr] <= ld_data;
  end

  // 조합 리드 (시뮬 메모리 모델). quartus 합성 시 이 모듈은 DDR 스트리밍으로 대체.
  assign rd_data = mem[rd_addr];

endmodule