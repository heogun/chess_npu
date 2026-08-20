// ddr_stream.sv - DDR3 가중치 스트리밍 리더 (FPGA-to-HPS 브리지 Avalon-MM 마스터)
//
// FTE 가 요구하는 FT int16 컬럼(HD 워드) 과 fpga_top PSQT 누적이 요구하는
// int32 그룹(8 워드) 을 HPS DDR3 로부터 64-bit 버스트로 공급한다.
//   - FT  : 컬럼 태그(= rd_addr[FT_ADDR_W-1:lc]) 단위로 전체 컬럼을 라인 버퍼에
//           적재. 태그가 바뀌면 페치(요구 시). 적재 완료 전엔 ft_rd_ready 낮게.
//   - PSQT: 그룹 태그(= rd_addr[PSQ_ADDR_W-1:3]) 단위로 8개 int32(4 워드) 를
//           레지스터 라인에 적재. 적재 전 psq_rd_ready 낮게.
//   - 소비자가 대기(rd_ready) 하는 요구-대기 방식. 산술 파이프라인은 불변.
//
// 메모리 배치 (SW 로더와 계약):
//   FT   : 작업 워드 인덱스 (int16) w 의 바이트 = FT_DDR_BASE  + w*2
//   PSQT : 작업 워드 인덱스 (int32) i 의 바이트 = PSQ_DDR_BASE + i*4
//   (little-endian; 64-bit 워드는 낮은 주소가 하위 비트)
module ddr_stream #(
  parameter int         HD         = 128,
  parameter int         FT_ADDR_W  = 22,
  parameter int         PSQ_ADDR_W = 18,
  parameter int         FT_DDR_BASE  = 32'h3500_0000,
  parameter int         PSQ_DDR_BASE = 32'h3400_0000
)(
  input  logic clk,
  input  logic rst,

  // ---- FT weight read (FTE, 주소 2클럭 유지: ph0/1) ----
  input  logic [FT_ADDR_W-1:0] ft_rd_addr,
  output logic [15:0]          ft_rd_data,
  output logic                 ft_rd_ready,

  // ---- PSQT read ----
  input  logic [PSQ_ADDR_W-1:0] psq_rd_addr,
  output logic [31:0]           psq_rd_data,
  output logic                  psq_rd_ready,

  // ---- Avalon-MM 마스터 (64-bit, read-only, burstcount<=64 워드) ----
  output logic [31:0] m_address,
  output logic        m_read,
  output logic [6:0]  m_burstcount,
  input  logic [63:0] m_readdata,
  input  logic        m_readdatavalid,
  input  logic        m_waitrequest
);

  localparam int LC        = $clog2(HD);
  localparam int COL_WORDS = HD / 4;             // 컬럼(=HD int16) 의 64-bit 워드 수
  localparam int BTW       = $clog2(COL_WORDS);  // 워드 포인터 폭
  // HPS F2H SDRAM 포트의 보드별 burst 수용 차이를 피하기 위해 한 beat씩
  // 요청한다. 주소/응답 프로토콜을 먼저 안정화한 뒤 성능 최적화는 별도로 한다.
  localparam logic [6:0] BMAXV = 7'd1;

  localparam int FT_TAG_W  = FT_ADDR_W - LC;
  localparam int PSQ_TAG_W = PSQ_ADDR_W - 3;

  wire [FT_TAG_W-1:0]  ft_tag_cur  = ft_rd_addr[FT_ADDR_W-1:LC];
  wire [PSQ_TAG_W-1:0] psq_tag_cur = psq_rd_addr[PSQ_ADDR_W-1:3];

// -------------------- FT 라인 버퍼 (64-bit x COL_WORDS) --------------------
  logic [63:0] ftbuf [0:COL_WORDS-1];
  logic [BTW-1:0] ft_fill;       // 적재된 워드 수 (0..COL_WORDS)
  logic [BTW:0]   ft_rem;        // 남은 워드
  logic [63:0]    ft_rd_q;
  always_ff @(posedge clk)
    ft_rd_q <= ftbuf[ft_rd_addr[LC-1:2]];
  assign ft_rd_data = ft_rd_q[ft_rd_addr[1:0]*16 +: 16];

// -------------------- PSQT 라인 (8 int32 = 4 워드) --------------------
  logic [255:0] psq_line;
  logic [1:0]   psq_fill;       // 적재 워드 수 (0..3)

// -------------------- 태그/잡 상태 --------------------
  logic [FT_TAG_W-1:0]  ft_tag, ft_job_tag;
  logic [PSQ_TAG_W-1:0] psq_tag, psq_job_tag;
  logic                 ft_job, psq_job;

  wire ft_need  = (ft_tag_cur  != ft_tag);
  wire psq_need = (psq_tag_cur != psq_tag);

  assign ft_rd_ready  = !ft_job  && !ft_need;
  assign psq_rd_ready = !psq_job && !psq_need;

// -------------------- 버스트 제어 --------------------
  typedef enum logic [1:0] {S_IDLE, S_REQ, S_DRAIN} st_t;
  st_t st;
  logic [6:0] bcnt_r;
  logic [6:0] beat;

   // 주소: component master 인터페이스는 byte 주소를 사용한다. 아래 계산은
   // HPS DDR byte 주소를 >>3 한 64-bit word 주소이므로 출력 시 복원한다.
  //   FT 컬럼 = HD int16 = HD*2 바이트 = COL_WORDS 심볼
  //   PSQT 그룹 = 8 int32 = 32 바이트 = 4 심볼
  wire [31:0] ft_addr_cur  = 32'(FT_DDR_BASE >> 3)
                            + (32'(ft_job_tag) << (LC - 2))
                            + 32'(COL_WORDS)
                            - 32'(ft_rem);
  wire [31:0] psq_addr_cur = 32'(PSQ_DDR_BASE >> 3)
                            + (32'(psq_job_tag) << 2)
                            + 32'(psq_fill);

   wire [6:0] ft_bcnt = (ft_rem > BMAXV) ? BMAXV : ft_rem;

  always_ff @(posedge clk) begin
    if (rst) begin
      st           <= S_IDLE;
      m_address    <= '0;
      m_read       <= 0;
      m_burstcount <= '0;
      bcnt_r       <= '0;
      beat         <= '0;
      ft_job       <= 0;
      psq_job      <= 0;
      ft_tag       <= '0;
      psq_tag      <= '0;
      ft_fill      <= '0;
      ft_rem       <= '0;
      psq_fill     <= '0;
      psq_line     <= '0;
    end else begin
      m_read <= 0;
      case (st)
        S_IDLE: begin
          m_address    <= '0;
          m_burstcount <= '0;
          if (!ft_job && !psq_job) begin
            if (ft_need) begin
              ft_job     <= 1;
              ft_job_tag <= ft_tag_cur;
              ft_fill    <= '0;
              ft_rem     <= COL_WORDS;
              st         <= S_REQ;
            end else if (psq_need) begin
              psq_job     <= 1;
              psq_job_tag <= psq_tag_cur;
              psq_fill    <= '0;
              st          <= S_REQ;
            end
          end
        end

        S_REQ: begin
           // Qsys master translator는 byte 주소를 그대로 전달하고, HPS slave
           // translator가 이를 64-bit word 주소로 변환한다.
           m_address    <= ft_job ? (ft_addr_cur << 3) : (psq_addr_cur << 3);
           m_burstcount <= ft_job ? ft_bcnt : 7'd1;
          m_read       <= 1;
          if (m_read && !m_waitrequest) begin
            bcnt_r  <= m_burstcount;
            beat    <= '0;
            m_read  <= 0;
            st      <= S_DRAIN;
          end
        end

        S_DRAIN: begin
          if (m_readdatavalid) begin
            if (ft_job) begin
              ftbuf[ft_fill] <= m_readdata;
              ft_fill        <= ft_fill + 1'b1;
              ft_rem         <= ft_rem - 1'b1;
            end else begin
              psq_line[psq_fill*64 +: 64] <= m_readdata;
              psq_fill                   <= psq_fill + 1'b1;
            end
            beat <= beat + 1'b1;
            if (beat == bcnt_r - 6'd1) begin
              if (ft_job) begin
                if (ft_rem == bcnt_r) begin   // 이 버스트가 컬럼 마지막 청크
                  ft_job <= 0;
                  ft_tag <= ft_job_tag;
                  st     <= S_IDLE;
                end else
                  st <= S_REQ;                // 다음 청크
              end else begin
                psq_job <= 0;
                psq_tag <= psq_job_tag;
                st      <= S_IDLE;
              end
            end
          end
        end

        default: st <= S_IDLE;
      endcase
    end
  end

  // 조합 PSQT 리드 (그룹 적재 완료 후 안정)
  assign psq_rd_data = psq_line[psq_rd_addr[2:0]*32 +: 32];

endmodule
