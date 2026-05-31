// spibridge — SPI I/O buffer for FFT (64 complex samples)
// CE0: 32-bit word = {imag[15:0], real[15:0]}
// Protocol: write 64 words → FFT auto-starts → read 64 words
`default_nettype none
module spibridge(
    input clk, input rst_n,
    input sck, input mosi, output reg miso, input ce0,
    output reg [31:0] fft_din, output reg fft_din_valid, output reg fft_start,
    input [31:0] fft_dout, input fft_dout_valid,
    input fft_busy, input fft_done
);
    // SCK edges
    reg [2:0] sf; always @(posedge clk) sf <= {sf[1:0], sck};
    wire s_rise = sf[2:1]==2'b01;
    wire s_fall = sf[2:1]==2'b10;

    reg [31:0] sreg;        // shift register
    reg [5:0]  sbit;        // bit counter 0..31
    reg        active;       // CE0 asserted
    reg [5:0]  wcnt;        // write count 0..63
    reg [5:0]  rcnt;        // read count 0..63
    reg        rmode;        // 0=write phase, 1=read phase
    reg        fft_triggered;

    // Input buffer: 64 complex samples from SPI
    reg [31:0] ibuf [0:63];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sreg<=0; sbit<=0; active<=0; miso<=0;
            fft_din<=0; fft_din_valid<=0; fft_start<=0;
            wcnt<=0; rcnt<=0; rmode<=0; fft_triggered<=0;
        end else begin
            fft_din_valid <= 0;
            fft_start <= 0;

            if (!ce0) begin
                if (!active) begin
                    active <= 1; sbit <= 0; sreg <= 0;
                end else if (s_rise) begin
                    sreg <= {sreg[30:0], mosi};
                    sbit <= sbit + 1;
                end
                // MISO: output on falling edge
                if (s_fall) begin
                    if (rmode && fft_dout_valid) begin
                        // Shift out FFT output, MSB first
                        miso <= fft_dout[31];
                    end else begin
                        miso <= fft_busy;  // status bit
                    end
                end
            end else if (active) begin
                active <= 0;
                if (sbit == 32 && !rmode && wcnt < 64) begin
                    ibuf[wcnt] <= sreg;
                    wcnt <= wcnt + 1;
                    if (wcnt == 63) begin
                        // All 64 samples received — start FFT
                        fft_start <= 1;
                        fft_triggered <= 1;
                    end
                end
            end

            // Feed buffer to FFT during load phase
            if (fft_triggered && wcnt == 64) begin
                // FFT is in load phase — feed data from buffer
                // Use a counter to walk through buffer
            end

            // After FFT done, enter read mode
            if (fft_done) begin
                rmode <= 1;
                rcnt <= 0;
                fft_triggered <= 0;
            end

            // Reset for next frame
            if (rmode && rcnt == 64) begin
                rmode <= 0;
                wcnt  <= 0;
            end
        end
    end

    // Feed data from buffer to FFT during load
    reg [5:0] feed_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            feed_cnt <= 0;
        end else if (fft_triggered) begin
            fft_din <= ibuf[feed_cnt];
            fft_din_valid <= 1;
            feed_cnt <= feed_cnt + 1;
            if (feed_cnt == 63) fft_triggered <= 0;
        end
    end

endmodule
`default_nettype wire
