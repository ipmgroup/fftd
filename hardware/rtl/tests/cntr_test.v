// cntr_test — output incrementing counter on each SPI read (no BRAM)
`default_nettype none
module fft_top (
    input  clk_100mhz,
    input  spi_sck, input spi_mosi, output spi_miso, input spi_ce0,
    output led1, output led2, output led3
);
    wire clk = clk_100mhz;

    reg [2:0] sc; always @(posedge clk) sc <= {sc[1:0], spi_sck};
    wire sf = sc[2:1] == 2'b10;

    reg [1:0] cd; always @(posedge clk) cd <= {cd[0], spi_ce0};
    wire cf = cd == 2'b10;

    reg [31:0] cnt = 0;  // increments on each CE0 transaction
    reg [31:0] so;
    reg [5:0]  bc;

    always @(posedge clk) begin
        if (cf) begin
            so <= cnt;
            cnt <= cnt + 1;
            bc <= 0;
        end else if (sf && !spi_ce0 && bc < 32) begin
            so <= {so[30:0], 1'b0};
            bc <= bc + 1;
        end
    end

    assign spi_miso = so[31];
    assign led1 = cnt[0];
    assign led2 = cnt[1];
    assign led3 = cnt[2];
endmodule
`default_nettype wire
