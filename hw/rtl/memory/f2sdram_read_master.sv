// V2 F2SDRAM read master.
//
// All addresses on this interface are 64-bit memory-word addresses. The
// adapter which connects this module to Platform Designer owns any byte/word
// translation. One command has one outstanding burst and a bounded lifetime.
module f2sdram_read_master #(
  parameter int ADDR_W = 29,
  parameter int TIMEOUT_CYCLES = 4096
) (
  input  logic             clk,
  input  logic             rst,

  input  logic             cmd_valid,
  output logic             cmd_ready,
  input  logic [ADDR_W-1:0] cmd_address,
  input  logic [7:0]       cmd_beats,

  output logic             mem_read,
  output logic [ADDR_W-1:0] mem_address,
  output logic [7:0]       mem_burstcount,
  input  logic             mem_waitrequest,
  input  logic             mem_readdatavalid,
  input  logic [63:0]      mem_readdata,

  output logic             rsp_valid,
  input  logic             rsp_ready,
  output logic [63:0]      rsp_data,
  output logic             rsp_last,
  output logic             rsp_error,
  output logic             busy
);

  localparam int COUNT_W = 8;
  localparam int TIMER_W = (TIMEOUT_CYCLES <= 1) ? 1 : $clog2(TIMEOUT_CYCLES + 1);
  localparam logic [TIMER_W-1:0] TIMEOUT_LIMIT = TIMER_W'(TIMEOUT_CYCLES - 1);

  typedef enum logic [2:0] {IDLE, ISSUE, DRAIN, ERROR} state_t;
  state_t state;

  logic [ADDR_W-1:0] address_r;
  logic [COUNT_W-1:0] beats_r;
  logic [COUNT_W-1:0] returned_r;
  logic [TIMER_W-1:0] timer_r;
  logic [63:0] rsp_data_r;
  logic rsp_last_r;
  logic rsp_valid_r;

  assign cmd_ready = (state == IDLE);
  assign busy = (state != IDLE);
  assign mem_read = (state == ISSUE);
  assign mem_address = address_r;
  assign mem_burstcount = beats_r;
  assign rsp_valid = rsp_valid_r;
  assign rsp_data = rsp_data_r;
  assign rsp_last = rsp_last_r;
  assign rsp_error = (state == ERROR);

  always_ff @(posedge clk) begin
    if (rst) begin
      state       <= IDLE;
      address_r   <= '0;
      beats_r     <= '0;
      returned_r  <= '0;
      timer_r     <= '0;
      rsp_data_r  <= '0;
      rsp_last_r  <= 1'b0;
      rsp_valid_r <= 1'b0;
    end else begin
      if (rsp_valid_r && rsp_ready) begin
        rsp_valid_r <= 1'b0;
        if (rsp_last_r)
          state <= IDLE;
      end

      case (state)
        IDLE: begin
          timer_r    <= '0;
          returned_r <= '0;
          if (cmd_valid) begin
            address_r <= cmd_address;
            beats_r   <= (cmd_beats == 0) ? 8'd1 : cmd_beats;
            state     <= ISSUE;
          end
        end

        ISSUE: begin
          if (timer_r == TIMEOUT_LIMIT) begin
            state <= ERROR;
          end else begin
            timer_r <= timer_r + 1'b1;
            if (!mem_waitrequest) begin
              timer_r <= '0;
              state   <= DRAIN;
            end
          end
        end

        DRAIN: begin
          if (mem_readdatavalid && !rsp_valid_r) begin
            rsp_data_r  <= mem_readdata;
            rsp_last_r  <= (returned_r + 1'b1 >= beats_r);
            rsp_valid_r <= 1'b1;
            returned_r  <= returned_r + 1'b1;
            timer_r     <= '0;
          end else if (timer_r == TIMEOUT_LIMIT) begin
            state <= ERROR;
          end else begin
            timer_r <= timer_r + 1'b1;
          end
        end

        ERROR: begin
          if (rsp_ready)
            state <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end
endmodule
