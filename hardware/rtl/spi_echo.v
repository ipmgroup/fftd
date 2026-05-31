// spi_echo — minimal SPI loopback: MISO echoes MOSI with 1-byte delay
`default_nettype none
module spi_echo(
    input clk_100mhz,
    input spi_sck, input spi_mosi, output spi_miso,
    input spi_ce0,
    output led1, output led2, output led3
);
    wire clk = clk_100mhz;
    reg rst_n=0; always @(posedge clk) rst_n<=1;

    reg [2:0] sc; always @(posedge clk) sc<={sc[1:0],spi_sck};
    wire sr=sc[2:1]==2'b01; wire sf=sc[2:1]==2'b10;

    reg ce0_d; always @(posedge clk) ce0_d<=spi_ce0;
    wire cf=ce0_d&&!spi_ce0;

    reg [7:0] byte_in, byte_out;
    reg [3:0] bc;
    reg miso;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_in<=0; byte_out<=0; bc<=0; miso<=0;
        end else begin
            if (cf) begin bc<=0; byte_in<=0; miso<=byte_out[7]; end
            if (!spi_ce0) begin
                if (sr) begin byte_in<={byte_in[6:0],spi_mosi}; bc<=bc+1; end
                if (sf && bc<7) miso<=byte_out[6-bc];
            end
            // Latch output byte at end of transaction
            if (!spi_ce0 && bc==8) byte_out <= byte_in;
        end
    end

    assign spi_miso = miso;

    reg [25:0] hb; always @(posedge clk) hb<=hb+1;
    assign led1 = hb[23];  // ~6 Hz heartbeat
    assign led2 = hb[24];
    assign led3 = hb[25];
endmodule
`default_nettype wire
