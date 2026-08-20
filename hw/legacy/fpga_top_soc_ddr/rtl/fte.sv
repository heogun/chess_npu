// fte.sv - Feature Transformer 엔진 (M2, small + big 경로)
//
// ref_eval.cc evaluate() 의 어큐뮬레이터 + quantize(reference #else 경로)를
// 하드웨어로 재현. ARM(테스트벤치)이 active feature 인덱스 리스트를 스트림으로
// 제공하면:
//   1) bias 열 + 각 feature 열을 bram 에서 읽어 main acc[row][*] 에 누적
//   2) big: threat feature 열을 thr acc[row][*] 에 누적 (bias 없음, 0 초기화)
//   3) quantize: q[(HD/2)*p + j] = clamp*clamp >> 9
//        small: s = clamp(acc, 0, 254)
//        big:   s = clamp(acc + thr, 0, 255)
//  q 를 인덱스 순서대로 스트림 출력 후 done.
//
// 메모리 레이아웃 (weight_bram):
//   [0 .. HD-1]                        : FT bias 열
//   [HD + f*HD .. HD + (f+1)*HD-1]     : main feature f 의 weight 열
//   [HD + NF*HD + f*HD .. ]            : threat feature f 의 weight 열 (big)
//
// 타이밍 규칙 (불변, 검증 하네스가 이와 독립적으로 C++ 참조와 대조):
//   wb_data    : wb_addr 세팅 다음 클럭부터 조합 유효
//   acc_rd_data: acc_rd_req=1 다음 클럭부터 동기 유효 (main/thr 동일)
//   누적 루프  : j 당 2클럭 (ph0=read, ph1=write)
//   quantize   : qj 당 4클럭 (qph0=a0 read -> qph1=s0 capture+a1 read
//                -> qph2=s1 capture -> qph3=emit, qj advance)
//
// feature 프리페치: 모든 행(bias/first-dummy 열)이 프리페치 래그를 흡수.
//   main 행은 bias 열, threat 행은 write 를 억제한 dummy 열이 그 역할을 하므로
//   행 진입 시 fifo_rd 1회로 충분하고 좌표/누적 상태 머신은 행 간 동일하다.
module fte #(
  parameter int HD     = 128,
  parameter int NF     = 22528,
  parameter int TFF    = 0,
  parameter int ADDR_W = 22,
  parameter int FMAX   = 4096
)(
  input  logic              clk,
  input  logic              rst,

  input  logic              start,
  input  logic              use_big,
  input  logic              stm,
  input  logic [31:0]       cnt0,
  input  logic [31:0]       cnt1,
  input  logic [31:0]       cntt0,
  input  logic [31:0]       cntt1,

  input  logic              feat_valid,
  output logic              feat_ready,
  input  logic [31:0]       feat,

  output logic [ADDR_W-1:0] wb_addr,
  input  logic [15:0]       wb_data,
  input  logic              wb_ready,      // wb_data 가 현재 wb_addr 에 대해 유효

  output logic              acc_rd_req,
  output logic [10:0]       acc_rd_addr,
  input  logic [31:0]       acc_rd_data,
  output logic              acc_wr_we,
  output logic [10:0]       acc_wr_addr,
  output logic [31:0]       acc_wr_data,

  output logic              thr_rd_req,
  output logic [10:0]       thr_rd_addr,
  input  logic [31:0]       thr_rd_data,
  output logic              thr_wr_we,
  output logic [10:0]       thr_wr_addr,
  output logic [31:0]       thr_wr_data,

  output logic              q_valid,
  output logic [$clog2(HD)-1:0] q_index,
  output logic [7:0]        q_data,

  output logic              done,

  // ---- 디버그: quantize 파이프라인 관찰 ----
  output logic [1:0]        dbg_qph,
  output logic [$clog2(HD/2)-1:0] dbg_qj,
  output logic [31:0]       dbg_s0q,
  output logic [31:0]       dbg_s1q,
  output logic [10:0]       dbg_acc_rd_addr,
  output logic [31:0]       dbg_acc_rd_data,
  output logic              dbg_acc_rd_req
);

  typedef enum logic [3:0] { S_IDLE, S_ROW0, S_ROW1, S_TROW0, S_TROW1, S_Q0, S_Q1, S_DONE } state_t;
  state_t st;

  typedef enum logic { SRC_BIAS, SRC_FEAT } src_t;
  src_t src;

  localparam logic [$clog2(HD)-1:0]  JMAX = $clog2(HD)'(HD - 1);
  localparam logic [$clog2(HD/2)-1:0] QMAX = $clog2(HD/2)'(HD/2 - 1);
  localparam logic [$clog2(HD)-1:0]  HDO2 = $clog2(HD)'(HD/2);
  localparam logic [ADDR_W-1:0]      THR_BASE = ADDR_W'(HD) + ADDR_W'(NF) * ADDR_W'(HD);

  logic [31:0]              fcnt;     // 현재 row 남은 feature 수
  logic [$clog2(HD)-1:0]    jctr;     // 열 내 위치 0..HD-1
  logic                     ph;       // 누적 2-클럭 위상
  logic                     row;      // 0=persp0, 1=persp1
  logic [31:0]              fcur;     // 현재 feature 인덱스
  logic [1:0]               qph;      // quantize 4-클럭 위상
  logic [$clog2(HD/2)-1:0]  qj;
  logic [31:0]              s0q, s1q, s0t, s1t;

  // ---- feature FIFO ----
  logic [31:0]              fifo [0:FMAX-1];
  logic [$clog2(FMAX):0]    fw, fr;
  logic                     fifo_rd;
  logic [31:0]              fout;

  always_ff @(posedge clk) begin
    if (rst) begin
      fw      <= '0;
      fr      <= '0;
      fout    <= '0;
    end else begin
      if (feat_valid && feat_ready) begin
        fifo[fw[$clog2(FMAX)-1:0]] <= feat;
        fw       <= fw + 1;
      end
      if (fifo_rd) begin
        fout <= fifo[fr[$clog2(FMAX)-1:0]];
        fr   <= fr + 1;
      end
    end
  end

  assign feat_ready = ~rst;

  // ---- 컨트롤러 ----
  always_ff @(posedge clk) begin
    if (rst) begin
      st      <= S_IDLE;
      src     <= SRC_BIAS;
      fcnt    <= '0;
      jctr    <= '0;
      ph      <= 0;
      row     <= 0;
      fcur    <= '0;
      qph     <= 0;
      qj      <= '0;
      fifo_rd <= 0;
    end else begin
      fifo_rd <= 0;
      case (st)
        S_IDLE: if (start) begin
          st      <= S_ROW0;
          row     <= 0;
          src     <= SRC_BIAS;
          fcnt    <= cnt0;
          jctr    <= '0;
          ph      <= 0;
          fifo_rd <= 1;                  // feature0 프리페치
        end

        S_ROW0, S_ROW1, S_TROW0, S_TROW1: begin
          if (!ph) begin
            // DDR 스트리밍: 현재 주소의 컬럼이 적재되기 전엔 대기 (산술 불변)
            if (wb_ready)
              ph <= 1;
          end else begin
            ph <= 0;
            if (jctr == JMAX) begin
              jctr <= '0;
              if (src == SRC_BIAS) begin
                src <= SRC_FEAT;
                // 빈 그룹(fcnt==0)이면 소비 금지: fout 은 다음 비어있지 않은
                // 그룹의 첫 feature 를 유지해야 정렬이 깨지지 않는다.
                if (fcnt != 0) begin
                  fcur    <= fout;         // 첫 feature (bias 열 프리페치 흡수)
                  fifo_rd <= 1;
                end
              end else if (fcnt > 1) begin
                fcur    <= fout;
                fcnt    <= fcnt - 1;
                fifo_rd <= 1;
              end else begin
                fcnt <= '0;
                case (st)
                  S_ROW0: begin
                    st   <= S_ROW1;
                    row  <= 1;
                    src  <= SRC_BIAS;
                    fcnt <= cnt1;
                  end
                  S_ROW1: begin
                    if (use_big) begin
                      st   <= S_TROW0;
                      row  <= 0;
                      src  <= SRC_BIAS;
                      fcnt <= cntt0;
                      // 주의: fifo_rd 금지 — 직전 열(fcnt 2->1)이 이미
                      // 다음 그룹 첫 threat feature 를 fout 에 프리페치함.
                    end else begin
                      st  <= S_Q0;
                      qph <= 0;
                      qj  <= '0;
                    end
                  end
                  S_TROW0: begin
                    st   <= S_TROW1;
                    row  <= 1;
                    src  <= SRC_BIAS;
                    fcnt <= cntt1;
                    // fifo_rd 금지 (위와 동일 사유)
                  end
                  default: begin          // S_TROW1
                    st  <= S_Q0;
                    qph <= 0;
                    qj  <= '0;
                  end
                endcase
              end
            end else
              jctr <= jctr + 1;
          end
        end

        S_Q0, S_Q1: begin
          case (qph)
            0: qph <= 1;
            1: begin
              s0q <= acc_rd_data;
              s0t <= thr_rd_data;
              qph <= 2;
            end
            2: begin
              s1q <= acc_rd_data;
              s1t <= thr_rd_data;
              qph <= 3;
            end
            default: begin
              qph <= 0;
              if (qj == QMAX) begin
                if (st == S_Q0) begin
                  st <= S_Q1;
                  qj <= '0;
                end else
                  st <= S_DONE;
              end else
                qj <= qj + 1;
            end
          endcase
        end

        S_DONE: st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end

  // ---- 주소 경로 (조합, 단일 드라이버) ----
  logic [ADDR_W-1:0] wb_addr_comb;
  always_comb begin
    if (st == S_ROW0 || st == S_ROW1) begin
      if (src == SRC_BIAS)
        wb_addr_comb = ADDR_W'(jctr);
      else
        wb_addr_comb = ADDR_W'(HD) + ADDR_W'(fcur) * ADDR_W'(HD) + ADDR_W'(jctr);
    end else if (st == S_TROW0 || st == S_TROW1)
      wb_addr_comb = THR_BASE + ADDR_W'(fcur) * ADDR_W'(HD) + ADDR_W'(jctr);
    else
      wb_addr_comb = '0;
  end
  assign wb_addr = wb_addr_comb;

  wire qpersp = (st == S_Q0) ? stm : ~stm;   // 조합: Q0=stm, Q1=~stm

  // ---- acc read (조합) ----
  always_comb begin
    if (st == S_ROW0 || st == S_ROW1 || st == S_TROW0 || st == S_TROW1) begin
      acc_rd_req  = !ph;
      acc_rd_addr = 11'({row, jctr});
    end else if (st == S_Q0 || st == S_Q1) begin
      acc_rd_req  = (qph == 0) || (qph == 1);
      acc_rd_addr = (qph == 0) ? 11'({qpersp, 1'b0, qj})
                               : 11'({qpersp, 1'b1, qj});
    end else begin
      acc_rd_req  = 0;
      acc_rd_addr = '0;
    end
  end

  // ---- 누적 write (ph==1); main 은 bias 상속 후 누적, threat 는 0 에서 누적 ----
  // threat 는 bias 없음: dummy(bias) 열이 ref_eval 의 assign(HD,0) 초기화 역할.
  // 빈 그룹(fcnt==0)의 drainer 열에서는 누적 금지 — fcur 은 이전 행 잔재이므로
  // 쓰레기 가중치가 더해진다.
  wire signed [31:0] sext_col = {{16{wb_data[15]}}, wb_data};
  wire acc_gate = (src != SRC_FEAT) || (fcnt != 0);
  assign acc_wr_we   = (st == S_ROW0 || st == S_ROW1) && ph && acc_gate;
  assign acc_wr_addr = 11'({row, jctr});
  assign acc_wr_data = (src == SRC_BIAS) ? {{16{wb_data[15]}}, wb_data}
                                         : (acc_rd_data + sext_col);
  assign thr_wr_we   = (st == S_TROW0 || st == S_TROW1) && ph && acc_gate;
  assign thr_wr_addr = 11'({row, jctr});
  assign thr_wr_data = (src == SRC_BIAS) ? '0 : (thr_rd_data + sext_col);

  // ---- thr read 는 main 과 동일 주소/요청 ----
  assign thr_rd_req  = acc_rd_req;
  assign thr_rd_addr = acc_rd_addr;

  // ---- quantize 출력 (qph==3): big 은 acc+thr 합산 후 clamp(0,255) ----
  wire [31:0] qs0 = use_big ? (s0q + s0t) : s0q;
  wire [31:0] qs1 = use_big ? (s1q + s1t) : s1q;
  wire [7:0]  qout;
  quantize u_q (.use_big(use_big), .s0(qs0), .s1(qs1), .q(qout));

  assign q_valid = (st == S_Q0 || st == S_Q1) && (qph == 3);
  assign q_index = (st == S_Q0) ? ($clog2(HD)'(qj)) : ($clog2(HD)'(qj) + HDO2);
  assign q_data  = qout;
  assign done    = (st == S_DONE);

  // ---- 디버그: quantize 파이프라인 관찰 ----
  assign dbg_qph         = qph;
  assign dbg_qj          = qj;
  assign dbg_s0q         = s0q;
  assign dbg_s1q         = s1q;
  assign dbg_acc_rd_addr = acc_rd_addr;
  assign dbg_acc_rd_data = acc_rd_data;
  assign dbg_acc_rd_req  = acc_rd_req;

endmodule