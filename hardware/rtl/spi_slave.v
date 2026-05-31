// spi_slave — Write 64 samples via SPI, read 64 results back
`default_nettype none
module spi_slave(
    input clk, input rst_n,
    input spi_sck, input spi_mosi, output reg spi_miso,
    input spi_ce0,
    output reg fft_start,
    output reg [31:0] fft_din,
    output reg fft_din_valid,
    input [31:0] fft_dout,
    input fft_dout_valid,
    input fft_busy, input fft_done
);
    reg [2:0] sc; always @(posedge clk) sc<={sc[1:0],spi_sck};
    wire sr = sc[2:1]==2'b01; wire sf = sc[2:1]==2'b10;
    reg ce0_d; always @(posedge clk) ce0_d<=spi_ce0;
    wire cf = ce0_d&&!spi_ce0; wire cr = !ce0_d&&spi_ce0;

    reg [31:0] si, so;
    reg [5:0] bc;
    reg [6:0] total;  // total CE0 transactions seen (0..127, wraps)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            si<=0; so<=0; bc<=0; spi_miso<=0;
            fft_start<=0; fft_din<=0; fft_din_valid<=0; total<=0;
        end else begin
            fft_start<=0; fft_din_valid<=0;

            if (cf) begin
                bc<=0; si<=0;
                so <= (total>=64 && total<128) ? fft_dout :
                      {16'd0, 3'b000, fft_done, fft_busy, 11'd0};
                spi_miso <= so[31];
            end

            if (!spi_ce0) begin
                if (sr) begin si<={si[30:0],spi_mosi}; bc<=bc+1; end
                if (sf) spi_miso <= so[31 - bc];
            end

            if (cr && bc==32) begin
                total <= total + 1;
                if (total < 64) begin
                    fft_din <= si;
                    fft_din_valid <= 1;
                    if (total == 63) begin
                        fft_start <= 1;
                    end
                end
            end

            if (fft_done) total <= 64;  // reset to read phase
        end
    end
endmodule
`default_nettype wire
