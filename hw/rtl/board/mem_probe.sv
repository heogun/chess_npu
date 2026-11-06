// DDR measurement master for the FPGA-to-SDRAM port. Not part of the accelerator.
// Runs reads or writes against a CSR-selected window, and records bandwidth, a latency histogram
// and data mismatches. Latency is from command accept to the first data beat of that burst.
//
// CSR word offsets:
// Addresses, BURST and BEATS count port beats of DATA_W bits (64 or 128).
//   0 ID        R   0x4D505231
//   1 CTRL      W   bit0 start, bit1 abort, bits[3:2] mode (0 seq read, 1 random read, 2 seq write),
//                   bit4 verify read data against the pattern
//   2 STATUS    R   bit0 busy (includes draining the statistics pipeline), bit1 done
//   3 BASE      RW  first address, in 64-bit words
//   4 MASK      RW  window size minus 1, in words, power of two minus 1
//   5 BURST     RW  words per transaction, 1 to 16
//   6 MAX_OUT   RW  read transactions in flight, 1 to 32
//   7 COUNT     RW  transactions to run
//   8 CYC_LO    R   cycles from start to the last response
//   9 CYC_HI    R
//  10 WAIT      R   cycles a request was held by waitrequest
//  11 BEATS     R   data beats transferred
//  12 LAT_LO    R   sum of read latency in cycles
//  13 LAT_HI    R
//  14 LAT_MIN   R
//  15 LAT_MAX   R
//  16 BAD       R   mismatching read beats
//  17 SEED      RW  pattern seed
//  18 FREE      R   free-running cycle counter
//  19 ISSUED    R   transactions accepted
//  20 BAD_WORD  R   word address of the first mismatch
//  21 SCRATCH   RW
//  22 WIDTH     R   DATA_W (older images return 0xDEADBEEF here: 64)
//  64-127 HIST  R   read latency histogram, 4 cycles per bin, the last bin collects the rest
//
// The pattern for 64-bit word address w is {~w, w} XOR {seed, seed}; a beat of N words at beat
// address b holds words b*N .. b*N+N-1, lowest word in the low bits. A location therefore reads
// the same whatever port width wrote it.
module mem_probe #(
    parameter int ADDR_W = 29,
    parameter int BURST_W = 8,
    parameter int DATA_W = 64
) (
    input  logic               clk,
    input  logic               rst,

    input  logic [11:0]        csr_address,  // bytes
    input  logic               csr_read,
    input  logic               csr_write,
    input  logic [31:0]        csr_writedata,
    output logic [31:0]        csr_readdata,
    output logic               csr_readdatavalid,
    output logic               csr_waitrequest,

    output logic [ADDR_W-1:0]  m_address,    // 64-bit words
    output logic               m_read,
    output logic               m_write,
    output logic [DATA_W-1:0]  m_writedata,
    output logic [DATA_W/8-1:0] m_byteenable,
    output logic [BURST_W-1:0] m_burstcount,
    input  logic [DATA_W-1:0]  m_readdata,
    input  logic               m_readdatavalid,
    input  logic               m_waitrequest
);
    localparam int FIFO_DEPTH = 32;
    localparam int HIST_BINS = 64;
    localparam int WORDS = DATA_W / 64;
    localparam int CHECK_W = 1 / ((DATA_W == 64 || DATA_W == 128) ? 1 : 0);

    typedef enum logic [1:0] {MODE_SEQ_READ, MODE_RAND_READ, MODE_SEQ_WRITE} mode_t;

    logic [ADDR_W-1:0] base, mask;
    logic [4:0]  burst;
    logic [5:0]  max_out;
    logic [31:0] count, seed, scratch;
    logic [1:0]  mode;
    logic        verify, busy, done;

    logic [63:0] cycles, lat_sum, free_cnt;
    logic [31:0] wait_cnt, beats, lat_min, lat_max, bad, issued, responses, bad_word;
    logic [31:0] hist [HIST_BINS];

    logic [ADDR_W-1:0] offset;
    logic [31:0]       lfsr;
    logic [4:0]        wr_beat;

    // In-flight read transactions: start time and word address.
    logic [31:0]       fifo_time [FIFO_DEPTH];
    logic [ADDR_W-1:0] fifo_addr [FIFO_DEPTH];
    logic [4:0]        fifo_wr, fifo_rd;
    logic [5:0]        in_flight;
    logic [4:0]        rd_beat;

    function automatic logic [DATA_W-1:0] pattern(input logic [ADDR_W-1:0] beat, input logic [31:0] s);
        logic [DATA_W-1:0] v;
        for (int i = 0; i < WORDS; i++) begin
            logic [31:0] w;
            w = 32'(beat) * 32'(WORDS) + 32'(i);
            v[64*i +: 64] = {~w, w} ^ {s, s};
        end
        return v;
    endfunction

    wire is_write = mode == 2'(MODE_SEQ_WRITE);
    // Zero-extended copies. Quartus Standard rejects casts to a parameter width.
    wire [4:0]        burst_m1 = burst - 5'd1;
    wire [ADDR_W-1:0] burst_ext = {{(ADDR_W-5){1'b0}}, burst};
    wire [ADDR_W-1:0] wr_beat_ext = {{(ADDR_W-5){1'b0}}, wr_beat};
    wire [ADDR_W-1:0] rd_beat_ext = {{(ADDR_W-5){1'b0}}, rd_beat};
    wire [ADDR_W-1:0] burst_align = ~{{(ADDR_W-5){1'b0}}, burst_m1};
    wire [ADDR_W-1:0] rand_offset = lfsr[ADDR_W-1:0] & mask & burst_align;  // needs ADDR_W <= 32
    wire [ADDR_W-1:0] cmd_offset = mode == 2'(MODE_RAND_READ) ? rand_offset : offset;
    wire [ADDR_W-1:0] cmd_addr = base + cmd_offset;
    wire more = busy && issued != count;

    wire rd_request = more && !is_write && in_flight < max_out;
    wire wr_request = more && is_write;

    assign m_address = wr_request ? base + offset : cmd_addr;
    assign m_read = rd_request;
    assign m_write = wr_request;
    assign m_writedata = pattern(base + offset + wr_beat_ext, seed);
    assign m_byteenable = '1;
    assign m_burstcount = {{(BURST_W-5){1'b0}}, burst};

    wire rd_accept = m_read && !m_waitrequest;
    wire wr_accept = m_write && !m_waitrequest;
    wire wr_last = wr_accept && wr_beat == burst - 5'd1;

    wire [ADDR_W-1:0] head_addr = fifo_addr[fifo_rd];
    wire resp_last = m_readdatavalid && rd_beat == burst - 5'd1;
    wire first_beat = m_readdatavalid && rd_beat == 5'd0;

    // Read beats go through a 4-stage pipeline for verification and latency statistics, so the
    // RAM read, subtract, compare and histogram update each get a cycle. done waits for it to drain.
    //   1: capture beat, expected address, start time and current cycle count
    //   2: latency and mismatch    3: histogram bin    4: update counters
    logic              p1_valid, p1_first;
    logic [DATA_W-1:0] p1_data;
    logic [ADDR_W-1:0] p1_addr;
    logic [31:0]       p1_start, p1_now;
    logic              p2_valid, p2_first, p2_bad;
    logic [ADDR_W-1:0] p2_addr;
    logic [31:0]       p2_lat;
    logic              p3_valid, p3_first, p3_bad;
    logic [ADDR_W-1:0] p3_addr;
    logic [31:0]       p3_lat;
    logic [5:0]        p3_bin;
    logic              finishing;
    wire pipe_busy = p1_valid || p2_valid || p3_valid;

    // The start pulse takes effect only when idle and drained.
    wire start = csr_write && csr_address[11:2] == 10'd1 && csr_writedata[0] && !busy && !finishing && !pipe_busy;
    wire abort = csr_write && csr_address[11:2] == 10'd1 && csr_writedata[1];

    always_ff @(posedge clk) begin
        free_cnt <= free_cnt + 1'b1;
        csr_readdatavalid <= csr_read;

        if (csr_write) begin
            unique case (csr_address[11:2])
                10'd1: begin
                    if (!busy) begin
                        mode <= csr_writedata[3:2];
                        verify <= csr_writedata[4];
                    end
                end
                10'd3: base <= csr_writedata[ADDR_W-1:0];
                10'd4: mask <= csr_writedata[ADDR_W-1:0];
                10'd5: burst <= csr_writedata[4:0];
                10'd6: max_out <= csr_writedata[5:0];
                10'd7: count <= csr_writedata;
                10'd17: seed <= csr_writedata;
                10'd21: scratch <= csr_writedata;
                default: ;
            endcase
        end

        if (start) begin
            busy <= 1'b1;
            done <= 1'b0;
            cycles <= '0;
            lat_sum <= '0;
            wait_cnt <= '0;
            beats <= '0;
            lat_min <= '1;
            lat_max <= '0;
            bad <= '0;
            bad_word <= '0;
            issued <= '0;
            responses <= '0;
            offset <= '0;
            wr_beat <= '0;
            rd_beat <= '0;
            fifo_wr <= '0;
            fifo_rd <= '0;
            in_flight <= '0;
            lfsr <= seed | 32'd1;
            for (int i = 0; i < HIST_BINS; i++) hist[i] <= '0;
        end else if (busy) begin
            cycles <= cycles + 1'b1;
            if ((m_read || m_write) && m_waitrequest) wait_cnt <= wait_cnt + 1'b1;

            if (rd_accept) begin
                fifo_time[fifo_wr] <= 32'(cycles);
                fifo_addr[fifo_wr] <= cmd_addr;
                fifo_wr <= fifo_wr + 1'b1;
                issued <= issued + 1'b1;
                offset <= (offset + burst_ext) & mask;
                lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            end

            if (wr_accept) begin
                beats <= beats + 1'b1;
                wr_beat <= wr_last ? '0 : wr_beat + 1'b1;
                if (wr_last) begin
                    issued <= issued + 1'b1;
                    responses <= responses + 1'b1;
                    offset <= (offset + burst_ext) & mask;
                end
            end

            if (m_readdatavalid) begin
                beats <= beats + 1'b1;
                rd_beat <= resp_last ? '0 : rd_beat + 1'b1;
            end

            if (resp_last) begin
                fifo_rd <= fifo_rd + 1'b1;
                responses <= responses + 1'b1;
            end

            unique case ({rd_accept, resp_last})
                2'b10: in_flight <= in_flight + 1'b1;
                2'b01: in_flight <= in_flight - 1'b1;
                default: ;
            endcase

            // A write finishes when its last beat is accepted. A read waits for its last response.
            if (responses + 32'(resp_last || wr_last) == count) begin
                busy <= 1'b0;
                finishing <= 1'b1;
            end
        end

        // Read beat pipeline. Runs after busy drops so the last beats are counted.
        p1_valid <= busy && m_readdatavalid;
        p1_first <= first_beat;
        p1_data <= m_readdata;
        p1_addr <= head_addr + rd_beat_ext;
        p1_start <= fifo_time[fifo_rd];
        p1_now <= cycles[31:0];

        p2_valid <= p1_valid;
        p2_first <= p1_first;
        p2_addr <= p1_addr;
        p2_lat <= p1_now - p1_start;
        p2_bad <= verify && p1_data != pattern(p1_addr, seed);

        p3_valid <= p2_valid;
        p3_first <= p2_first;
        p3_addr <= p2_addr;
        p3_lat <= p2_lat;
        p3_bad <= p2_bad;
        p3_bin <= |p2_lat[31:8] ? 6'(HIST_BINS - 1) : p2_lat[7:2];

        if (p3_valid && p3_bad) begin
            if (bad == 0) bad_word <= 32'(p3_addr);
            bad <= bad + 1'b1;
        end
        if (p3_valid && p3_first) begin
            lat_sum <= lat_sum + 64'(p3_lat);
            if (p3_lat < lat_min) lat_min <= p3_lat;
            if (p3_lat > lat_max) lat_max <= p3_lat;
            for (int i = 0; i < HIST_BINS; i++)
                if (p3_bin == 6'(i)) hist[i] <= hist[i] + 1'b1;
        end

        if (finishing && !busy && !pipe_busy) begin
            finishing <= 1'b0;
            done <= 1'b1;
        end

        if (abort) begin
            busy <= 1'b0;
            finishing <= 1'b0;
        end

        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            finishing <= 1'b0;
            p1_valid <= 1'b0;
            p2_valid <= 1'b0;
            p3_valid <= 1'b0;
            free_cnt <= '0;
            csr_readdatavalid <= 1'b0;
            base <= '0;
            mask <= '0;
            burst <= 5'd1;
            max_out <= 6'd1;
            count <= '0;
            seed <= '0;
            scratch <= '0;
            mode <= '0;
            verify <= 1'b0;
            issued <= '0;
            responses <= '0;
            in_flight <= '0;
            wr_beat <= '0;
            rd_beat <= '0;
            offset <= '0;
            fifo_wr <= '0;
            fifo_rd <= '0;
        end
    end

    assign csr_waitrequest = 1'b0;

    always_ff @(posedge clk) begin
        if (csr_read) begin
            if (csr_address[11:8] == 4'b0001) begin
                csr_readdata <= hist[csr_address[7:2]];
            end else begin
                unique case (csr_address[11:2])
                    10'd0: csr_readdata <= 32'h4D50_5231;
                    10'd2: csr_readdata <= 32'({done, busy || finishing});
                    10'd3: csr_readdata <= 32'(base);
                    10'd4: csr_readdata <= 32'(mask);
                    10'd5: csr_readdata <= 32'(burst);
                    10'd6: csr_readdata <= 32'(max_out);
                    10'd7: csr_readdata <= count;
                    10'd8: csr_readdata <= cycles[31:0];
                    10'd9: csr_readdata <= cycles[63:32];
                    10'd10: csr_readdata <= wait_cnt;
                    10'd11: csr_readdata <= beats;
                    10'd12: csr_readdata <= lat_sum[31:0];
                    10'd13: csr_readdata <= lat_sum[63:32];
                    10'd14: csr_readdata <= lat_min;
                    10'd15: csr_readdata <= lat_max;
                    10'd16: csr_readdata <= bad;
                    10'd17: csr_readdata <= seed;
                    10'd18: csr_readdata <= free_cnt[31:0];
                    10'd19: csr_readdata <= issued;
                    10'd20: csr_readdata <= bad_word;
                    10'd21: csr_readdata <= scratch;
                    10'd22: csr_readdata <= 32'(DATA_W);
                    default: csr_readdata <= 32'hDEAD_BEEF;
                endcase
            end
        end
    end
endmodule
