// fpga_top_soc.sv - Avalon-MM 래퍼 (Intel Platform Designer / Quartus 연동용)
//
// fpga_top (M4-RTL 배칭 NPU 토프) 을 Avalon-MM 슬레이브 인터페이스로 노출.
// Quartus Prime 프로젝트에서:
//   - s_hps   : lwhps2fpga 브리지에 연결        (HPS 마스터 -> fpga_top 창)
//   - s_load  : hps2fpga 브리지에 연결          (HPS 마스터 -> 가중치 로드)
//   - irq_out : FPGA-to-HPS 인터럽트 (f2h_irq0) 에 연결
//
// 창 레이아웃 (워드 오프셋, nnuehw.h ABI 와 동일):
//   CSR      : 0x0000 .. 0x0027
//   desc 링  : 0x0010 .. 0x040F  (64 엔트리 x 16 워드)
//   feat     : 0x0410 .. 0x440F  (64 프레임 x 256 워드)
//   result   : 0x4410 .. 0x480F  (256 엔트리 x 4 워드)
//   -> 창 크기 = 0x4810 워드 = 0x12040 바이트
//
// 가중치 로드 주소 맵 (s_load, 바이트 주소 [31:2] 워드 어드레스 상위 2비트로 선택):
//   word_addr[31:30] = 2'b00 : FT 가중치  (ft_addr = word_addr[FT_ADDR_W-1:0], wdata[15:0])
//                      2'b01 : FC 가중치  (fc_addr = word_addr[FC_ADDR_W-1:0], wdata[7:0])
//                      2'b10 : PSQT 가중치 (psq_addr = word_addr[PSQ_ADDR_W-1:0], wdata[31:0])
//   나머지는 무시 (write no-op, read 0).
//
// 버스 타이밍: 쓰기 0-wait, 읽기 1-사이클 레이턴시 (readdatavalid 사용).
//   fpga_top 의 hps_rdata 는 hps_re 후 1 클럭에 등록되므로, 래퍼에서 hps_re 를
//   1 클럭 폭으로 발생시키고 그 다음 사이클 readdatavalid=1 로 내보낸다.

module fpga_top_soc #(
  parameter int HD         = 1024,   // big: 1024, small: 128
  parameter int NF         = 22528,  // main feature 차원
  parameter int TFF        = 79856,  // threat 차원 (small: 0)
  parameter int PSQI       = 22528,  // main psqt 입력 차원
  parameter int FT_ADDR_W  = 27,     // clog2(HD + (NF+TFF)*HD)
  parameter int FC_ADDR_W  = 18,
  parameter int PSQ_ADDR_W = 20
)(
  input  logic clk,
  input  logic reset_n,          // active-low (외부 PLL/리셋)

  // ---- Avalon-MM 슬레이브 1: HPS 창 (lwhps2fpga) ----
  input  logic [17:0] s_hps_address,   // 바이트 주소 (0x00000..0x3FFFF)
  input  logic        s_hps_read,
  input  logic        s_hps_write,
  input  logic [31:0] s_hps_writedata,
  output logic [31:0] s_hps_readdata,
  output logic        s_hps_readdatavalid,
  output logic        s_hps_waitrequest,

  // ---- Avalon-MM 슬레이브 2: 가중치 로드 (hps2fpga) ----
  input  logic [31:0] s_load_address,  // 바이트 주소
  input  logic        s_load_read,
  input  logic        s_load_write,
  input  logic [31:0] s_load_writedata,
  output logic [31:0] s_load_readdata,
  output logic        s_load_readdatavalid,
  output logic        s_load_waitrequest,

  // ---- 인터럽트 (FPGA-to-HPS 브리지) ----
  output logic irq_out
);

  // ---- 내부 신호 ----
  logic        rst;
  logic        hps_we, hps_re;
  logic [14:0] hps_addr;
  logic [31:0] hps_wdata, hps_rdata;
  logic        ft_we, fc_we, psq_we;
  logic [FT_ADDR_W-1:0]  ft_addr;
  logic [FC_ADDR_W-1:0]  fc_addr;
  logic [PSQ_ADDR_W-1:0] psq_addr;
  logic [15:0] ft_data;
  logic [7:0]  fc_data;
  logic [31:0] psq_data;
  logic        irq;

  // ---- fpga_top 인스턴스 (파라미터 전파) ----
  fpga_top #(
    .HD(HD), .NF(NF), .TFF(TFF), .PSQI(PSQI),
    .FT_ADDR_W(FT_ADDR_W), .FC_ADDR_W(FC_ADDR_W), .PSQ_ADDR_W(PSQ_ADDR_W)
  ) u_fpga_top (
    .clk(clk), .rst(rst),
    .hps_we(hps_we), .hps_re(hps_re),
    .hps_addr(hps_addr), .hps_wdata(hps_wdata), .hps_rdata(hps_rdata),
    .ft_we(ft_we), .ft_addr(ft_addr), .ft_data(ft_data),
    .fc_we(fc_we), .fc_addr(fc_addr), .fc_data(fc_data),
    .psq_we(psq_we), .psq_addr(psq_addr), .psq_data(psq_data),
    .irq(irq)
  );
  assign irq_out = irq;

  // =====================================================================
  //  리셋 동기화 (100MHz 도메인)
  // =====================================================================
  logic reset_sync [0:1];
  always_ff @(posedge clk) begin
    reset_sync[0] <= ~reset_n;
    reset_sync[1] <= reset_sync[0];
  end
  assign rst = reset_sync[1];

  // =====================================================================
  //  슬레이브 1: HPS 창
  //  쓰기 0-wait, 읽기 1-사이클 레이턴시
  // =====================================================================
  logic [14:0] hps_addr_q;
  logic [31:0] hps_wdata_q;
  logic        read_pending;

  // 주소/데이터 파이프 등록 (Avalon 마스터는 주소를 홀드하지만 안전하게 1스테이지)
  always_ff @(posedge clk) begin
    if (rst) begin
      hps_addr_q  <= 0;
      hps_wdata_q <= 0;
      hps_we      <= 0;
      hps_re      <= 0;
      read_pending <= 0;
    end else begin
      hps_we <= 0;
      hps_re <= 0;
      if (s_hps_write) begin
        hps_addr_q  <= s_hps_address[16:2];       // 바이트 -> 워드 (15비트)
        hps_wdata_q <= s_hps_writedata;
        hps_we      <= 1;                          // 0-wait 쓰기
      end
      if (s_hps_read) begin
        hps_addr_q   <= s_hps_address[16:2];
        hps_re       <= 1;                         // 1-사이클 레이턴시 읽기
        read_pending <= 1;
      end else if (read_pending) begin
        read_pending <= 0;
      end
    end
  end

  assign hps_addr  = hps_addr_q;
  assign hps_wdata = hps_wdata_q;

  // 읽기 데이터: fpga_top 이 hps_rdata 를 hps_re 후 1클럭에 등록 -> 다음사이클 출력
  logic [31:0] hps_rdata_q;
  always_ff @(posedge clk) begin
    if (rst)
      hps_rdata_q <= 0;
    else if (hps_re)              // posedge 에서 hps_rdata 유효 -> 캡처
      hps_rdata_q <= hps_rdata;
  end

  always_ff @(posedge clk) begin
    if (rst)
      s_hps_readdatavalid <= 0;
    else
      s_hps_readdatavalid <= read_pending;
  end
  assign s_hps_readdata    = hps_rdata_q;
  assign s_hps_waitrequest = 1'b0;

  // =====================================================================
  //  슬레이브 2: 가중치 로드 (3 포트 선택)
  //  쓰기 0-wait, 읽기는 리드백 미지원(0 반환)
  // =====================================================================
  always_ff @(posedge clk) begin
    if (rst) begin
      ft_we <= 0; fc_we <= 0; psq_we <= 0;
      ft_addr <= 0; fc_addr <= 0; psq_addr <= 0;
      ft_data <= 0; fc_data <= 0; psq_data <= 0;
    end else begin
      ft_we <= 0; fc_we <= 0; psq_we <= 0;
      if (s_load_write) begin
        unique case (s_load_address[31:30])
          2'b00: begin
            ft_we   <= 1;
            ft_addr <= s_load_address[FT_ADDR_W+1:2];
            ft_data <= s_load_writedata[15:0];
          end
          2'b01: begin
            fc_we   <= 1;
            fc_addr <= s_load_address[FC_ADDR_W+1:2];
            fc_data <= s_load_writedata[7:0];
          end
          2'b10: begin
            psq_we   <= 1;
            psq_addr <= s_load_address[PSQ_ADDR_W+1:2];
            psq_data <= s_load_writedata;
          end
          default: ;
        endcase
      end
    end
  end

  assign s_load_readdata      = 32'b0;   // 가중치 리드백은 미지원
  assign s_load_readdatavalid = s_load_read;
  assign s_load_waitrequest   = 1'b0;

endmodule
