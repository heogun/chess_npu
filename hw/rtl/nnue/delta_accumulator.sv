// Persistent DE1-SoC accumulator update primitive.
//
// The feature-transformer scheduler supplies one complete int16 feature
// column per update. REFRESH starts from bias; ACCUMULATE applies signed
// add/remove columns without clearing state. This primitive is independent of
// DDR addressing and can therefore be verified with a local memory model.
module delta_accumulator #(
  parameter int LANES = 128,
  parameter int DATA_W = 16,
  parameter int ACC_W = 32
) (
  input logic                         clk,
  input logic                         rst,
  input logic                         clear,
  input logic                         update_valid,
  input logic                         update_add,
  input logic signed [DATA_W-1:0]     update_data [0:LANES-1],
  output logic                         update_ready,
  output logic signed [ACC_W-1:0]     value [0:LANES-1]
);

  assign update_ready = !clear;

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      for (int lane = 0; lane < LANES; lane++)
        value[lane] <= '0;
    end else if (update_valid) begin
      for (int lane = 0; lane < LANES; lane++) begin
        if (update_add)
          value[lane] <= value[lane] + ACC_W'($signed(update_data[lane]));
        else
          value[lane] <= value[lane] - ACC_W'($signed(update_data[lane]));
      end
    end
  end
endmodule
