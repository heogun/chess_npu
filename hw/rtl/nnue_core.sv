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
// With READ_QUEUE = 1 the feature-row phase runs ahead of its data: each feature's row and PSQT
// commands go into a small command queue, the read engine starts the next command as soon as the
// previous one is accepted, and a sink queue routes each returning word by the entry of the
// command it belongs to. Rows and PSQT reads then follow each other without a round trip.
// docs/reports/perf_proposal.md, step 3.
//
// With WIDE_FC = 1 (step 5; needs FC_CACHE) the FC cache is four word banks, so a whole FC0 or FC1
// column (32 int8 weights, four words) is read in one cycle and goes through 32 multipliers. FT
// marks which of its 128 output words are non-zero, and the FC0 scan visits only those words,
// fetching the next one while the current word's lanes issue. Integer sums do not depend on
// order, so the results are the same as with the 8-wide path.
//
// With HW_PLAN = 1 the core can choose a request's source slots itself (descriptor PLAN bit,
// header word 3 bit 28). The host then sends each perspective's full sorted lists as for a
// refresh, and the destination. The core keeps every slot's lists and a 128+128-bit parity
// signature per perspective. It hashes the current lists (copying them into the destination),
// bounds every other slot by popcount of the signature difference, merges candidates exactly in
// order of that bound until the bound reaches the best cost, and writes the winner's add and
// remove lists into a diff buffer that the row phase reads. A perspective with no cheaper source
// is refreshed. CSR 23 (PLAN) reports the chosen operations and sources, CSR 24 (CAPS) the
// features. Only slots owned by the request's context are candidates.
//
// BUS_W = 128 reads through a 128-bit FPGA-to-SDRAM port (step 4). Addresses stay byte addresses,
// bursts count 16-byte beats and the descriptor must be 16-byte aligned. An accumulator RAM entry
// then holds two tiles: a PSQ row beat is one tile (two beats fill an entry, one tile per cycle),
// an active row beat is a whole entry (two tiles per cycle). FC weights must come from the cache.
// CSR 22 (BUS) reports BUS_W so the host can release the second port pair (fpgaportrst 0x133).
//
// Simulation and compilation of this module do not establish correctness on the board.
module nnue_core
#(
  parameter int WATCHDOG_CYCLES = 1 << 20,  // cycles without memory progress before ERR_TIMEOUT
  parameter bit FC_CACHE        = 1'b1,     // on-chip FC weights for two buckets
  parameter bit READ_QUEUE      = 1'b1,     // queued row and PSQT reads in the accumulator phase
  parameter int BUS_W           = 64,       // memory data width: 64 or 128
  parameter bit WIDE_FC         = 1'b1,     // one FC0/FC1 column per cycle from a 4-bank FC cache
  parameter bit HW_PLAN         = 1'b1      // the core can choose source slots (PLAN requests)
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
  input  logic [BUS_W-1:0] m_readdata,
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
    CSR_TSEL = 16, CSR_TDATA = 17, CSR_CTX = 18, CSR_SLOTS = 19, CSR_PSEL = 20, CSR_PDATA = 21,
    CSR_BUS = 22, CSR_PLAN = 23, CSR_CAPS = 24;

  // Profile counters, selected by PSEL and read from PDATA. Cleared on start.
  // 0-11: cycles per stage. Every non-idle state belongs to exactly one, so they sum to CYCLES.
  //   0 descriptor and drain, 1 feature row wait, 2 PSQT wait, 3 other accumulator work,
  //   4 FT, 5 FC bias, 6 FC0 scan, 7 FC0 column wait, 8 activation, 9 FC1, 10 FC2, 11 final
  // 12-19: read requests issued per sink: header, features, PSQ row (and FT bias), active row,
  //   PSQT row, FC bias, FC0 column, FC2. 20: FC1 columns (counted apart from FC0). 21: FC cache
  //   fills. With the cache, FC requests are counted the same way but served on chip, and stage 5
  //   includes the fill.
  // 22: cycles spent planning (PLAN requests), also counted in stage 0.
  localparam int PERF_STAGES = 12, PERF_COUNT = 23;

  // FC cache: word offsets inside one bucket's stack.
  localparam int FCC_WORDS   = (int'(STACK_FC2_OFFSET) + int'(FC2_BYTES)) / 8;  // 4401
  localparam int FCC_FC0     = int'(STACK_FC0_OFFSET) / 8;
  localparam int FCC_FC1     = int'(STACK_FC1_OFFSET) / 8;
  localparam int FCC_FC2     = int'(STACK_FC2_OFFSET) / 8;
  localparam int CHECK_FCC   = 1 / ((int'(STACK_FC0_OFFSET) % 8 == 0 && int'(STACK_FC1_OFFSET) % 8 == 0 &&
                                     int'(STACK_FC2_OFFSET) % 8 == 0 && int'(FC_BIAS_BYTES) == 264) ? 1 : 0);

  // Memory beat width. Everything below that depends on it is derived here.
  localparam bit W128       = BUS_W == 128;
  localparam int CHECK_BUS  = 1 / ((BUS_W == 64 || (W128 && FC_CACHE)) ? 1 : 0);
  localparam int BSH        = W128 ? 4 : 3;           // log2(bytes per beat)
  localparam int ACC_W      = 2 * BUS_W;              // accumulator RAM entry: one tile or two
  localparam int ALB        = W128 ? 4 : 3;           // log2(int16 lanes per entry)
  localparam int UB         = W128 ? 5 : 6;           // entry index bits within a bank
  localparam int UNITS      = 1 << (UB + 1);          // entries per slot and perspective
  localparam int FLB        = W128 ? 3 : 2;           // log2(features per beat)
  localparam int FEAT_ENT   = FEAT_WORDS * 64 / BUS_W;
  localparam int FAW        = $clog2(FEAT_ENT);
  localparam int PSQT_LANES = BUS_W / 32;             // PSQT int32 values per beat
  localparam int HDR_WPB    = BUS_W / 64;             // descriptor words per beat
  // FC cache: 128-bit fills write an even and an odd word bank, so an entry stride must be even.
  localparam bit WIDE       = WIDE_FC && FC_CACHE;
  // Wide cache: an entry is a whole number of four-word quads, so entry 1 starts in bank 0.
  localparam int FCQ        = (FCC_WORDS + 3) / 4;                 // quads per entry (1101)
  localparam int FCC_STRIDE = WIDE ? 4 * FCQ : W128 ? FCC_WORDS + 1 : FCC_WORDS;
  localparam int FILL_BEATS = (FCC_WORDS * 8 + (BUS_W / 8) - 1) / (BUS_W / 8);

  // Error codes, reported in STATUS[15:8]
  localparam logic [7:0] ERR_NONE = 0, ERR_MAGIC = 1, ERR_ABI = 2, ERR_HASH = 3, ERR_NET = 4,
    ERR_RANGE = 5, ERR_RESERVED = 6, ERR_TIMEOUT = 7, ERR_ALIGN = 8, ERR_SLOT = 9;

  // Per-perspective operations in a descriptor
  localparam logic [1:0] OP_NONE = 2'd0, OP_REFRESH = 2'd1, OP_INCR = 2'd2;

  typedef enum logic [5:0] {
    S_IDLE, S_DRAIN, S_HDR, S_HDR_WAIT, S_HDR_LATCH, S_HDR_CHECK, S_FEAT_WAIT, S_FILL_WAIT,
    S_P_BEGIN, S_PL_RD, S_PL_DATA, S_COPY, S_COPY_WAIT,
    S_BIAS_WAIT, S_ROW_NEXT, S_ROW_RD, S_ROW_LAT, S_ROW_WAIT, S_PSQT_WAIT, S_ROW_DRAIN, S_PS, S_P_NEXT,
    S_FT, S_FT_WAIT, S_STK_WAIT,
    S_FC0_RD, S_FC0_LOAD, S_FC0_PICK, S_FC0_WAIT,
    S_AC_A, S_AC_B, S_AC_C,
    S_FC1_PICK, S_FC1_WAIT, S_FC2_WAIT,
    S_FINAL_A, S_FINAL_B, S_FINAL_C,
    S_PN_SIG, S_PN_SIGW, S_PN_LB, S_PN_PICK, S_PN_PICK2, S_PN_PICK2B, S_PN_PICK3, S_PN_M0, S_PN_M1, S_PN_M2, S_PN_M,
    S_PN_END, S_PN_NEXTP
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
  logic [11:0] list_base [0:7];

  // ---- Slot table ----
  logic [1:0]  slot_valid [0:SLOTS-1];
  logic [15:0] slot_owner [0:SLOTS-1];
  logic [1:0]  look_dst_valid, look_src0_valid, look_src1_valid;
  logic [15:0] look_dst_owner, look_src0_owner, look_src1_owner;

  // ---- Hardware request planner (HW_PLAN) ----
  localparam int LST_PER   = int'(MAX_PSQ_ACTIVE) + int'(MAX_THREAT_ACTIVE);  // 288 per slot and perspective
  localparam int LST_DEPTH = SLOTS * 2 * LST_PER;
  localparam int LAW       = $clog2(LST_DEPTH);
  localparam int CHECK_LST = 1 / ((LST_PER == 288 && MAX_PSQ_ACTIVE == 32) ? 1 : 0);
  logic             plan;                    // this request is planned by the core
  logic [1:0]       list_valid [0:SLOTS-1];  // the slot's stored lists describe its accumulator
  logic [5:0]       st_npsq [0:2*SLOTS-1];   // stored list lengths, index {slot, perspective}
  logic [8:0]       st_nact [0:2*SLOTS-1];
  logic [255:0]     cur_sig [0:1];           // current signature: PSQ bits 127:0, active 255:128
  logic             use_diff [0:1];          // the row phase reads this perspective from u_dif
  logic [31:0]      plan_word;
  logic             lst_we;
  logic [LAW-1:0]   lst_waddr, lst_raddr;
  logic [15:0]      lst_wdata, lst_rdata;
  logic             sig_we;
  logic [5:0]       sig_waddr, sig_raddr;
  logic [255:0]     sig_wdata, sig_rdata;
  logic             dif_we;
  logic [11:0]      dif_waddr, dif_raddr;  // {perspective, buffer, offset}
  logic [15:0]      dif_wdata, dif_rdata;
  // signature pass: issue (pn_*), data (sa_*), hash (sb_*)
  logic             pn_p, pn_k, pn_err;
  logic [9:0]       pn_i;
  logic [11:0]      pn_addr;
  logic             pn_fdrive;
  logic             sa_v, sa_p, sa_k, sb_v, sb_p, sb_k;
  logic [9:0]       sa_i;
  logic [FLB-1:0]   sa_lane;
  logic [6:0]       sb_h;
  logic [15:0]      s_prev;
  logic [15:0]      sa_x;
  logic [31:0]      sa_prod;
  // bound pass: issue, xor, partial popcounts, bound
  logic [5:0]       lb_s;
  logic             la_v, lc_v, ld_v;
  logic [4:0]       la_s, lc_s, ld_s;
  logic [255:0]     lx;
  logic [5:0]       p32 [0:7];
  logic [9:0]       lbv [0:SLOTS-1];
  logic [SLOTS-1:0] cand, visited;
  // pick: one scan over the slots per candidate
  logic [5:0]       pk_s;
  logic [9:0]       pk_min;
  logic [4:0]       pk_arg;
  logic             pk_any;
  logic [10:0]      best_cost;
  logic [4:0]       best_s;
  logic             best_any;
  // merge of stored list S (u_lst) and current list C (u_feat), PSQ then active
  logic [4:0]       ms;
  logic             mk, mwrite;
  logic [9:0]       ci, sj, nC, nS;
  logic [11:0]      baseC;
  logic [LAW-1:0]   baseS;
  logic [15:0]      cv, sv, cdata;
  logic [FLB-1:0]   c_lane;
  logic [10:0]      mcost, mbound;
  logic [8:0]       na, nr;
  // Every costing merge writes its lists into the trial buffer; an accepted one becomes the best.
  logic             tbuf, bbuf;
  logic [8:0]       t_na0, t_nr0, b_na0, b_nr0, b_na1, b_nr1;
  // Pick: two-stage minimum over (bound, slot) of the unvisited candidates.
  logic [9:0]       g_min [0:7];
  logic [4:0]       g_arg [0:7];
  logic [7:0]       g_any;
  logic [9:0]       gc_min [0:7];
  logic [4:0]       gc_arg [0:7];
  logic [7:0]       gc_any;
  logic [9:0]       pc_min, hc_min [0:1], h_min [0:1];
  logic [4:0]       pc_arg, hc_arg [0:1], h_arg [0:1];
  logic             pc_any;
  logic [1:0]       hc_any, h_any;
  logic             m_cend, m_send, m_add, m_rem, m_eq, m_advc, m_advs;
  logic [10:0]      m_cost_next;

  function automatic logic [LAW-1:0] lst_base(input logic [4:0] sl, input logic pp);
    // {slot, perspective} * 288 as 256 + 32, without a multiplier
    return LAW'({sl, pp, 8'd0}) + LAW'({sl, pp, 5'd0});
  endfunction

  function automatic logic [5:0] pop32(input logic [31:0] v);
    logic [5:0] n;
    n = 6'd0;
    for (int b = 0; b < 32; b++) n = n + 6'(v[b]);
    return n;
  endfunction

  logic             feat_we;
  logic [FAW-1:0]   feat_waddr, feat_raddr;
  logic [BUS_W-1:0] feat_wdata, feat_rdata;

  logic        cur_p;
  logic [1:0]  list_k;           // {active, remove}
  logic [9:0]  cur_i;
  logic [2:0]  cur_list;
  logic [11:0] gidx;
  logic [15:0] cur_feature;
  logic        cur_act, cur_rem;
  assign cur_act     = list_k[1];
  assign cur_rem     = list_k[0];
  assign cur_list    = {cur_p, list_k};
  assign gidx        = list_base[cur_list] + 12'(cur_i);
  assign feat_raddr  = pn_fdrive ? pn_addr[FLB +: FAW] : gidx[FLB +: FAW];
  assign cur_feature = (HW_PLAN && use_diff[cur_p]) ? dif_rdata : feat_rdata[16 * gidx[FLB-1:0] +: 16];
  assign dif_raddr   = gidx;

  // ---- Accumulator: the first and second half of the 1024 values are separate banks, so FT
  // reads both at once. An entry is one tile (64-bit bus) or two tiles (128-bit bus); the
  // tile_* pipeline works on entries, and tile_t* is an entry index with the bank in bit UB. ----
  logic             acc_we;
  logic [6:0]       acc_wtile;
  logic [UB+5:0]    acc_waddr, acc_raddr_lo, acc_raddr_hi;
  logic [ACC_W-1:0] acc_wdata, acc_rdata_lo, acc_rdata_hi, acc_rdata_rmw;

  logic             tile_v0, tile_v1, bias_mode;
  tile_mode_t       tile_mode0, tile_mode1;
  logic [6:0]       tile_t0, tile_t1, copy_t;
  logic [ACC_W-1:0] tile_delta0, tile_delta1;
  logic [BUS_W-1:0] tile_hold;
  logic [4:0]       tile_rslot;

  assign tile_rslot    = (tile_mode0 == T_COPY) ? src_slot[cur_p] : dst_slot;
  assign acc_waddr     = {dst_slot, cur_p, acc_wtile[UB-1:0]};
  assign acc_rdata_rmw = tile_t1[UB] ? acc_rdata_hi : acc_rdata_lo;

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
  // Wide FC0 scan: FT output words with any non-zero byte, still to visit.
  logic [127:0] ft_nzmask;
  logic [6:0]   nxt_ptr;
  logic         nxt_any, scan_single, scan_settled;

  // ---- FC ----
  logic [31:0]        stack_base;
  logic signed [31:0] fc0 [0:31];
  logic signed [31:0] fc1 [0:31];
  logic signed [31:0] fc2;
  logic [7:0]         concat [0:127];
  logic [7:0]         mac_value;
  logic [6:0]         fc1_col;
  logic signed [15:0] mac_prod [0:31];
  logic               mac_quad;   // the 32 products are one whole column (wide FC0/FC1)
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
  // Wide: the three activation steps are a pipeline, one element per cycle.
  logic        ac_v0, ac_v1, ac_v2;
  logic [4:0]  ac_i0, ac_iq, ac_i1;
  logic signed [31:0] ac_sel, ac_xq, ac_x1;  // selected input, then with its magnitude

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
  logic [BUS_W-1:0] fcc_wdata;
  logic [63:0] fcc_rdata;
  logic [255:0] fcc_quad;  // wide cache: words raddr .. raddr+3, in order
  logic [1:0]  fcc_wbank;  // wide cache: bank of the (first) word being filled
  logic        c_bank1;  // 128-bit bus: odd word bank for the word read in the c_v1 cycle
  logic [1:0]  c_rot1;   // wide cache: first word's bank for the read in the c_v1 cycle
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
  logic [255:0] c_data2;
  logic        cache_idle;
  assign cache_idle = cq_left == 0 && !c_v1 && !c_v2;
  assign fcc_raddr  = (fcc_e ? 14'(FCC_STRIDE) : 14'd0) + 14'(cq_addr);

  // ---- Counters ----
  logic [31:0] cycles, mem_waits, mem_words;
  logic [31:0] perf [0:PERF_COUNT-1];
  logic [4:0]  psel;
  logic        go_pulse;
  logic [4:0]  go_index;
  logic [3:0]  stage;

  always_comb begin
    case (state)
      S_ROW_NEXT, S_ROW_RD, S_ROW_LAT, S_ROW_WAIT,
      S_ROW_DRAIN:                                    stage = 4'd1;
      S_PSQT_WAIT:                                    stage = 4'd2;
      S_P_BEGIN, S_PL_RD, S_PL_DATA, S_COPY, S_COPY_WAIT,
      S_BIAS_WAIT, S_PS, S_P_NEXT:                    stage = 4'd3;
      S_FT, S_FT_WAIT:                                stage = 4'd4;
      S_STK_WAIT, S_FILL_WAIT:                        stage = 4'd5;
      // With the cache, waiting in PICK for the previous column or the final drain is column wait.
      S_FC0_PICK:                                     stage = WIDE ? ((scan_nz == 0 && !nxt_any) ? 4'd7 : 4'd6)
                                                    : (FC_CACHE && ((scan_nz != 0 && cq_left > 6'd1) ||
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

  // ---- Read queue (READ_QUEUE): commands waiting for the read engine, and the sink entry of
  // every command whose data has not arrived yet, in issue order ----
  localparam int CQ_DEPTH = 4, SQ_DEPTH = 8;
  logic [31:0] cq_a [0:CQ_DEPTH-1];
  logic [15:0] cq_w [0:CQ_DEPTH-1];
  logic [1:0]  cq_head, cq_tail;
  logic [2:0]  cq_count;
  sink_t       sq_mode [0:SQ_DEPTH-1];
  logic [15:0] sq_w    [0:SQ_DEPTH-1];
  logic        sq_rem  [0:SQ_DEPTH-1];
  logic [2:0]  sq_head, sq_tail;
  logic [3:0]  sq_count;
  logic        q_active, s_rem;  // current sink entry came from the queue, and its remove flag
  logic        row_ok, q_room, q_push, cq_pop, sq_take;
  logic [31:0] q_row_addr, q_psqt_addr;
  logic [15:0] q_row_words;
  sink_t       snk_mode;
  logic [15:0] snk_left, snk_idx;
  logic        snk_rem;

  assign row_ok      = cur_act ? ({16'd0, cur_feature} < ACTIVE_DIMENSIONS[31:0])
                               : ({16'd0, cur_feature} < PSQ_DIMENSIONS[31:0]);
  assign q_room      = cq_count <= 3'(CQ_DEPTH - 2) && sq_count <= 4'(SQ_DEPTH - 2);
  assign q_push      = READ_QUEUE && state == S_ROW_LAT && row_ok && q_room;
  assign cq_pop      = READ_QUEUE && cmd_left == 0 && !aborting && cq_count != 0;
  assign sq_take     = READ_QUEUE && row_left == 0 && sq_count != 0;
  assign q_row_addr  = cur_act ? weight_base + OFF_ACTIVE_WEIGHTS[31:0] + {6'd0, cur_feature, 10'd0}
                               : weight_base + OFF_PSQ_WEIGHTS[31:0] + {5'd0, cur_feature, 11'd0};
  assign q_psqt_addr = weight_base + (cur_act ? OFF_ACTIVE_PSQT[31:0] : OFF_PSQ_PSQT[31:0]) + {11'd0, cur_feature, 5'd0};
  assign q_row_words = cur_act ? ACTIVE_ROW_BYTES[15:0] >> BSH : PSQ_ROW_BYTES[15:0] >> BSH;
  // When the current entry is used up, the next queued one takes over in the same cycle.
  assign snk_mode    = sq_take ? sq_mode[sq_head] : sink_mode;
  assign snk_left    = sq_take ? sq_w[sq_head] : row_left;
  assign snk_idx     = sq_take ? 16'd0 : word_idx;
  assign snk_rem     = sq_take ? sq_rem[sq_head] : (q_active ? s_rem : cur_rem);

  assign scan_nz = {|scan_word[63:56], |scan_word[55:48], |scan_word[47:40], |scan_word[39:32],
                    |scan_word[31:24], |scan_word[23:16], |scan_word[15:8], |scan_word[7:0]};
  always_comb begin
    scan_lane = 3'd0;
    for (int k = 7; k >= 0; k--) if (scan_nz[k]) scan_lane = 3'(k);
    scan_single = scan_nz != 0 && (scan_nz & (scan_nz - 8'd1)) == 8'd0;
    nxt_any     = ft_nzmask != 128'd0;
    nxt_ptr     = 7'd0;
    for (int k = 127; k >= 0; k--) if (ft_nzmask[k]) nxt_ptr = 7'(k);
  end

  // ---- Memories ----
  generate
    if (HW_PLAN) begin : g_plan_ram
      sdp_ram #(.WIDTH(16), .DEPTH(LST_DEPTH)) u_lst (
        .clk, .we(lst_we), .waddr(lst_waddr), .wdata(lst_wdata), .raddr(lst_raddr), .rdata(lst_rdata));
      sdp_ram #(.WIDTH(256), .DEPTH(2 * SLOTS)) u_sig (
        .clk, .we(sig_we), .waddr(sig_waddr), .wdata(sig_wdata), .raddr(sig_raddr), .rdata(sig_rdata));
      sdp_ram #(.WIDTH(16), .DEPTH(4096)) u_dif (
        .clk, .we(dif_we), .waddr(dif_waddr), .wdata(dif_wdata), .raddr(dif_raddr), .rdata(dif_rdata));
    end else begin : g_no_plan_ram
      assign lst_rdata = 16'd0;
      assign sig_rdata = 256'd0;
      assign dif_rdata = 16'd0;
    end
  endgenerate

  // ---- Planner pick: minimum of each group of four slots, then of the eight groups ----
  always_comb begin
    for (int g = 0; g < 8; g++) begin
      gc_any[g] = 1'b0;
      gc_min[g] = 10'd0;
      gc_arg[g] = 5'd0;
      for (int j = 0; j < 4; j++)
        if (cand[{g[2:0], j[1:0]}] && !visited[{g[2:0], j[1:0]}] &&
            (!gc_any[g] || lbv[{g[2:0], j[1:0]}] < gc_min[g])) begin
          gc_any[g] = 1'b1;
          gc_min[g] = lbv[{g[2:0], j[1:0]}];
          gc_arg[g] = {g[2:0], j[1:0]};
        end
    end
    for (int h = 0; h < 2; h++) begin
      hc_any[h] = 1'b0;
      hc_min[h] = 10'd0;
      hc_arg[h] = 5'd0;
      for (int j = 0; j < 4; j++)
        if (g_any[{h[0], j[1:0]}] && (!hc_any[h] || g_min[{h[0], j[1:0]}] < hc_min[h])) begin
          hc_any[h] = 1'b1;
          hc_min[h] = g_min[{h[0], j[1:0]}];
          hc_arg[h] = g_arg[{h[0], j[1:0]}];
        end
    end
    // The lower slots win ties, as in the stages before.
    pc_any = h_any[0] || h_any[1];
    if (h_any[0] && (!h_any[1] || h_min[0] <= h_min[1])) begin
      pc_min = h_min[0];
      pc_arg = h_arg[0];
    end else begin
      pc_min = h_min[1];
      pc_arg = h_arg[1];
    end
  end

  // ---- Planner address and merge decisions ----
  assign cdata       = feat_rdata[16 * c_lane +: 16];
  assign m_cend      = ci >= nC;
  assign m_send      = sj >= nS;
  assign m_add       = !m_cend && (m_send || cv < sv);
  assign m_rem       = !m_send && (m_cend || sv < cv);
  assign m_eq        = !m_cend && !m_send && cv == sv;
  assign m_advc      = state == S_PN_M && (m_add || m_eq);
  assign m_advs      = state == S_PN_M && (m_rem || m_eq);
  assign m_cost_next = mcost + ((m_add || m_rem) ? (mk ? 11'd1 : 11'd2) : 11'd0);
  assign pn_fdrive   = HW_PLAN && (state == S_PN_SIG || state == S_PN_M1 || state == S_PN_M2 || state == S_PN_M);
  assign sig_raddr   = {lb_s[4:0], pn_p};
  always_comb begin
    case (state)
      S_PN_SIG: pn_addr = list_base[{pn_p, pn_k, 1'b0}] + 12'(pn_i);
      S_PN_M1:  pn_addr = baseC;
      S_PN_M2:  pn_addr = baseC + 12'd1;
      default:  pn_addr = baseC + 12'(ci) + 12'd1 + {11'd0, m_advc};
    endcase
    case (state)
      S_PN_M1: lst_raddr = baseS;
      S_PN_M2: lst_raddr = baseS + LAW'(1);
      default: lst_raddr = baseS + LAW'(sj) + LAW'(1) + {{(LAW-1){1'b0}}, m_advs};
    endcase
  end

  sdp_ram #(.WIDTH(BUS_W), .DEPTH(FEAT_ENT)) u_feat (
    .clk, .we(feat_we), .waddr(feat_waddr), .wdata(feat_wdata), .raddr(feat_raddr), .rdata(feat_rdata));
  sdp_ram #(.WIDTH(ACC_W), .DEPTH(SLOTS * UNITS)) u_acc_lo (
    .clk, .we(acc_we && !acc_wtile[UB]), .waddr(acc_waddr), .wdata(acc_wdata),
    .raddr(acc_raddr_lo), .rdata(acc_rdata_lo));
  sdp_ram #(.WIDTH(ACC_W), .DEPTH(SLOTS * UNITS)) u_acc_hi (
    .clk, .we(acc_we && acc_wtile[UB]), .waddr(acc_waddr), .wdata(acc_wdata),
    .raddr(acc_raddr_hi), .rdata(acc_rdata_hi));
  sdp_ram #(.WIDTH(64), .DEPTH(SLOTS * 8)) u_psqt (
    .clk, .we(psqt_we), .waddr(psqt_waddr), .wdata(psqt_wdata), .raddr(psqt_raddr), .rdata(psqt_rdata));
  generate
    if (WIDE) begin : g_fcq
      // Four banks of one word; quad address = word address / 4. A read of word w returns w..w+3.
      logic [63:0] rd [0:3];
      logic [13:0] wq;
      assign wq = (fcc_e ? 14'(FCC_STRIDE) : 14'd0) + 14'(cq_addr);
      genvar b;  // Quartus Standard does not take a genvar declared in the loop header
      for (b = 0; b < 4; b++) begin : g_bank
        logic        we_b;
        logic [1:0]  off_b;  // (b - wq) mod 4, computed in two bits
        logic [11:0] ra_b;
        // Bank b holds the word whose index is b mod 4: word wq + ((b - wq) mod 4).
        assign off_b = 2'(b) - wq[1:0];
        assign ra_b  = 12'((wq + {12'd0, off_b}) >> 2);
        assign we_b = fcc_we && (fcc_wbank == 2'(b) || (W128 && {fcc_wbank[1], 1'b1} == 2'(b)));
        sdp_ram #(.WIDTH(64), .DEPTH(2 * FCQ)) u_fcq (
          .clk, .we(we_b), .waddr(fcc_waddr[11:0]),
          .wdata((W128 && (b % 2) == 1) ? fcc_wdata[BUS_W-1 -: 64] : fcc_wdata[63:0]),
          .raddr(ra_b), .rdata(rd[b]));
      end
      // Rotate by the first word's bank (registered with the read), as concatenations.
      always_comb
        case (c_rot1)
          2'd0:    fcc_quad = {rd[3], rd[2], rd[1], rd[0]};
          2'd1:    fcc_quad = {rd[0], rd[3], rd[2], rd[1]};
          2'd2:    fcc_quad = {rd[1], rd[0], rd[3], rd[2]};
          default: fcc_quad = {rd[2], rd[1], rd[0], rd[3]};
        endcase
      assign fcc_rdata = fcc_quad[63:0];
    end else if (FC_CACHE && !W128) begin : g_fcc
      sdp_ram #(.WIDTH(64), .DEPTH(2 * FCC_WORDS)) u_fcc (
        .clk, .we(fcc_we), .waddr(fcc_waddr), .wdata(fcc_wdata), .raddr(fcc_raddr), .rdata(fcc_rdata));
    end else if (FC_CACHE) begin : g_fcc2
      // Even and odd words in separate banks: a fill writes both, a read selects one.
      logic [63:0] rd_even, rd_odd;
      sdp_ram #(.WIDTH(64), .DEPTH(FCC_STRIDE)) u_fcc_even (
        .clk, .we(fcc_we), .waddr(fcc_waddr[12:0]), .wdata(fcc_wdata[63:0]), .raddr(fcc_raddr[13:1]),
        .rdata(rd_even));
      sdp_ram #(.WIDTH(64), .DEPTH(FCC_STRIDE)) u_fcc_odd (
        .clk, .we(fcc_we), .waddr(fcc_waddr[12:0]), .wdata(fcc_wdata[BUS_W-1 -: 64]), .raddr(fcc_raddr[13:1]),
        .rdata(rd_odd));
      assign fcc_rdata = c_bank1 ? rd_odd : rd_even;
    end else begin : g_no_fcc
      assign fcc_rdata = 64'd0;
    end
    if (!WIDE) begin : g_no_quad
      assign fcc_quad = {192'd0, fcc_rdata};
    end
  endgenerate
  sdp_ram #(.WIDTH(64), .DEPTH(128)) u_ft (
    .clk, .we(ft_v1), .waddr(ft_addr1), .wdata(ft_out), .raddr(ft_raddr), .rdata(ft_rdata));

  always_comb begin
    if (state == S_FT) begin
      acc_raddr_lo = {dst_slot, ft_perspective, ft_t[5 -: UB]};
      acc_raddr_hi = {dst_slot, ft_perspective, ft_t[5 -: UB]};
    end else begin
      acc_raddr_lo = (tile_v0 && !tile_t0[UB]) ? {tile_rslot, cur_p, tile_t0[UB-1:0]}
                                               : {dst_slot, tsel[10], tsel[8 -: UB]};
      acc_raddr_hi = (tile_v0 && tile_t0[UB])  ? {tile_rslot, cur_p, tile_t0[UB-1:0]}
                                               : {dst_slot, tsel[10], tsel[8 -: UB]};
    end

    if (WIDE && (state == S_FC0_RD || state == S_FC0_PICK)) ft_raddr = nxt_ptr;
    else if (state == S_FC0_RD)                             ft_raddr = ft_ptr;
    else                                                    ft_raddr = tsel[9:3];

    for (int k = 0; k < 8; k++)
      ft_out[8*k +: 8] = ft_product(ft_a[k], ft_b[k]);
  end

  task automatic go(input logic [31:0] addr, input logic [15:0] words, input sink_t mode);
    cmd_addr  <= addr;
    cmd_left  <= words;
    row_left  <= words;
    word_idx  <= 16'd0;
    sink_mode <= mode;
    q_active  <= 1'b0;
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
    cq_count <= 3'd0;
    sq_count <= 4'd0;
    cq_head  <= 2'd0;
    cq_tail  <= 2'd0;
    sq_head  <= 3'd0;
    sq_tail  <= 3'd0;
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

  logic [BUS_W-1:0] rd;
  logic [127:0]     rd_w;  // rd zero-extended, so 128-bit-only slices also elaborate at 64 bits
  assign rd   = m_readdata;
  assign rd_w = 128'(m_readdata);

  logic start_req, soft_reset;
  assign start_req  = csr_write && csr_address == CSR_CONTROL && csr_writedata[0];
  assign soft_reset = csr_write && csr_address == CSR_CONTROL && csr_writedata[1];

  assign irq = irq_enable && done;

  // Tensor reads are valid only while the core is idle. Tensor 0 reads the last destination slot.
  assign csr_waitrequest = csr_read && csr_address == CSR_TDATA && tsel_wait != 0;

  logic [ACC_W-1:0] tile_dbg;
  assign tile_dbg = tsel[9] ? acc_rdata_hi : acc_rdata_lo;

  always_ff @(posedge clk) begin
    case (tsel[31:28])
      4'd0:    tdata <= {{16{tile_dbg[16*tsel[ALB-1:0] + 15]}}, tile_dbg[16*tsel[ALB-1:0] +: 16]};
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
      CSR_BUS:      csr_readdata <= 32'(BUS_W);
      CSR_PLAN:     csr_readdata <= plan_word;
      CSR_CAPS:     csr_readdata <= {30'd0, HW_PLAN, WIDE};
      default:      csr_readdata <= 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    feat_we <= 1'b0;
    psqt_we <= 1'b0;
    fcc_we  <= 1'b0;
    lst_we  <= 1'b0;
    sig_we  <= 1'b0;
    dif_we  <= 1'b0;
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
      cmd_addr <= cmd_addr + (32'(m_burstcount) << BSH);
      cmd_left <= aborting ? 16'd0 : cmd_left - 16'(m_burstcount);
    end
    if (cmd_left == 0) aborting <= 1'b0;

    // ---- Read queue ----
    if (cq_pop) begin
      cmd_addr <= cq_a[cq_head];
      cmd_left <= cq_w[cq_head];
      cq_head  <= cq_head + 2'd1;
    end
    if (q_push) begin
      cq_a[cq_tail]         <= q_row_addr;
      cq_w[cq_tail]         <= q_row_words;
      cq_a[cq_tail + 2'd1]  <= q_psqt_addr;
      cq_w[cq_tail + 2'd1]  <= PSQT_ROW_BYTES[15:0] >> BSH;
      cq_tail               <= cq_tail + 2'd2;
      sq_mode[sq_tail]        <= cur_act ? M_ACTIVE_ROW : M_PSQ_ROW;
      sq_w[sq_tail]           <= q_row_words;
      sq_rem[sq_tail]         <= cur_rem;
      sq_mode[sq_tail + 3'd1] <= M_PSQT;
      sq_w[sq_tail + 3'd1]    <= PSQT_ROW_BYTES[15:0] >> BSH;
      sq_rem[sq_tail + 3'd1]  <= cur_rem;
      sq_tail                 <= sq_tail + 3'd2;
    end
    cq_count <= cq_count + (q_push ? 3'd2 : 3'd0) - (cq_pop ? 3'd1 : 3'd0);
    sq_count <= sq_count + (q_push ? 4'd2 : 4'd0) - (sq_take ? 4'd1 : 4'd0);
    if (sq_take) begin
      sink_mode <= sq_mode[sq_head];
      s_rem     <= sq_rem[sq_head];
      q_active  <= 1'b1;
      row_left  <= sq_w[sq_head];
      word_idx  <= 16'd0;
      sq_head   <= sq_head + 3'd1;
    end

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
    if (state >= S_PN_SIG)       perf[22] <= perf[22] + 32'd1;
    go_pulse <= 1'b0;
    if (go_pulse)                perf[go_index] <= perf[go_index] + 32'd1;
    if (q_push) begin
      if (cur_act) perf[15] <= perf[15] + 32'd1;
      else         perf[14] <= perf[14] + 32'd1;
      perf[16] <= perf[16] + 32'd1;
    end

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
      for (int k = 0; k < ACC_W / 16; k++)
        case (tile_mode1)
          T_LOAD:  acc_wdata[16*k +: 16] <= tile_delta1[16*k +: 16];
          T_ADD:   acc_wdata[16*k +: 16] <= acc_rdata_rmw[16*k +: 16] + tile_delta1[16*k +: 16];
          T_SUB:   acc_wdata[16*k +: 16] <= acc_rdata_rmw[16*k +: 16] - tile_delta1[16*k +: 16];
          default: acc_wdata[16*k +: 16] <= acc_rdata_rmw[16*k +: 16];
        endcase
    end

    // ---- FT pipeline ----
    // Every FT pass writes all 128 words, so the mask is rebuilt for each evaluation.
    if (WIDE && ft_v1) ft_nzmask[ft_addr1] <= ft_out != 64'd0;
    if (ft_v0) begin
      ft_addr1 <= ft_addr0;
      // With two tiles per entry, the low address bit of the tile picks the half.
      for (int k = 0; k < 8; k++) begin
        ft_a[k] <= ft_clamp(acc_rdata_lo[(W128 ? 128 * ft_addr0[0] : 0) + 16*k +: 16]);
        ft_b[k] <= ft_clamp(acc_rdata_hi[(W128 ? 128 * ft_addr0[0] : 0) + 16*k +: 16]);
      end
    end

    // ---- MAC pipeline ----
    if (mac_v0) begin
      mac_v1  <= mac_layer == 2'd2;
      mac_sum <= 19'(mac_prod[0]) + 19'(mac_prod[1]) + 19'(mac_prod[2]) + 19'(mac_prod[3]) +
                 19'(mac_prod[4]) + 19'(mac_prod[5]) + 19'(mac_prod[6]) + 19'(mac_prod[7]);
      if (WIDE && mac_quad) begin
        for (int k = 0; k < 32; k++) begin
          if (mac_layer == 2'd0) fc0[k] <= fc0[k] + 32'(mac_prod[k]);
          if (mac_layer == 2'd1) fc1[k] <= fc1[k] + 32'(mac_prod[k]);
        end
      end else begin
        for (int k = 0; k < 8; k++) begin
          if (mac_layer == 2'd0) fc0[{mac_idx, 3'(k)}] <= fc0[{mac_idx, 3'(k)}] + 32'(mac_prod[k]);
          if (mac_layer == 2'd1) fc1[{mac_idx, 3'(k)}] <= fc1[{mac_idx, 3'(k)}] + 32'(mac_prod[k]);
        end
      end
    end
    if (mac_v1) fc2 <= fc2 + 32'(mac_sum);

    // ---- Planner: signature pass data and hash stages ----
    sa_v <= 1'b0;
    sb_v <= 1'b0;
    if (sa_v) begin
      // Copy into the destination's stored lists, check order and range, hash.
      lst_we    <= 1'b1;
      lst_waddr <= lst_base(dst_slot, sa_p) + (sa_k ? LAW'(32) + LAW'(sa_i) : LAW'(sa_i));
      lst_wdata <= feat_rdata[16 * sa_lane +: 16];
      sa_x      <= feat_rdata[16 * sa_lane +: 16];
      if (sa_i != 10'd0 && feat_rdata[16 * sa_lane +: 16] <= s_prev) pn_err <= 1'b1;
      if (sa_k ? ({16'd0, feat_rdata[16 * sa_lane +: 16]} >= ACTIVE_DIMENSIONS[31:0])
               : ({16'd0, feat_rdata[16 * sa_lane +: 16]} >= PSQ_DIMENSIONS[31:0])) pn_err <= 1'b1;
      s_prev  <= feat_rdata[16 * sa_lane +: 16];
      sa_prod <= 32'(feat_rdata[16 * sa_lane +: 16]) * 32'd40503;
      sb_v    <= 1'b1;
      sb_p    <= sa_p;
      sb_k    <= sa_k;
    end
    if (sb_v) cur_sig[sb_p][{sb_k, sa_prod[14:8]}] <= ~cur_sig[sb_p][{sb_k, sa_prod[14:8]}];

    // ---- Planner: bound pass (xor, partial popcounts, bound and candidate flag) ----
    la_v <= 1'b0;
    lc_v <= la_v;
    ld_v <= lc_v;
    if (la_v) begin
      lx   <= sig_rdata ^ cur_sig[pn_p];
      lc_s <= la_s;
    end
    if (lc_v) begin
      for (int k = 0; k < 8; k++) p32[k] <= pop32(lx[32*k +: 32]);
      ld_s <= lc_s;
    end
    if (ld_v) begin
      // A PSQ row is two active rows.
      lbv[ld_s]  <= ((10'(p32[0]) + 10'(p32[1]) + 10'(p32[2]) + 10'(p32[3])) << 1)
                    + 10'(p32[4]) + 10'(p32[5]) + 10'(p32[6]) + 10'(p32[7]);
      cand[ld_s] <= slot_valid[ld_s][pn_p] && list_valid[ld_s][pn_p] && slot_owner[ld_s] == ctx && ld_s != dst_slot;
    end

    // ---- Activation pipeline (wide): square, then write both activations ----
    ac_v0 <= 1'b0;
    ac_v1 <= ac_v0;
    ac_v2 <= ac_v1;
    if (WIDE && ac_v0) begin
      ac_iq  <= ac_i0;
      ac_xq  <= ac_sel;
      ac_mag <= sqr_magnitude(ac_sel);
    end
    if (WIDE && ac_v1) begin
      ac_i1     <= ac_iq;
      ac_x1     <= ac_xq;
      ac_square <= 34'(ac_mag) * 34'(ac_mag);
    end
    if (WIDE && ac_v2) begin
      // Activation shifts: WeightScaleBits + 1 after FC0, WeightScaleBits after FC1.
      if (!ac_layer) begin
        concat[{2'b00, ac_i1}] <= sqr_from_square(ac_square, 7);
        concat[{2'b01, ac_i1}] <= clipped_relu(ac_x1, 7);
      end else begin
        concat[{2'b10, ac_i1}] <= sqr_from_square(ac_square, 6);
        concat[{2'b11, ac_i1}] <= clipped_relu(ac_x1, 6);
      end
    end

    // ---- FC cache read pipeline: issue, M10K read, register, consume ----
    c_v1 <= 1'b0;
    c_v2 <= c_v1;
    if (cq_left != 0) begin
      c_v1     <= 1'b1;
      c_bank1  <= fcc_raddr[0];
      c_rot1   <= fcc_raddr[1:0];
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
      c_data2  <= fcc_quad;
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
          mac_quad  <= WIDE;
          for (int k = 0; k < (WIDE ? 32 : 8); k++)
            mac_prod[k] <= $signed({{8{c_data2[8*k + 7]}}, c_data2[8*k +: 8]}) * $signed({8'd0, c_value2});
        end
        default: begin  // K_FC2
          mac_v0    <= 1'b1;
          mac_layer <= 2'd2;
          mac_quad  <= 1'b0;
          for (int k = 0; k < 8; k++)
            mac_prod[k] <= $signed({{8{c_data2[8*k + 7]}}, c_data2[8*k +: 8]})
                         * $signed({8'd0, concat[{c_idx2[3:0], 3'(k)}]});
        end
      endcase
    end

    // ---- Data sink. row_left == 0 discards stale words after an abort. ----
    // Row-phase sinks may start from the read queue in the cycle their first word arrives
    // (snk_*). Every other sink is decoded from registered state only, which keeps the queue
    // logic out of the FC multiplier paths.
    if (m_readdatavalid && snk_left != 0) begin
      row_left <= snk_left - 16'd1;
      word_idx <= snk_idx + 16'd1;

      case (snk_mode)
        M_PSQ_ROW: begin
          if (!snk_idx[0]) tile_hold <= rd;
          else begin
            tile_v0     <= 1'b1;
            tile_t0     <= snk_idx[7:1];
            tile_delta0 <= {rd, tile_hold};
            tile_mode0  <= bias_mode ? T_LOAD : (snk_rem ? T_SUB : T_ADD);
          end
        end

        // A beat of int8 weights is a whole entry: 8 (64-bit) or 16 (128-bit) lanes.
        M_ACTIVE_ROW: begin
          tile_v0    <= 1'b1;
          tile_t0    <= snk_idx[6:0];
          tile_mode0 <= snk_rem ? T_SUB : T_ADD;
          for (int k = 0; k < BUS_W / 8; k++)
            tile_delta0[16*k +: 16] <= {{8{rd[8*k + 7]}}, rd[8*k +: 8]};
        end

        // Bucket index = beat * lanes + lane, written as bit concatenation: Quartus mis-sized the
        // multiplied form (warning 10027) although simulation was right.
        M_PSQT: begin
          if (W128) begin
            for (int j = 0; j < 4; j++)
              if (snk_rem)
                psqt_acc[cur_p][{snk_idx[0], 2'(j)}] <= psqt_acc[cur_p][{snk_idx[0], 2'(j)}] - $signed(rd_w[32*j +: 32]);
              else
                psqt_acc[cur_p][{snk_idx[0], 2'(j)}] <= psqt_acc[cur_p][{snk_idx[0], 2'(j)}] + $signed(rd_w[32*j +: 32]);
          end else begin
            for (int j = 0; j < 2; j++)
              if (snk_rem)
                psqt_acc[cur_p][{snk_idx[1:0], 1'(j)}] <= psqt_acc[cur_p][{snk_idx[1:0], 1'(j)}] - $signed(rd_w[32*j +: 32]);
              else
                psqt_acc[cur_p][{snk_idx[1:0], 1'(j)}] <= psqt_acc[cur_p][{snk_idx[1:0], 1'(j)}] + $signed(rd_w[32*j +: 32]);
          end
        end

        default: ;
      endcase
    end

    if (m_readdatavalid && row_left != 0) begin
      case (sink_mode)
        // Explicit word positions: Quartus treated the computed index form as never writing
        // hdr[4..5] (warning 10030) although simulation was right.
        M_HDR:
          if (W128) begin
            case (word_idx[1:0])
              2'd0: begin hdr[0] <= rd_w[63:0]; hdr[1] <= rd_w[127:64]; end
              2'd1: begin hdr[2] <= rd_w[63:0]; hdr[3] <= rd_w[127:64]; end
              2'd2: begin hdr[4] <= rd_w[63:0]; hdr[5] <= rd_w[127:64]; end
              default: ;
            endcase
          end else if (word_idx < 16'd6) hdr[word_idx[2:0]] <= rd_w[63:0];

        M_FEAT: begin
          feat_we    <= 1'b1;
          feat_waddr <= word_idx[FAW-1:0];
          feat_wdata <= rd;
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
          mac_quad  <= 1'b0;
          for (int k = 0; k < 8; k++)
            mac_prod[k] <= $signed({{8{rd[8*k + 7]}}, rd[8*k +: 8]}) * $signed({8'd0, mac_value});
        end

        M_FC2: begin
          mac_v0    <= 1'b1;
          mac_layer <= 2'd2;
          mac_quad  <= 1'b0;
          for (int k = 0; k < 8; k++)
            mac_prod[k] <= $signed({{8{rd[8*k + 7]}}, rd[8*k +: 8]})
                         * $signed({8'd0, concat[{word_idx[3:0], 3'(k)}]});
        end

        M_FILL: begin
          fcc_we    <= 1'b1;
          fcc_wdata <= rd;
          if (WIDE) begin
            // Quad address and bank of the beat's first word (128-bit: words 2j and 2j+1).
            fcc_waddr <= (fill_e ? 14'(FCQ) : 14'd0) + (W128 ? {1'b0, word_idx[13:1]} : {2'b00, word_idx[13:2]});
            fcc_wbank <= W128 ? {word_idx[0], 1'b0} : word_idx[1:0];
          end else
            fcc_waddr <= (fill_e ? 14'(FCC_STRIDE >> (W128 ? 1 : 0)) : 14'd0) + word_idx[13:0];
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
          if (desc_addr[BSH-1:0] != 0 || weight_base[11:0] != 0) fail(ERR_ALIGN);
          else state <= S_DRAIN;
        end
      end

      // Words from an aborted run must be gone before a new run issues reads.
      S_DRAIN: if (cmd_left == 0 && outstanding == 0 && cache_idle) state <= S_HDR;

      S_HDR: begin
        go(desc_addr, DESC_HEADER_WORDS[15:0] * 16'd8 >> BSH, M_HDR);
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
        plan        <= HW_PLAN && hdr[3][28];
        look_dst_valid  <= slot_valid[hdr[3][4:0]];
        look_dst_owner  <= slot_owner[hdr[3][4:0]];
        look_src0_valid <= slot_valid[hdr[3][12:8]];
        look_src0_owner <= slot_owner[hdr[3][12:8]];
        look_src1_valid <= slot_valid[hdr[3][20:16]];
        look_src1_owner <= slot_owner[hdr[3][20:16]];
        for (int w = 0; w < 2; w++)
          for (int k = 0; k < 4; k++)
            n_list[w*4 + k] <= hdr[4 + w][16*k +: 10];
        list_base[0] <= 12'd0;
        list_base[1] <= 12'(hdr[4][9:0]);
        list_base[2] <= 12'(hdr[4][9:0]) + 12'(hdr[4][25:16]);
        list_base[3] <= 12'(hdr[4][9:0]) + 12'(hdr[4][25:16]) + 12'(hdr[4][41:32]);
        list_base[4] <= 12'(hdr[4][9:0]) + 12'(hdr[4][25:16]) + 12'(hdr[4][41:32]) + 12'(hdr[4][57:48]);
        state <= S_HDR_CHECK;
      end

      S_HDR_CHECK: begin
        list_base[5] <= list_base[4] + 12'(n_list[4]);
        list_base[6] <= list_base[4] + 12'(n_list[4]) + 12'(n_list[5]);
        list_base[7] <= list_base[4] + 12'(n_list[4]) + 12'(n_list[5]) + 12'(n_list[6]);

        if (hdr[0][31:0] != DESC_MAGIC[31:0]) fail(ERR_MAGIC);
        else if (hdr[0][47:32] != ABI_VERSION[15:0]) fail(ERR_ABI);
        else if (hdr[1][31:0] != NETWORK_HASH[31:0]) fail(ERR_HASH);
        else if (hdr[1][63:32] != NET_ID[31:0]) fail(ERR_NET);
        else if (hdr[0][63:48] != 0 || hdr[2][39:33] != 0 || hdr[2][47:43] != 0 || hdr[3][63:29] != 0 ||
                 (hdr[3][28] && !HW_PLAN))
          fail(ERR_RESERVED);
        // A planned request carries full lists: both perspectives as refreshes.
        else if (plan && (op[0] != OP_REFRESH || op[1] != OP_REFRESH))
          fail(ERR_RANGE);
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
          if (op[0] != OP_NONE) list_valid[dst_slot][0] <= 1'b0;
          if (op[1] != OP_NONE) list_valid[dst_slot][1] <= 1'b0;
          use_diff[0] <= 1'b0;
          use_diff[1] <= 1'b0;
          plan_word   <= {11'd0, src_slot[1], 3'd0, src_slot[0], 3'd0, 1'b0, op[1], op[0]};
          if (op[0] != OP_NONE || op[1] != OP_NONE) slot_owner[dst_slot] <= ctx;
          go(desc_addr + 32'(DESC_HEADER_WORDS) * 32'd8,
             (16'(hdr[4][9:0]) + 16'(hdr[4][25:16]) + 16'(hdr[4][41:32]) + 16'(hdr[4][57:48]) +
              16'(hdr[5][9:0]) + 16'(hdr[5][25:16]) + 16'(hdr[5][41:32]) + 16'(hdr[5][57:48]) +
              16'((1 << FLB) - 1)) >> FLB,
             M_FEAT);
          state <= S_FEAT_WAIT;
          cur_p <= 1'b0;
        end
      end

      S_FEAT_WAIT: if (row_done && !feat_we) begin
        if (plan) begin
          pn_p       <= 1'b0;
          pn_k       <= 1'b0;
          pn_i       <= 10'd0;
          pn_err     <= 1'b0;
          cur_sig[0] <= 256'd0;
          cur_sig[1] <= 256'd0;
          state      <= S_PN_SIG;
        end else state <= S_P_BEGIN;
      end

      // ---- Planner ----
      // Signature pass: every current feature, PSQ and active of both perspectives.
      S_PN_SIG: begin
        if (pn_i != n_list[{pn_p, pn_k, 1'b0}]) begin
          sa_v    <= 1'b1;
          sa_p    <= pn_p;
          sa_k    <= pn_k;
          sa_i    <= pn_i;
          sa_lane <= pn_addr[FLB-1:0];
          pn_i    <= pn_i + 10'd1;
        end else if (!(pn_p && pn_k)) begin
          {pn_p, pn_k} <= {pn_p, pn_k} + 2'd1;
          pn_i         <= 10'd0;
        end else begin
          pn_i  <= 10'd0;
          state <= S_PN_SIGW;
        end
      end

      // Drain, then store both signatures and list lengths of the destination.
      S_PN_SIGW: if (!sa_v && !sb_v) begin
        if (pn_err) fail(ERR_RANGE);
        else if (pn_i == 10'd0) begin
          sig_we    <= 1'b1;
          sig_waddr <= {dst_slot, 1'b0};
          sig_wdata <= cur_sig[0];
          pn_i      <= 10'd1;
        end else begin
          sig_we    <= 1'b1;
          sig_waddr <= {dst_slot, 1'b1};
          sig_wdata <= cur_sig[1];
          st_npsq[{dst_slot, 1'b0}] <= n_list[0][5:0];
          st_nact[{dst_slot, 1'b0}] <= n_list[2][8:0];
          st_npsq[{dst_slot, 1'b1}] <= n_list[4][5:0];
          st_nact[{dst_slot, 1'b1}] <= n_list[6][8:0];
          pn_p      <= 1'b0;
          lb_s      <= 6'd0;
          state     <= S_PN_LB;
        end
      end

      // Bound of every slot for perspective pn_p; refresh cost as the first best.
      S_PN_LB: begin
        if (lb_s != 6'd32) begin
          la_v <= 1'b1;
          la_s <= lb_s[4:0];
          lb_s <= lb_s + 6'd1;
          if (lb_s == 6'd0) begin
            best_cost <= {n_list[{pn_p, 2'b00}], 1'b0} + 11'd2 + {1'b0, n_list[{pn_p, 2'b10}]};
            best_any  <= 1'b0;
            visited   <= '0;
          end
        end else if (!la_v && !lc_v && !ld_v) state <= S_PN_PICK;
      end

      // The unvisited candidate with the lowest bound, first slot on ties: groups of four, then
      // the eight group minima, then the decision.
      S_PN_PICK: begin
        for (int g = 0; g < 8; g++) begin
          g_any[g] <= gc_any[g];
          g_min[g] <= gc_min[g];
          g_arg[g] <= gc_arg[g];
        end
        state <= S_PN_PICK2;
      end

      S_PN_PICK2: begin
        for (int h = 0; h < 2; h++) begin
          h_any[h] <= hc_any[h];
          h_min[h] <= hc_min[h];
          h_arg[h] <= hc_arg[h];
        end
        state <= S_PN_PICK2B;
      end

      S_PN_PICK2B: begin
        pk_any <= pc_any;
        pk_min <= pc_min;
        pk_arg <= pc_arg;
        state  <= S_PN_PICK3;
      end

      S_PN_PICK3: begin
        if (pk_any && {1'b0, pk_min} < best_cost) begin
          visited[pk_arg] <= 1'b1;
          ms      <= pk_arg;
          mwrite  <= 1'b1;
          mbound  <= best_cost;
          mk      <= 1'b0;
          mcost   <= 11'd0;
          state   <= S_PN_M0;
        end else state <= S_PN_END;
      end

      // Merge setup for kind mk of slot ms.
      S_PN_M0: begin
        nC    <= n_list[{pn_p, mk, 1'b0}];
        baseC <= list_base[{pn_p, mk, 1'b0}];
        nS    <= mk ? {1'b0, st_nact[{ms, pn_p}]} : {4'd0, st_npsq[{ms, pn_p}]};
        baseS <= lst_base(ms, pn_p) + (mk ? LAW'(32) : LAW'(0));
        ci    <= 10'd0;
        sj    <= 10'd0;
        na    <= 9'd0;
        nr    <= 9'd0;
        state <= S_PN_M1;
      end

      S_PN_M1: begin  // element 0 of both lists is being read
        c_lane <= pn_addr[FLB-1:0];
        state  <= S_PN_M2;
      end

      S_PN_M2: begin  // heads arrive; element 1 is being read
        cv     <= cdata;
        sv     <= lst_rdata;
        c_lane <= pn_addr[FLB-1:0];
        state  <= S_PN_M;
      end

      // One step per cycle: equal advances both, the smaller one is an add (current only) or a
      // remove (stored only). The next element of each list is already being read.
      S_PN_M: begin
        c_lane <= pn_addr[FLB-1:0];
        if (m_advc) begin
          ci <= ci + 10'd1;
          cv <= cdata;
        end
        if (m_advs) begin
          sj <= sj + 10'd1;
          sv <= lst_rdata;
        end
        mcost <= m_cost_next;
        if (mwrite && (m_add || m_rem)) begin
          dif_we    <= 1'b1;
          dif_wdata <= m_add ? cv : sv;
          dif_waddr <= {pn_p, tbuf, mk ? (m_add ? 10'd64 + {1'b0, na} : 10'd320 + {1'b0, nr})
                                       : (m_add ? 10'd0 + {1'b0, na}  : 10'd32 + {1'b0, nr})};
          if (m_add) na <= na + 9'd1;
          else       nr <= nr + 9'd1;
        end
        if (m_cost_next >= mbound) begin
          // No better than the best so far: next candidate.
          state <= S_PN_PICK;
        end else if (m_cend && m_send) begin
          if (!mk) begin
            t_na0 <= na;
            t_nr0 <= nr;
            mk    <= 1'b1;
            state <= S_PN_M0;
          end else begin
            // Accepted: the trial buffer becomes the best one.
            best_cost <= m_cost_next;
            best_s    <= ms;
            best_any  <= 1'b1;
            bbuf      <= tbuf;
            tbuf      <= !tbuf;
            b_na0     <= t_na0;
            b_nr0     <= t_nr0;
            b_na1     <= na;
            b_nr1     <= nr;
            state     <= S_PN_PICK;
          end
        end
      end

      // Best source found: the row phase reads its lists from the best buffer. Else refresh.
      S_PN_END: begin
        if (best_any) begin
          n_list[{pn_p, 2'b00}]    <= {1'b0, b_na0};
          n_list[{pn_p, 2'b01}]    <= {1'b0, b_nr0};
          n_list[{pn_p, 2'b10}]    <= {1'b0, b_na1};
          n_list[{pn_p, 2'b11}]    <= {1'b0, b_nr1};
          list_base[{pn_p, 2'b00}] <= {pn_p, bbuf, 10'd0};
          list_base[{pn_p, 2'b01}] <= {pn_p, bbuf, 10'd32};
          list_base[{pn_p, 2'b10}] <= {pn_p, bbuf, 10'd64};
          list_base[{pn_p, 2'b11}] <= {pn_p, bbuf, 10'd320};
          use_diff[pn_p]           <= 1'b1;
          op[pn_p]                 <= OP_INCR;
          src_slot[pn_p]           <= best_s;
        end
        state <= S_PN_NEXTP;
      end

      S_PN_NEXTP: begin
        if (!pn_p) begin
          pn_p  <= 1'b1;
          lb_s  <= 6'd0;
          state <= S_PN_LB;
        end else begin
          plan_word <= {11'd0, src_slot[1], 3'd0, src_slot[0], 3'd0, 1'b1, op[1], op[0]};
          cur_p     <= 1'b0;
          state     <= S_P_BEGIN;
        end
      end

      S_P_BEGIN: begin
        pk <= 2'd0;
        case (op[cur_p])
          OP_REFRESH: begin
            for (int b = 0; b < 8; b++) psqt_acc[cur_p][b] <= 32'sd0;
            bias_mode <= 1'b1;
            go(weight_base + OFF_FT_BIAS[31:0], PSQ_ROW_BYTES[15:0] >> BSH, M_PSQ_ROW);
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
        if (copy_t == 7'(UNITS - 1)) state <= S_COPY_WAIT;
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
        end else if (READ_QUEUE) begin
          state <= S_ROW_DRAIN;
        end else begin
          pk    <= 2'd0;
          state <= S_PS;
        end
      end

      S_ROW_RD: state <= S_ROW_LAT;

      // Queued: the commands go into the queue in this cycle (q_push); without room, wait here.
      S_ROW_LAT: if (READ_QUEUE) begin
        if (!row_ok) fail(ERR_RANGE);
        else if (q_room) begin
          cur_i <= cur_i + 10'd1;
          state <= S_ROW_NEXT;
        end
      end else begin
        if (cur_act) begin
          if ({16'd0, cur_feature} >= ACTIVE_DIMENSIONS[31:0]) fail(ERR_RANGE);
          else begin
            go(weight_base + OFF_ACTIVE_WEIGHTS[31:0] + {6'd0, cur_feature, 10'd0},
               ACTIVE_ROW_BYTES[15:0] >> BSH, M_ACTIVE_ROW);
            state <= S_ROW_WAIT;
          end
        end else begin
          if ({16'd0, cur_feature} >= PSQ_DIMENSIONS[31:0]) fail(ERR_RANGE);
          else begin
            go(weight_base + OFF_PSQ_WEIGHTS[31:0] + {5'd0, cur_feature, 11'd0},
               PSQ_ROW_BYTES[15:0] >> BSH, M_PSQ_ROW);
            state <= S_ROW_WAIT;
          end
        end
      end

      S_ROW_WAIT: if (row_done) begin
        go(weight_base + (cur_act ? OFF_ACTIVE_PSQT[31:0] : OFF_PSQ_PSQT[31:0]) + {11'd0, cur_feature, 5'd0},
           PSQT_ROW_BYTES[15:0] >> BSH, M_PSQT);
        state <= S_PSQT_WAIT;
      end

      S_PSQT_WAIT: if (row_done) begin
        cur_i <= cur_i + 10'd1;
        state <= S_ROW_NEXT;
      end

      S_ROW_DRAIN: if (cq_count == 0 && cmd_left == 0 && sq_count == 0 && row_done) begin
        pk    <= 2'd0;
        state <= S_PS;
      end

      S_PS: begin
        psqt_we    <= 1'b1;
        psqt_waddr <= {dst_slot, cur_p, pk};
        psqt_wdata <= {psqt_acc[cur_p][{pk, 1'b1}], psqt_acc[cur_p][{pk, 1'b0}]};
        pk         <= pk + 2'd1;
        if (pk == 2'd3) begin
          slot_valid[dst_slot][cur_p] <= 1'b1;
          list_valid[dst_slot][cur_p] <= plan;
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
             16'(FILL_BEATS), M_FILL);
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
        ft_ptr    <= 7'd0;
        layer     <= 2'd0;
        scan_word <= 64'd0;
        state     <= S_FC0_RD;
      end

      // Wide: ft_raddr follows nxt_ptr; with no non-zero word left, PICK finishes.
      S_FC0_RD: state <= (WIDE && !nxt_any) ? S_FC0_PICK : S_FC0_LOAD;

      S_FC0_LOAD: begin
        scan_word <= ft_rdata;
        if (WIDE) begin
          ft_ptr                <= nxt_ptr;
          ft_nzmask[nxt_ptr]    <= 1'b0;
          scan_settled          <= 1'b0;
        end
        state     <= S_FC0_PICK;
      end

      S_FC0_PICK: if (WIDE) begin
        // One column per cycle. ft_raddr has pointed at the next non-zero word since the cycle
        // after the last load (scan_settled), so that word can replace the current one in the
        // cycle its last lane issues.
        scan_settled <= 1'b1;
        if (scan_nz != 0) begin
          scan_word[8*scan_lane +: 8] <= 8'd0;
          cgo(13'(FCC_FC0) + {1'b0, ft_ptr, scan_lane, 2'b00}, 6'd1, K_COL, scan_word[8*scan_lane +: 8], 2'd0);
          if (scan_single && nxt_any) begin
            if (scan_settled) begin
              scan_word          <= ft_rdata;
              ft_ptr             <= nxt_ptr;
              ft_nzmask[nxt_ptr] <= 1'b0;
              scan_settled       <= 1'b0;
            end else
              state <= S_FC0_RD;
          end
        end else if (nxt_any) begin
          if (scan_settled) begin
            scan_word          <= ft_rdata;
            ft_ptr             <= nxt_ptr;
            ft_nzmask[nxt_ptr] <= 1'b0;
            scan_settled       <= 1'b0;
          end
        end else if (cache_idle && !mac_v0 && !mac_v1) begin
          ac_layer <= 1'b0;
          ac_i     <= 5'd0;
          state    <= S_AC_A;
        end
      end else begin
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

      S_AC_A: if (WIDE) begin
        // Issue element ac_i; the pipeline below takes its magnitude, squares it and writes it.
        // (Selecting one of 32 values and taking the magnitude in one cycle missed 100 MHz.)
        ac_v0  <= 1'b1;
        ac_i0  <= ac_i;
        ac_sel <= ac_layer ? fc1[ac_i] : fc0[ac_i];
        ac_i   <= ac_i + 5'd1;
        if (ac_i == 5'd31) state <= S_AC_C;
      end else begin
        ac_x   <= ac_layer ? fc1[ac_i] : fc0[ac_i];
        ac_mag <= sqr_magnitude(ac_layer ? fc1[ac_i] : fc0[ac_i]);
        state  <= S_AC_B;
      end

      S_AC_B: begin
        ac_square <= 34'(ac_mag) * 34'(ac_mag);
        state     <= S_AC_C;
      end

      S_AC_C: if (WIDE) begin
        // Drained: every element of this layer is in concat.
        if (!ac_v0 && !ac_v1 && !ac_v2) begin
          if (!ac_layer) begin
            layer   <= 2'd1;
            fc1_col <= 7'd0;
            state   <= S_FC1_PICK;
          end else begin
            cgo(13'(FCC_FC2), 6'(FC2_BYTES / 8), K_FC2, 8'd0, 2'd2);
            state <= S_FC2_WAIT;
          end
        end
      end else begin
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
          cgo(13'(FCC_FC1) + {4'd0, fc1_col[5:0], 2'b00}, WIDE ? 6'd1 : 6'd4, K_COL, concat[fc1_col], 2'd1);
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
      cq_count <= 3'd0;
      sq_count <= 4'd0;
      cq_head  <= 2'd0;
      cq_tail  <= 2'd0;
      sq_head  <= 3'd0;
      sq_tail  <= 3'd0;
      if (cmd_left != 0) aborting <= 1'b1;
    end

    if (rst) begin
      cq_count     <= 3'd0;
      sq_count     <= 4'd0;
      cq_head      <= 2'd0;
      cq_tail      <= 2'd0;
      sq_head      <= 3'd0;
      sq_tail      <= 3'd0;
      q_active     <= 1'b0;
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
      ac_v0       <= 1'b0;
      ac_v1       <= 1'b0;
      ac_v2       <= 1'b0;
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
      for (int i = 0; i < SLOTS; i++) list_valid[i] <= 2'b00;
      sa_v        <= 1'b0;
      sb_v        <= 1'b0;
      la_v        <= 1'b0;
      lc_v        <= 1'b0;
      ld_v        <= 1'b0;
      use_diff[0] <= 1'b0;
      use_diff[1] <= 1'b0;
      plan        <= 1'b0;
      plan_word   <= 32'd0;
    end
  end

endmodule
