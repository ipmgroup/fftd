// spi_test3 — SPI readback test (100 MHz, no PLL, simple)
// Fills buffer: buf[i] = {i[5:0], 2'd0, i[5:0], 2'd0, i[5:0], 2'd0, i[5:0], 2'd0}
//              = 0x00ii00ii (repeated i in each byte)
`default_nettype none
module fft_top (
    input  clk_100mhz,
    input  spi_sck, input spi_mosi, output spi_miso, input spi_ce0,
    output led1, output led2, output led3
);
    wire clk = clk_100mhz;

    reg rst_n = 0;
    always @(posedge clk) rst_n <= 1;

    // ── Fill buffer with test pattern ────────────
    reg [31:0] tbuf [0:63];
    reg [5:0]  ii;
    reg        fill_done;
    always @(posedge clk) begin
        if (!rst_n) begin
            ii <= 0;
            fill_done <= 0;
        end else if (!fill_done) begin
            tbuf[ii] <= {27'd0, ii + 1'b1};  // values 1..64
            ii <= ii + 1;
            if (ii == 63) fill_done <= 1;
        end
    end

    // ── SPI edge detection ───────────────────────
    reg [2:0] sc; always @(posedge clk) sc <= {sc[1:0], spi_sck};
    wire sf = sc[2:1] == 2'b10;  // SCK falling edge

    reg [1:0] cd; always @(posedge clk) cd <= {cd[0], spi_ce0};
    wire cf = cd == 2'b10;  // CE0 falling edge

    // ── Shift register ───────────────────────────
    reg [31:0] so;
    reg [5:0]  bc, rd;

    always @(posedge clk) begin
        if (!rst_n) begin
            so <= 0;
            bc <= 0;
            rd <= 0;
        end else begin
            if (cf) begin
                so <= tbuf[rd];  // direct BRAM read
                bc <= 0;
                rd <= rd + 1;
            end else if (sf && !spi_ce0 && bc < 32) begin
                so <= {so[30:0], 1'b0};
                bc <= bc + 1;
            end
        end
    end

    assign spi_miso = so[31];
    assign led1 = fill_done;   // ON when buffer filled
    assign led2 = cf;          // blink on CE0 activity
    assign led3 = 0;

endmodule
`default_nettype wire
