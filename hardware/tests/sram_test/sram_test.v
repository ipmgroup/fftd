//=============================================================================
// sram_test — Minimal SPI↔SRAM test for ICEZero
//
// SPI commands: SRAM_ADDR(0x52), SRAM_WRITE(0x42), SRAM_READ(0x22), STATUS(0x60)
// PLL: 100 MHz → configurable output (16, 25, 33, 50 MHz)
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module sram_test (
    input  wire         clk_100mhz,
    // SPI
    input  wire         spi_sck,
    input  wire         spi_mosi,
    output wire         spi_miso,
    input  wire         spi_ce0,
    // LEDs
    output wire         led1,
    output wire         led2,
    output wire         led3,
    // SRAM
    output wire [18:0]  sram_a,
    inout  wire [15:0]  sram_dq,
    output wire         sram_ce_n,
    output wire         sram_oe_n,
    output wire         sram_we_n,
    output wire         sram_lb_n,
    output wire         sram_ub_n
);

    // ── PLL: 100 MHz → 16 MHz ─────────────────────
    // DIVR=0 (÷1), DIVF=7 (×8), DIVQ=5 (÷32) → 25 MHz
    // For 16 MHz: DIVR=4 (÷5), DIVF=7 (×8), DIVQ=3 (÷8) → 20 MHz
    // Try DIVR=0, DIVF=7, DIVQ=5 → 100×8/32 = 25 MHz first
    wire clk;

    SB_PLL40_PAD #(
        .FEEDBACK_PATH("SIMPLE"),
        .DIVR(4'b0000),
        .DIVF(7'b0000111),
        .DIVQ(3'b100),          // ÷16 → 50 MHz
        .FILTER_RANGE(3'b001)
    ) pll_inst (
        .PACKAGEPIN    (clk_100mhz),
        .PLLOUTGLOBAL  (clk),
        .RESETB        (1'b1),
        .BYPASS        (1'b0)
    );

    // ── Reset ──────────────────────────────────────
    reg [7:0] rst_cnt = 0;
    reg       rst_n = 0;
    always @(posedge clk) begin
        if (rst_cnt != 8'hFF) rst_cnt <= rst_cnt + 1;
        rst_n <= (rst_cnt == 8'hFF);
    end

    // ── SPI Protocol Slave ──────────────────────────
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

    // ── Status ──────────────────────────────────────
    wire [7:0] status_byte = {rst_n, sram_op_busy, 2'b0, 4'h0};

    // ── LEDs ────────────────────────────────────────
    assign led1 = sram_op_busy;
    assign led2 = sram_req_r;
    assign led3 = rst_n;

    // ── SRAM Commands ───────────────────────────────
    reg [18:0] sram_ptr;
    reg        sram_req_r;
    reg        sram_op_write;
    reg        sram_op_busy;
    reg [31:0] sram_wdata_r;
    reg [31:0] sram_rdata_r;
    reg        sram_rdata_valid_r;
    reg [1:0]  sram_byte_cnt;

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

            // SRAM_ADDR (0x52): 3 bytes → 19-bit addr
            if (rx_data_valid && cmd_byte == 8'h52) begin
                case (sram_byte_cnt)
                    2'd0: sram_ptr[18:16] <= rx_data_byte[2:0];
                    2'd1: sram_ptr[15:8]  <= rx_data_byte;
                    2'd2: sram_ptr[7:0]   <= rx_data_byte;
                endcase
                sram_byte_cnt <= sram_byte_cnt + 1;
            end

            // SRAM_WRITE (0x42): 4 bytes → 32-bit word
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

            // SRAM_READ (0x22): no payload
            if (cmd_valid && cmd_byte == 8'h22 && !sram_op_busy) begin
                sram_req_r <= 1;
                sram_op_write <= 0;
                sram_op_busy <= 1;
            end

            // Operation done
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

    // ── SRAM Controller ─────────────────────────────
    wire        sram_req   = sram_req_r;
    wire        sram_wr    = sram_op_write;
    wire [18:0] sram_addr  = sram_ptr;
    wire [31:0] sram_wdata = sram_wdata_r;
    wire [31:0] sram_rdata;
    wire        sram_busy, sram_done, sram_rvalid;

    // ── SB_IO for data bus (icotools pattern) ──────
    wire [15:0] sram_din;
    wire [15:0] sram_dout;
    wire        sram_oe_n_int;

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : sram_dio
            SB_IO #(
                .PIN_TYPE(6'b1010_01),
                .PULLUP(1'b0)
            ) dio (
                .PACKAGE_PIN(sram_dq[gi]),
                .OUTPUT_ENABLE(sram_oe_n_int),
                .D_OUT_0(sram_dout[gi]),
                .D_IN_0(sram_din[gi])
            );
        end
    endgenerate

    sram_ctrl_simple sram (
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
        .sram_oe_n  (sram_oe_n_int),
        .sram_we_n  (sram_we_n),
        .sram_lb_n  (sram_lb_n),
        .sram_ub_n  (sram_ub_n)
    );

    assign sram_oe_n = sram_oe_n_int;

    // ── Response mux ────────────────────────────────
    reg [1:0] sram_rd_byte_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sram_rd_byte_cnt <= 0;
        else begin
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

    always @(*) begin
        tx_data_byte = status_byte;
        if (cmd_byte == 8'h22) tx_data_byte = sram_rd_byte;
        if (cmd_byte == 8'h42) tx_data_byte = 8'h04;
        if (cmd_error)         tx_data_byte = 8'h01;
    end

    always @(posedge clk) begin
        ext_resp_valid <= 0;
        if (in_gap && cmd_byte == 8'h22) begin
            ext_resp_len   <= 8'd4;
            ext_resp_valid <= 1;
        end
    end

endmodule

`default_nettype wire
