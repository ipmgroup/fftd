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
//   0x41 WRITE_DATA    → ACK with byte count (direct-to-BRAM input)
//   0x43 WRITE_SRAM    → stage input frame into external SRAM (copied to BRAM
//                        by an input-DMA at START; may be sent while busy)
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

    // BULK_READ (0x23): stream the whole spectrum in one SPI transaction.
    wire        stream_mode = (cmd_byte == 8'h23);

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
        .stream_mode    (stream_mode),
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
    // Low nibble carries the BFP exponent of the buffered (SRAM) result —
    // latched at DMA time so it stays valid even while a new FFT recomputes a
    // different exponent in the core. sram_exp declared with the scheduler.
    wire [3:0] sram_exp;
    wire [7:0] status_byte = {fft_ready, fft_busy, drdy_r, 1'b0, sram_exp};

    // core→SPI: status byte synchronised into the SPI domain. When `done`
    // propagates, bfp_exp has been stable for many cycles, so no bit-skew
    // hazard for the value the host rescales with.
    wire [7:0] status_byte_spi;
    ff2_sync #(.W(8)) u_status_sync (
        .clk(clk_spi), .d(status_byte), .q(status_byte_spi));

    // core→SPI: DMA-complete pulse to reset the readout bin pointer (the result
    // is only available in SRAM once the BRAM→SRAM copy has finished).
    wire dma_done;                 // core-domain pulse (declared with scheduler)
    wire dma_done_spi;
    pulse_sync u_done_sync (
        .src_clk(clk), .src_pulse(dma_done),
        .dst_clk(clk_spi), .dst_rst_n(rst_n_spi), .dst_pulse(dma_done_spi));

    // ── DRDY output (cleared after readout completes or FFT restarts) ──
    reg drdy_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drdy_r <= 0;
        end else begin
            if (dma_done)
                drdy_r <= 1;       // result copied to SRAM → ready to read
            // Clear on the START *request* (not feed_start): with SRAM-staged
            // input the FFT only launches after the input-DMA (~1024 SRAM reads),
            // so clearing at feed time would leave `done` asserted from the
            // previous frame during that window — a host polling right after
            // START would read the stale result. Clearing on fft_start_cmd drops
            // `done` immediately and it is re-raised only by dma_done.
            if (fft_start_cmd)
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

    // Input-DMA (SRAM input region → data_buf) write port. Declared here so the
    // BRAM write mux below can see it; driven by the SRAM scheduler.
    reg               idma_we;
    reg [N_LOG2-1:0]  idma_waddr;
    reg [15:0]        idma_wdata;

    // data_buf write mux: the input-DMA (SRAM-staged input, 0x42) takes priority
    // over the direct SPI write (0x41). The two paths are never active together.
    always @(posedge clk) begin
        if (idma_we)     data_buf[idma_waddr] <= idma_wdata;
        else if (buf_we) data_buf[buf_waddr]  <= buf_wdata;
        buf_rdata <= data_buf[buf_raddr];
    end

    // ── SPI data mode + buffer write ──────────────
    reg        spi_data_mode;
    reg        sram_in;          // 0x42: input staged into SRAM (not BRAM)
    reg        spi_byte_hi;
    reg [15:0] spi_sample;
    reg [N_LOG2-1:0] spi_wr_addr;
    reg        buf_feeding;
    reg        buf_din_valid;
    reg        spi_wr_pending;  // delay write 1 cycle for spi_sample to settle

    // SPI→scheduler input-write handshake (both in core domain). When a 16-bit
    // sample is assembled in SRAM-input mode (0x42), post it for the scheduler to
    // write into the SRAM input region. Sample period (~50 core cycles) ≫ SRAM
    // write latency (6 cycles), so a single-entry handshake never overruns.
    reg        iwr_set;
    reg [15:0] iwr_data_r;
    reg [N_LOG2-1:0] iwr_addr_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_data_mode <= 0; sram_in <= 0; spi_byte_hi <= 0; spi_sample <= 0;
            spi_wr_addr <= 0; buf_we <= 0; spi_wr_pending <= 0;
            buf_raddr <= 0; buf_feeding <= 0; buf_din_valid <= 0;
            iwr_set <= 0; iwr_data_r <= 0; iwr_addr_r <= 0;
        end else begin
            buf_we  <= 0;
            iwr_set <= 0;
            // 0x41: legacy direct-to-BRAM input. 0x43: SRAM-staged input.
            // spi_wr_addr is NOT reset per command: a full frame is sent as
            // several ≤120-sample chunk transactions and the 10-bit address wraps
            // at 1024, so consecutive chunks accumulate into one aligned frame.
            if (cmd_valid_c && cmd_byte == 8'h41) begin
                spi_data_mode <= 1; sram_in <= 0; spi_byte_hi <= 0;
                spi_wr_pending <= 0;
            end
            if (cmd_valid_c && cmd_byte == 8'h43) begin
                sram_in <= 1; spi_byte_hi <= 0;
            end
            // START in SRAM-input mode feeds the (input-DMA-filled) BRAM.
            if (fft_start_cmd && sram_in)
                spi_data_mode <= 1;
            if (fft_done) begin
                spi_data_mode <= 0; buf_feeding <= 0;
            end
            // SPI byte assembly. 0x43 posts samples to the scheduler for SRAM
            // staging (allowed any time, incl. during compute/readout, so the
            // host can preload while the core is busy). 0x41 writes BRAM directly
            // and only while idle. Gating on cmd_byte prevents the dummy MOSI
            // bytes of a read transaction (0x21/0x23) from being mistaken for
            // input samples.
            if (rx_data_valid_c && cmd_byte == 8'h43) begin
                if (!spi_byte_hi) begin
                    spi_sample[15:8] <= rx_data_byte;
                    spi_byte_hi <= 1;
                end else begin
                    spi_byte_hi <= 0;
                    iwr_data_r  <= {spi_sample[15:8], rx_data_byte};
                    iwr_addr_r  <= spi_wr_addr;
                    iwr_set     <= 1;
                    spi_wr_addr <= spi_wr_addr + 1;
                end
            end else if (rx_data_valid_c && cmd_byte == 8'h41 && !fft_busy) begin
                if (!spi_byte_hi) begin
                    spi_sample[15:8] <= rx_data_byte;
                    spi_byte_hi <= 1;
                end else begin
                    spi_sample[7:0] <= rx_data_byte;
                    spi_byte_hi <= 0;
                    spi_wr_pending <= 1;  // write next cycle when spi_sample settled
                end
            end
            // Delayed write (0x41 path): spi_sample is now fully updated
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

    // Start sequencing. A start request (host START or the one-shot free-run at
    // boot) is latched and only consumed once BOTH the core and the BRAM→SRAM
    // copy DMA are idle — starting a new FFT mid-copy would raise `busy` (which
    // gates ext_rd_data) and overwrite the BRAM, corrupting the buffered result.
    wire dma_idle = !dma_active && !dma_pending;
    wire free_run = !drdy_r && !result_in_sram;   // self-test FFT, only pre-first-result

    // SRAM-staged input (0x42): a START first triggers an input-DMA copy of the
    // staged frame from SRAM into the BRAM the FFT feeds from. The FFT launch is
    // held until that copy finishes (input_ready). `input_dma_pending`/
    // `input_ready` live in the scheduler; `input_dma_req` arms the copy.
    wire input_dma_req = fft_start_cmd && sram_in;
    wire input_ok      = !sram_in || input_ready;

    reg start_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) start_pending <= 0;
        else begin
            if (fft_start_cmd) start_pending <= 1;
            if (fft_start_r)   start_pending <= 0;
        end
    end

    wire do_start = !fft_busy && !fft_done && dma_idle && input_ok
                    && (start_pending || free_run);
    wire feed_start = fft_start_r;

    reg fft_start_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fft_start_r <= 0;
        else if (do_start)
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

    // SRAM-backed readout word, maintained by the core-domain read-server for
    // the bin currently addressed by rd_bin (see the SRAM scheduler below).
    wire [31:0] sram_rd_word;

    // Bytes for the current bin, packed MSB-first.
    wire [31:0] bin_word = {rd_data[15:0], rd_data[31:16]};

    // Readout runs in the SPI clock domain (clk_spi). It samples sram_rd_word —
    // a core→SPI CDC read that is safe because rd_bin is held stable per bin and
    // the next bin is prefetched 2 byte periods ahead, giving the read-server
    // ample time to refresh sram_rd_word for the new address.
    always @(posedge clk_spi) begin
        rd_data <= sram_rd_word;
    end

    always @(posedge clk_spi or negedge rst_n_spi) begin
        if (!rst_n_spi) begin
            rd_bin      <= 0;
            rd_byte_idx <= 0;
            reading     <= 0;
            tx_word     <= 0;
        end else begin
            if (dma_done_spi) rd_bin <= 0;  // result available once DMA→SRAM done

            // READ_RESULT (0x21): chunked read, rd_bin persists across frames.
            if (cmd_valid && cmd_byte == 8'h21)
                reading <= 1;

            // BULK_READ (0x23): stream whole spectrum, restart from bin 0.
            if (cmd_valid && cmd_byte == 8'h23) begin
                reading <= 1;
                rd_bin  <= 0;
            end

            if (reading && !in_tx_data) begin
                // Pre-data phase (command echo / gap / TX header): keep the
                // current bin loaded so the first data byte = bin_word[31:24].
                // For BULK_READ this also waits out the rd_bin=0 settle.
                rd_byte_idx <= 0;
                tx_word     <= bin_word;
            end else if (tx_rd && reading) begin
                case (rd_byte_idx)
                    2'd0: begin rd_byte_idx <= 2'd1; tx_word <= {tx_word[23:0], 8'h00}; end
                    2'd1: begin rd_byte_idx <= 2'd2; tx_word <= {tx_word[23:0], 8'h00};
                                rd_bin <= rd_bin + 1; end  // prefetch next bin
                    2'd2: begin rd_byte_idx <= 2'd3; tx_word <= {tx_word[23:0], 8'h00}; end
                    2'd3: begin rd_byte_idx <= 2'd0; tx_word <= bin_word; end  // next bin ready
                endcase
            end

            // End of any SPI transaction clears the read flag (covers both the
            // chunked 0x21 path and the CS-terminated BULK_READ stream).
            if (!cs_active)
                reading <= 0;
        end
    end

    wire [7:0] rd_byte = tx_word[31:24];   // direct wire — no mux in TX path

    // ── Response data mux (SPI domain) ────────────
    always @(*) begin
        tx_data_byte = status_byte_spi;    // default: STATUS_REQ (synced)
        if (cmd_byte == 8'h21)  tx_data_byte = rd_byte;
        if (cmd_byte == 8'h23)  tx_data_byte = rd_byte;   // BULK_READ stream
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
        // BULK_READ: enter TX_DATA with a nonzero length; stream_mode keeps it
        // from terminating, so the actual byte count is set by the master (CS).
        if (in_gap && cmd_byte == 8'h23) begin
            ext_resp_len   <= 8'd4;
            ext_resp_valid <= 1;
        end
    end

    // ── LEDs ──────────────────────────────────────
    assign led1 = fft_busy;
    assign led2 = din_valid;   // DEBUG: blink during data load
    assign led3 = drdy_r;

    // ── SRAM result buffer: DMA (BRAM→SRAM) + read-server ──────────────
    // Double-buffering datapath. After each FFT frame the 1024 complex bins are
    // copied from the core BRAM into external SRAM (DMA). The SPI readout then
    // streams from SRAM, freeing the core BRAM so the next FFT can compute while
    // the host is still reading the previous result.
    //
    // A single core-domain scheduler owns sram_ctrl, so there is never a request
    // conflict: by default it runs the read-server (refreshing sram_rd_word for
    // the bin the SPI side is reading); when a frame completes it switches to the
    // DMA copy loop (higher priority), then returns to serving reads.

    reg         sram_req;
    reg         sram_wr;
    reg  [18:0] sram_addr;
    reg  [31:0] sram_wdata;
    wire [31:0] sram_rdata;
    wire        sram_busy, sram_done, sram_rvalid;

    // rd_bin (SPI domain) → core domain. Slowly changing (one step per ~4 SPI
    // byte periods), so a 2-FF vector sync with a little bit-skew is fine: the
    // read-server re-reads continuously and settles long before the SPI side
    // samples the prefetched word.
    wire [N_LOG2-1:0] rd_bin_c;
    ff2_sync #(.W(N_LOG2)) u_rdbin_sync (.clk(clk), .d(rd_bin), .q(rd_bin_c));

    // `reading` (SPI domain) → core. Held high for the whole read transaction,
    // so a 2-FF level sync is safe. The DMA copy of the next frame is deferred
    // while this is high so it cannot overwrite the SRAM buffer the host is
    // currently streaming (single-buffer compute/readout overlap, B2).
    wire reading_c;
    ff2_sync u_reading_sync (.clk(clk), .d(reading), .q(reading_c));

    reg [N_LOG2-1:0] dma_addr;       // BRAM read address (DMA only)
    reg [N_LOG2-1:0] dma_i;          // current bin being copied
    reg              dma_active;
    reg              dma_done_r;     // 1-cycle pulse when copy finishes
    reg              dma_pending;    // a frame finished, awaiting copy
    reg              result_in_sram;
    reg  [3:0]       sram_exp_r;     // BFP exponent of the buffered result
    reg  [31:0]      sram_rd_word_r; // current bin word for the SPI readout
    reg  [2:0]       brwait;

    // Input path (SRAM-staged, 0x43): host-write FIFO + input-DMA state.
    //
    // Host input samples (0x43) are pushed by the SPI assembly block (`iwr_set`)
    // and drained by this scheduler into the SRAM input region. A single-entry
    // handshake is NOT enough: when the scheduler is busy with a multi-thousand-
    // cycle output-DMA (BRAM→SRAM copy of the previous result), it cannot service
    // input writes for a long time, so back-to-back samples would overrun and be
    // silently dropped (leaving X holes in the staged frame). A small FIFO plus
    // a drain step inside the output-DMA loop (see SC_DMA_NEXT) absorbs the burst.
    // Pointers carry an extra wrap bit so empty/full need no separate counter
    // (and thus no simultaneous push/pop update hazard).
    localparam IWR_DEPTH = 16, IWR_AW = 4;
    reg [15:0]        iwr_fifo_data [0:IWR_DEPTH-1];
    reg [N_LOG2-1:0]  iwr_fifo_addr [0:IWR_DEPTH-1];
    reg [IWR_AW:0]    iwr_wptr, iwr_rptr;  // {wrap, index}
    wire              iwr_empty = (iwr_wptr == iwr_rptr);
    wire              iwr_full  = (iwr_wptr[IWR_AW-1:0] == iwr_rptr[IWR_AW-1:0])
                                && (iwr_wptr[IWR_AW] != iwr_rptr[IWR_AW]);
    reg              input_dma_pending; // a START armed an input copy
    reg              input_ready;       // staged frame copied SRAM→BRAM
    reg [N_LOG2-1:0] idma_i;            // current input sample being copied
    reg [3:0]        iwr_ret;           // SC_IWR_WAIT return state

    // SRAM byte-address base for the input staging region. The 32-bit output
    // result occupies SRAM words 0..2047 (bins 0..1023 × 2 words); the input
    // region starts well past it at byte 8192 (word 4096).
    localparam [18:0] IN_BASE = 19'd8192;

    assign ext_rd_addr  = dma_addr;
    assign dma_done     = dma_done_r;
    assign sram_exp     = sram_exp_r;
    assign sram_rd_word = sram_rd_word_r;

    localparam SC_RD_REQ   = 3'd0,
               SC_RD_WAIT  = 3'd1,
               SC_DMA_SET  = 3'd2,
               SC_DMA_WAIT = 3'd3,
               SC_DMA_WR   = 3'd4,
               SC_DMA_NEXT = 3'd5,
               SC_IWR_WAIT = 3'd6,  // input-write to SRAM in flight
               SC_IDMA_RD  = 3'd7;  // input-DMA: SRAM read → BRAM write
    reg [3:0] sched;
    reg       idma_phase;  // 0 = issue read, 1 = wait rvalid / next

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_req <= 0; sram_wr <= 0; sram_addr <= 0; sram_wdata <= 0;
            dma_addr <= 0; dma_i <= 0; dma_active <= 0; dma_done_r <= 0;
            dma_pending <= 0; result_in_sram <= 0; sram_exp_r <= 0;
            sram_rd_word_r <= 0; brwait <= 0; sched <= SC_RD_REQ;
            input_dma_pending <= 0; input_ready <= 0;
            iwr_wptr <= 0; iwr_rptr <= 0; iwr_ret <= SC_RD_REQ;
            idma_i <= 0; idma_we <= 0; idma_waddr <= 0; idma_wdata <= 0;
            idma_phase <= 0;
        end else begin
            sram_req   <= 0;   // default: pulse req for one cycle
            dma_done_r <= 0;
            idma_we    <= 0;   // default: pulse BRAM write for one cycle

            // A finished FFT frame schedules a BRAM→SRAM copy.
            if (fft_done)      dma_pending       <= 1;
            // A START in SRAM-input mode arms the input copy.
            if (input_dma_req) input_dma_pending <= 1;
            // Consumed once the feed begins; re-armed by the next START.
            if (feed_start)    input_ready       <= 0;

            // ── Input-write FIFO push (host 0x43 sample). Pops happen in the
            // case below (independent rptr), so push/pop never collide.
            if (iwr_set && !iwr_full) begin
                iwr_fifo_data[iwr_wptr[IWR_AW-1:0]] <= iwr_data_r;
                iwr_fifo_addr[iwr_wptr[IWR_AW-1:0]] <= iwr_addr_r;
                iwr_wptr <= iwr_wptr + 1'b1;
            end

            case (sched)
                // ── Dispatcher / read-server: keep sram_rd_word fresh ──
                SC_RD_REQ: begin
                    // Priority: host input write (must never drop) > input copy
                    // > output copy (background, when no read in flight) >
                    // read-server refresh. Input writes outrank the output-DMA so
                    // the staged frame is complete before the input-DMA reads it.
                    if (!iwr_empty) begin
                        iwr_rptr    <= iwr_rptr + 1'b1;
                        sram_req    <= 1;
                        sram_wr     <= 1;
                        sram_addr   <= IN_BASE + {iwr_fifo_addr[iwr_rptr[IWR_AW-1:0]], 2'b00};
                        sram_wdata  <= {16'd0, iwr_fifo_data[iwr_rptr[IWR_AW-1:0]]};
                        iwr_ret     <= SC_RD_REQ;
                        sched       <= SC_IWR_WAIT;
                    end else if (input_dma_pending) begin
                        input_dma_pending <= 0;
                        idma_i     <= 0;
                        idma_phase <= 0;
                        sched      <= SC_IDMA_RD;
                    end else if (dma_pending && !reading_c) begin
                        dma_pending <= 0;
                        dma_active  <= 1;
                        dma_i       <= 0;
                        sched       <= SC_DMA_SET;
                    end else begin
                        sram_req  <= 1;
                        sram_wr   <= 0;
                        sram_addr <= {rd_bin_c, 2'b00};   // byte addr = bin*4
                        sched     <= SC_RD_WAIT;
                    end
                end
                SC_RD_WAIT: begin
                    if (sram_rvalid) begin
                        sram_rd_word_r <= sram_rdata;
                        sched <= SC_RD_REQ;
                    end
                end

                // ── Host input write → SRAM input region. Returns to iwr_ret so
                // it can be invoked both from the dispatcher and mid output-DMA. ──
                SC_IWR_WAIT: begin
                    if (sram_done) sched <= iwr_ret;
                end

                // ── Input-DMA: copy SRAM[IN_BASE+i] → data_buf[i] ──
                SC_IDMA_RD: begin
                    if (!idma_phase) begin
                        sram_req   <= 1;
                        sram_wr    <= 0;
                        sram_addr  <= IN_BASE + {idma_i, 2'b00};
                        idma_phase <= 1;
                    end else if (sram_rvalid) begin
                        idma_we    <= 1;
                        idma_waddr <= idma_i;
                        idma_wdata <= sram_rdata[15:0];
                        idma_phase <= 0;
                        if (idma_i == N-1) begin
                            input_ready <= 1;
                            sched       <= SC_RD_REQ;
                        end else begin
                            idma_i <= idma_i + 1;
                        end
                    end
                end

                // ── DMA: copy bram[dma_i] → SRAM[dma_i] ──
                SC_DMA_SET: begin
                    dma_addr <= dma_i;     // drive BRAM ext read port
                    brwait   <= 0;
                    sched    <= SC_DMA_WAIT;
                end
                SC_DMA_WAIT: begin
                    brwait <= brwait + 1;
                    if (brwait == 3'd3) begin   // ext_rd_data valid (2-cyc BRAM pipe + margin)
                        sram_req   <= 1;
                        sram_wr    <= 1;
                        sram_addr  <= {dma_i, 2'b00};
                        sram_wdata <= ext_rd_data;
                        sched      <= SC_DMA_WR;
                    end
                end
                SC_DMA_WR: begin
                    if (sram_done) sched <= SC_DMA_NEXT;
                end
                SC_DMA_NEXT: begin
                    // Drain any pending host input writes before the next bin so
                    // a long output-DMA can never starve (and thus drop) staged
                    // 0x43 samples. SRAM write (~6 cyc) is faster than the SPI
                    // sample period, so the FIFO stays shallow; we service one per
                    // bin boundary and re-check here until empty.
                    if (!iwr_empty) begin
                        iwr_rptr   <= iwr_rptr + 1'b1;
                        sram_req   <= 1;
                        sram_wr    <= 1;
                        sram_addr  <= IN_BASE + {iwr_fifo_addr[iwr_rptr[IWR_AW-1:0]], 2'b00};
                        sram_wdata <= {16'd0, iwr_fifo_data[iwr_rptr[IWR_AW-1:0]]};
                        iwr_ret    <= SC_DMA_NEXT;
                        sched      <= SC_IWR_WAIT;
                    end else if (dma_i == N-1) begin
                        dma_active     <= 0;
                        dma_done_r     <= 1;
                        result_in_sram <= 1;
                        sram_exp_r     <= fft_bfp_exp;  // latch this frame's exponent
                        sched          <= SC_RD_REQ;
                    end else begin
                        dma_i <= dma_i + 1;
                        sched <= SC_DMA_SET;
                    end
                end
                default: sched <= SC_RD_REQ;
            endcase
        end
    end

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
