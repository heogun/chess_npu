`timescale 1ns/1ps
module tb_fte_real;
  logic clk=0, rst=1, start=0, stm=0, use_big=0;
  logic [31:0] cnt0=0, cnt1=0, cntt0=0, cntt1=0;
  logic feat_valid=0; logic [31:0] feat=0;
  logic ld_we=0; logic [21:0] ld_addr=0; logic [15:0] ld_data=0;
  logic q_valid, done; logic [7:0] q_index, q_data;
  logic feat_ready;
  top_fte u (.*);

  int fd;
  initial begin
    $readmemh("/tmp/ftreal_hex.txt", u.u_wb.mem);
    repeat(4) #5 clk=~clk;
    rst=0;
    // features: from FTLIST
    feat_valid=1;
    // persp0 (stm=0) 32개 -> cnt0
    repeat(32) begin @(negedge clk); feat = 32'he000; end
    // persp1 32개 -> cnt1
    repeat(32) begin @(negedge clk); feat = 32'hf000; end
    feat_valid=0;
    @(negedge clk); cnt0=32; cnt1=32; stm=0; start=1;
    @(negedge clk); start=0;
    fd = $fopen("/tmp/trace.txt","w");
    wait(done);
    $fclose(fd);
    $display("DONE fails-unknown");
    $finish;
  end

  // trace each cycle
  always @(posedge clk) begin
    if (!rst)
      $fwrite(fd, "st=%0d ph=%0d src=%0d fcnt=%0d jctr=%0d fcur=%0d qph=%0d qj=%0d qv=%0d qi=%0d qd=%0d wba=%0d fout=%0d fw=%0d fr=%0d\n",
        u.u_fte.st, u.u_fte.ph, u.u_fte.src, u.u_fte.fcnt, u.u_fte.jctr, u.u_fte.fcur,
        u.u_fte.qph, u.u_fte.qj, q_valid, q_index, q_data, u.u_fte.wb_addr, u.u_fte.fout,
        u.u_fte.fw, u.u_fte.fr);
  end
endmodule