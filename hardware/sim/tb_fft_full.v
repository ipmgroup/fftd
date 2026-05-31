//=============================================================================
// tb_fft_full — Full FFT chain test via SPI protocol (iverilog)
//
// Tests: STATUS_REQ → CONTROL START → poll DRDY → READ_RESULT
// Verifies: non-zero output, conjugate symmetry (real input)
//
// Run:
//   iverilog -g2012 -o build/tb_fft_full.vvp -I../rtl \
//     tb_fft_full.v ../rtl/fft_core.v ../rtl/fft_top.v \
//     ../rtl/twiddle_rom.v ../rtl/spi_slave_proto.v ../rtl/sram_ctrl.v
//   vvp build/tb_fft_full.vvp
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_fft_full;

    // ── DUT ───────────────────────────────────────
    reg        clk;
    reg        spi_sck;
    reg        spi_mosi;
    wire       spi_miso;
    reg        spi_ce0;
    wire       drdy;
    wire       led1, led2, led3;
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

    // ── 100 MHz clock ─────────────────────────────
    initial clk = 0;
    always #5 clk = ~clk;

    // ── Test statistics ───────────────────────────
    integer   test_n, test_pass, test_fail;
    integer   cyc;

    // ── SPI buffers ───────────────────────────────
    reg [7:0] tx_buf [0:511];
    reg [7:0] rx_buf [0:511];
    reg [7:0] spi_rx_byte;

    // ── SPI byte transfer (Mode 0, FPGA samples on SCK rise) ──
    // SCK period = 250 ns (4 MHz) — slow enough for sim, fast enough for DRDY
    task spi_byte;
        input [7:0] tx;
        integer b;
        reg [7:0] rx;
        begin
            rx = 0;
            for (b = 0; b < 8; b = b + 1) begin
                spi_mosi = tx[7];
                tx = {tx[6:0], 1'b0};
                #125 spi_sck = 1;
                #1   rx = {rx[6:0], spi_miso};
                #124 spi_sck = 0;
            end
            spi_rx_byte = rx;
        end
    endtask

    // ── SPI transaction: assert CS, send N bytes, capture response ──
    task spi_xfer;
        input integer nbytes;
        integer i;
        begin
            spi_ce0 = 0;
            #200;  // CS setup
            for (i = 0; i < nbytes; i = i + 1) begin
                spi_byte(tx_buf[i]);
                rx_buf[i] = spi_rx_byte;
            end
            #200;  // CS hold
            spi_ce0 = 1;
            #500;  // inter-frame gap
        end
    endtask

    // ── Build STATUS_REQ frame ────────────────────
    task build_status_req;
        input [7:0] seq;
        begin
            tx_buf[0] = 8'h60;
            tx_buf[1] = 8'h00;
            tx_buf[2] = seq;
            tx_buf[3] = 8'h60 ^ 8'h00 ^ seq;
        end
    endtask

    // ── Build CONTROL START frame ─────────────────
    task build_ctrl_start;
        input [7:0] seq;
        begin
            tx_buf[0] = 8'h50;
            tx_buf[1] = 8'h01;     // 1 data byte
            tx_buf[2] = seq;
            tx_buf[3] = 8'h50 ^ 8'h01 ^ seq;
            tx_buf[4] = 8'h01;     // START code
        end
    endtask

    // ── Build READ_RESULT frame ───────────────────
    task build_read_result;
        input [7:0] seq;
        input [7:0] nbins;
        begin
            tx_buf[0] = 8'h21;
            tx_buf[1] = 8'h01;     // 1 data byte (NUM_BINS)
            tx_buf[2] = seq;
            tx_buf[3] = 8'h21 ^ 8'h01 ^ seq;
            tx_buf[4] = nbins;     // NUM_BINS
        end
    endtask

    // ── Verify response checksum ──────────────────
    function verify_resp;
        input [7:0] rcmd;
        input [7:0] rlen;
        input [7:0] rseq;
        input [7:0] rxsum;
        begin
            verify_resp = (rxsum == (rcmd ^ rlen ^ rseq));
        end
    endfunction

    // ── Find response in rx_buf (may have offset due to pipeline) ──
    function integer find_resp;
        input integer start;
        input integer end_idx;
        integer i;
        begin
            find_resp = -1;
            for (i = start; i <= end_idx; i = i + 1) begin
                if (rx_buf[i] == 8'h60 || rx_buf[i] == 8'h50 ||
                    rx_buf[i] == 8'h21 || rx_buf[i] == 8'h80) begin
                    find_resp = i;
                    i = end_idx + 1;  // break
                end
            end
        end
    endfunction

    // ── Check 16-bit value within tolerance ───────
    function check_val;
        input [31:0] actual;    // {im[15:0], re[15:0]}
        input [31:0] expected;
        input [31:0] tolerance;
        integer act_re, act_im, exp_re, exp_im;
        begin
            act_re = $signed(actual[15:0]);
            act_im = $signed(actual[31:16]);
            exp_re = $signed(expected[15:0]);
            exp_im = $signed(expected[31:16]);
            check_val = (act_re >= exp_re - tolerance) && (act_re <= exp_re + tolerance) &&
                        (act_im >= exp_im - tolerance) && (act_im <= exp_im + tolerance);
        end
    endfunction

    // ── FFT result array (read from FPGA) ─────────
    reg [31:0] fft_data [0:63];

    // ═══════════════════════════════════════════════
    // Main test
    // ═══════════════════════════════════════════════
    initial begin
        integer off, i, rlen, dlen;
        integer sym_ok;
        reg [7:0] rcmd, rseq, rxsum;
        reg [31:0] val;

        test_n    = 0;
        test_pass = 0;
        test_fail = 0;

        // ── Init ───────────────────────────────────
        clk      = 0;
        spi_sck  = 0;
        spi_mosi = 0;
        spi_ce0  = 1;
        cyc      = 0;

        // Wait for reset
        repeat (500) @(posedge clk);
        $display("\n╔══════════════════════════════════════════╗");
        $display("║  FFT Full-Chain Test (SPI Protocol)     ║");
        $display("╚══════════════════════════════════════════╝\n");

        // ── TEST 1: STATUS_REQ after reset ─────────
        test_n = test_n + 1;
        $display("TEST %0d: STATUS_REQ (should show ready=1, busy=0, drdy=0)", test_n);

        build_status_req(8'h01);
        // Send 4-byte header + 1 gap + 5 response bytes = 10 bytes
        for (i = 0; i < 10; i = i + 1) tx_buf[4 + i] = 8'h00;
        spi_xfer(14);  // 4 hdr + 1 gap + 5 resp = 10 → send 14 to be safe

        off = find_resp(4, 12);
        if (off >= 4 && off <= 8) begin
            rcmd  = rx_buf[off];
            rlen  = rx_buf[off+1];
            rseq  = rx_buf[off+2];
            rxsum = rx_buf[off+3];
            $display("  Response at off=%0d: CMD=%02x LEN=%02x SEQ=%02x XSUM=%02x",
                     off, rcmd, rlen, rseq, rxsum);
            if (verify_resp(rcmd, rlen, rseq, rxsum)) begin
                $display("  Checksum OK, STATUS=%02x", rx_buf[off+4]);
                // STATUS: bit7=ready, bit6=busy, bit5=drdy
                if (rx_buf[off+4][7] && !rx_buf[off+4][6] && !rx_buf[off+4][5]) begin
                    $display("  PASS — ready, not busy, not done\n");
                    test_pass = test_pass + 1;
                end else begin
                    $display("  FAIL — unexpected status bits\n");
                    test_fail = test_fail + 1;
                end
            end else begin
                $display("  FAIL — checksum mismatch\n");
                test_fail = test_fail + 1;
            end
        end else begin
            $display("  FAIL — no response found (off=%0d)\n", off);
            test_fail = test_fail + 1;
        end

        // ── TEST 2: CONTROL START ─────────────────
        test_n = test_n + 1;
        $display("TEST %0d: CONTROL START → FFT should start (busy=1, drdy→1)", test_n);

        build_ctrl_start(8'h02);
        for (i = 0; i < 6; i = i + 1) tx_buf[5 + i] = 8'h00;
        spi_xfer(11);  // 5 hdr+data + 1 gap + 5 resp

        off = find_resp(5, 9);
        if (off >= 5 && off <= 8) begin
            rcmd  = rx_buf[off];
            rlen  = rx_buf[off+1];
            rseq  = rx_buf[off+2];
            rxsum = rx_buf[off+3];
            if (verify_resp(rcmd, rlen, rseq, rxsum) && rcmd == 8'h50 && rlen == 0) begin
                $display("  ACK received — PASS\n");
                test_pass = test_pass + 1;
            end else begin
                $display("  FAIL — bad ACK: CMD=%02x LEN=%02x\n", rcmd, rlen);
                test_fail = test_fail + 1;
            end
        end else begin
            $display("  FAIL — no response\n");
            test_fail = test_fail + 1;
        end

        // ── TEST 3: Wait for DRDY ─────────────────
        test_n = test_n + 1;
        $display("TEST %0d: Poll STATUS until DRDY (max 5000 cycles)", test_n);
        repeat (2000) @(posedge clk);  // let FFT run (~31 µs at 50 MHz = ~1550 cycles)

        // Poll STATUS with gap
        build_status_req(8'h03);
        for (i = 0; i < 10; i = i + 1) tx_buf[4 + i] = 8'h00;
        spi_xfer(14);

        off = find_resp(4, 12);
        if (off >= 4 && off <= 8 && verify_resp(rx_buf[off], rx_buf[off+1], rx_buf[off+2], rx_buf[off+3])) begin
            $display("  STATUS=%02x (ready=%b busy=%b drdy=%b)",
                     rx_buf[off+4], rx_buf[off+4][7], rx_buf[off+4][6], rx_buf[off+4][5]);
            if (rx_buf[off+4][5]) begin
                $display("  DRDY asserted — PASS\n");
                test_pass = test_pass + 1;
            end else begin
                // Poll again
                repeat (2000) @(posedge clk);
                build_status_req(8'h04);
                for (i = 0; i < 10; i = i + 1) tx_buf[4 + i] = 8'h00;
                spi_xfer(14);
                off = find_resp(4, 12);
                if (off >= 4 && rx_buf[off+4][5]) begin
                    $display("  DRDY asserted on retry — PASS\n");
                    test_pass = test_pass + 1;
                end else begin
                    $display("  FAIL — DRDY never asserted, STATUS=%02x\n",
                             off >= 4 ? rx_buf[off+4] : 0);
                    test_fail = test_fail + 1;
                end
            end
        end else begin
            $display("  FAIL — bad response\n");
            test_fail = test_fail + 1;
        end

        // ── TEST 4: READ_RESULT 64 bins ────────────
        test_n = test_n + 1;
        $display("TEST %0d: READ_RESULT 64 bins", test_n);

        build_read_result(8'h05, 8'd64);  // request 64 bins
        // Response: 4 hdr + 128 data bytes (64 bins × 2 bytes = re[15:0])
        // Total SPI bytes: 5 req + 1 gap + 4+128 resp = 138 → 140 to be safe
        for (i = 0; i < 135; i = i + 1) tx_buf[5 + i] = 8'h00;
        spi_xfer(140);

        off = find_resp(5, 12);
        if (off >= 5 && off <= 10) begin
            rcmd  = rx_buf[off];
            rlen  = rx_buf[off+1];
            rseq  = rx_buf[off+2];
            rxsum = rx_buf[off+3];
            $display("  Response: CMD=%02x LEN=%02x SEQ=%02x XSUM=%02x",
                     rcmd, rlen, rseq, rxsum);

            if (verify_resp(rcmd, rlen, rseq, rxsum) && rcmd == 8'h21) begin
                dlen = rlen;
                $display("  Data length = %0d bytes (%0d bins)", dlen, dlen/2);

                // Extract FFT data (re[15:0] only, big-endian)
                for (i = 0; i < 64 && (off+5+i*2+1) < 140; i = i + 1) begin
                    fft_data[i] = {16'd0, rx_buf[off+5+i*2], rx_buf[off+5+i*2+1]};
                end

                // ── Verify: DC non-zero ────────────
                $display("\n  DC bin (0): re=%0d", $signed(fft_data[0][15:0]));
                if (fft_data[0] != 0) begin
                    $display("  DC non-zero — OK");
                end else begin
                    $display("  WARNING: DC is zero");
                end

                // ── Verify: conjugate symmetry ─────
                sym_ok = 1;
                for (i = 1; i < 32; i = i + 1) begin
                    if (fft_data[i][15:0] != fft_data[64-i][15:0]) begin
                        // X[k].re should equal X[N-k].re for real input
                        if ($signed(fft_data[i][15:0]) != $signed(fft_data[64-i][15:0])) begin
                            $display("  Symmetry FAIL at bin %0d: re=%0d vs %0d",
                                     i, $signed(fft_data[i][15:0]), $signed(fft_data[64-i][15:0]));
                            sym_ok = 0;
                        end
                    end
                end
                if (sym_ok) begin
                    $display("  Conjugate symmetry — PASS");
                    test_pass = test_pass + 1;
                end else begin
                    $display("  Conjugate symmetry — FAIL");
                    test_fail = test_fail + 1;
                end

                // ── Print all bins for manual check ─
                $display("\n  ── FFT Bins (re, magnitude) ──");
                for (i = 0; i < 64; i = i + 1) begin
                    val = fft_data[i];
                    $display("  bin%2d: re=%6d  hex=%04x", i, $signed(val[15:0]), val[15:0]);
                end

            end else begin
                $display("  FAIL — bad response header\n");
                test_fail = test_fail + 1;
            end
        end else begin
            $display("  FAIL — no response found (off=%0d)\n", off);
            test_fail = test_fail + 1;
        end

        // ═══════════════════════════════════════════
        // Summary
        // ═══════════════════════════════════════════
        $display("\n╔══════════════════════════════════════════╗");
        $display("║  RESULTS: %0d/%0d passed, %0d failed     ║",
                 test_pass, test_n, test_fail);
        $display("╚══════════════════════════════════════════╝\n");

        if (test_fail > 0) $display("SOME TESTS FAILED!");
        else              $display("ALL TESTS PASSED!");

        $finish;
    end

    // ── Cycle counter ─────────────────────────────
    always @(posedge clk) cyc <= cyc + 1;

    // ── Timeout (1M cycles = 10 ms) ──────────────
    initial begin
        #10_000_000;
        $display("\nTIMEOUT — simulation aborted");
        $finish;
    end

endmodule

`default_nettype wire
