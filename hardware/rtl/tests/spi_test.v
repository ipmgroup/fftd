// fft_top — SPI readback test (no FFT, test pattern only)
// Fills capture buffer with known ramp: buf[i] = {i, i<<8}
// SPI reads should return 0x00000000, 0x00010001, 0x00020002, ...
`default_nettype none

module fft_top (
    input  clk_100mhz,
    input  spi_sck, input spi_mosi, output spi_miso, input spi_ce0,
    output led1, output led2, output led3
);

    wire clk;
    SB_PLL40_PAD #(
        .FEEDBACK_PATH("SIMPLE"),
        .DIVR(4'b0000), .DIVF(7'b0000111), .DIVQ(3'b100),
        .FILTER_RANGE(3'b001)
    ) pll_inst (
        .PACKAGEPIN(clk_100mhz),
        .PLLOUTCORE(), .PLLOUTGLOBAL(clk),
        .RESETB(1'b1), .BYPASS(1'b0)
    );

    reg [7:0] rst_cnt = 0;
    reg rst_n = 0;
    always @(posedge clk) begin
        if (rst_cnt != -1) rst_cnt <= rst_cnt + 1;
        rst_n <= (rst_cnt == -1);
    end

    // ── Test pattern buffer ──────────────────────
    reg [31:0] cap_buf [0:63];
    reg [5:0]  init_idx;
    reg        init_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_idx  <= 0;
            init_done <= 0;
        end else if (!init_done) begin
            cap_buf[init_idx] <= {init_idx, 8'd0, init_idx, 8'd0};  // {idx, 0, idx, 0}
            init_idx <= init_idx + 1;
            if (init_idx == 63) init_done <= 1;
        end
    end

    // ── SPI readback ─────────────────────────────
    reg [2:0] ce0_sync, sck_sync;
    always @(posedge clk) begin
        ce0_sync <= {ce0_sync[1:0], spi_ce0};
        sck_sync <= {sck_sync[1:0], spi_sck};
    end
    wire ce0_fall = ce0_sync[2:1] == 2'b10;
    wire sck_fall = sck_sync[2:1] == 2'b10;

    reg [31:0] so;
    reg [5:0]  bc, rd_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            so <= 0; bc <= 0; rd_addr <= 0;
        end else begin
            if (ce0_fall) begin
                so      <= cap_buf[rd_addr];
                bc      <= 0;
                rd_addr <= rd_addr + 1;
            end else if (sck_fall && bc < 32) begin
                so <= {so[30:0], 1'b0};
                bc <= bc + 1;
            end
        end
    end

    assign spi_miso = so[31];
    assign led1 = init_done;
    assign led2 = 0;
    assign led3 = 1;

endmodule
`default_nettype wire
