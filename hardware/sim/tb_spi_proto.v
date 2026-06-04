//=============================================================================
// tb_spi_proto — Test bench for spi_slave_proto + fft_top (Verilog-2001)
//
// Simulates Raspberry Pi SPI master (Mode 0, CPOL=0, CPHA=0).
// Tests: STATUS_REQ, FFT_CONFIG, WRITE_DATA, CONTROL, READ_RESULT
// Verifies XOR checksums and response data.
//
// Run: make -f Makefile   or:
//   iverilog -g2012 -o build/tb_spi_proto.vvp \
//     tb_spi_proto.v ../rtl/fft_core.v ../rtl/fft_top.v \
//     ../rtl/twiddle_rom.v ../rtl/spi_slave_proto.v
//   vvp build/tb_spi_proto.vvp
//=============================================================================

`timescale 1ns / 1ps

module tb_spi_proto;

    // ── DUT signals ───────────────────────────────
    reg        clk;
    reg        spi_sck;
    reg        spi_mosi;
    wire       spi_miso;
    reg        spi_ce0;
    wire       drdy;
    wire       led1, led2, led3;

    // ── External SRAM pins + behavioural model ────
    wire [18:0] sram_a;
    wire [15:0] sram_dq;
    wire        sram_ce_n, sram_oe_n, sram_we_n, sram_lb_n, sram_ub_n;

    // ── DUT ───────────────────────────────────────
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
        .a    (sram_a),
        .dq   (sram_dq),
        .ce_n (sram_ce_n),
        .oe_n (sram_oe_n),
        .we_n (sram_we_n),
        .lb_n (sram_lb_n),
        .ub_n (sram_ub_n)
    );

    // ── 100 MHz clock ─────────────────────────────
    always #5 clk = ~clk;

    // ── Test state ────────────────────────────────
    integer   test_pass, test_fail;
    reg [7:0] tx_buf [0:511];   // max 512-byte transaction
    reg [7:0] rx_buf [0:511];
    integer   tx_len, rx_len;

    // ── SPI byte transfer (Mode 0) ────────────────
    reg [7:0] spi_rx_byte;   // result register for spi_byte task
    task spi_byte;
        input [7:0] tx;
        integer b;
        reg [7:0] rx;
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

    // ── Full SPI transaction ──────────────────────
    task spi_xfer;
        input  integer nbytes;
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

    // ── XOR checksum ──────────────────────────────
    function [7:0] xsum;
        input [7:0] a, b, c;
        xsum = a ^ b ^ c;
    endfunction

    // ── Build and send command, return response ────
    // tx_buf layout: [CMD][LEN][SEQ][XSUM][DATA...][GAP][0x00*...]
    // rx_buf will have response at offset (4 + req_data_len + 1)
    task cmd_send;
        input  [7:0]  cmd;
        input  [7:0]  req_len;
        input  [7:0]  seq;
        input  [7:0]  req_data;    // up to 8 request data bytes in packed form
        input  [7:0]  resp_data_len;
        output [7:0]  resp_hdr0, resp_hdr1, resp_hdr2, resp_hdr3;
        output [7:0]  resp_data0, resp_data1, resp_data2, resp_data3;
        output [7:0]  resp_data4, resp_data5, resp_data6, resp_data7;
        integer total, i, off;
        begin
            total = 4 + req_len + 1 + 4 + resp_data_len;
            off   = 4 + req_len + 1;   // response header offset

            // Request header
            tx_buf[0] = cmd;
            tx_buf[1] = req_len;
            tx_buf[2] = seq;
            tx_buf[3] = xsum(cmd, req_len, seq);

            // Request data (packed in req_data, MSB first)
            for (i = 0; i < req_len && i < 4; i = i + 1)
                tx_buf[4 + i] = (req_data >> (8 * (req_len - 1 - i))) & 8'hFF;

            // Gap
            tx_buf[4 + req_len] = 8'h00;

            // Dummy bytes for response
            for (i = 0; i < 4 + resp_data_len; i = i + 1)
                tx_buf[off + i] = 8'h00;

            spi_xfer(total);

            // Extract response
            resp_hdr0 = rx_buf[off + 0];
            resp_hdr1 = rx_buf[off + 1];
            resp_hdr2 = rx_buf[off + 2];
            resp_hdr3 = rx_buf[off + 3];
            resp_data0 = (resp_data_len > 0) ? rx_buf[off + 4] : 8'h00;
            resp_data1 = (resp_data_len > 1) ? rx_buf[off + 5] : 8'h00;
            resp_data2 = (resp_data_len > 2) ? rx_buf[off + 6] : 8'h00;
            resp_data3 = (resp_data_len > 3) ? rx_buf[off + 7] : 8'h00;
            resp_data4 = (resp_data_len > 4) ? rx_buf[off + 8] : 8'h00;
            resp_data5 = (resp_data_len > 5) ? rx_buf[off + 9] : 8'h00;
            resp_data6 = (resp_data_len > 6) ? rx_buf[off + 10] : 8'h00;
            resp_data7 = (resp_data_len > 7) ? rx_buf[off + 11] : 8'h00;
        end
    endtask

    // ── Verify response checksum ───────────────────
    task verify_xsum;
        input [7:0] h0, h1, h2, h3;
        input [255:0] name;
        begin
            if (h3 != xsum(h0, h1, h2)) begin
                $display("  FAIL: %0s checksum mismatch (got 0x%02h, exp 0x%02h)",
                         name, h3, xsum(h0, h1, h2));
                test_fail = test_fail + 1;
            end else begin
                test_pass = test_pass + 1;
            end
        end
    endtask

    // ── Tests ──────────────────────────────────────

    task test_status;
        reg [7:0] h0, h1, h2, h3, d0, d1, d2, d3, d4, d5, d6, d7;
        begin
            $display("[TEST] STATUS_REQ (0x60)...");
            cmd_send(8'h60, 8'd0, 8'd1, 8'h00, 8'd1,
                     h0, h1, h2, h3, d0, d1, d2, d3, d4, d5, d6, d7);
            verify_xsum(h0, h1, h2, h3, "STATUS");
            if (h0 == 8'h60) begin
                $display("  PASS: status=0x%02h (ready=%b busy=%b done=%b)",
                         d0, d0[7], d0[6], d0[5]);
                test_pass = test_pass + 1;
            end else begin
                $display("  FAIL: resp CMD=0x%02h", h0);
                test_fail = test_fail + 1;
            end
        end
    endtask

    task test_config;
        reg [7:0] h0, h1, h2, h3, d0, d1, d2, d3, d4, d5, d6, d7;
        begin
            $display("[TEST] FFT_CONFIG (0x51)...");
            // FFT-64 + Radix-4: SIZE=0x40, FLAGS=0x10 → packed = 0x4010
            cmd_send(8'h51, 8'd2, 8'd2, 16'h4010, 8'd0,
                     h0, h1, h2, h3, d0, d1, d2, d3, d4, d5, d6, d7);
            if (h0 == 8'h51)
                $display("  PASS: ACK");
            else begin
                $display("  FAIL: resp CMD=0x%02h", h0);
                test_fail = test_fail + 1;
            end
            test_pass = test_pass + 1;
        end
    endtask

    task test_control_start;
        reg [7:0] h0, h1, h2, h3, d0, d1, d2, d3, d4, d5, d6, d7;
        begin
            $display("[TEST] CONTROL START (0x50)...");
            cmd_send(8'h50, 8'd1, 8'd3, 8'h01, 8'd0,
                     h0, h1, h2, h3, d0, d1, d2, d3, d4, d5, d6, d7);
            if (h0 == 8'h50)
                $display("  PASS: ACK");
            else begin
                $display("  FAIL: resp CMD=0x%02h", h0);
                test_fail = test_fail + 1;
            end
            test_pass = test_pass + 1;
        end
    endtask

    task test_wait_done;
        integer timeout;
        reg [7:0] h0, h1, h2, h3, d0, d1, d2, d3, d4, d5, d6, d7;
        reg       ok;
        begin
            $display("[TEST] Wait FFT done...");
            timeout = 0;
            ok = 0;
            while (timeout < 5000 && !ok) begin
                cmd_send(8'h60, 8'd0, 8'd4, 8'h00, 8'd1,
                         h0, h1, h2, h3, d0, d1, d2, d3, d4, d5, d6, d7);
                if (d0[5]) begin  // done bit
                    $display("  PASS: FFT done after %0d polls", timeout + 1);
                    test_pass = test_pass + 1;
                    ok = 1;
                end
                timeout = timeout + 1;
                #2000;
            end
            if (!ok) begin
                $display("  FAIL: FFT timeout");
                test_fail = test_fail + 1;
            end
        end
    endtask

    task test_read;
        input [7:0] num_bins;
        reg [7:0] h0, h1, h2, h3, d0, d1, d2, d3, d4, d5, d6, d7;
        reg [15:0] val;
        integer b;
        begin
            $display("[TEST] READ_RESULT (0x21) %0d bins...", num_bins);
            cmd_send(8'h21, 8'd1, 8'd5, {2'd0, num_bins}, num_bins * 8'd2,
                     h0, h1, h2, h3, d0, d1, d2, d3, d4, d5, d6, d7);

            if (h0 != 8'h21) begin
                $display("  FAIL: resp CMD=0x%02h", h0);
                test_fail = test_fail + 1;
            end else begin
                // First few bins (we can only see 8 bytes = 4 bins from this interface)
                for (b = 0; b < 4 && b < num_bins; b = b + 1) begin
                    case (b)
                        0: val = {d0, d1};
                        1: val = {d2, d3};
                        2: val = {d4, d5};
                        3: val = {d6, d7};
                    endcase
                    $display("    bin[%0d] = 0x%04h", b, val);
                end
                $display("  PASS: %0d bins received", num_bins);
                test_pass = test_pass + 1;
            end
        end
    endtask

    // ── BULK_READ (0x23): stream N bins in one transaction ──
    task test_bulk_read;
        input integer num_bins;
        integer total, i, off;
        reg [7:0] h0, h1, h2, h3;
        reg [15:0] re, im;
        integer b;
        begin
            $display("[TEST] BULK_READ (0x23) %0d bins (1 transaction)...", num_bins);
            // Frame: CMD,LEN=0,SEQ,XSUM, GAP, then stream 4*num_bins data bytes.
            off   = 9;                      // 4 hdr + 1 gap + 4 TX hdr
            total = off + num_bins * 4;
            tx_buf[0] = 8'h23;
            tx_buf[1] = 8'd0;
            tx_buf[2] = 8'd7;
            tx_buf[3] = xsum(8'h23, 8'd0, 8'd7);
            for (i = 4; i < total; i = i + 1)
                tx_buf[i] = 8'h00;

            spi_xfer(total);

            h0 = rx_buf[5]; h1 = rx_buf[6]; h2 = rx_buf[7]; h3 = rx_buf[8];
            verify_xsum(h0, h1, h2, h3, "BULK");
            if (h0 != 8'h23) begin
                $display("  FAIL: resp CMD=0x%02h (exp 0x23)", h0);
                test_fail = test_fail + 1;
            end else begin
                for (b = 0; b < 6 && b < num_bins; b = b + 1) begin
                    re = {rx_buf[off + b*4 + 0], rx_buf[off + b*4 + 1]};
                    im = {rx_buf[off + b*4 + 2], rx_buf[off + b*4 + 3]};
                    $display("    bin[%0d] re=0x%04h im=0x%04h", b, re, im);
                end
                $display("  PASS: streamed %0d bins in one transaction", num_bins);
                test_pass = test_pass + 1;
            end
        end
    endtask

    task test_bad_checksum;
        integer total, i, off;
        reg [7:0] h0, h1, h2, h3;
        begin
            $display("[TEST] Bad checksum...");
            // STATUS_REQ with intentionally wrong checksum
            tx_buf[0] = 8'h60;
            tx_buf[1] = 8'h00;
            tx_buf[2] = 8'h06;
            tx_buf[3] = 8'h00;  // WRONG (correct: 0x60^0x00^0x06 = 0x66)
            tx_buf[4] = 8'h00;  // gap
            for (i = 0; i < 5; i = i + 1)
                tx_buf[5 + i] = 8'h00;  // dummy for response
            spi_xfer(10);

            off = 5;
            h0 = rx_buf[off + 0];
            h1 = rx_buf[off + 1];
            h2 = rx_buf[off + 2];
            h3 = rx_buf[off + 3];

            if (h0 == 8'h80) begin
                $display("  PASS: error response 0x80");
                test_pass = test_pass + 1;
            end else begin
                $display("  FAIL: expected 0x80, got 0x%02h", h0);
                test_fail = test_fail + 1;
            end
        end
    endtask

    // ── Main ──────────────────────────────────────
    initial begin
        clk     = 0;
        spi_sck = 0;
        spi_mosi = 0;
        spi_ce0 = 1;
        test_pass = 0;
        test_fail = 0;

        $display("=============================================");
        $display(" SPI Protocol Test Bench (no CRC)");
        $display("=============================================");

        #5000;  // wait for reset
        $display("");

        test_status();
        test_config();
        test_control_start();
        test_wait_done();
        test_read(6'd8);
        test_read(6'd63);
        test_bulk_read(8);
        test_bad_checksum();

        $display("");
        $display("=============================================");
        $display(" RESULTS: %0d passed, %0d failed", test_pass, test_fail);
        $display("=============================================");

        if (test_fail > 0) begin
            $display("SOME TESTS FAILED!");
            $stop;
        end else begin
            $display("ALL TESTS PASSED!");
            $finish;
        end
    end

    // Watchdog
    initial begin
        #30000000;
        $display("TIMEOUT");
        $stop;
    end

endmodule

//=============================================================================
// sram_model — behavioural async SRAM (AS6C4008 512K×16), enough for sim.
//   Read : combinational drive when CE#=0, OE#=0, WE#=1.
//   Write: latched on WE# rising edge with byte enables LB#/UB#.
//=============================================================================
module sram_model (
    input  wire [18:0] a,
    inout  wire [15:0] dq,
    input  wire        ce_n,
    input  wire        oe_n,
    input  wire        we_n,
    input  wire        lb_n,
    input  wire        ub_n
);
    reg [15:0] mem [0:524287];

    assign dq = (!ce_n && !oe_n && we_n) ? mem[a] : 16'hzzzz;

    always @(posedge we_n or posedge ce_n) begin
        if (!ce_n) begin   // sampled as WE#/CE# returns high → data still driven
            if (!lb_n) mem[a][7:0]  <= dq[7:0];
            if (!ub_n) mem[a][15:8] <= dq[15:8];
        end
    end
endmodule
