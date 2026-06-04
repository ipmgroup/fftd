//=============================================================================
// spi_slave_proto — SPI Slave with Framed Protocol (XOR checksum, no CRC)
//
// SPI Mode 0 (CPOL=0, CPHA=0).
//   - FPGA samples MOSI on SCK rising, changes MISO on SCK falling.
//   - 3-stage synchronisers on all SPI inputs.
//
// Frame format (per fft_spi_protocol_doc.md):
//   Request:  [CMD][LEN][SEQ][XSUM][DATA_0..DATA_{LEN-1}]
//   Gap:      1 byte (slave processes command, MISO=0x00)
//   Response: [CMD][RESP_LEN][SEQ][XSUM][RESP_DATA_0..]
//
// Master must send exactly 4 + LEN + 1 + 4 + RESP_LEN bytes.
//
// Commands:
//   0x60 STATUS_REQ   → RESP_LEN=1  (status byte)
//   0x51 FFT_CONFIG    → RESP_LEN=0  (ACK — header-only response)
//   0x41 WRITE_DATA    → RESP_LEN=1  (count of samples accepted)
//   0x21 READ_RESULT   → RESP_LEN up to 128 (N bins × 2 bytes each)
//   0x50 CONTROL       → RESP_LEN=0  (ACK)
//
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module spi_slave_proto (
    input  wire        clk,
    input  wire        rst_n,

    // ── SPI pins ──────────────────────────────────
    input  wire        spi_sck,
    input  wire        spi_mosi,
    output wire        spi_miso,
    input  wire        spi_ce0,

    // ── Command interface (to application) ────────
    output reg         cmd_valid,       // pulse: command decoded, checksum OK
    output reg         cmd_error,       // pulse: checksum mismatch
    output reg  [7:0]  cmd_byte,
    output reg  [7:0]  cmd_len,
    output reg  [7:0]  cmd_seq,
    output reg  [7:0]  rx_data_byte,
    output reg         rx_data_valid,   // pulse when rx_data_byte valid
    output reg         rx_frame_done,   // pulse: all request data received

    // ── Response data (from application) ──────────
    input  wire [7:0]  tx_data_byte,    // byte to transmit during TX_DATA phase
    output reg         tx_rd,           // pulse: app should advance to next byte
    output reg         tx_done,         // pulse: response fully transmitted

    // ── Response length override (for READ_RESULT) ─
    input  wire [7:0]  ext_resp_len,    // override resp_data_len
    input  wire        ext_resp_valid,  // 1 = use ext_resp_len instead of default

    // ── Streaming mode (bulk read) ────────────────
    // When high during TX_DATA the response is NOT terminated by resp_data_len;
    // bytes keep streaming (tx_rd pulses every byte) until the master deasserts
    // CS. Used by BULK_READ to return the whole spectrum in one transaction.
    input  wire        stream_mode,

    // ── Convenience: current state exposed ───────
    output wire        cs_active,
    output wire        in_gap,          // high during GAP byte
    output wire        in_tx_data       // high during TX_DATA phase
);

    // ── 2-stage synchronisers ─────────────────────
    // Reliable up to ~25 MHz SPI at 100 MHz FPGA clock.
    reg [1:0] sck_s;
    reg [2:0] ce0_s;                 // 3-stage on CE0 (slow)
    reg [1:0] mosi_s;

    always @(posedge clk) begin
        sck_s  <= {sck_s[0],  spi_sck};
        ce0_s  <= {ce0_s[1:0], spi_ce0};
        mosi_s <= {mosi_s[0],  spi_mosi};
    end

    wire sck_rise = (sck_s[1:0] == 2'b01);
    wire sck_fall = (sck_s[1:0] == 2'b10);
    wire cs_act_w = !ce0_s[2];
    wire cs_fall  = (ce0_s[2:1] == 2'b10);

    assign cs_active = cs_act_w;

    // ── RX shift register ─────────────────────────
    reg [7:0] rx_sr;
    reg [2:0] rx_bit;

    always @(posedge clk) begin
        if (!cs_act_w) begin
            rx_bit <= 0;
        end else if (sck_rise) begin
            rx_sr  <= {rx_sr[6:0], mosi_s[1]};
            rx_bit <= rx_bit + 1;
        end
    end

    wire byte_end   = sck_rise && (rx_bit == 3'd7);

    // rx_sr_next: the value rx_sr will have after the non-blocking assignment
    // at byte_end, rx_sr is stale (missing the LSB just sampled).
    // rx_sr_next is the correct full byte at byte_end.
    wire [7:0] rx_sr_next = {rx_sr[6:0], mosi_s[1]};

    // ── TX shift register with proper load/shift gating ──
    reg [7:0] tx_sr;
    reg       tx_load_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_sr           <= 8'h00;
            tx_load_pending <= 0;
        end else begin
            if (byte_end && cs_act_w)
                tx_load_pending <= 1;

            if (sck_fall && cs_act_w) begin
                if (tx_load_pending) begin
                    tx_sr           <= next_tx_byte;
                    tx_load_pending <= 0;
                end else begin
                    tx_sr <= {tx_sr[6:0], 1'b0};
                end
            end

            if (cs_fall) begin
                tx_sr           <= next_tx_byte;
                tx_load_pending <= 0;
            end
        end
    end

    assign spi_miso = tx_sr[7];

    // ── Protocol state machine ────────────────────
    localparam ST_IDLE      = 4'd0;
    localparam ST_RX_CMD    = 4'd1;
    localparam ST_RX_LEN    = 4'd2;
    localparam ST_RX_SEQ    = 4'd3;
    localparam ST_RX_XSUM   = 4'd4;
    localparam ST_RX_DATA   = 4'd5;
    localparam ST_GAP       = 4'd6;
    localparam ST_TX_CMD    = 4'd7;
    localparam ST_TX_LEN    = 4'd8;
    localparam ST_TX_SEQ    = 4'd9;
    localparam ST_TX_XSUM   = 4'd10;
    localparam ST_TX_DATA   = 4'd11;

    reg [3:0] state;
    reg [7:0] r_cmd, r_len, r_seq;
    reg [7:0] data_cnt;
    reg [7:0] tx_cnt;
    reg       xsum_ok;
    reg [7:0] resp_data_len;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            r_cmd    <= 0;
            r_len    <= 0;
            r_seq    <= 0;
            data_cnt <= 0;
            xsum_ok  <= 0;
            resp_data_len <= 0;
            tx_cnt   <= 0;
        end else begin
            if (!cs_act_w)
                state <= ST_IDLE;

            if (byte_end && cs_act_w) begin
                case (state)

                    ST_IDLE: begin
                        // First byte is CMD — capture it immediately
                        r_cmd <= rx_sr_next;
                        state <= ST_RX_LEN;     // skip RX_CMD, go to LEN
                    end

                    ST_RX_CMD: begin
                        // (Unreachable — kept for safety)
                        r_cmd <= rx_sr_next;
                        state <= ST_RX_LEN;
                    end

                    ST_RX_LEN: begin
                        r_len <= rx_sr_next;
                        state <= ST_RX_SEQ;
                    end

                    ST_RX_SEQ: begin
                        r_seq <= rx_sr_next;
                        state <= ST_RX_XSUM;
                    end

                    ST_RX_XSUM: begin
                        if (rx_sr_next == (r_cmd ^ r_len ^ r_seq)) begin
                            xsum_ok <= 1;
                            if (r_len == 0) begin
                                state    <= ST_GAP;
                                data_cnt <= 0;
                            end else begin
                                state    <= ST_RX_DATA;
                                data_cnt <= 0;
                            end
                        end else begin
                            xsum_ok <= 0;
                            state   <= ST_GAP;
                        end
                    end

                    ST_RX_DATA: begin
                        data_cnt <= data_cnt + 1;
                        if (data_cnt == r_len - 1) begin
                            state <= ST_GAP;
                        end
                    end

                    ST_GAP: begin
                        if (xsum_ok) begin
                            if (ext_resp_valid) begin
                                resp_data_len <= ext_resp_len;
                            end else begin
                                case (r_cmd)
                                    8'h60: resp_data_len <= 8'd1;
                                    8'h51: resp_data_len <= 8'd0;
                                    8'h41: resp_data_len <= 8'd1;
                                    8'h21: resp_data_len <= 8'd1;
                                    8'h50: resp_data_len <= 8'd0;
                                    default: resp_data_len <= 8'd0;
                                endcase
                            end
                        end else begin
                            r_cmd          <= 8'h80;
                            resp_data_len  <= 8'd1;
                        end
                        tx_cnt <= 0;
                        state  <= ST_TX_CMD;
                    end

                    ST_TX_CMD:  state <= ST_TX_LEN;
                    ST_TX_LEN:  state <= ST_TX_SEQ;
                    ST_TX_SEQ:  state <= ST_TX_XSUM;

                    ST_TX_XSUM: begin
                        if (resp_data_len == 0) begin
                            state <= ST_IDLE;
                        end else begin
                            state  <= ST_TX_DATA;
                            tx_cnt <= 0;
                        end
                    end

                    ST_TX_DATA: begin
                        tx_cnt <= tx_cnt + 1;
                        // In stream mode keep emitting until CS deasserts
                        // (handled by the !cs_act_w → ST_IDLE reset at top).
                        if (tx_cnt == resp_data_len - 1 && !stream_mode) begin
                            state <= ST_IDLE;
                        end
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

    // ── TX byte selection ─────────────────────────
    wire [7:0] resp_cmd  = xsum_ok ? r_cmd : 8'h80;
    wire [7:0] resp_len  = resp_data_len;
    wire [7:0] resp_seq  = r_seq;
    wire [7:0] resp_xsum = resp_cmd ^ resp_len ^ resp_seq;

    reg [7:0] next_tx_byte;
    always @(*) begin
        case (state)
            ST_IDLE:     next_tx_byte = 8'h00;
            ST_RX_CMD,
            ST_RX_LEN,
            ST_RX_SEQ,
            ST_RX_XSUM,
            ST_RX_DATA:  next_tx_byte = 8'h00;
            ST_GAP:      next_tx_byte = 8'h00;
            ST_TX_CMD:   next_tx_byte = resp_cmd;
            ST_TX_LEN:   next_tx_byte = resp_len;
            ST_TX_SEQ:   next_tx_byte = resp_seq;
            ST_TX_XSUM:  next_tx_byte = resp_xsum;
            ST_TX_DATA:  next_tx_byte = tx_data_byte;
            default:     next_tx_byte = 8'h00;
        endcase
    end

    assign in_gap     = (state == ST_GAP);
    assign in_tx_data = (state == ST_TX_DATA);

    // ── Application-facing outputs ────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_valid     <= 0;
            cmd_error     <= 0;
            cmd_byte      <= 0;
            cmd_len       <= 0;
            cmd_seq       <= 0;
            rx_data_byte  <= 0;
            rx_data_valid <= 0;
            rx_frame_done <= 0;
            tx_rd         <= 0;
            tx_done       <= 0;
        end else begin
            cmd_valid     <= 0;
            cmd_error     <= 0;
            rx_data_valid <= 0;
            rx_frame_done <= 0;
            tx_rd         <= 0;
            tx_done       <= 0;

            // Use rx_sr_next (not rx_sr) because rx_sr is stale at byte_end
            if (byte_end && cs_act_w) begin

                if (state == ST_RX_XSUM) begin
                    cmd_byte <= r_cmd;
                    cmd_len  <= r_len;
                    cmd_seq  <= r_seq;
                    if (rx_sr_next == (r_cmd ^ r_len ^ r_seq))
                        cmd_valid <= 1;
                    else
                        cmd_error <= 1;
                end

                if (state == ST_RX_DATA) begin
                    rx_data_byte  <= rx_sr_next;
                    rx_data_valid <= 1;
                    if (data_cnt == r_len - 1)
                        rx_frame_done <= 1;
                end

                if (state == ST_TX_DATA) begin
                    tx_rd <= 1;
                    if (tx_cnt == resp_data_len - 1)
                        tx_done <= 1;
                end

            end
        end
    end

endmodule

`default_nettype wire
