// M0 board check: proves JTAG configuration, CLOCK_50 and the LED pins. Not part of the accelerator.
// The free-running count is exposed through In-System Sources and Probes in Gray code, so an
// unsynchronized JTAG capture is off by at most one count.
module m0_blink (
    input  logic       CLOCK_50,
    output logic [9:0] LEDR
);
    logic [31:0] count = '0;

    always_ff @(posedge CLOCK_50) count <= count + 1'b1;

    // A dot walks from LEDR0 to LEDR9 at 0.17 s per step, then all LEDs stay off for 1 s.
    // Slow enough to check by eye that each pin is the expected LED.
    always_comb begin
        LEDR = '0;
        if (count[26:23] <= 4'd9) LEDR[count[26:23]] = 1'b1;
    end

    altsource_probe #(
        .sld_auto_instance_index("YES"),
        .sld_instance_index(0),
        .instance_id("CNT0"),
        .probe_width(32),
        .source_width(0),
        .source_initial_value("0"),
        .enable_metastability("NO")
    ) u_probe (
        .probe(count ^ (count >> 1))
    );
endmodule
