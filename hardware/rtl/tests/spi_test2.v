// spi_test2 — SPI readback test (100 MHz, no PLL)
// Fills buffer with 0x00000000, 0x00010001, 0x00020002, ...
`default_nettype none
module fft_top (
    input  clk_100mhz,
    input  spi_sck, input spi_mosi, output spi_miso, input spi_ce0,
    output led1, output led2, output led3
);
    wire clk = clk_100mhz;

    reg rst_n = 0;
    always @(posedge clk) rst_n <= 1;

    // Fill buffer with test pattern
    reg [31:0] cap_buf [0:63];
    reg [5:0]  idx;
    reg        done;
    always @(posedge clk) begin
        if (!done) begin
            cap_buf[idx] <= {16'd0, idx, 8'd0};  // {0, idx[5:0], 0x00}
            idx <= idx + 1;
            if (idx == 63) done <= 1;
        end
    end

    // SPI readback (same as spi_echo style)
    reg [2:0] sc; always @(posedge clk) sc <= {sc[1:0], spi_sck};
    wire sr = sc[2:1] == 2'b01;
    wire sf = sc[2:1] == 2'b10;

    reg ce0_d; always @(posedge clk) ce0_d <= spi_ce0;
    wire cf = ce0_d && !spi_ce0;  // falling edge

    reg [31:0] so;
    reg [5:0]  bc, rd_addr;
    reg        miso_reg;

    always @(posedge clk) begin
        if (cf) begin
            so      <= cap_buf[rd_addr];
            bc      <= 0;
            rd_addr <= rd_addr + 1;
            miso_reg <= cap_buf[rd_addr][31];  // MSB first
        end
        if (!spi_ce0) begin
            if (sr && bc < 31) begin
                so <= {so[30:0], 1'b0};
                bc <= bc + 1;
            end
            if (sf && bc < 31)
                miso_reg <= so[30];  // next bit after shift
        end
    end

    assign spi_miso = miso_reg;
    assign led1 = done;
    assign led2 = 0;
    assign led3 = 0;
endmodule
`default_nettype wire
