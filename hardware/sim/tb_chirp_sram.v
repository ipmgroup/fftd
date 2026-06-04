//=============================================================================
// tb_chirp_sram — full-path chirp co-simulation through fft_top
//
// Drives the complete SPI + SRAM-staged input datapath (the same path the
// iceZero hat exercises on the RPi):
//   1. read 1024 real samples from fft_input.hex  {0000, sample[15:0]}
//   2. stage them into the SRAM input region via WRITE_SRAM (0x43), in chunks
//   3. CONTROL START → input-DMA (SRAM→BRAM) → FFT → output-DMA (BRAM→SRAM)
//   4. poll STATUS until done, then BULK_READ (0x23) all 1024 bins
//   5. write the spectrum to fft_output.hex  {imag[15:0], real[15:0]}
//
// Used by chirp_sim_sram.py to compare the FPGA spectrum against numpy and
// emit chirp_fft_comparison.png.
//=============================================================================
`timescale 1ns / 1ps

module tb_chirp_sram;

    localparam N = 1024;

    // ── DUT signals ───────────────────────────────
    reg        clk;
    reg        spi_sck;
    reg        spi_mosi;
    wire       spi_miso;
    reg        spi_ce0;
    wire       drdy, led1, led2, led3;

    wire [18:0] sram_a;
    wire [15:0] sram_dq;
    wire        sram_ce_n, sram_oe_n, sram_we_n, sram_lb_n, sram_ub_n;

    fft_top dut (
        .clk_100mhz (clk),
        .spi_sck    (spi_sck),
        .spi_mosi   (spi_mosi),
        .spi_miso   (spi_miso),
        .spi_ce0    (spi_ce0),
        .drdy       (drdy),
        .led1       (led1),
        .led2       (led2),
        .led3       (led3),
        .sram_a     (sram_a),
        .sram_dq    (sram_dq),
        .sram_ce_n  (sram_ce_n),
        .sram_oe_n  (sram_oe_n),
        .sram_we_n  (sram_we_n),
        .sram_lb_n  (sram_lb_n),
        .sram_ub_n  (sram_ub_n)
    );

    sram_model u_sram (
        .a (sram_a), .dq (sram_dq), .ce_n (sram_ce_n), .oe_n (sram_oe_n),
        .we_n (sram_we_n), .lb_n (sram_lb_n), .ub_n (sram_ub_n)
    );

    always #5 clk = ~clk;   // 100 MHz

    // ── Storage ───────────────────────────────────
    reg [31:0] samples [0:N-1];
    reg [31:0] results [0:N-1];
    // Big enough for a 1024-bin BULK_READ (9 + 4096 = 4105 bytes).
    reg [7:0]  tx_buf [0:4399];
    reg [7:0]  rx_buf [0:4399];
    reg [7:0]  spi_rx_byte;

    // ── SPI master (Mode 0) ───────────────────────
    task spi_byte;
        input [7:0] tx;
        integer b; reg [7:0] rx;
        begin
            rx = 0;
            for (b = 0; b < 8; b = b + 1) begin
                spi_mosi = tx[7];
                tx = {tx[6:0], 1'b0};
                #62 spi_sck = 1;
                #1  rx = {rx[6:0], spi_miso};
                #61 spi_sck = 0;
                #62;
            end
            spi_rx_byte = rx;
        end
    endtask

    task spi_xfer;
        input integer nbytes;
        integer i;
        begin
            spi_ce0 = 0;
            #200;
            for (i = 0; i < nbytes; i = i + 1) begin
                spi_byte(tx_buf[i]);
                rx_buf[i] = spi_rx_byte;
            end
            #200;
            spi_ce0 = 1;
            #200;
        end
    endtask

    function [7:0] xsum;
        input [7:0] a, b, c;
        xsum = a ^ b ^ c;
    endfunction

    integer ci, s, nsamp, total, i, b, timeout, fd;
    reg [7:0] seqn;
    reg [15:0] re, im, smp;
    reg ok;

    initial begin
        $readmemh("fft_input.hex", samples);

        clk = 0; spi_sck = 0; spi_mosi = 0; spi_ce0 = 1;
        #5000;   // reset settle

        // ── 1) Stage chirp into SRAM via WRITE_SRAM (0x43), 120-sample chunks
        seqn = 8'd20;
        for (ci = 0; ci < N; ci = ci + 120) begin
            nsamp = (N - ci > 120) ? 120 : (N - ci);
            tx_buf[0] = 8'h43;
            tx_buf[1] = nsamp * 2;
            tx_buf[2] = seqn;
            tx_buf[3] = xsum(8'h43, nsamp * 2, seqn);
            for (s = 0; s < nsamp; s = s + 1) begin
                smp = samples[ci + s][15:0];
                tx_buf[4 + s*2]     = smp[15:8];   // hi byte first
                tx_buf[4 + s*2 + 1] = smp[7:0];
            end
            tx_buf[4 + nsamp*2] = 8'h00;            // gap
            for (i = 0; i < 4; i = i + 1)
                tx_buf[4 + nsamp*2 + 1 + i] = 8'h00;
            total = 4 + nsamp*2 + 1 + 4;
            spi_xfer(total);
            seqn = seqn + 1;
        end
        $display("staged %0d samples (sram_in=%b)", N, dut.sram_in);

        // ── 2) CONTROL START
        tx_buf[0] = 8'h50; tx_buf[1] = 8'd1; tx_buf[2] = seqn;
        tx_buf[3] = xsum(8'h50, 8'd1, seqn);
        tx_buf[4] = 8'h01;                          // CTRL_START
        for (i = 5; i < 10; i = i + 1) tx_buf[i] = 8'h00;
        spi_xfer(10);
        seqn = seqn + 1;

        // ── 3) Poll STATUS until done
        ok = 0; timeout = 0;
        while (timeout < 12000 && !ok) begin
            tx_buf[0] = 8'h60; tx_buf[1] = 8'd0; tx_buf[2] = seqn;
            tx_buf[3] = xsum(8'h60, 8'd0, seqn);
            for (i = 4; i < 10; i = i + 1) tx_buf[i] = 8'h00;
            spi_xfer(10);
            if (rx_buf[9][5]) ok = 1;               // done bit
            timeout = timeout + 1;
            #2000;
        end
        seqn = seqn + 1;
        if (!ok) begin
            $display("ERROR: FFT (SRAM input) timeout");
            $finish;
        end
        $display("FFT done, bfp_exp=%0d", dut.sram_exp);

        // ── 4) BULK_READ all N bins in one transaction
        total = 9 + N*4;
        tx_buf[0] = 8'h23; tx_buf[1] = 8'd0; tx_buf[2] = seqn;
        tx_buf[3] = xsum(8'h23, 8'd0, seqn);
        for (i = 4; i < total; i = i + 1) tx_buf[i] = 8'h00;
        spi_xfer(total);

        for (b = 0; b < N; b = b + 1) begin
            re = {rx_buf[9 + b*4 + 0], rx_buf[9 + b*4 + 1]};
            im = {rx_buf[9 + b*4 + 2], rx_buf[9 + b*4 + 3]};
            results[b] = {im, re};                  // {imag[15:0], real[15:0]}
        end

        // ── 5) Dump spectrum + exponent
        fd = $fopen("fft_output.hex", "w");
        if (fd == 0) begin $display("ERROR: cannot open fft_output.hex"); $finish; end
        for (b = 0; b < N; b = b + 1)
            $fwrite(fd, "%08x\n", results[b]);
        $fclose(fd);

        fd = $fopen("fft_exp.txt", "w");
        $fwrite(fd, "%0d\n", dut.sram_exp);
        $fclose(fd);

        $display("OK: fft_output.hex written (%0d bins), bfp_exp=%0d", N, dut.sram_exp);
        $finish;
    end

    // Watchdog
    initial begin
        #80000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

//=============================================================================
// sram_model — behavioural async SRAM (AS6C4008 512K×16)
//=============================================================================
module sram_model (
    input  wire [18:0] a,
    inout  wire [15:0] dq,
    input  wire        ce_n, oe_n, we_n, lb_n, ub_n
);
    reg [15:0] mem [0:524287];
    assign dq = (!ce_n && !oe_n && we_n) ? mem[a] : 16'hzzzz;
    always @(posedge we_n or posedge ce_n) begin
        if (!ce_n) begin
            if (!lb_n) mem[a][7:0]  <= dq[7:0];
            if (!ub_n) mem[a][15:8] <= dq[15:8];
        end
    end
endmodule
