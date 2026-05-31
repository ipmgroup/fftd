// pll_blink — verify PLL works: LED blinks at ~3 Hz using 50 MHz PLL clock
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
    ) pll (
        .PACKAGEPIN(clk_100mhz), .PLLOUTCORE(), .PLLOUTGLOBAL(clk),
        .RESETB(1'b1), .BYPASS(1'b0)
    );

    reg [25:0] cnt = 0;
    always @(posedge clk) cnt <= cnt + 1;

    assign led1 = cnt[24];  // 50M / 2^25 ≈ 1.5 Hz
    assign led2 = cnt[23];  // 3 Hz
    assign led3 = cnt[22];  // 6 Hz
    assign spi_miso = 0;
endmodule
`default_nettype wire
