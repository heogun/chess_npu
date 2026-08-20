// fc_pipe.sv - FC 파이프라인 (M3 시뮬레이션용, 시퀀셜 MAC)
//
// ref_eval evaluate() 651-687 (SF18 propagate + SqrClippedReLU + ClippedReLU,
// fwdOut) 을 그대로 재현:
//   fc0_out[j] = bias[j] + Σ_i q[i]*w[j*paddedIn+i]      (j<16, paddedIn=HD)
//   ac_sqr_0[i]  = min(127, fc0_out[i]^2 >> 19)          (i<16)
//   ac_0[i]      = clamp(fc0_out[i] >> 6, 0, 127)        (i<16)
//   ac_sqr_0[15+i] = ac_0[i]                             (i<15: [15] 덮어씀)
//   fc1_out[j] = bias[j] + Σ_i ac_sqr_0[i]*w[j*32+i]     (j<32, [30..31]=0)
//   ac_1[i]     = clamp(fc1_out[i] >> 6, 0, 127)         (i<32)
//   v2         = bias[0] + Σ_i ac_1[i]*w[i]              (i<32)
//   fwdOut     = fc0_out[15] * 9600 / 8128   (int32 산술: 캐리/래핑 재현)
//   result     = (int32)(v2 + fwdOut)                    (= FCDUMP POS)

module fc_pipe #(
  parameter int HD     = 1024,
  parameter int ADDR_W = 18
)(
  input  logic              clk,
  input  logic              rst,

  input  logic              start,
  input  logic [2:0]        bucket,

  input  logic              q_we,
  input  logic [$clog2(HD)-1:0] q_addr,
  input  logic [7:0]        q_data,

  output logic [ADDR_W-1:0] fc_rd_addr,
  input  logic [7:0]        fc_rd_data,

  output logic              done,
  output logic [31:0]       result,
  output logic [31:0]       fwd_out
);

  localparam int PAD0 = (HD + 15) / 16 * 16;
  localparam int O_FC0B = 0;
  localparam int O_FC0W = 16 * 4;
  localparam int O_FC1B = O_FC0W + 16 * PAD0;
  localparam int O_FC1W = O_FC1B + 32 * 4;
  localparam int O_FC2B = O_FC1W + 32 * 32;
  localparam int O_FC2W = O_FC2B + 1 * 4;
  localparam int BUCKET = O_FC2W + 32;

  typedef enum logic [3:0] {
    S_IDLE, S_FC0B, S_FC0W, S_ACT,
    S_FC1B, S_FC1W, S_ACT1,
    S_FC2B, S_FC2W, S_DONE
  } state_t;
  state_t st;

  logic [7:0] q [0:HD-1];
  always_ff @(posedge clk) begin
    if (q_we)
      q[q_addr] <= q_data;
  end

  logic [4:0]  j;              // fc0: 0..15, fc1: 0..31
  logic [10:0] i;              // fc0: 0..PAD0-1, fc1/fc2: 0..31
  logic [1:0]  bc;             // bias 바이트 0..3 (LE)
  logic signed [63:0] acc;
  logic signed [31:0] fc0_raw [0:15];
  logic [7:0]  fcin [0:31];    // ac_sqr_0 (fc1 입력, [30..31]=0)
  logic signed [31:0] fc1_raw [0:31];
  logic [7:0]  ac1 [0:31];
  logic signed [63:0] fc2_raw;
  logic [31:0] fwd_q, res_q;

  logic [ADDR_W-1:0] base;
  assign base = ADDR_W'(bucket) * ADDR_W'(BUCKET);

  // ---- 바이트 주소 멀티플렉서 (fc_rd_addr 는 조합 리드) ----
  logic [ADDR_W-1:0] bias_addr, w_addr;
  always_comb begin
    bias_addr = '0;
    unique case (st)
      S_FC0B: bias_addr = base + ADDR_W'(O_FC0B) + ADDR_W'(j) * 4 + ADDR_W'(bc);
      S_FC1B: bias_addr = base + ADDR_W'(O_FC1B) + ADDR_W'(j) * 4 + ADDR_W'(bc);
      S_FC2B: bias_addr = base + ADDR_W'(O_FC2B) + ADDR_W'(bc);
      default: bias_addr = '0;
    endcase
  end
  always_comb begin
    w_addr = '0;
    unique case (st)
      S_FC0W: w_addr = base + ADDR_W'(O_FC0W) + ADDR_W'(j) * ADDR_W'(PAD0) + ADDR_W'(i);
      S_FC1W: w_addr = base + ADDR_W'(O_FC1W) + ADDR_W'(j) * 32 + ADDR_W'(i);
      S_FC2W: w_addr = base + ADDR_W'(O_FC2W) + ADDR_W'(i);
      default: w_addr = '0;
    endcase
  end

  assign fc_rd_addr = (st == S_FC0B || st == S_FC1B || st == S_FC2B) ? bias_addr : w_addr;

  logic signed [7:0] w_sext;
  assign w_sext = $signed(fc_rd_data);

  logic [7:0] m_in;
  always_comb begin
    unique case (st)
      S_FC0W: m_in = q[i[$clog2(HD)-1:0]];
      S_FC1W: m_in = fcin[i[4:0]];
      S_FC2W: m_in = ac1[i[4:0]];
      default: m_in = '0;
    endcase
  end

  logic signed [63:0] mac_next;
  assign mac_next = acc + $signed(64'(m_in)) * $signed(w_sext);

    logic signed [31:0] fwd_mul32;
  assign fwd_mul32 = $signed(fc0_raw[15]) * $signed(32'd9600);

  logic signed [31:0] fwd_div32;
  assign fwd_div32 = $signed(fwd_q) / 32'sd8128;

  always_ff @(posedge clk) begin
    if (rst) begin
      st      <= S_IDLE;
      j       <= '0;
      i       <= '0;
      bc      <= '0;
      acc     <= '0;
      fc2_raw <= '0;
      fwd_q   <= '0;
      res_q   <= '0;
      done    <= 0;
    end else begin
      done <= 0;
      unique case (st)
        S_IDLE: if (start) begin
          j  <= 0;
          bc <= 0;
          st <= S_FC0B;
        end

        // ---- bias 바이트 LE 누적 (bc 0..3, 마지막 바이트에서 부호확장) ----
        S_FC0B: begin
          acc[8*bc +: 8] <= fc_rd_data;
          if (bc == 3) begin
            acc[63:32] <= {{32{fc_rd_data[7]}}};
            bc <= 0;
            i  <= 0;
            st <= S_FC0W;
          end else
            bc <= bc + 1;
        end

        S_FC0W: begin
          acc <= mac_next;
          if (i == 11'(PAD0 - 1)) begin
            fc0_raw[j[3:0]] <= mac_next[31:0];
            i <= 0;
            if (j == 15) begin
              j  <= 0;
              st <= S_ACT;
            end else begin
              j  <= j + 1;
              st <= S_FC0B;
            end
          end else
            i <= i + 1;
        end

        S_ACT: begin
          // [0..14] = sqr, [15+i] = ac_0[i] (i<15), [30..31] = 0
          fcin[0]  <= sqr7(fc0_raw[0]);  fcin[15] <= ac7(fc0_raw[0]);
          fcin[1]  <= sqr7(fc0_raw[1]);  fcin[16] <= ac7(fc0_raw[1]);
          fcin[2]  <= sqr7(fc0_raw[2]);  fcin[17] <= ac7(fc0_raw[2]);
          fcin[3]  <= sqr7(fc0_raw[3]);  fcin[18] <= ac7(fc0_raw[3]);
          fcin[4]  <= sqr7(fc0_raw[4]);  fcin[19] <= ac7(fc0_raw[4]);
          fcin[5]  <= sqr7(fc0_raw[5]);  fcin[20] <= ac7(fc0_raw[5]);
          fcin[6]  <= sqr7(fc0_raw[6]);  fcin[21] <= ac7(fc0_raw[6]);
          fcin[7]  <= sqr7(fc0_raw[7]);  fcin[22] <= ac7(fc0_raw[7]);
          fcin[8]  <= sqr7(fc0_raw[8]);  fcin[23] <= ac7(fc0_raw[8]);
          fcin[9]  <= sqr7(fc0_raw[9]);  fcin[24] <= ac7(fc0_raw[9]);
          fcin[10] <= sqr7(fc0_raw[10]); fcin[25] <= ac7(fc0_raw[10]);
          fcin[11] <= sqr7(fc0_raw[11]); fcin[26] <= ac7(fc0_raw[11]);
          fcin[12] <= sqr7(fc0_raw[12]); fcin[27] <= ac7(fc0_raw[12]);
          fcin[13] <= sqr7(fc0_raw[13]); fcin[28] <= ac7(fc0_raw[13]);
          fcin[14] <= sqr7(fc0_raw[14]); fcin[29] <= ac7(fc0_raw[14]);
          fcin[30] <= '0;
          fcin[31] <= '0;
          fwd_q    <= fwd_mul32;
          j        <= 0;
          bc       <= 0;
          st       <= S_FC1B;
        end

        S_FC1B: begin
          acc[8*bc +: 8] <= fc_rd_data;
          if (bc == 3) begin
            acc[63:32] <= {{32{fc_rd_data[7]}}};
            bc <= 0;
            i  <= 0;
            st <= S_FC1W;
          end else
            bc <= bc + 1;
        end

        S_FC1W: begin
          acc <= mac_next;
          if (i == 31) begin
            fc1_raw[j] <= mac_next[31:0];
            i <= 0;
            if (j == 31) begin
              j  <= 0;
              st <= S_ACT1;
            end else begin
              j  <= j + 1;
              st <= S_FC1B;
            end
          end else
            i <= i + 1;
        end

        S_ACT1: begin
          ac1[0]  <= ac7(fc1_raw[0]);
          ac1[1]  <= ac7(fc1_raw[1]);
          ac1[2]  <= ac7(fc1_raw[2]);
          ac1[3]  <= ac7(fc1_raw[3]);
          ac1[4]  <= ac7(fc1_raw[4]);
          ac1[5]  <= ac7(fc1_raw[5]);
          ac1[6]  <= ac7(fc1_raw[6]);
          ac1[7]  <= ac7(fc1_raw[7]);
          ac1[8]  <= ac7(fc1_raw[8]);
          ac1[9]  <= ac7(fc1_raw[9]);
          ac1[10] <= ac7(fc1_raw[10]);
          ac1[11] <= ac7(fc1_raw[11]);
          ac1[12] <= ac7(fc1_raw[12]);
          ac1[13] <= ac7(fc1_raw[13]);
          ac1[14] <= ac7(fc1_raw[14]);
          ac1[15] <= ac7(fc1_raw[15]);
          ac1[16] <= ac7(fc1_raw[16]);
          ac1[17] <= ac7(fc1_raw[17]);
          ac1[18] <= ac7(fc1_raw[18]);
          ac1[19] <= ac7(fc1_raw[19]);
          ac1[20] <= ac7(fc1_raw[20]);
          ac1[21] <= ac7(fc1_raw[21]);
          ac1[22] <= ac7(fc1_raw[22]);
          ac1[23] <= ac7(fc1_raw[23]);
          ac1[24] <= ac7(fc1_raw[24]);
          ac1[25] <= ac7(fc1_raw[25]);
          ac1[26] <= ac7(fc1_raw[26]);
          ac1[27] <= ac7(fc1_raw[27]);
          ac1[28] <= ac7(fc1_raw[28]);
          ac1[29] <= ac7(fc1_raw[29]);
          ac1[30] <= ac7(fc1_raw[30]);
          ac1[31] <= ac7(fc1_raw[31]);
          bc <= 0;
          st <= S_FC2B;
        end

        S_FC2B: begin
          acc[8*bc +: 8] <= fc_rd_data;
          if (bc == 3) begin
            acc[63:32] <= {{32{fc_rd_data[7]}}};
            bc <= 0;
            i  <= 0;
            st <= S_FC2W;
          end else
            bc <= bc + 1;
        end

        S_FC2W: begin
          acc <= mac_next;
          fc2_raw <= mac_next;
          if (i == 31) begin
            res_q <= 32'(mac_next + $signed(fwd_div32));
            st    <= S_DONE;
          end else
            i <= i + 1;
        end

        S_DONE: begin
          done <= 1;
          st   <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end

  assign result  = res_q;
  assign fwd_out = fwd_div32;

  // min(127, x*x >> 19)
  function automatic logic [7:0] sqr7(input logic signed [31:0] v);
    logic signed [63:0] p;
    p = $signed(v) * $signed(v);
    sqr7 = ($unsigned(p >>> 19) > 127) ? 8'd127 : p[26:19];
  endfunction

  // clamp(x >> 6, 0, 127)
  function automatic logic [7:0] ac7(input logic signed [31:0] v);
    logic signed [31:0] s;
    s = v >>> 6;
    ac7 = (s < 0) ? '0 : (s > 127 ? 8'd127 : s[7:0]);
  endfunction

endmodule