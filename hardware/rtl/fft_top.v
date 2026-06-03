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

    // ── PLL: 100 MHz → two phase-aligned clocks ──────────
    //   clk_spi = 87.5 MHz (GENCLK)      → SPI sample domain
    //   clk     = 43.75 MHz (GENCLK_HALF)→ FFT core domain
    //   DIVR=0 → Fref=100; DIVF=6 → Fvco=700 (533-1066 ✓); DIVQ=3 (÷8) →
    //   87.5 MHz on port A; port B = GENCLK_HALF = 43.75 MHz, edge-aligned.
    //   87.5 MHz leaves ~8% margin under the SPI-domain Fmax (~95 MHz); 100 MHz
    //   does not close reliably. SPI oversampling at 87.5 MHz → SCK up to ~22 MHz.
    wire clk;       // 43.75 MHz core
    wire clk_spi;   // 87.5 MHz SPI

    SB_PLL40_2F_PAD #(
        .FEEDBACK_PATH("SIMPLE"),
        .DIVR(4'b0000),
        .DIVF(7'b0000110),
        .DIVQ(3'b011),
        .FILTER_RANGE(3'b001),
        .PLLOUT_SELECT_PORTA("GENCLK"),
        .PLLOUT_SELECT_PORTB("GENCLK_HALF")
    ) pll_inst (
        .PACKAGEPIN    (clk_100mhz),
        .PLLOUTGLOBALA (clk_spi),
        .PLLOUTGLOBALB (clk),
        .RESETB        (1'b1),
        .BYPASS        (1'b0)
    );

    // ── Reset: 255 cycles in each domain ─────────────────
    reg [7:0] rst_cnt = 0;
    reg       rst_n = 0;
    reg       soft_rst = 0;
    always @(posedge clk) begin
        if (rst_cnt != 8'hFF) rst_cnt <= rst_cnt + 1;
        rst_n <= (rst_cnt == 8'hFF) && !soft_rst;
    end

    // SPI-domain reset (released after core reset is stable).
    reg [7:0] rst_cnt_spi = 0;
    reg       rst_n_spi   = 0;
    always @(posedge clk_spi) begin
        if (rst_cnt_spi != 8'hFF) rst_cnt_spi <= rst_cnt_spi + 1;
        rst_n_spi <= (rst_cnt_spi == 8'hFF);
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
        .clk            (clk_spi),
        .rst_n          (rst_n_spi),
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

    // ── CDC: SPI domain (clk_spi) ⇄ core domain (clk) ─────
    // SPI→core event pulses (cmd_valid / rx_data_valid / rx_frame_done) are
    // 1-cycle@100 MHz — too narrow for the 50 MHz core to catch directly, so
    // they go through toggle pulse-synchronisers. The associated data buses
    // (cmd_byte, rx_data_byte) are registered in the SPI domain and held
    // stable for many core cycles around the pulse, so they are sampled
    // directly when the synchronised pulse fires.
    wire cmd_valid_c, rx_data_valid_c, rx_frame_done_c;

    pulse_sync u_cmd_valid_sync (
        .src_clk(clk_spi), .src_pulse(cmd_valid),
        .dst_clk(clk), .dst_rst_n(rst_n), .dst_pulse(cmd_valid_c));
    pulse_sync u_rx_dv_sync (
        .src_clk(clk_spi), .src_pulse(rx_data_valid),
        .dst_clk(clk), .dst_rst_n(rst_n), .dst_pulse(rx_data_valid_c));
    pulse_sync u_rx_fd_sync (
        .src_clk(clk_spi), .src_pulse(rx_frame_done),
        .dst_clk(clk), .dst_rst_n(rst_n), .dst_pulse(rx_frame_done_c));

    // ── Status register (core domain, source) ─────
    wire fft_busy, fft_done;
    wire [3:0] fft_bfp_exp;        // BFP exponent from fft_core (true = out << exp)
    wire fft_ready = !fft_busy && rst_n;
    // Use drdy_r (latched) instead of fft_done (1-cycle pulse) for status.
    // Low nibble carries the BFP exponent so the host can rescale results.
    wire [7:0] status_byte = {fft_ready, fft_busy, drdy_r, 1'b0, fft_bfp_exp};

    // core→SPI: status byte synchronised into the SPI domain. When `done`
    // propagates, bfp_exp has been stable for many cycles, so no bit-skew
    // hazard for the value the host rescales with.
    wire [7:0] status_byte_spi;
    ff2_sync #(.W(8)) u_status_sync (
        .clk(clk_spi), .d(status_byte), .q(status_byte_spi));

    // core→SPI: frame_done pulse to reset the readout bin pointer.
    wire fft_done_spi;
    pulse_sync u_done_sync (
        .src_clk(clk), .src_pulse(fft_done),
        .dst_clk(clk_spi), .dst_rst_n(rst_n_spi), .dst_pulse(fft_done_spi));

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
            if (rx_frame_done_c && cmd_byte == 8'h50) begin
                case (rx_data_byte)
                    8'h01: fft_start_cmd <= 1;
                    8'h04: soft_rst <= 1;
                    default: ;
                endcase
            end
            if (soft_rst) soft_rst <= 0;
        end
    end

    // ── SPI Data Buffer (1024×16-bit BRAM) ────────
    (* syn_ramstyle = "block_ram" *) reg [15:0] data_buf [0:N-1];
    reg [N_LOG2-1:0]  buf_waddr;
    reg [15:0]        buf_wdata;
    reg               buf_we;
    reg [N_LOG2-1:0]  buf_raddr;
    reg [15:0]        buf_rdata;

    always @(posedge clk) begin
        if (buf_we) data_buf[buf_waddr] <= buf_wdata;
        buf_rdata <= data_buf[buf_raddr];
    end

    // ── SPI data mode + buffer write ──────────────
    reg        spi_data_mode;
    reg        spi_byte_hi;
    reg [15:0] spi_sample;
    reg [N_LOG2-1:0] spi_wr_addr;
    reg        buf_feeding;
    reg        buf_din_valid;
    reg        spi_wr_pending;  // delay write 1 cycle for spi_sample to settle

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_data_mode <= 0; spi_byte_hi <= 0; spi_sample <= 0;
            spi_wr_addr <= 0; buf_we <= 0; spi_wr_pending <= 0;
            buf_raddr <= 0; buf_feeding <= 0; buf_din_valid <= 0;
        end else begin
            buf_we <= 0;
            if (cmd_valid_c && cmd_byte == 8'h41) begin
                spi_data_mode <= 1; spi_byte_hi <= 0;
                spi_wr_pending <= 0;
            end
            if (fft_done) begin
                spi_data_mode <= 0; buf_feeding <= 0;
            end
            // SPI byte assembly → write pending
            if (rx_data_valid_c && spi_data_mode && !fft_busy) begin
                if (!spi_byte_hi) begin
                    spi_sample[15:8] <= rx_data_byte;
                    spi_byte_hi <= 1;
                end else begin
                    spi_sample[7:0] <= rx_data_byte;
                    spi_byte_hi <= 0;
                    spi_wr_pending <= 1;  // write next cycle when spi_sample settled
                end
            end
            // Delayed write: spi_sample is now fully updated
            if (spi_wr_pending) begin
                spi_wr_pending <= 0;
                buf_waddr <= spi_wr_addr;
                buf_wdata <= spi_sample;
                buf_we <= 1;
                spi_wr_addr <= spi_wr_addr + 1;
            end
            // CTRL_START → begin feeding buffer to FFT
            if (fft_start_r && spi_data_mode)
                buf_feeding <= 1;

            // Feed with 1-cycle BRAM latency compensation
            if (buf_feeding) begin
                if (fft_busy && !din_ready) begin
                    buf_din_valid <= 0;
                end else begin
                    buf_din_valid <= 1;
                    if (buf_din_valid && din_ready)
                        buf_raddr <= buf_raddr + 1;
                end
            end else begin
                buf_din_valid <= 0;
            end
        end
    end

    // ── FFT Input: internal ramp OR buffer feed ────
    reg [10:0] data_cnt;
    reg        din_valid;
    reg [9:0]  feed_val;
    wire [2*W-1:0] din = spi_data_mode ? {16'd0, buf_rdata} : {16'd0, feed_val};
    wire       din_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_cnt <= 0; din_valid <= 0; feed_val <= 0;
        end else begin
            if (fft_start_cmd || soft_rst) begin
                data_cnt <= 0; feed_val <= 0;
            end
            if (!spi_data_mode) begin
                if (data_cnt < N) begin
                    din_valid <= 1;
                    if (din_ready) begin
                        data_cnt <= data_cnt + 1;
                        feed_val <= feed_val + 1;
                    end
                end else din_valid <= 0;
            end else begin
                din_valid <= buf_din_valid;
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
        .ext_rd_data(ext_rd_data),
        .bfp_exp    (fft_bfp_exp)
    );

    // ── READ_RESULT data pump (4 bytes/bin: re_hi,re_lo,im_hi,im_lo) ──
    // The 4 bytes of the current bin are held in a shift register (tx_word)
    // and the emitted byte is always tx_word[31:24] — a direct wire, no mux.
    // The next bin is prefetched mid-word (rd_bin++ at byte 1), so when the
    // word reloads at byte 3 the BRAM read data is already settled. This
    // keeps the SPI transmit path short enough to sustain high SCK.
    reg [N_LOG2-1:0] rd_bin;
    reg [1:0]         rd_byte_idx;  // 0=re_hi 1=re_lo 2=im_hi 3=im_lo
    reg [31:0]        rd_data;      // {im[31:16], re[15:0]}
    reg [31:0]        tx_word;      // {re_hi, re_lo, im_hi, im_lo}, MSB first
    reg               reading;

    assign ext_rd_addr = rd_bin;

    // Bytes for the current bin, packed MSB-first.
    wire [31:0] bin_word = {rd_data[15:0], rd_data[31:16]};

    // Readout runs in the SPI clock domain (clk_spi). It drives the core BRAM
    // read address (ext_rd_addr = rd_bin) and samples ext_rd_data — a CDC read
    // that is safe because rd_bin is held stable for a full byte period and the
    // next bin is prefetched 2 byte periods ahead (see the byte FSM below).
    always @(posedge clk_spi) begin
        rd_data <= ext_rd_data;   // settles a few clk_spi cycles after rd_bin
    end

    always @(posedge clk_spi or negedge rst_n_spi) begin
        if (!rst_n_spi) begin
            rd_bin      <= 0;
            rd_byte_idx <= 0;
            reading     <= 0;
            tx_word     <= 0;
        end else begin
            if (fft_done_spi) rd_bin <= 0;

            if (cmd_valid && cmd_byte == 8'h21) begin
                rd_byte_idx <= 0;
                reading     <= 1;
                tx_word     <= bin_word;   // load first bin (rd_data settled)
            end

            if (tx_rd && reading) begin
                case (rd_byte_idx)
                    2'd0: begin rd_byte_idx <= 2'd1; tx_word <= {tx_word[23:0], 8'h00}; end
                    2'd1: begin rd_byte_idx <= 2'd2; tx_word <= {tx_word[23:0], 8'h00};
                                rd_bin <= rd_bin + 1; end  // prefetch next bin
                    2'd2: begin rd_byte_idx <= 2'd3; tx_word <= {tx_word[23:0], 8'h00}; end
                    2'd3: begin rd_byte_idx <= 2'd0; tx_word <= bin_word; end  // next bin ready
                endcase
            end

            if (tx_done && reading)
                reading <= 0;
        end
    end

    wire [7:0] rd_byte = tx_word[31:24];   // direct wire — no mux in TX path

    // ── Response data mux (SPI domain) ────────────
    always @(*) begin
        tx_data_byte = status_byte_spi;    // default: STATUS_REQ (synced)
        if (cmd_byte == 8'h21)  tx_data_byte = rd_byte;
        if (cmd_byte == 8'h41)  tx_data_byte = cmd_len;
        if (cmd_error)          tx_data_byte = 8'h01;
    end

    // ── Response length override (READ_RESULT), SPI domain ──
    reg [7:0] num_bins_r;
    always @(posedge clk_spi) begin
        if (rx_data_valid && cmd_byte == 8'h21)
            num_bins_r <= rx_data_byte;
    end

    always @(posedge clk_spi) begin
        ext_resp_valid <= 0;
        if (in_gap && cmd_byte == 8'h21) begin
            ext_resp_len   <= num_bins_r * 8'd4;  // 4 bytes/bin (re + im)
            ext_resp_valid <= 1;
        end
    end

    // ── LEDs ──────────────────────────────────────
    assign led1 = fft_busy;
    assign led2 = din_valid;   // DEBUG: blink during data load
    assign led3 = drdy_r;

    // ── SRAM Controller (for future data buffer) ──
    // Currently idle: Pi↔SRAM data path via WRITE_DATA/READ_RESULT TBD
    wire        sram_req;
    wire        sram_wr;
    wire [18:0] sram_addr;
    wire [31:0] sram_wdata;
    wire [31:0] sram_rdata;
    wire        sram_busy, sram_done, sram_rvalid;

    // Tie SRAM to idle for now (no requests)
    assign sram_req  = 1'b0;
    assign sram_wr   = 1'b0;
    assign sram_addr = 19'd0;
    assign sram_wdata = 32'd0;

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
        .sram_dq    (sram_dq),
        .sram_ce_n  (sram_ce_n),
        .sram_oe_n  (sram_oe_n),
        .sram_we_n  (sram_we_n),
        .sram_lb_n  (sram_lb_n),
        .sram_ub_n  (sram_ub_n)
    );

endmodule

//=============================================================================
// CDC helpers
//=============================================================================

// Level/vector synchroniser (2 FF). For slowly-changing buses where a few
// cycles of skew between bits is acceptable (e.g. status that is polled).
module ff2_sync #(parameter W = 1) (
    input  wire          clk,
    input  wire [W-1:0]  d,
    output reg  [W-1:0]  q
);
    reg [W-1:0] meta;
    always @(posedge clk) begin
        meta <= d;
        q    <= meta;
    end
endmodule

// Toggle-based pulse synchroniser. A 1-cycle pulse in the source domain
// produces a 1-cycle pulse in the destination domain, regardless of clock
// ratio/phase. `rst_n` is in the destination domain.
module pulse_sync (
    input  wire  src_clk,
    input  wire  src_pulse,
    input  wire  dst_clk,
    input  wire  dst_rst_n,
    output wire  dst_pulse
);
    reg tgl = 1'b0;
    always @(posedge src_clk)
        if (src_pulse) tgl <= ~tgl;

    reg [2:0] sync;
    always @(posedge dst_clk or negedge dst_rst_n)
        if (!dst_rst_n) sync <= 3'b000;
        else            sync <= {sync[1:0], tgl};

    assign dst_pulse = sync[2] ^ sync[1];
endmodule

`default_nettype wire
