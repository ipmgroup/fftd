// spi_fft_bridge — SPI send data + read FFT results
`default_nettype none
module spi_fft_bridge(
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
    reg [2:0] sc; always @(posedge clk) sc <= {sc[1:0], spi_sck};
    wire sck_rise = sc[2:1]==2'b01;
    wire sck_fall = sc[2:1]==2'b10;

    reg [31:0] sr_in, sr_out;
    reg [5:0] bit_cnt;
    reg active;
    reg [5:0] samp_cnt;
    reg reading;   // in readback mode after FFT done
    reg [5:0] rd_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sr_in<=0; sr_out<=0; bit_cnt<=0; active<=0; spi_miso<=0;
            fft_start<=0; fft_din<=0; fft_din_valid<=0;
            samp_cnt<=0; reading<=0; rd_cnt<=0;
        end else begin
            fft_start <= 0;
            fft_din_valid <= 0;

            if (!spi_ce0) begin
                if (!active) begin
                    active <= 1; bit_cnt <= 0; sr_in <= 0;
                    // Prepare first MISO bit from readback buffer or status
                    if (reading) sr_out <= fft_dout;
                end else begin
                    if (sck_rise) begin
                        sr_in <= {sr_in[30:0], spi_mosi};
                        bit_cnt <= bit_cnt + 1;
                    end
                    // MISO: shift out on falling edge
                    if (sck_fall) begin
                        if (reading) spi_miso <= sr_out[31];
                        else spi_miso <= fft_busy;
                    end
                end
            end else if (active) begin
                active <= 0;
                if (bit_cnt == 32 && !reading) begin
                    fft_din <= sr_in;
                    fft_din_valid <= 1;
                    samp_cnt <= samp_cnt + 1;
                    if (samp_cnt == 63) begin
                        fft_start <= 1;
                        samp_cnt <= 0;
                    end
                end
            end

            // Enter readback mode on FFT done
            if (fft_done) begin
                reading <= 1;
                rd_cnt <= 0;
            end

            // During readback, Pi reads 64 samples via CE0
            // Each CE0 transaction: MISO outputs dout[0]..dout[31]
            // Pi needs to read 64 * 32 bits. On each CE0 assertion,
            // we shift out the current dout word.
            if (reading && fft_dout_valid) begin
                rd_cnt <= rd_cnt + 1;
                if (rd_cnt == 63) reading <= 0;
            end

            if (fft_done) samp_cnt <= 0;
        end
    end
endmodule
`default_nettype wire
