// DE1-SoC top. USE_NNUE = 0 builds the F2SDRAM/CSR measurement block (mem_probe), 1 builds the
// SF19 NNUE core. Both sit behind the same HPS system: CSR on the lightweight bridge at 0xFF200000,
// reads through the 64-bit F2SDRAM port. They run on the 100 MHz PLL clock.
// HPS port list and wiring follow the Terasic reference DE1_SOC_Linux_FB.v. The system reset is
// h2f_reset looped back, as in that reference.
// LEDR0: PLL locked. LEDR1: NNUE done/irq (USE_NNUE only). LEDR9: about 0.75 Hz blink while out of reset.
module board_top #(
    parameter int USE_NNUE = 0
) (
    input  logic        CLOCK_50,
    output logic [9:0]  LEDR,

    output logic [14:0] HPS_DDR3_ADDR,
    output logic [2:0]  HPS_DDR3_BA,
    output logic        HPS_DDR3_CAS_N,
    output logic        HPS_DDR3_CKE,
    output logic        HPS_DDR3_CK_N,
    output logic        HPS_DDR3_CK_P,
    output logic        HPS_DDR3_CS_N,
    output logic [3:0]  HPS_DDR3_DM,
    inout  wire  [31:0] HPS_DDR3_DQ,
    inout  wire  [3:0]  HPS_DDR3_DQS_N,
    inout  wire  [3:0]  HPS_DDR3_DQS_P,
    output logic        HPS_DDR3_ODT,
    output logic        HPS_DDR3_RAS_N,
    output logic        HPS_DDR3_RESET_N,
    input  logic        HPS_DDR3_RZQ,
    output logic        HPS_DDR3_WE_N,

    inout  wire         HPS_CONV_USB_N,
    output logic        HPS_ENET_GTX_CLK,
    inout  wire         HPS_ENET_INT_N,
    output logic        HPS_ENET_MDC,
    inout  wire         HPS_ENET_MDIO,
    input  logic        HPS_ENET_RX_CLK,
    input  logic [3:0]  HPS_ENET_RX_DATA,
    input  logic        HPS_ENET_RX_DV,
    output logic [3:0]  HPS_ENET_TX_DATA,
    output logic        HPS_ENET_TX_EN,
    inout  wire  [3:0]  HPS_FLASH_DATA,
    output logic        HPS_FLASH_DCLK,
    output logic        HPS_FLASH_NCSO,
    inout  wire         HPS_GSENSOR_INT,
    inout  wire         HPS_I2C1_SCLK,
    inout  wire         HPS_I2C1_SDAT,
    inout  wire         HPS_I2C2_SCLK,
    inout  wire         HPS_I2C2_SDAT,
    inout  wire         HPS_I2C_CONTROL,
    inout  wire         HPS_KEY,
    inout  wire         HPS_LED,
    inout  wire         HPS_LTC_GPIO,
    output logic        HPS_SD_CLK,
    inout  wire         HPS_SD_CMD,
    inout  wire  [3:0]  HPS_SD_DATA,
    output logic        HPS_SPIM_CLK,
    input  logic        HPS_SPIM_MISO,
    output logic        HPS_SPIM_MOSI,
    inout  wire         HPS_SPIM_SS,
    input  logic        HPS_UART_RX,
    output logic        HPS_UART_TX,
    input  logic        HPS_USB_CLKOUT,
    inout  wire  [7:0]  HPS_USB_DATA,
    input  logic        HPS_USB_DIR,
    input  logic        HPS_USB_NXT,
    output logic        HPS_USB_STP
);
    logic clk_100, pll_locked, hps_fpga_reset_n;

    logic [11:0] csr_address;
    logic        csr_read, csr_write, csr_waitrequest, csr_readdatavalid;
    logic [31:0] csr_writedata, csr_readdata;

    logic [28:0] sdram_address;
    logic [7:0]  sdram_burstcount, sdram_byteenable;
    logic        sdram_read, sdram_write, sdram_waitrequest, sdram_readdatavalid;
    logic [63:0] sdram_writedata, sdram_readdata;

    soc u0 (
        .clk_clk               (CLOCK_50),
        .reset_reset_n         (hps_fpga_reset_n),
        .clk_100_clk           (clk_100),
        .pll_locked_export     (pll_locked),
        .hps_reset_reset_n     (hps_fpga_reset_n),

        .csr_address           (csr_address),
        .csr_read              (csr_read),
        .csr_write             (csr_write),
        .csr_writedata         (csr_writedata),
        .csr_byteenable        (),
        .csr_burstcount        (),
        .csr_debugaccess       (),
        .csr_readdata          (csr_readdata),
        .csr_readdatavalid     (csr_readdatavalid),
        .csr_waitrequest       (csr_waitrequest),

        .sdram_address         (sdram_address),
        .sdram_burstcount      (sdram_burstcount),
        .sdram_read            (sdram_read),
        .sdram_write           (sdram_write),
        .sdram_writedata       (sdram_writedata),
        .sdram_byteenable      (sdram_byteenable),
        .sdram_readdata        (sdram_readdata),
        .sdram_readdatavalid   (sdram_readdatavalid),
        .sdram_waitrequest     (sdram_waitrequest),

        .memory_mem_a          (HPS_DDR3_ADDR),
        .memory_mem_ba         (HPS_DDR3_BA),
        .memory_mem_ck         (HPS_DDR3_CK_P),
        .memory_mem_ck_n       (HPS_DDR3_CK_N),
        .memory_mem_cke        (HPS_DDR3_CKE),
        .memory_mem_cs_n       (HPS_DDR3_CS_N),
        .memory_mem_ras_n      (HPS_DDR3_RAS_N),
        .memory_mem_cas_n      (HPS_DDR3_CAS_N),
        .memory_mem_we_n       (HPS_DDR3_WE_N),
        .memory_mem_reset_n    (HPS_DDR3_RESET_N),
        .memory_mem_dq         (HPS_DDR3_DQ),
        .memory_mem_dqs        (HPS_DDR3_DQS_P),
        .memory_mem_dqs_n      (HPS_DDR3_DQS_N),
        .memory_mem_odt        (HPS_DDR3_ODT),
        .memory_mem_dm         (HPS_DDR3_DM),
        .memory_oct_rzqin      (HPS_DDR3_RZQ),

        .hps_io_hps_io_emac1_inst_TX_CLK (HPS_ENET_GTX_CLK),
        .hps_io_hps_io_emac1_inst_TXD0   (HPS_ENET_TX_DATA[0]),
        .hps_io_hps_io_emac1_inst_TXD1   (HPS_ENET_TX_DATA[1]),
        .hps_io_hps_io_emac1_inst_TXD2   (HPS_ENET_TX_DATA[2]),
        .hps_io_hps_io_emac1_inst_TXD3   (HPS_ENET_TX_DATA[3]),
        .hps_io_hps_io_emac1_inst_RXD0   (HPS_ENET_RX_DATA[0]),
        .hps_io_hps_io_emac1_inst_MDIO   (HPS_ENET_MDIO),
        .hps_io_hps_io_emac1_inst_MDC    (HPS_ENET_MDC),
        .hps_io_hps_io_emac1_inst_RX_CTL (HPS_ENET_RX_DV),
        .hps_io_hps_io_emac1_inst_TX_CTL (HPS_ENET_TX_EN),
        .hps_io_hps_io_emac1_inst_RX_CLK (HPS_ENET_RX_CLK),
        .hps_io_hps_io_emac1_inst_RXD1   (HPS_ENET_RX_DATA[1]),
        .hps_io_hps_io_emac1_inst_RXD2   (HPS_ENET_RX_DATA[2]),
        .hps_io_hps_io_emac1_inst_RXD3   (HPS_ENET_RX_DATA[3]),
        .hps_io_hps_io_qspi_inst_IO0     (HPS_FLASH_DATA[0]),
        .hps_io_hps_io_qspi_inst_IO1     (HPS_FLASH_DATA[1]),
        .hps_io_hps_io_qspi_inst_IO2     (HPS_FLASH_DATA[2]),
        .hps_io_hps_io_qspi_inst_IO3     (HPS_FLASH_DATA[3]),
        .hps_io_hps_io_qspi_inst_SS0     (HPS_FLASH_NCSO),
        .hps_io_hps_io_qspi_inst_CLK     (HPS_FLASH_DCLK),
        .hps_io_hps_io_sdio_inst_CMD     (HPS_SD_CMD),
        .hps_io_hps_io_sdio_inst_D0      (HPS_SD_DATA[0]),
        .hps_io_hps_io_sdio_inst_D1      (HPS_SD_DATA[1]),
        .hps_io_hps_io_sdio_inst_CLK     (HPS_SD_CLK),
        .hps_io_hps_io_sdio_inst_D2      (HPS_SD_DATA[2]),
        .hps_io_hps_io_sdio_inst_D3      (HPS_SD_DATA[3]),
        .hps_io_hps_io_usb1_inst_D0      (HPS_USB_DATA[0]),
        .hps_io_hps_io_usb1_inst_D1      (HPS_USB_DATA[1]),
        .hps_io_hps_io_usb1_inst_D2      (HPS_USB_DATA[2]),
        .hps_io_hps_io_usb1_inst_D3      (HPS_USB_DATA[3]),
        .hps_io_hps_io_usb1_inst_D4      (HPS_USB_DATA[4]),
        .hps_io_hps_io_usb1_inst_D5      (HPS_USB_DATA[5]),
        .hps_io_hps_io_usb1_inst_D6      (HPS_USB_DATA[6]),
        .hps_io_hps_io_usb1_inst_D7      (HPS_USB_DATA[7]),
        .hps_io_hps_io_usb1_inst_CLK     (HPS_USB_CLKOUT),
        .hps_io_hps_io_usb1_inst_STP     (HPS_USB_STP),
        .hps_io_hps_io_usb1_inst_DIR     (HPS_USB_DIR),
        .hps_io_hps_io_usb1_inst_NXT     (HPS_USB_NXT),
        .hps_io_hps_io_spim1_inst_CLK    (HPS_SPIM_CLK),
        .hps_io_hps_io_spim1_inst_MOSI   (HPS_SPIM_MOSI),
        .hps_io_hps_io_spim1_inst_MISO   (HPS_SPIM_MISO),
        .hps_io_hps_io_spim1_inst_SS0    (HPS_SPIM_SS),
        .hps_io_hps_io_uart0_inst_RX     (HPS_UART_RX),
        .hps_io_hps_io_uart0_inst_TX     (HPS_UART_TX),
        .hps_io_hps_io_i2c0_inst_SDA     (HPS_I2C1_SDAT),
        .hps_io_hps_io_i2c0_inst_SCL     (HPS_I2C1_SCLK),
        .hps_io_hps_io_i2c1_inst_SDA     (HPS_I2C2_SDAT),
        .hps_io_hps_io_i2c1_inst_SCL     (HPS_I2C2_SCLK),
        .hps_io_hps_io_gpio_inst_GPIO09  (HPS_CONV_USB_N),
        .hps_io_hps_io_gpio_inst_GPIO35  (HPS_ENET_INT_N),
        .hps_io_hps_io_gpio_inst_GPIO40  (HPS_LTC_GPIO),
        .hps_io_hps_io_gpio_inst_GPIO48  (HPS_I2C_CONTROL),
        .hps_io_hps_io_gpio_inst_GPIO53  (HPS_LED),
        .hps_io_hps_io_gpio_inst_GPIO54  (HPS_KEY),
        .hps_io_hps_io_gpio_inst_GPIO61  (HPS_GSENSOR_INT)
    );

    // Reset: asserted asynchronously, released synchronously to clk_100.
    wire rst_async_n = hps_fpga_reset_n & pll_locked;
    logic [2:0] rst_sync;
    always_ff @(posedge clk_100 or negedge rst_async_n)
        if (!rst_async_n) rst_sync <= '0;
        else              rst_sync <= {rst_sync[1:0], 1'b1};
    wire rst = ~rst_sync[2];

    logic core_irq;

    generate
        if (USE_NNUE == 0) begin : g_probe
            assign core_irq = 1'b0;
            mem_probe #(.ADDR_W(29), .BURST_W(8)) probe (
                .clk               (clk_100),
                .rst               (rst),
                .csr_address       (csr_address),
                .csr_read          (csr_read),
                .csr_write         (csr_write),
                .csr_writedata     (csr_writedata),
                .csr_readdata      (csr_readdata),
                .csr_readdatavalid (csr_readdatavalid),
                .csr_waitrequest   (csr_waitrequest),
                .m_address         (sdram_address),
                .m_read            (sdram_read),
                .m_write           (sdram_write),
                .m_writedata       (sdram_writedata),
                .m_byteenable      (sdram_byteenable),
                .m_burstcount      (sdram_burstcount),
                .m_readdata        (sdram_readdata),
                .m_readdatavalid   (sdram_readdatavalid),
                .m_waitrequest     (sdram_waitrequest)
            );
        end else begin : g_nnue
            logic [31:0] m_address;
            logic [4:0]  m_burstcount;

            // The core returns read data one cycle after an accepted read (no waitrequest).
            always_ff @(posedge clk_100)
                if (rst) csr_readdatavalid <= 1'b0;
                else     csr_readdatavalid <= csr_read && !csr_waitrequest;

            nnue_core core (
                .clk             (clk_100),
                .rst             (rst),
                .csr_address     (csr_address[6:2]),  // 32-bit word offset; higher bytes alias
                .csr_read        (csr_read),
                .csr_write       (csr_write),
                .csr_writedata   (csr_writedata),
                .csr_readdata    (csr_readdata),
                .csr_waitrequest (csr_waitrequest),
                .m_address       (m_address),
                .m_read          (sdram_read),
                .m_burstcount    (m_burstcount),
                .m_waitrequest   (sdram_waitrequest),
                .m_readdata      (sdram_readdata),
                .m_readdatavalid (sdram_readdatavalid),
                .irq             (core_irq)
            );

            // Byte address to the port's 64-bit word address; the core only issues aligned reads.
            assign sdram_address    = m_address[31:3];
            assign sdram_burstcount = {3'd0, m_burstcount};
            assign sdram_write      = 1'b0;
            assign sdram_writedata  = '0;
            assign sdram_byteenable = '1;
        end
    endgenerate

    logic [26:0] blink;
    always_ff @(posedge clk_100)
        if (rst) blink <= '0;
        else     blink <= blink + 27'd1;

    assign LEDR = {blink[26], 7'd0, core_irq, pll_locked};
endmodule
