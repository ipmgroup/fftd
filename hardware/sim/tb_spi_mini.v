//=============================================================================
// tb_spi_mini — Minimal test: spi_slave_proto only (no FFT)
// Sends STATUS_REQ and dumps all received bytes
//=============================================================================

`timescale 1ns / 1ps

module tb_spi_mini;

    reg        clk;
    reg        spi_sck;
    reg        spi_mosi;
    wire       spi_miso;
    reg        spi_ce0;

    // ── DUT: spi_slave_proto only ──────────────────
    wire        cmd_valid, cmd_error;
    wire [7:0]  cmd_byte, cmd_len, cmd_seq;
    wire [7:0]  rx_data_byte;
    wire        rx_data_valid, rx_frame_done;
    wire        tx_rd, tx_done;
    wire        cs_active, in_gap, in_tx_data;
    reg  [7:0]  tx_data_byte;
    reg  [7:0]  ext_resp_len;
    reg         ext_resp_valid;

    spi_slave_proto dut (
        .clk            (clk),
        .rst_n          (1'b1),
        .spi_sck        (spi_sck),
        .spi_mosi       (spi_mosi),
        .spi_miso       (spi_miso),
        .spi_ce0        (spi_ce0),
        .cmd_valid      (cmd_valid),
        .cmd_error      (cmd_error),
        .cmd_byte       (cmd_byte),
        .cmd_len        (cmd_len),
        .cmd_seq        (cmd_seq),
        .rx_data_byte   (rx_data_byte),
        .rx_data_valid  (rx_data_valid),
        .rx_frame_done  (rx_frame_done),
        .tx_data_byte   (tx_data_byte),
        .tx_rd          (tx_rd),
        .tx_done        (tx_done),
        .ext_resp_len   (ext_resp_len),
        .ext_resp_valid (ext_resp_valid),
        .cs_active      (cs_active),
        .in_gap         (in_gap),
        .in_tx_data     (in_tx_data)
    );

    // Response data: always 0xA5 (test pattern)
    always @(*) tx_data_byte = 8'hA5;
    always @(*) ext_resp_len   = 8'd1;
    always @(*) ext_resp_valid = 1'b0;

    always #5 clk = ~clk;

    // ── SPI helpers ────────────────────────────────
    reg [7:0] spi_rx_byte;
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

    function [7:0] xsum;
        input [7:0] a, b, c;
        xsum = a ^ b ^ c;
    endfunction

    reg [7:0] rx_buf [0:31];
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
            #500;
        end
    endtask

    reg [7:0] tx_buf [0:31];

    // ── Test ───────────────────────────────────────
    integer i;
    initial begin
        clk     = 0;
        spi_sck = 0;
        spi_mosi = 0;
        spi_ce0 = 1;

        #1000;

        $display("=== STATUS_REQ (0x60, len=0, seq=0x01) ===");

        // Build frame: CMD + LEN + SEQ + XSUM + GAP + 5 dummy
        tx_buf[0] = 8'h60;                        // CMD
        tx_buf[1] = 8'h00;                        // LEN
        tx_buf[2] = 8'h01;                        // SEQ
        tx_buf[3] = xsum(8'h60, 8'h00, 8'h01);    // XSUM = 0x61
        for (i = 4; i < 10; i = i + 1)
            tx_buf[i] = 8'h00;                     // GAP + dummy

        spi_xfer(10);

        $display("Raw rx_buf:");
        for (i = 0; i < 10; i = i + 1)
            $display("  [%0d] = 0x%02h (%0d)", i, rx_buf[i], rx_buf[i]);

        // Response should start at offset 5
        $display("Response header at [5..8]:");
        $display("  CMD  = 0x%02h (expect 0x60)", rx_buf[5]);
        $display("  LEN  = 0x%02h (expect 0x01)", rx_buf[6]);
        $display("  SEQ  = 0x%02h (expect 0x01)", rx_buf[7]);
        $display("  XSUM = 0x%02h (expect 0x%02h)", rx_buf[8], xsum(rx_buf[5], rx_buf[6], rx_buf[7]));
        $display("  DATA = 0x%02h (expect 0xA5)", rx_buf[9]);

        $display("");
        $display("=== Bad checksum test ===");

        tx_buf[0] = 8'h60;
        tx_buf[1] = 8'h00;
        tx_buf[2] = 8'h02;
        tx_buf[3] = 8'h00;   // WRONG (should be 0x62)
        for (i = 4; i < 10; i = i + 1)
            tx_buf[i] = 8'h00;

        spi_xfer(10);

        $display("Response header at [5..8]:");
        $display("  CMD  = 0x%02h (expect 0x80 for error)", rx_buf[5]);
        $display("  LEN  = 0x%02h", rx_buf[6]);
        $display("  SEQ  = 0x%02h", rx_buf[7]);
        $display("  XSUM = 0x%02h", rx_buf[8]);
        $display("  ERR  = 0x%02h", rx_buf[9]);

        $finish;
    end

endmodule
