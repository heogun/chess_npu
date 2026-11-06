// SF19 NNUE core with on-chip accumulator slots.
//
// Each perspective of a request is a full refresh, an incremental update from another slot, or
// a reuse of the destination slot. The core then computes FT, FC0-FC2 and the final
// (psqt, positional) pair. Register and descriptor formats are in docs/reports/M3_resources.md.
//
// With FC_CACHE = 1 the FC layers of the two most recently used buckets live on chip. A miss
// copies the whole bucket (bias, FC0, FC1, FC2: 4,401 words) from memory once; afterwards FC
// reads come from M10K at one word per cycle, and a new column is issued while the previous one
// is still in flight. A write to BASE or CONTROL bit 4 empties the cache, so weights must not
// change in memory without one of them. docs/reports/perf_proposal.md, step 2.
//
// Simulation and compilation of this module do not establish correctness on the board.
module nnue_core
#(
  parameter int WATCHDOG_CYCLES = 1 << 20,  // cycles without memory progress before ERR_TIMEOUT
  parameter bit FC_CACHE        = 1'b1      // on-chip FC weights for two buckets
) (
  input  logic        clk,
  input  logic        rst,

  // CSR slave: read latency of 1 unless csr_waitrequest is high
  input  logic [4:0]  csr_address,
  input  logic        csr_read,
  input  logic        csr_write,
  input  logic [31:0] csr_writedata,
  output logic [31:0] csr_readdata,
  output logic        csr_waitrequest,

  // Memory master: word-aligned byte addresses, pipelined bursts
  output logic [31:0] m_address,
  output logic        m_read,
  output logic [4:0]  m_burstcount,
  input  logic        m_waitrequest,
  input  logic [63:0] m_readdata,
  input  logic        m_readdatavalid,

  output logic        irq
);

  import nnue_spec_pkg::*;
  import nnue_math_pkg::*;

  // ---- Elaboration checks: this datapath only implements the sf_19 graph ----
  localparam int CHECK_DIMS = 1 / ((L1 == 1024 && L2 == 32 && L3 == 32 && PSQT_BUCKETS == 8 &&
                                    LAYER_STACKS == 8 && BUS_BYTES == 8) ? 1 : 0);
  localparam int CHECK_ROWS = 1 / ((PSQ_ROW_BYTES == 2048 && ACTIVE_ROW_BYTES == 1024 &&
                                    PSQT_ROW_BYTES == 32 && FC0_COL_BYTES == 32 &&
                                    FC1_COL_BYTES == 32 && FC2_BYTES == 128 &&
                                    FC1_INPUTS == 64 && FC2_INPUTS == 128) ? 1 : 0);
  localparam int CHECK_SCALE = 1 / ((OUTPUT_SCALE == 16 && WEIGHT_SCALE_BITS == 6 &&
                                     POSITIONAL_DIVISOR == 16384) ? 1 : 0);
  localparam int CHECK_SLOTS = 1 / ((ACC_SLOTS == 32 && DESC_HEADER_WORDS == 6) ? 1 : 0);

  localparam logic [31:0] ID_VALUE = 32'h4E4E5545;  // "NNUE"
  localparam int MAX_BURST  = 16;
  localparam int SLOTS      = int'(ACC_SLOTS);
  localparam int FEAT_WORDS = (2 * int'(MAX_PSQ_ACTIVE) + 2 * int'(MAX_THREAT_ACTIVE)) * 2 / 4;

  // CSR word offsets
  localparam logic [4:0] CSR_ID = 0, CSR_ABI = 1, CSR_HASH = 2, CSR_NET = 3, CSR_CONTROL = 4,
    CSR_STATUS = 5, CSR_DESC = 6, CSR_BASE = 7, CSR_SEQ = 8, CSR_OUT_PSQT = 9, CSR_OUT_POS = 10,
    CSR_RAW_PSQT = 11, CSR_RAW_POS = 12, CSR_CYCLES = 13, CSR_WAITS = 14, CSR_WORDS = 15,
    CSR_TSEL = 16, CSR_TDATA = 17, CSR_CTX = 18, CSR_SLOTS = 19, CSR_PSEL = 20, CSR_PDATA = 21;

  // Profile counters, selected by PSEL and read from PDATA. Cleared on start.
  // 0-11: cycles per stage. Every non-idle state belongs to exactly one, so they sum to CYCLES.
  //   0 descriptor and drain, 1 feature row wait, 2 PSQT wait, 3 other accumulator work,
  //   4 FT, 5 FC bias, 6 FC0 scan, 7 FC0 column wait, 8 activation, 9 FC1, 10 FC2, 11 final
  // 12-19: read requests issued per sink: header, features, PSQ row (and FT bias), active row,
  //   PSQT row, FC bias, FC0 column, FC2. 20: FC1 columns (counted apart from FC0). 21: FC cache
  //   fills. With the cache, FC requests are counted the same way but served on chip, and stage 5
  //   includes the fill.
  localparam int PERF_STAGES = 12, PERF_COUNT = 22;

  // FC cache: word offsets inside one bucket's stack.
  localparam int FCC_WORDS   = (int'(STACK_FC2_OFFSET) + int'(FC2_BYTES)) / 8;  // 4401
  localparam int FCC_FC0     = int'(STACK_FC0_OFFSET) / 8;
  localparam int FCC_FC1     = int'(STACK_FC1_OFFSET) / 8;
  localparam int FCC_FC2     = int'(STACK_FC2_OFFSET) / 8;
  localparam int CHECK_FCC   = 1 / ((int'(STACK_FC0_OFFSET) % 8 == 0 && int'(STACK_FC1_OFFSET) % 8 == 0 &&
                                     int'(STACK_FC2_OFFSET) % 8 == 0 && int'(FC_BIAS_BYTES) == 264) ? 1 : 0);

  // Error codes, reported in STATUS[15:8]
  localparam logic [7:0] ERR_NONE = 0, ERR_MAGIC = 1, ERR_ABI = 2, ERR_HASH = 3, ERR_NET = 4,
    ERR_RANGE = 5, ERR_RESERVED = 6, ERR_TIMEOUT = 7, ERR_ALIGN = 8, ERR_SLOT = 9;

  // Per-perspective operations in a descriptor
  localparam logic [1:0] OP_NONE = 2'd0, OP_REFRESH = 2'd1, OP_INCR = 2'd2;

  typedef enum logic [5:0] {
    S_IDLE, S_DRAIN, S_HDR, S_HDR_WAIT, S_HDR_LATCH, S_HDR_CHECK, S_FEAT_WAIT, S_FILL_WAIT,
    S_P_BEGIN, S_PL_RD, S_PL_DATA, S_COPY, S_COPY_WAIT,
    S_BIAS_WAIT, S_ROW_NEXT, S_ROW_RD, S_ROW_LAT, S_ROW_WAIT, S_PSQT_WAIT, S_PS, S_P_NEXT,
    S_FT, S_FT_WAIT, S_STK_WAIT,
    S_FC0_RD, S_FC0_LOAD, S_FC0_PICK, S_FC0_WAIT,
    S_AC_A, S_AC_B, S_AC_C,
    S_FC1_PICK, S_FC1_WAIT, S_FC2_WAIT,
    S_FINAL_A, S_FINAL_B, S_FINAL_C
  } state_t;

  typedef enum logic [3:0] {
    M_HDR, M_FEAT, M_PSQ_ROW, M_ACTIVE_ROW, M_PSQT, M_FC_BIAS, M_FC_COL, M_FC2, M_FILL
  } sink_t;

  // Kinds of words read from the FC cache
  typedef enum logic [1:0] { K_BIAS, K_COL, K_FC2 } fck_t;

  typedef enum logic [1:0] { T_LOAD, T_ADD, T_SUB, T_COPY } tile_mode_t;

  state_t state;
  sink_t  sink_mode;

  // ---- CSR state ----
  logic [31:0] desc_addr, weight_base;
  logic        irq_enable, done, err_flag;
  logic [7:0]  err_code;
  logic [31:0] tsel;
  logic [2:0]  tsel_wait;
  logic [31:0] tdata;

  // ---- Read engine ----
  logic [31:0] cmd_addr;
  logic [15:0] cmd_left, row_left, word_idx;
  logic [15:0] outstanding;
  logic        aborting;
  logic [20:0] wd;

  assign m_read       = cmd_left != 0;
  assign m_address    = cmd_addr;
  assign m_burstcount = (cmd_left > 16'(MAX_BURST)) ? 5'(MAX_BURST) : cmd_left[4:0];

  logic accept;
  assign accept = m_read && !m_waitrequest;

  // ---- Descriptor ----
  logic [63:0] hdr [0:5];
  logic [31:0] seq;
  logic [15:0] ctx;
  logic        stm;
  logic [2:0]  bucket;
  logic [4:0]  dst_slot;
  logic [4:0]  src_slot [0:1];
  logic [1:0]  op [0:1];
  logic [9:0]  n_list [0:7];     // index {perspective, active, remove}
  logic [10:0] list_base [0:7];

  // ---- Slot table ----
  logic [1:0]  slot_valid [0:SLOTS-1];
  logic [15:0] slot_owner [0:SLOTS-1];
  logic [1:0]  look_dst_valid, look_src0_valid, look_src1_valid;
  logic [15:0] look_dst_owner, look_src0_owner, look_src1_owner;

  logic        feat_we;
  logic [8:0]  feat_waddr, feat_raddr;
  logic [63:0] feat_wdata, feat_rdata;

  logic        cur_p;
  logic [1:0]  list_k;           // {active, remove}
  logic [9:0]  cur_i;
  logic [2:0]  cur_list;
  logic [10:0] gidx;
  logic [15:0] cur_feature;
  logic        cur_act, cur_rem;
  assign cur_act     = list_k[1];
  assign cur_rem     = list_k[0];
  assign cur_list    = {cur_p, list_k};
  assign gidx        = list_base[cur_list] + 11'(cur_i);
  assign feat_raddr  = gidx[10:2];
  assign cur_feature = feat_rdata[16 * gidx[1:0] +: 16];

  // ---- Accumulator: tiles 0-63 and 64-127 are separate banks, so FT reads both at once ----
  logic         acc_we;
  logic [6:0]   acc_wtile;
  logic [11:0]  acc_waddr, acc_raddr_lo, acc_raddr_hi;
  logic [127:0] acc_wdata, acc_rdata_lo, acc_rdata_hi, acc_rdata_rmw;

  logic         tile_v0, tile_v1, bias_mode;
  tile_mode_t   tile_mode0, tile_mode1;
  logic [6:0]   tile_t0, tile_t1, copy_t;
  logic [127:0] tile_delta0, tile_delta1;
  logic [63:0]  tile_hold;
  logic [4:0]   tile_rslot;

  assign tile_rslot    = (tile_mode0 == T_COPY) ? src_slot[cur_p] : dst_slot;
  assign acc_waddr     = {dst_slot, cur_p, acc_wtile[5:0]};
  assign acc_rdata_rmw = tile_t1[6] ? acc_rdata_hi : acc_rdata_lo;

  // ---- PSQT: working registers plus one memory word per pair of buckets ----
  logic signed [31:0] psqt_acc [0:1][0:7];
  logic         psqt_we;
  logic [7:0]   psqt_waddr, psqt_raddr;
  logic [63:0]  psqt_wdata, psqt_rdata;
  logic [4:0]   psqt_rslot;
  logic [1:0]   pk;
  assign psqt_raddr = {psqt_rslot, cur_p, pk};

  // ---- FT ----
  logic        ft_p;
  logic [5:0]  ft_t;
  logic        ft_v0, ft_v1;
  logic [6:0]  ft_addr0, ft_addr1;
  logic [7:0]  ft_a [0:7], ft_b [0:7];
  logic [63:0] ft_out;
  logic        ft_perspective;
  assign ft_perspective = ft_p ? ~stm : stm;

  logic [6:0]  ft_raddr, ft_ptr;
  logic [63:0] ft_rdata, scan_word;
  logic [7:0]  scan_nz;
  logic [2:0]  scan_lane;

  // ---- FC ----
  logic [31:0]        stack_base;
  logic signed [31:0] fc0 [0:31];
  logic signed [31:0] fc1 [0:31];
  logic signed [31:0] fc2;
  logic [7:0]         concat [0:127];
  logic [7:0]         mac_value;
  logic [6:0]         fc1_col;
  logic signed [15:0] mac_prod [0:7];
  logic               mac_v0, mac_v1;
  logic [1:0]         mac_idx;
  logic [1:0]         mac_layer;  // 0 FC0, 1 FC1, 2 FC2
  logic signed [18:0] mac_sum;
  logic [1:0]         layer;

  // ---- Activation ----
  logic [4:0]  ac_i;
  logic [16:0] ac_mag;
  logic [33:0] ac_square;
  logic signed [31:0] ac_x;
  logic        ac_layer;

  // ---- Final ----
  logic signed [31:0] fwd, skip, raw_psqt, raw_pos, out_psqt, out_pos;
  logic signed [63:0] fwd_scaled;

  // ---- FC cache ----
  logic        fcc_valid [0:1];
  logic [2:0]  fcc_tag   [0:1];
  logic        fcc_lru;            // entry to replace next when both are valid
  logic        fcc_e, fill_e;      // entry in use, entry being filled
  logic        fcc_we;
  logic [13:0] fcc_waddr, fcc_raddr;
  logic [63:0] fcc_wdata, fcc_rdata;
  // Issue: one word per cycle while cq_left != 0. Each word carries its own index, input value
  // and layer, so a new column may be issued while the previous one is still in the pipeline.
  logic [12:0] cq_addr;
  logic [5:0]  cq_left, cq_idx;
  fck_t        cq_kind;
  logic [7:0]  cq_value;
  logic [1:0]  cq_layer;
  logic        c_v1, c_v2;
  fck_t        c_kind1, c_kind2;
  logic [5:0]  c_idx1, c_idx2;
  logic [7:0]  c_value1, c_value2;
  logic [1:0]  c_layer1, c_layer2;
  logic [63:0] c_data2;
  logic        cache_idle;
  assign cache_idle = cq_left == 0 && !c_v1 && !c_v2;
  assign fcc_raddr  = (fcc_e ? 14'(FCC_WORDS) : 14'd0) + 14'(cq_addr);

  // ---- Counters ----
  logic [31:0] cycles, mem_waits, mem_words;
  logic [31:0] perf [0:PERF_COUNT-1];
  logic [4:0]  psel;
  logic        go_pulse;
  logic [4:0]  go_index;
  logic [3:0]  stage;

  always_comb begin
    case (state)
      S_ROW_NEXT, S_ROW_RD, S_ROW_LAT, S_ROW_WAIT:    stage = 4'd1;
      S_PSQT_WAIT:                                    stage = 4'd2;
      S_P_BEGIN, S_PL_RD, S_PL_DATA, S_COPY, S_COPY_WAIT,
      S_BIAS_WAIT, S_PS, S_P_NEXT:                    stage = 4'd3;
      S_FT, S_FT_WAIT:                                stage = 4'd4;
      S_STK_WAIT, S_FILL_WAIT:                        stage = 4'd5;
      // With the cache, waiting in PICK for the previous column or the final drain is column wait.
      S_FC0_PICK:                                     stage = (FC_CACHE && ((scan_nz != 0 && cq_left > 6'd1) ||
                                                               (scan_nz == 0 && ft_ptr == 7'd127)))
                                                              ? 4'd7 : 4'd6;
      S_FC0_RD, S_FC0_LOAD:                           stage = 4'd6;
      S_FC0_WAIT:                                     stage = 4'd7;
      S_AC_A, S_AC_B, S_AC_C:                         stage = 4'd8;
      S_FC1_PICK, S_FC1_WAIT:                         stage = 4'd9;
      S_FC2_WAIT:                                     stage = 4'd10;
      S_FINAL_A, S_FINAL_B, S_FINAL_C:                stage = 4'd11;
      default:                                        stage = 4'd0;  // S_DRAIN, header, features
    endcase
  end

  logic pipes_idle;
  assign pipes_idle = !tile_v0 && !tile_v1 && !acc_we && !mac_v0 && !mac_v1;
  logic row_done;
  assign row_done = row_left == 0 && pipes_idle;

  assign scan_nz = {|scan_word[63:56], |scan_word[55:48], |scan_word[47:40], |scan_word[39:32],
                    |scan_word[31:24], |scan_word[23:16], |scan_word[15:8], |scan_word[7:0]};
  always_comb begin
    scan_lane = 3'd0;
    for (int k = 7; k >= 0; k--) if (scan_nz[k]) scan_lane = 3'(k);
  end

  // ---- Memories ----
  sdp_ram #(.WIDTH(64), .DEPTH(FEAT_WORDS)) u_feat (
    .clk, .we(feat_we), .waddr(feat_waddr), .wdata(feat_wdata), .raddr(feat_raddr), .rdata(feat_rdata));
  sdp_ram #(.WIDTH(128), .DEPTH(SLOTS * 128)) u_acc_lo (
    .clk, .we(acc_we && !acc_wtile[6]), .waddr(acc_waddr), .wdata(acc_wdata),
    .raddr(acc_raddr_lo), .rdata(acc_rdata_lo));
  sdp_ram #(.WIDTH(128), .DEPTH(SLOTS * 128)) u_acc_hi (
    .clk, .we(acc_we && acc_wtile[6]), .waddr(acc_waddr), .wdata(acc_wdata),
    .raddr(acc_raddr_hi), .rdata(acc_rdata_hi));
  sdp_ram #(.WIDTH(64), .DEPTH(SLOTS * 8)) u_psqt (
    .clk, .we(psqt_we), .waddr(psqt_waddr), .wdata(psqt_wdata), .raddr(psqt_raddr), .rdata(psqt_rdata));
  generate
    if (FC_CACHE) begin : g_fcc
      sdp_ram #(.WIDTH(64), .DEPTH(2 * FCC_WORDS)) u_fcc (
        .clk, .we(fcc_we), .waddr(fcc_waddr), .wdata(fcc_wdata), .raddr(fcc_raddr), .rdata(fcc_rdata));
    end else begin : g_no_fcc
      assign fcc_rdata = 64'd0;
    end
  endgenerate
  sdp_ram #(.WIDTH(64), .DEPTH(128)) u_ft (
    .clk, .we(ft_v1), .waddr(ft_addr1), .wdata(ft_out), .raddr(ft_raddr), .rdata(ft_rdata));

  always_comb begin
    if (state == S_FT) begin
      acc_raddr_lo = {dst_slot, ft_perspective, ft_t};
      acc_raddr_hi = {dst_slot, ft_perspective, ft_t};
    end else begin
      acc_raddr_lo = (tile_v0 && !tile_t0[6]) ? {tile_rslot, cur_p, tile_t0[5:0]}
                                              : {dst_slot, tsel[10], tsel[8:3]};
      acc_raddr_hi = (tile_v0 && tile_t0[6])  ? {tile_rslot, cur_p, tile_t0[5:0]}
                                              : {dst_slot, tsel[10], tsel[8:3]};
    end

    if (state == S_FC0_RD)    ft_raddr = ft_ptr;
    else                      ft_raddr = tsel[9:3];

    for (int k = 0; k < 8; k++)
      ft_out[8*k +: 8] = ft_product(ft_a[k], ft_b[k]);
  end

  task automatic go(input logic [31:0] addr, input logic [15:0] words, input sink_t mode);
    cmd_addr  <= addr;
    cmd_left  <= words;
    row_left  <= words;
    word_idx  <= 16'd0;
    sink_mode <= mode;
    go_pulse  <= 1'b1;
    go_index  <= (mode == M_FILL) ? 5'd21 : (mode == M_FC_COL && layer != 2'd0) ? 5'd20 : 5'd12 + 5'(mode);
  endtask

  // Starts reading `words` cache words of the current entry. Counted as the same request kinds as
  // the memory path, so the request counters stay comparable.
  task automatic cgo(input logic [12:0] addr, input logic [5:0] words, input fck_t kind,
                     input logic [7:0] value, input logic [1:0] lyr);
    cq_addr  <= addr;
    cq_left  <= words;
    cq_idx   <= 6'd0;
    cq_kind  <= kind;
    cq_value <= value;
    cq_layer <= lyr;
    go_pulse <= 1'b1;
    go_index <= (kind == K_BIAS) ? 5'd17 : (kind == K_FC2) ? 5'd19 : (lyr != 2'd0) ? 5'd20 : 5'd18;
  endtask

  task automatic fail(input logic [7:0] code);
    state    <= S_IDLE;
    done     <= 1'b1;
    err_flag <= 1'b1;
    err_code <= code;
    row_left <= 16'd0;
    cq_left  <= 6'd0;
    if (cmd_left != 0) aborting <= 1'b1;
  endtask

  // Validates one perspective's fields from the raw descriptor words.
  function automatic logic op_range_bad(input logic [1:0] o, input logic [7:0] src,
                                        input logic [15:0] psq_add, input logic [15:0] psq_rem,
                                        input logic [15:0] act_add, input logic [15:0] act_rem);
    if (o == 2'd3) return 1'b1;
    if (o == OP_INCR && src >= ACC_SLOTS[7:0]) return 1'b1;
    if (psq_add > MAX_PSQ_ACTIVE[15:0] || psq_rem > MAX_PSQ_ACTIVE[15:0]) return 1'b1;
    if (act_add > MAX_THREAT_ACTIVE[15:0] || act_rem > MAX_THREAT_ACTIVE[15:0]) return 1'b1;
    if (o == OP_REFRESH && (psq_rem != 0 || act_rem != 0)) return 1'b1;
    if (o == OP_NONE && (psq_add != 0 || psq_rem != 0 || act_add != 0 || act_rem != 0)) return 1'b1;
    return 1'b0;
  endfunction

  // Validates one perspective against the slot table latched in S_HDR_LATCH.
  function automatic logic op_slot_bad(input logic [1:0] o, input logic [4:0] src,
                                       input logic src_valid, input logic [15:0] src_owner,
                                       input logic [4:0] dst, input logic dst_valid,
                                       input logic [15:0] dst_owner, input logic [15:0] owner);
    if (o == OP_INCR) return src == dst || !src_valid || src_owner != owner;
    if (o == OP_NONE) return !dst_valid || dst_owner != owner;
    return 1'b0;
  endfunction

  logic [63:0] rd;
  assign rd = m_readdata;

  logic start_req, soft_reset;
  assign start_req  = csr_write && csr_address == CSR_CONTROL && csr_writedata[0];
  assign soft_reset = csr_write && csr_address == CSR_CONTROL && csr_writedata[1];

  assign irq = irq_enable && done;

  // Tensor reads are valid only while the core is idle. Tensor 0 reads the last destination slot.
  assign csr_waitrequest = csr_read && csr_address == CSR_TDATA && tsel_wait != 0;

  logic [127:0] tile_dbg;
  assign tile_dbg = tsel[9] ? acc_rdata_hi : acc_rdata_lo;

  always_ff @(posedge clk) begin
    case (tsel[31:28])
      4'd0:    tdata <= {{16{tile_dbg[16*tsel[2:0] + 15]}}, tile_dbg[16*tsel[2:0] +: 16]};
      4'd1:    tdata <= psqt_acc[tsel[3]][tsel[2:0]];
      4'd2:    tdata <= {24'd0, ft_rdata[8*tsel[2:0] +: 8]};
      4'd3:    tdata <= fc0[tsel[4:0]];
      4'd4:    tdata <= {24'd0, concat[tsel[6:0]]};
      4'd5:    tdata <= fc1[tsel[4:0]];
      4'd6:    tdata <= fc2;
      4'd7:    tdata <= fwd;
      4'd8:    tdata <= skip;
      default: tdata <= 32'd0;
    endcase

    case (csr_address)
      CSR_ID:       csr_readdata <= ID_VALUE;
      CSR_ABI:      csr_readdata <= ABI_VERSION[31:0];
      CSR_HASH:     csr_readdata <= NETWORK_HASH[31:0];
      CSR_NET:      csr_readdata <= NET_ID[31:0];
      CSR_CONTROL:  csr_readdata <= {29'd0, irq_enable, 2'd0};
      CSR_STATUS:   csr_readdata <= {16'd0, err_code, 5'd0, err_flag, done, state != S_IDLE};
      CSR_DESC:     csr_readdata <= desc_addr;
      CSR_BASE:     csr_readdata <= weight_base;
      CSR_SEQ:      csr_readdata <= seq;
      CSR_OUT_PSQT: csr_readdata <= out_psqt;
      CSR_OUT_POS:  csr_readdata <= out_pos;
      CSR_RAW_PSQT: csr_readdata <= raw_psqt;
      CSR_RAW_POS:  csr_readdata <= raw_pos;
      CSR_CYCLES:   csr_readdata <= cycles;
      CSR_WAITS:    csr_readdata <= mem_waits;
      CSR_WORDS:    csr_readdata <= mem_words;
      CSR_TSEL:     csr_readdata <= tsel;
      CSR_TDATA:    csr_readdata <= tdata;
      CSR_CTX:      csr_readdata <= {16'd0, ctx};
      CSR_SLOTS:    csr_readdata <= ACC_SLOTS[31:0];
      CSR_PSEL:     csr_readdata <= {27'd0, psel};
      CSR_PDATA:    csr_readdata <= (int'(psel) < PERF_COUNT) ? perf[psel] : 32'd0;
      default:      csr_readdata <= 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    feat_we <= 1'b0;
    psqt_we <= 1'b0;
    fcc_we  <= 1'b0;
    tile_v0 <= 1'b0;
    tile_v1 <= tile_v0;
    acc_we  <= tile_v1;
    mac_v0  <= 1'b0;
    mac_v1  <= 1'b0;
    ft_v0   <= 1'b0;
    ft_v1   <= ft_v0;

    if (tsel_wait != 0) tsel_wait <= tsel_wait - 3'd1;

    // ---- CSR writes ----
    if (csr_write) begin
      case (csr_address)
        CSR_CONTROL: begin
          irq_enable <= csr_writedata[2];
          if (csr_writedata[3]) begin  // clear done and error
            done     <= 1'b0;
            err_flag <= 1'b0;
            err_code <= ERR_NONE;
          end
          if (csr_writedata[4]) begin  // invalidate every slot and the FC cache
            for (int i = 0; i < SLOTS; i++) slot_valid[i] <= 2'b00;
            fcc_valid[0] <= 1'b0;
            fcc_valid[1] <= 1'b0;
          end
        end
        CSR_DESC: desc_addr <= csr_writedata;
        CSR_BASE: begin
          // Accumulators derived from other weights must not survive a weight change.
          weight_base <= csr_writedata;
          for (int i = 0; i < SLOTS; i++) slot_valid[i] <= 2'b00;
          fcc_valid[0] <= 1'b0;
          fcc_valid[1] <= 1'b0;
        end
        CSR_TSEL: begin
          tsel      <= csr_writedata;
          tsel_wait <= 3'd4;
        end
        CSR_PSEL: psel <= csr_writedata[4:0];
        default: ;
      endcase
    end

    // ---- Read engine ----
    if (accept) begin
      cmd_addr <= cmd_addr + {24'd0, m_burstcount, 3'b000};
      cmd_left <= aborting ? 16'd0 : cmd_left - 16'(m_burstcount);
    end
    if (cmd_left == 0) aborting <= 1'b0;

    case ({accept, m_readdatavalid})
      2'b10:   outstanding <= outstanding + 16'(m_burstcount);
      2'b11:   outstanding <= outstanding + 16'(m_burstcount) - 16'd1;
      2'b01:   outstanding <= outstanding - 16'd1;
      default: ;
    endcase

    if (m_read && m_waitrequest) mem_waits <= mem_waits + 32'd1;
    if (m_readdatavalid)         mem_words <= mem_words + 32'd1;
    if (state != S_IDLE)         cycles    <= cycles + 32'd1;
    if (state != S_IDLE)         perf[stage] <= perf[stage] + 32'd1;
    go_pulse <= 1'b0;
    if (go_pulse)                perf[go_index] <= perf[go_index] + 32'd1;

    // ---- Watchdog: counts only while waiting on memory ----
    if (state == S_IDLE || accept || m_readdatavalid || (cmd_left == 0 && outstanding == 0))
      wd <= 21'd0;
    else
      wd <= wd + 21'd1;

    // ---- Accumulator pipeline: read, compute, write ----
    if (tile_v0) begin
      tile_t1     <= tile_t0;
      tile_delta1 <= tile_delta0;
      tile_mode1  <= tile_mode0;
    end
    if (tile_v1) begin
      acc_wtile <= tile_t1;
      for (int k = 0; k < 8; k++)
        case (tile_mode1)
          T_LOAD:  acc_wdata[16*k +: 16] <= tile_delta1[16*k +: 16];
          T_ADD:   acc_wdata[16*k +: 16] <= acc_rdata_rmw[16*k +: 16] + tile_delta1[16*k +: 16];
          T_SUB:   acc_wdata[16*k +: 16] <= acc_rdata_rmw[16*k +: 16] - tile_delta1[16*k +: 16];
          default: acc_wdata[16*k +: 16] <= acc_rdata_rmw[16*k +: 16];
        endcase
    end

    // ---- FT pipeline ----
    if (ft_v0) begin
      ft_addr1 <= ft_addr0;
      for (int k = 0; k < 8; k++) begin
        ft_a[k] <= ft_clamp(acc_rdata_lo[16*k +: 16]);
        ft_b[k] <= ft_clamp(acc_rdata_hi[16*k +: 16]);
      end
    end

    // ---- MAC pipeline ----
    if (mac_v0) begin
      mac_v1  <= mac_layer == 2'd2;
      mac_sum <= 19'(mac_prod[0]) + 19'(mac_prod[1]) + 19'(mac_prod[2]) + 19'(mac_prod[3]) +
                 19'(mac_prod[4]) + 19'(mac_prod[5]) + 19'(mac_prod[6]) + 19'(mac_prod[7]);
      for (int k = 0; k < 8; k++) begin
        if (mac_layer == 2'd0) fc0[{mac_idx, 3'(k)}] <= fc0[{mac_idx, 3'(k)}] + 32'(mac_prod[k]);
        if (mac_layer == 2'd1) fc1[{mac_idx, 3'(k)}] <= fc1[{mac_idx, 3'(k)}] + 32'(mac_prod[k]);
      end
    end
    if (mac_v1) fc2 <= fc2 + 32'(mac_sum);

    // ---- FC cache read pipeline: issue, M10K read, register, consume ----
    c_v1 <= 1'b0;
    c_v2 <= c_v1;
    if (cq_left != 0) begin
      c_v1     <= 1'b1;
      c_kind1  <= cq_kind;
      c_idx1   <= cq_idx;
      c_value1 <= cq_value;
      c_layer1 <= cq_layer;
      cq_addr  <= cq_addr + 13'd1;
      cq_idx   <= cq_idx + 6'd1;
      cq_left  <= cq_left - 6'd1;
    end
    if (c_v1) begin
      c_kind2  <= c_kind1;
      c_idx2   <= c_idx1;
      c_value2 <= c_value1;
      c_layer2 <= c_layer1;
      c_data2  <= fcc_rdata;
    end
    if (c_v2) begin
      case (c_kind2)
        K_BIAS: begin
          if (c_idx2 < 6'd16) begin
            fc0[{c_idx2[3:0], 1'b0}] <= $signed(c_data2[31:0]);
            fc0[{c_idx2[3:0], 1'b1}] <= $signed(c_data2[63:32]);
          end else if (c_idx2 < 6'd32) begin
            fc1[{c_idx2[3:0], 1'b0}] <= $signed(c_data2[31:0]);
            fc1[{c_idx2[3:0], 1'b1}] <= $signed(c_data2[63:32]);
          end else begin
            fc2 <= $signed(c_data2[31:0]);
          end
        end
        K_COL: begin
          mac_v0    <= 1'b1;
          mac_idx   <= c_idx2[1:0];
          mac_layer <= c_layer2;
          for (int k = 0; k < 8; k++)
            mac_prod[k] <= $signed({{8{c_data2[8*k + 7]}}, c_data2[8*k +: 8]}) * $signed({8'd0, c_value2});
        end
        default: begin  // K_FC2
          mac_v0    <= 1'b1;
          mac_layer <= 2'd2;
          for (int k = 0; k < 8; k++)
            mac_prod[k] <= $signed({{8{c_data2[8*k + 7]}}, c_data2[8*k +: 8]})
                         * $signed({8'd0, concat[{c_idx2[3:0], 3'(k)}]});
        end
      endcase
    end

    // ---- Data sink. row_left == 0 discards stale words after an abort. ----
    if (m_readdatavalid && row_left != 0) begin
      row_left <= row_left - 16'd1;
      word_idx <= word_idx + 16'd1;

      case (sink_mode)
        M_HDR: if (word_idx < 16'd6) hdr[word_idx[2:0]] <= rd;

        M_FEAT: begin
          feat_we    <= 1'b1;
          feat_waddr <= word_idx[8:0];
          feat_wdata <= rd;
        end

        M_PSQ_ROW: begin
          if (!word_idx[0]) tile_hold <= rd;
          else begin
            tile_v0     <= 1'b1;
            tile_t0     <= word_idx[7:1];
            tile_delta0 <= {rd, tile_hold};
            tile_mode0  <= bias_mode ? T_LOAD : (cur_rem ? T_SUB : T_ADD);
          end
        end

        M_ACTIVE_ROW: begin
          tile_v0    <= 1'b1;
          tile_t0    <= word_idx[6:0];
          tile_mode0 <= cur_rem ? T_SUB : T_ADD;
          for (int k = 0; k < 8; k++)
            tile_delta0[16*k +: 16] <= {{8{rd[8*k + 7]}}, rd[8*k +: 8]};
        end

        M_PSQT: begin
          if (cur_rem) begin
            psqt_acc[cur_p][{word_idx[1:0], 1'b0}] <= psqt_acc[cur_p][{word_idx[1:0], 1'b0}] - $signed(rd[31:0]);
            psqt_acc[cur_p][{word_idx[1:0], 1'b1}] <= psqt_acc[cur_p][{word_idx[1:0], 1'b1}] - $signed(rd[63:32]);
          end else begin
            psqt_acc[cur_p][{word_idx[1:0], 1'b0}] <= psqt_acc[cur_p][{word_idx[1:0], 1'b0}] + $signed(rd[31:0]);
            psqt_acc[cur_p][{word_idx[1:0], 1'b1}] <= psqt_acc[cur_p][{word_idx[1:0], 1'b1}] + $signed(rd[63:32]);
          end
        end

        M_FC_BIAS: begin
          if (word_idx < 16'd16) begin
            fc0[{word_idx[3:0], 1'b0}] <= $signed(rd[31:0]);
            fc0[{word_idx[3:0], 1'b1}] <= $signed(rd[63:32]);
          end else if (word_idx < 16'd32) begin
            fc1[{word_idx[3:0], 1'b0}] <= $signed(rd[31:0]);
            fc1[{word_idx[3:0], 1'b1}] <= $signed(rd[63:32]);
          end else begin
            fc2 <= $signed(rd[31:0]);
          end
        end

        M_FC_COL: begin
          mac_v0    <= 1'b1;
          mac_idx   <= word_idx[1:0];
          mac_layer <= layer;
          for (int k = 0; k < 8; k++)
            mac_prod[k] <= $signed({{8{rd[8*k + 7]}}, rd[8*k +: 8]}) * $signed({8'd0, mac_value});
        end

        M_FC2: begin
          mac_v0    <= 1'b1;
          mac_layer <= 2'd2;
          for (int k = 0; k < 8; k++)
            mac_prod[k] <= $signed({{8{rd[8*k + 7]}}, rd[8*k +: 8]})
                         * $signed({8'd0, concat[{word_idx[3:0], 3'(k)}]});
        end

        M_FILL: begin
          fcc_we    <= 1'b1;
          fcc_waddr <= (fill_e ? 14'(FCC_WORDS) : 14'd0) + word_idx[13:0];
          fcc_wdata <= rd;
        end

        default: ;
      endcase
    end

    // ---- Control ----
    case (state)
      S_IDLE: begin
        if (start_req) begin
          done      <= 1'b0;
          err_flag  <= 1'b0;
          err_code  <= ERR_NONE;
          cycles    <= 32'd0;
          mem_waits <= 32'd0;
          mem_words <= 32'd0;
          for (int i = 0; i < PERF_COUNT; i++) perf[i] <= 32'd0;
          bias_mode <= 1'b0;  // An aborted run can end during a bias read.
          if (desc_addr[2:0] != 0 || weight_base[11:0] != 0) fail(ERR_ALIGN);
          else state <= S_DRAIN;
        end
      end

      // Words from an aborted run must be gone before a new run issues reads.
      S_DRAIN: if (cmd_left == 0 && outstanding == 0 && cache_idle) state <= S_HDR;

      S_HDR: begin
        go(desc_addr, DESC_HEADER_WORDS[15:0], M_HDR);
        state <= S_HDR_WAIT;
      end

      S_HDR_WAIT: if (row_done) state <= S_HDR_LATCH;

      S_HDR_LATCH: begin
        seq    <= hdr[2][31:0];
        stm    <= hdr[2][32];
        bucket <= hdr[2][42:40];
        ctx    <= hdr[2][63:48];
        dst_slot    <= hdr[3][4:0];
        src_slot[0] <= hdr[3][12:8];
        src_slot[1] <= hdr[3][20:16];
        op[0]       <= hdr[3][25:24];
        op[1]       <= hdr[3][27:26];
        look_dst_valid  <= slot_valid[hdr[3][4:0]];
        look_dst_owner  <= slot_owner[hdr[3][4:0]];
        look_src0_valid <= slot_valid[hdr[3][12:8]];
        look_src0_owner <= slot_owner[hdr[3][12:8]];
        look_src1_valid <= slot_valid[hdr[3][20:16]];
        look_src1_owner <= slot_owner[hdr[3][20:16]];
        for (int w = 0; w < 2; w++)
          for (int k = 0; k < 4; k++)
            n_list[w*4 + k] <= hdr[4 + w][16*k +: 10];
        list_base[0] <= 11'd0;
        list_base[1] <= 11'(hdr[4][9:0]);
        list_base[2] <= 11'(hdr[4][9:0]) + 11'(hdr[4][25:16]);
        list_base[3] <= 11'(hdr[4][9:0]) + 11'(hdr[4][25:16]) + 11'(hdr[4][41:32]);
        list_base[4] <= 11'(hdr[4][9:0]) + 11'(hdr[4][25:16]) + 11'(hdr[4][41:32]) + 11'(hdr[4][57:48]);
        state <= S_HDR_CHECK;
      end

      S_HDR_CHECK: begin
        list_base[5] <= list_base[4] + 11'(n_list[4]);
        list_base[6] <= list_base[4] + 11'(n_list[4]) + 11'(n_list[5]);
        list_base[7] <= list_base[4] + 11'(n_list[4]) + 11'(n_list[5]) + 11'(n_list[6]);

        if (hdr[0][31:0] != DESC_MAGIC[31:0]) fail(ERR_MAGIC);
        else if (hdr[0][47:32] != ABI_VERSION[15:0]) fail(ERR_ABI);
        else if (hdr[1][31:0] != NETWORK_HASH[31:0]) fail(ERR_HASH);
        else if (hdr[1][63:32] != NET_ID[31:0]) fail(ERR_NET);
        else if (hdr[0][63:48] != 0 || hdr[2][39:33] != 0 || hdr[2][47:43] != 0 || hdr[3][63:28] != 0)
          fail(ERR_RESERVED);
        else if (hdr[3][7:0] >= ACC_SLOTS[7:0] ||
                 op_range_bad(hdr[3][25:24], hdr[3][15:8], hdr[4][15:0], hdr[4][31:16], hdr[4][47:32], hdr[4][63:48]) ||
                 op_range_bad(hdr[3][27:26], hdr[3][23:16], hdr[5][15:0], hdr[5][31:16], hdr[5][47:32], hdr[5][63:48]))
          fail(ERR_RANGE);
        else if (op_slot_bad(op[0], src_slot[0], look_src0_valid[0], look_src0_owner, dst_slot,
                             look_dst_valid[0], look_dst_owner, ctx) ||
                 op_slot_bad(op[1], src_slot[1], look_src1_valid[1], look_src1_owner, dst_slot,
                             look_dst_valid[1], look_dst_owner, ctx))
          fail(ERR_SLOT);
        else begin
          // From here until a perspective finishes, an interrupted run leaves it invalid.
          if (op[0] != OP_NONE) slot_valid[dst_slot][0] <= 1'b0;
          if (op[1] != OP_NONE) slot_valid[dst_slot][1] <= 1'b0;
          if (op[0] != OP_NONE || op[1] != OP_NONE) slot_owner[dst_slot] <= ctx;
          go(desc_addr + 32'(DESC_HEADER_WORDS) * 32'd8,
             (16'(hdr[4][9:0]) + 16'(hdr[4][25:16]) + 16'(hdr[4][41:32]) + 16'(hdr[4][57:48]) +
              16'(hdr[5][9:0]) + 16'(hdr[5][25:16]) + 16'(hdr[5][41:32]) + 16'(hdr[5][57:48]) + 16'd3) >> 2,
             M_FEAT);
          state <= S_FEAT_WAIT;
          cur_p <= 1'b0;
        end
      end

      S_FEAT_WAIT: if (row_done && !feat_we) state <= S_P_BEGIN;

      S_P_BEGIN: begin
        pk <= 2'd0;
        case (op[cur_p])
          OP_REFRESH: begin
            for (int b = 0; b < 8; b++) psqt_acc[cur_p][b] <= 32'sd0;
            bias_mode <= 1'b1;
            go(weight_base + OFF_FT_BIAS[31:0], PSQ_ROW_BYTES[15:0] >> 3, M_PSQ_ROW);
            state <= S_BIAS_WAIT;
          end
          OP_INCR: begin
            psqt_rslot <= src_slot[cur_p];
            state      <= S_PL_RD;
          end
          default: begin
            psqt_rslot <= dst_slot;
            state      <= S_PL_RD;
          end
        endcase
      end

      S_PL_RD: state <= S_PL_DATA;

      S_PL_DATA: begin
        psqt_acc[cur_p][{pk, 1'b0}] <= $signed(psqt_rdata[31:0]);
        psqt_acc[cur_p][{pk, 1'b1}] <= $signed(psqt_rdata[63:32]);
        pk <= pk + 2'd1;
        if (pk != 2'd3) state <= S_PL_RD;
        else if (op[cur_p] == OP_INCR) begin
          copy_t <= 7'd0;
          state  <= S_COPY;
        end else state <= S_P_NEXT;
      end

      S_COPY: begin
        tile_v0    <= 1'b1;
        tile_t0    <= copy_t;
        tile_mode0 <= T_COPY;
        copy_t     <= copy_t + 7'd1;
        if (copy_t == 7'd127) state <= S_COPY_WAIT;
      end

      S_COPY_WAIT: if (row_done) begin
        list_k <= 2'd0;
        cur_i  <= 10'd0;
        state  <= S_ROW_NEXT;
      end

      S_BIAS_WAIT: if (row_done) begin
        bias_mode <= 1'b0;
        list_k    <= 2'd0;
        cur_i     <= 10'd0;
        state     <= S_ROW_NEXT;
      end

      S_ROW_NEXT: begin
        if (cur_i != n_list[cur_list]) state <= S_ROW_RD;
        else if (list_k != 2'd3) begin
          list_k <= list_k + 2'd1;
          cur_i  <= 10'd0;
        end else begin
          pk    <= 2'd0;
          state <= S_PS;
        end
      end

      S_ROW_RD: state <= S_ROW_LAT;

      S_ROW_LAT: begin
        if (cur_act) begin
          if ({16'd0, cur_feature} >= ACTIVE_DIMENSIONS[31:0]) fail(ERR_RANGE);
          else begin
            go(weight_base + OFF_ACTIVE_WEIGHTS[31:0] + {6'd0, cur_feature, 10'd0},
               ACTIVE_ROW_BYTES[15:0] >> 3, M_ACTIVE_ROW);
            state <= S_ROW_WAIT;
          end
        end else begin
          if ({16'd0, cur_feature} >= PSQ_DIMENSIONS[31:0]) fail(ERR_RANGE);
          else begin
            go(weight_base + OFF_PSQ_WEIGHTS[31:0] + {5'd0, cur_feature, 11'd0},
               PSQ_ROW_BYTES[15:0] >> 3, M_PSQ_ROW);
            state <= S_ROW_WAIT;
          end
        end
      end

      S_ROW_WAIT: if (row_done) begin
        go(weight_base + (cur_act ? OFF_ACTIVE_PSQT[31:0] : OFF_PSQ_PSQT[31:0]) + {11'd0, cur_feature, 5'd0},
           PSQT_ROW_BYTES[15:0] >> 3, M_PSQT);
        state <= S_PSQT_WAIT;
      end

      S_PSQT_WAIT: if (row_done) begin
        cur_i <= cur_i + 10'd1;
        state <= S_ROW_NEXT;
      end

      S_PS: begin
        psqt_we    <= 1'b1;
        psqt_waddr <= {dst_slot, cur_p, pk};
        psqt_wdata <= {psqt_acc[cur_p][{pk, 1'b1}], psqt_acc[cur_p][{pk, 1'b0}]};
        pk         <= pk + 2'd1;
        if (pk == 2'd3) begin
          slot_valid[dst_slot][cur_p] <= 1'b1;
          state <= S_P_NEXT;
        end
      end

      S_P_NEXT: begin
        if (!cur_p) begin
          cur_p <= 1'b1;
          state <= S_P_BEGIN;
        end else begin
          ft_p  <= 1'b0;
          ft_t  <= 6'd0;
          state <= S_FT;
        end
      end

      S_FT: begin
        ft_v0    <= 1'b1;
        ft_addr0 <= {ft_p, ft_t};
        ft_t     <= ft_t + 6'd1;
        if (ft_t == 6'd63) begin
          ft_p <= 1'b1;
          if (ft_p) state <= S_FT_WAIT;
        end
      end

      S_FT_WAIT: if (!ft_v0 && !ft_v1) begin
        stack_base <= weight_base + OFF_STACKS[31:0] + {29'd0, bucket} * STACK_STRIDE_BYTES[31:0];
        if (!FC_CACHE) begin
          go(weight_base + OFF_STACKS[31:0] + {29'd0, bucket} * STACK_STRIDE_BYTES[31:0],
             FC_BIAS_BYTES[15:0] >> 3, M_FC_BIAS);
          state <= S_STK_WAIT;
        end else if (fcc_valid[0] && fcc_tag[0] == bucket) begin
          fcc_e   <= 1'b0;
          fcc_lru <= 1'b1;
          cgo(13'd0, 6'(FC_BIAS_BYTES / 8), K_BIAS, 8'd0, 2'd0);
          state   <= S_STK_WAIT;
        end else if (fcc_valid[1] && fcc_tag[1] == bucket) begin
          fcc_e   <= 1'b1;
          fcc_lru <= 1'b0;
          cgo(13'd0, 6'(FC_BIAS_BYTES / 8), K_BIAS, 8'd0, 2'd0);
          state   <= S_STK_WAIT;
        end else begin
          // Miss: refill an empty entry, else the least recently used one.
          fill_e <= !fcc_valid[0] ? 1'b0 : !fcc_valid[1] ? 1'b1 : fcc_lru;
          if (!fcc_valid[0])      fcc_valid[0] <= 1'b0;
          else if (!fcc_valid[1]) fcc_valid[1] <= 1'b0;
          else                    fcc_valid[fcc_lru] <= 1'b0;
          go(weight_base + OFF_STACKS[31:0] + {29'd0, bucket} * STACK_STRIDE_BYTES[31:0],
             16'(FCC_WORDS), M_FILL);
          state <= S_FILL_WAIT;
        end
      end

      S_FILL_WAIT: if (row_done && !fcc_we) begin
        fcc_valid[fill_e] <= 1'b1;
        fcc_tag[fill_e]   <= bucket;
        fcc_e             <= fill_e;
        fcc_lru           <= !fill_e;
        cgo(13'd0, 6'(FC_BIAS_BYTES / 8), K_BIAS, 8'd0, 2'd0);
        state             <= S_STK_WAIT;
      end

      S_STK_WAIT: if (FC_CACHE ? cache_idle : row_done) begin
        ft_ptr <= 7'd0;
        layer  <= 2'd0;
        state  <= S_FC0_RD;
      end

      S_FC0_RD: state <= S_FC0_LOAD;

      S_FC0_LOAD: begin
        scan_word <= ft_rdata;
        state     <= S_FC0_PICK;
      end

      S_FC0_PICK: begin
        if (scan_nz != 0) begin
          if (!FC_CACHE) begin
            mac_value <= scan_word[8*scan_lane +: 8];
            scan_word[8*scan_lane +: 8] <= 8'd0;
            go(stack_base + STACK_FC0_OFFSET[31:0] + {17'd0, ft_ptr, scan_lane, 5'd0},
               FC0_COL_BYTES[15:0] >> 3, M_FC_COL);
            state <= S_FC0_WAIT;
          end else if (cq_left <= 6'd1) begin
            // The last word of the previous column issues this cycle; this column follows it.
            scan_word[8*scan_lane +: 8] <= 8'd0;
            cgo(13'(FCC_FC0) + {1'b0, ft_ptr, scan_lane, 2'b00}, 6'd4, K_COL,
                scan_word[8*scan_lane +: 8], 2'd0);
          end
        end else if (ft_ptr == 7'd127) begin
          if (!FC_CACHE || (cache_idle && !mac_v0 && !mac_v1)) begin
            ac_layer <= 1'b0;
            ac_i     <= 5'd0;
            state    <= S_AC_A;
          end
        end else begin
          ft_ptr <= ft_ptr + 7'd1;
          state  <= S_FC0_RD;
        end
      end

      S_FC0_WAIT: if (row_done) state <= S_FC0_PICK;

      S_AC_A: begin
        ac_x   <= ac_layer ? fc1[ac_i] : fc0[ac_i];
        ac_mag <= sqr_magnitude(ac_layer ? fc1[ac_i] : fc0[ac_i]);
        state  <= S_AC_B;
      end

      S_AC_B: begin
        ac_square <= 34'(ac_mag) * 34'(ac_mag);
        state     <= S_AC_C;
      end

      S_AC_C: begin
        // Activation shifts: WeightScaleBits + 1 after FC0, WeightScaleBits after FC1.
        if (!ac_layer) begin
          concat[{2'b00, ac_i}] <= sqr_from_square(ac_square, 7);
          concat[{2'b01, ac_i}] <= clipped_relu(ac_x, 7);
        end else begin
          concat[{2'b10, ac_i}] <= sqr_from_square(ac_square, 6);
          concat[{2'b11, ac_i}] <= clipped_relu(ac_x, 6);
        end
        ac_i <= ac_i + 5'd1;
        if (ac_i != 5'd31) state <= S_AC_A;
        else if (!ac_layer) begin
          layer   <= 2'd1;
          fc1_col <= 7'd0;
          state   <= S_FC1_PICK;
        end else begin
          if (FC_CACHE) cgo(13'(FCC_FC2), 6'(FC2_BYTES / 8), K_FC2, 8'd0, 2'd2);
          else          go(stack_base + STACK_FC2_OFFSET[31:0], FC2_BYTES[15:0] >> 3, M_FC2);
          state <= S_FC2_WAIT;
        end
      end

      S_FC1_PICK: begin
        if (fc1_col == 7'd64) begin
          if (!FC_CACHE || (cache_idle && !mac_v0 && !mac_v1)) begin
            ac_layer <= 1'b1;
            ac_i     <= 5'd0;
            state    <= S_AC_A;
          end
        end else if (!FC_CACHE) begin
          fc1_col <= fc1_col + 7'd1;
          if (concat[fc1_col] != 0) begin
            mac_value <= concat[fc1_col];
            go(stack_base + STACK_FC1_OFFSET[31:0] + {20'd0, fc1_col, 5'd0},
               FC1_COL_BYTES[15:0] >> 3, M_FC_COL);
            state <= S_FC1_WAIT;
          end
        end else if (concat[fc1_col] == 0) begin
          fc1_col <= fc1_col + 7'd1;
        end else if (cq_left <= 6'd1) begin
          fc1_col <= fc1_col + 7'd1;
          cgo(13'(FCC_FC1) + {4'd0, fc1_col[5:0], 2'b00}, 6'd4, K_COL, concat[fc1_col], 2'd1);
        end
      end

      S_FC1_WAIT: if (row_done) state <= S_FC1_PICK;

      S_FC2_WAIT: if (FC_CACHE ? (cache_idle && !mac_v0 && !mac_v1) : row_done) begin
        skip  <= fc0[30] - fc0[31];
        fwd   <= fc2 + (fc0[30] - fc0[31]);
        state <= S_FINAL_A;
      end

      S_FINAL_A: begin
        fwd_scaled <= 64'(fwd) * $signed(POSITIONAL_MULTIPLIER);
        raw_psqt   <= sdiv_pow2_32(psqt_acc[stm][bucket] - psqt_acc[!stm][bucket], 1);
        state      <= S_FINAL_B;
      end

      S_FINAL_B: begin
        raw_pos  <= 32'(sdiv_pow2_64(fwd_scaled, 14));
        out_psqt <= sdiv_pow2_32(raw_psqt, 4);
        state    <= S_FINAL_C;
      end

      S_FINAL_C: begin
        out_pos <= sdiv_pow2_32(raw_pos, 4);
        done    <= 1'b1;
        state   <= S_IDLE;
      end

      default: state <= S_IDLE;
    endcase

    // Memory stopped responding. Stale data is discarded through row_left == 0.
    if (state != S_IDLE && wd >= 21'(WATCHDOG_CYCLES)) fail(ERR_TIMEOUT);

    // Host-initiated abort, keeping the outstanding-read count for S_DRAIN.
    if (soft_reset) begin
      state    <= S_IDLE;
      done     <= 1'b0;
      err_flag <= 1'b0;
      err_code <= ERR_NONE;
      row_left <= 16'd0;
      cq_left  <= 6'd0;
      if (cmd_left != 0) aborting <= 1'b1;
    end

    if (rst) begin
      cq_left      <= 6'd0;
      c_v1         <= 1'b0;
      c_v2         <= 1'b0;
      fcc_we       <= 1'b0;
      fcc_valid[0] <= 1'b0;
      fcc_valid[1] <= 1'b0;
      fcc_lru      <= 1'b0;
      state       <= S_IDLE;
      cmd_left    <= 16'd0;
      row_left    <= 16'd0;
      word_idx    <= 16'd0;
      outstanding <= 16'd0;
      aborting    <= 1'b0;
      wd          <= 21'd0;
      done        <= 1'b0;
      err_flag    <= 1'b0;
      err_code    <= ERR_NONE;
      irq_enable  <= 1'b0;
      tsel        <= 32'd0;
      tsel_wait   <= 3'd0;
      desc_addr   <= 32'd0;
      weight_base <= 32'd0;
      feat_we     <= 1'b0;
      psqt_we     <= 1'b0;
      tile_v0     <= 1'b0;
      tile_v1     <= 1'b0;
      acc_we      <= 1'b0;
      mac_v0      <= 1'b0;
      mac_v1      <= 1'b0;
      ft_v0       <= 1'b0;
      ft_v1       <= 1'b0;
      cycles      <= 32'd0;
      mem_waits   <= 32'd0;
      mem_words   <= 32'd0;
      bias_mode   <= 1'b0;
      psel        <= 5'd0;
      go_pulse    <= 1'b0;
      for (int i = 0; i < PERF_COUNT; i++) perf[i] <= 32'd0;
      for (int i = 0; i < SLOTS; i++) slot_valid[i] <= 2'b00;
    end
  end

endmodule
