//=============================================================================
// fft_top — ICEZero FFT Accelerator with SPI Protocol + SRAM
//
// Architecture:
//   spi_slave_proto  ←→  Raspberry Pi (SPI0, Mode 0)
//   fft_core          →  1024-point radix-2 DIT FFT (internal BRAM)
//   sram_ctrl         →  AS6C4008 512K×16 external SRAM buffer
//   Internal test pattern generator (ramp 0..1023, imag=0)
//
// SPI Commands:
//   0x60 STATUS_REQ   → returns {ready,busy,done,error,4'h0}
//   0x51 FFT_CONFIG    → ACK only (size/flags not used yet)
//   0x41 WRITE_DATA    → ACK with byte count
//   0x21 READ_RESULT   → returns N bins × 2 bytes (big-endian re[15:0])
//   0x50 CONTROL       → START(0x01), STOP(0x02), RESET(0x04)
//
// Pins (from icotools icezero.pcf):
//   clk(49), spi_sck(79), spi_mosi(90), spi_miso(87), spi_ce0(85)
//   drdy(88), led1(110)=busy, led2(93)=done, led3(94)=drdy
//   SRAM: ce(24), we(11), oe(76), lb(81), ub(75), a[18:0], dq[15:0]
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module fft_top (
    input  wire         clk_100mhz,
    // SPI
    input  wire         spi_sck,
    input  wire         spi_mosi,
    output wire         spi_miso,
    input  wire         spi_ce0,
    output wire         drdy,
    // LEDs
    output wire         led1,
    output wire         led2,
    output wire         led3,
    // SRAM AS6C4008
    output wire [18:0]  sram_a,
    inout  wire [15:0]  sram_dq,
    output wire         sram_ce_n,
    output wire         sram_oe_n,
    output wire         sram_we_n,
    output wire         sram_lb_n,
    output wire         sram_ub_n
);

    localparam W      = 16;
    localparam N      = 1024;
    localparam N_LOG2 = 10;

    // ── PLL: 100 MHz → 50 MHz (multiplier safe, Fmax=72) ─
    //   DIVR=0 (÷1) → Fref=100 MHz
    //   DIVF=7 (×8) → Fvco=800 MHz (533-1066 ✓)
    //   DIVQ=4 (÷16) → Fout=50 MHz
    wire clk;

    SB_PLL40_PAD #(
        .FEEDBACK_PATH("SIMPLE"),
        .DIVR(4'b0000),
        .DIVF(7'b0000111),
        .DIVQ(3'b100),
        .FILTER_RANGE(3'b001)
    ) pll_inst (
        .PACKAGEPIN    (clk_100mhz),
        .PLLOUTGLOBAL  (clk),
        .RESETB        (1'b1),
        .BYPASS        (1'b0)
    );

    // ── Reset: 255 cycles ≈ 5 µs at 50 MHz ────
    reg [7:0] rst_cnt = 0;
    reg       rst_n = 0;
    reg       soft_rst = 0;
    always @(posedge clk) begin
        if (rst_cnt != 8'hFF) rst_cnt <= rst_cnt + 1;
        rst_n <= (rst_cnt == 8'hFF) && !soft_rst;
    end

    // ── SPI Protocol Slave ────────────────────────
    wire        cmd_valid, cmd_error;
    wire [7:0]  cmd_byte, cmd_len, cmd_seq;
    wire [7:0]  rx_data_byte;
    wire        rx_data_valid, rx_frame_done;
    wire        tx_rd, tx_done;
    wire        cs_active, in_gap, in_tx_data;
    reg  [7:0]  tx_data_byte;
    reg  [7:0]  ext_resp_len;
    reg         ext_resp_valid;

    spi_slave_proto spi_proto (
        .clk            (clk),
        .rst_n          (rst_n),
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

    // ── Status register ───────────────────────────
    wire fft_busy, fft_done;
    wire fft_ready = !fft_busy && rst_n;
    // Use drdy_r (latched) instead of fft_done (1-cycle pulse) for status
    wire [7:0] status_byte = {fft_ready, fft_busy, drdy_r, 1'b0, 4'h0};

    // ── DRDY output (cleared after readout completes or FFT restarts) ──
    reg drdy_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drdy_r <= 0;
        end else begin
            if (fft_done)
                drdy_r <= 1;
            if (feed_start)
                drdy_r <= 0;
        end
    end
    assign drdy = drdy_r;

    // ── CONTROL command ───────────────────────────
    reg fft_start_cmd;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fft_start_cmd <= 0;
            soft_rst      <= 0;
        end else begin
            fft_start_cmd <= 0;
            if (rx_frame_done && cmd_byte == 8'h50) begin
                case (rx_data_byte)
                    8'h01: fft_start_cmd <= 1;
                    8'h04: soft_rst <= 1;
                    default: ;
                endcase
            end
            if (soft_rst) soft_rst <= 0;
        end
    end

    // ── FFT Input: internal test ramp ─────────────
    reg [10:0] data_cnt;  // counts how many values fed (0..N)
    reg        din_valid;
    reg [9:0]  feed_val;  // actual data value (0..N-1)
    wire [2*W-1:0] din = {16'd0, feed_val};
    wire       din_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_cnt <= 0;
            din_valid <= 0;
            feed_val  <= 0;
        end else begin
            // Restart counter on FFT start or soft reset
            if (fft_start_cmd || soft_rst) begin
                data_cnt <= 0;
                feed_val  <= 0;
            end

            // Feed N values, then stop
            if (data_cnt < N) begin
                din_valid <= 1;
                if (din_ready) begin
                    data_cnt <= data_cnt + 1;
                    feed_val <= feed_val + 1;
                end
            end else begin
                din_valid <= 0;
            end
        end
    end

    wire feed_start = fft_start_cmd || (!fft_busy && !fft_done && !drdy_r);

    // start: hold until FFT begins loading
    reg fft_start_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fft_start_r <= 0;
        else if (!fft_busy && !fft_done && !drdy_r)
            fft_start_r <= 1;
        else if (fft_busy)
            fft_start_r <= 0;
    end

    // ── FFT Core ──────────────────────────────────
    wire [N_LOG2-1:0] ext_rd_addr;
    wire [31:0]        ext_rd_data;

    fft_core #(.N_LOG2(N_LOG2), .WIDTH(W)) fft (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (fft_start_r),
        .din        (din),
        .din_valid  (din_valid),
        .din_ready  (din_ready),
        .dout       (),
        .dout_valid (),
        .busy       (fft_busy),
        .frame_done (fft_done),
        .ext_rd_addr(ext_rd_addr),
        .ext_rd_data(ext_rd_data)
    );

    // ── READ_RESULT data pump ─────────────────────
    reg [N_LOG2-1:0] rd_bin;
    reg               rd_hi;       // 0=re[15:8], 1=re[7:0]
    reg [31:0]        rd_data;
    reg               reading;

    assign ext_rd_addr = rd_bin;

    always @(posedge clk) begin
        rd_data <= ext_rd_data;   // 1 cycle after ext_rd_addr
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_bin  <= 0;
            rd_hi   <= 0;
            reading <= 0;
        end else begin
            if (fft_done) rd_bin <= 0;

            if (cmd_valid && cmd_byte == 8'h21) begin
                rd_hi   <= 0;
                reading <= 1;
            end

            if (tx_rd && reading) begin
                if (rd_hi) begin
                    rd_bin <= rd_bin + 1;
                    rd_hi  <= 0;
                end else begin
                    rd_hi <= 1;
                end
            end

            if (tx_done && reading)
                reading <= 0;
        end
    end

    wire [7:0] rd_byte = rd_hi ? rd_data[7:0] : rd_data[15:8];

    // ── Response data mux ─────────────────────────
    always @(*) begin
        tx_data_byte = status_byte;    // default: STATUS_REQ
        if (cmd_byte == 8'h21)  tx_data_byte = rd_byte;
        if (cmd_byte == 8'h22)  tx_data_byte = sram_rd_byte;
        if (cmd_byte == 8'h41)  tx_data_byte = cmd_len;
        if (cmd_byte == 8'h42)  tx_data_byte = 8'h04;  // SRAM_WRITE: echo 4 bytes
        if (cmd_error)          tx_data_byte = 8'h01;
    end

    // ── Response length override (READ_RESULT, SRAM_READ) ────
    reg [7:0] num_bins_r;
    always @(posedge clk) begin
        if (rx_data_valid && cmd_byte == 8'h21)
            num_bins_r <= rx_data_byte;
    end

    always @(posedge clk) begin
        ext_resp_valid <= 0;
        if (in_gap && cmd_byte == 8'h21) begin
            ext_resp_len   <= num_bins_r * 8'd2;  // 2 bytes/bin (re only)
            ext_resp_valid <= 1;
        end
        if (in_gap && cmd_byte == 8'h22) begin
            ext_resp_len   <= 8'd4;  // 4 bytes (32-bit word)
            ext_resp_valid <= 1;
        end
    end

    // ── LEDs ──────────────────────────────────────
    assign led1 = fft_busy;
    assign led2 = din_valid;   // DEBUG: blink during data load
    assign led3 = drdy_r;

    // ── SRAM Debug Commands ───────────────────────
    // 0x52 SRAM_ADDR  → set SRAM byte-address pointer (3 bytes payload)
    // 0x42 SRAM_WRITE → write 32-bit word, auto-inc pointer (+4)
    // 0x22 SRAM_READ  → read 32-bit word, auto-inc pointer (+4)
    reg [18:0] sram_ptr;
    reg        sram_req_r;
    reg        sram_op_write;   // 1=write, 0=read
    reg        sram_op_busy;    // local FSM busy
    reg [31:0] sram_wdata_r;
    reg [31:0] sram_rdata_r;
    reg        sram_rdata_valid_r;
    reg [1:0]  sram_byte_cnt;   // 0..3 for address/data assembly

    // SRAM command state
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_ptr <= 0;
            sram_req_r <= 0;
            sram_op_write <= 0;
            sram_op_busy <= 0;
            sram_wdata_r <= 0;
            sram_rdata_r <= 0;
            sram_rdata_valid_r <= 0;
            sram_byte_cnt <= 0;
        end else begin
            sram_req_r <= 0;
            sram_rdata_valid_r <= 0;

            // SRAM_ADDR command: 3 bytes = 19-bit addr
            if (rx_data_valid && cmd_byte == 8'h52) begin
                case (sram_byte_cnt)
                    2'd0: sram_ptr[18:16] <= rx_data_byte[2:0];
                    2'd1: sram_ptr[15:8]  <= rx_data_byte;
                    2'd2: sram_ptr[7:0]   <= rx_data_byte;
                endcase
                sram_byte_cnt <= sram_byte_cnt + 1;
            end

            // SRAM_WRITE command: 4 bytes = 32-bit word
            if (rx_data_valid && cmd_byte == 8'h42) begin
                case (sram_byte_cnt)
                    2'd0: sram_wdata_r[31:24] <= rx_data_byte;
                    2'd1: sram_wdata_r[23:16] <= rx_data_byte;
                    2'd2: sram_wdata_r[15:8]  <= rx_data_byte;
                    2'd3: begin
                        sram_wdata_r[7:0] <= rx_data_byte;
                        sram_req_r <= 1;
                        sram_op_write <= 1;
                        sram_op_busy <= 1;
                    end
                endcase
                if (sram_byte_cnt == 2'd3)
                    sram_byte_cnt <= 0;
                else
                    sram_byte_cnt <= sram_byte_cnt + 1;
            end

            // SRAM_READ command: no payload, issue read immediately
            if (cmd_valid && cmd_byte == 8'h22 && !sram_op_busy) begin
                sram_req_r <= 1;
                sram_op_write <= 0;
                sram_op_busy <= 1;
            end

            // SRAM operation done
            if (sram_op_busy && sram_done) begin
                sram_op_busy <= 0;
                if (!sram_op_write) begin
                    sram_rdata_r <= sram_rdata;
                    sram_rdata_valid_r <= 1;
                end
                sram_ptr <= sram_ptr + 19'd4;
            end

            // Reset byte counter on new command
            if (cmd_valid && cmd_byte != 8'h52 && cmd_byte != 8'h42)
                sram_byte_cnt <= 0;
        end
    end

    // SRAM controller request mux
    wire        sram_req   = sram_req_r;
    wire        sram_wr    = sram_op_write;
    wire [18:0] sram_addr  = sram_ptr;
    wire [31:0] sram_wdata = sram_wdata_r;
    wire [31:0] sram_rdata;
    wire        sram_busy, sram_done, sram_rvalid;

    // SRAM_READ response data byte mux
    reg [1:0] sram_rd_byte_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_rd_byte_cnt <= 0;
        end else begin
            if (cmd_valid && cmd_byte == 8'h22)
                sram_rd_byte_cnt <= 0;
            if (tx_rd && cmd_byte == 8'h22)
                sram_rd_byte_cnt <= sram_rd_byte_cnt + 1;
        end
    end

    wire [7:0] sram_rd_byte =
        (sram_rd_byte_cnt == 2'd0) ? sram_rdata_r[31:24] :
        (sram_rd_byte_cnt == 2'd1) ? sram_rdata_r[23:16] :
        (sram_rd_byte_cnt == 2'd2) ? sram_rdata_r[15:8]  :
                                     sram_rdata_r[7:0];

    // ── SB_IO for SRAM data bus (per icotools example) ──
    wire [15:0] sram_din;        // data FROM SRAM (registered by SB_IO)
    wire [15:0] sram_dout;       // data TO SRAM
    wire        sram_oe_n;       // SRAM OE# — also used as SB_IO OUTPUT_ENABLE

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : sram_dio
            SB_IO #(
                .PIN_TYPE(6'b1010_01),  // input registered, output no reg, enable registered
                .PULLUP(1'b0)
            ) dio (
                .PACKAGE_PIN(sram_dq[gi]),
                .OUTPUT_ENABLE(sram_oe_n),    // same signal as SRAM OE#!
                .D_OUT_0(sram_dout[gi]),
                .D_IN_0(sram_din[gi])
            );
        end
    endgenerate

    sram_ctrl sram (
        .clk        (clk),
        .rst_n      (rst_n),
        .req        (sram_req),
        .wr         (sram_wr),
        .addr       (sram_addr),
        .wdata      (sram_wdata),
        .rdata      (sram_rdata),
        .busy       (sram_busy),
        .done       (sram_done),
        .rdata_valid(sram_rvalid),
        .sram_a     (sram_a),
        .sram_din   (sram_din),
        .sram_dout  (sram_dout),
        .sram_ce_n  (sram_ce_n),
        .sram_oe_n  (sram_oe_n),
        .sram_we_n  (sram_we_n),
        .sram_lb_n  (sram_lb_n),
        .sram_ub_n  (sram_ub_n)
    );

endmodule

`default_nettype wire
