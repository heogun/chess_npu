// Stockfish 18 FT column scheduler for the DE1-SoC accelerator.
//
// Physical int16 layout:
//   bias:    [0 .. HD-1]
//   feature: HD + feature_index * HD + lane
//
// The memory adapter returns one complete HD-lane column. This module owns
// sequencing and applies it to the persistent accumulator. DDR protocol
// details remain outside this module.
module ft_delta_engine #(
  parameter int HD = 128,
  parameter int ADDR_W = 22
) (
  input logic clk,
  input logic rst,

  input logic start,
  input logic start_refresh,
  output logic ready,

  input logic feature_valid,
  output logic feature_ready,
  input logic [31:0] feature_index,
  input logic feature_add,

  output logic mem_req,
  output logic [ADDR_W-1:0] mem_base_addr,
  input logic mem_valid,
  input logic signed [15:0] mem_data [0:HD-1],

  output logic signed [31:0] accumulator [0:HD-1]
);

  typedef enum logic [2:0] {IDLE, REQUEST_BIAS, WAIT_BIAS,
                            ACCEPT_FEATURE, REQUEST_FEATURE, WAIT_FEATURE} state_t;
  state_t state;

  logic feature_add_r;
  logic [31:0] feature_index_r;
  logic update_valid;
  logic update_add;
  logic clear_acc;

  delta_accumulator #(.LANES(HD)) u_acc (
    .clk(clk), .rst(rst), .clear(clear_acc),
    .update_valid(update_valid), .update_add(update_add),
    .update_data(mem_data), .update_ready(), .value(accumulator)
  );

  assign ready = (state == IDLE);
  assign feature_ready = (state == ACCEPT_FEATURE);
  assign mem_req = (state == REQUEST_BIAS || state == REQUEST_FEATURE);
  assign mem_base_addr = (state == REQUEST_BIAS) ? '0 :
                         ADDR_W'(HD) + ADDR_W'(feature_index_r) * ADDR_W'(HD);

  always_ff @(posedge clk) begin
    if (rst) begin
      state          <= IDLE;
      feature_add_r  <= 1'b0;
      feature_index_r<= '0;
      update_valid   <= 1'b0;
      update_add     <= 1'b0;
      clear_acc      <= 1'b0;
    end else begin
      update_valid <= 1'b0;
      clear_acc    <= 1'b0;

      case (state)
        IDLE: begin
          if (start) begin
            if (start_refresh) begin
              clear_acc <= 1'b1;
              state <= REQUEST_BIAS;
            end else begin
              state <= ACCEPT_FEATURE;
            end
          end
        end

        REQUEST_BIAS: begin
          state <= WAIT_BIAS;
        end

        WAIT_BIAS: begin
          if (mem_valid) begin
            update_valid <= 1'b1;
            update_add   <= 1'b1;
            state        <= ACCEPT_FEATURE;
          end
        end

        ACCEPT_FEATURE: begin
          if (feature_valid) begin
            feature_index_r <= feature_index;
            feature_add_r   <= feature_add;
            state           <= REQUEST_FEATURE;
          end
        end

        REQUEST_FEATURE: begin
          state <= WAIT_FEATURE;
        end

        WAIT_FEATURE: begin
          if (mem_valid) begin
            update_valid <= 1'b1;
            update_add   <= feature_add_r;
            state        <= ACCEPT_FEATURE;
          end
        end

        default: state <= IDLE;
      endcase
    end
  end
endmodule
