//=============================================================================
// sram_ctrl — AS6C4008 512K×16 SRAM Controller (32-bit word interface)
//
// ICEZero board: 2× AS6C4008 (512K×8) in parallel = 512K×16
// 19-bit address bus, 16-bit data bus, LB#/UB# byte controls
//
// Timing (55 ns @ 50 MHz = 3 cycles per access):
//   Read:  addr→CE#→OE#→data valid in 55 ns → 3 cycles
//   Write: addr→CE#→WE#↓→WE#↑ in 55 ns    → 3 cycles
//
// 32-bit word = 2 × 16-bit SRAM accesses
//   Read latency:  3 + 3 = 6 cycles
//   Write latency: 3 + 3 = 6 cycles
//
// Address space: 19-bit SRAM addr × 16-bit = 1 MB total
//                32-bit word space: 256K words
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module sram_ctrl (
    input  wire         clk,
    input  wire         rst_n,

    // ── Application interface (32-bit word) ──────
    input  wire         req,            // 1 = start read/write
    input  wire         wr,             // 1 = write, 0 = read
    input  wire [18:0]  addr,           // 19-bit byte address (must be 4-byte aligned)
    input  wire [31:0]  wdata,          // write data
    output reg  [31:0]  rdata,          // read data (valid with done)
    output reg          busy,           // 1 = operation in progress
    output reg          done,           // 1-cycle pulse when operation completes
    output reg          rdata_valid,    // 1-cycle pulse with rdata

    // ── SRAM physical pins (from icotools icezero.pcf) ──
    output wire [18:0]  sram_a,
    inout  wire [15:0]  sram_dq,
    output wire         sram_ce_n,
    output wire         sram_oe_n,
    output wire         sram_we_n,
    output wire         sram_lb_n,
    output wire         sram_ub_n
);

    // ── State machine ─────────────────────────────
    localparam ST_IDLE    = 3'd0;
    localparam ST_RD_LO   = 3'd1;   // read lower 16 bits
    localparam ST_RD_HI   = 3'd2;   // read upper 16 bits
    localparam ST_RD_DONE = 3'd3;
    localparam ST_WR_LO   = 3'd4;   // write lower 16 bits
    localparam ST_WR_HI   = 3'd5;   // write upper 16 bits
    localparam ST_WR_DONE = 3'd6;

    reg [2:0]  state;
    reg [2:0]  cyc_cnt;         // 0..3 cycles per SRAM access
    reg [18:0] addr_r;          // latched byte address
    reg [31:0] wdata_r;         // latched write data

    // ── SRAM control signals ──────────────────────
    reg        ce_n, oe_n, we_n, lb_n, ub_n;
    reg [15:0] dq_out;
    reg        dq_oe;           // 1 = FPGA drives DQ

    assign sram_ce_n = ce_n;
    assign sram_oe_n = oe_n;
    assign sram_we_n = we_n;
    assign sram_lb_n = lb_n;
    assign sram_ub_n = ub_n;
    assign sram_a    = addr_r;
    assign sram_dq   = dq_oe ? dq_out : 16'hZZZZ;

    // ── SRAM word address (byte addr / 2) ─────────
    wire [18:0] word_addr   = addr[18:1];           // byte→word (÷2)
    wire [18:0] next_word   = word_addr + 19'd1;

    // ── Timing: 3 cycles per SRAM access ──────────
    // Cycle 0: assert CE#, set addr/ctrl
    // Cycle 1: wait
    // Cycle 2: latch read data / deassert WE#
    // Cycle 3: deassert CE#, advance to next word

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            cyc_cnt  <= 0;
            addr_r   <= 0;
            wdata_r  <= 0;
            rdata    <= 0;
            busy     <= 0;
            done     <= 0;
            rdata_valid <= 0;
            ce_n     <= 1;
            oe_n     <= 1;
            we_n     <= 1;
            lb_n     <= 1;
            ub_n     <= 1;
            dq_out   <= 0;
            dq_oe    <= 0;
        end else begin
            done     <= 0;
            rdata_valid <= 0;

            case (state)

                // ── IDLE: wait for request ─────────
                ST_IDLE: begin
                    ce_n  <= 1;
                    oe_n  <= 1;
                    we_n  <= 1;
                    lb_n  <= 1;
                    ub_n  <= 1;
                    dq_oe <= 0;
                    if (req && !busy) begin
                        addr_r  <= addr;
                        wdata_r <= wdata;
                        busy    <= 1;
                        cyc_cnt <= 0;
                        if (wr) begin
                            state  <= ST_WR_LO;
                            addr_r <= word_addr;
                            dq_out <= wdata[15:0];
                            dq_oe  <= 1;
                            ce_n   <= 0;
                            we_n   <= 0;
                            lb_n   <= 0;
                            ub_n   <= 0;
                        end else begin
                            state  <= ST_RD_LO;
                            addr_r <= word_addr;
                            ce_n   <= 0;
                            oe_n   <= 0;
                            lb_n   <= 0;
                            ub_n   <= 0;
                        end
                    end
                end

                // ── READ LO (lower 16 bits) ────────
                ST_RD_LO: begin
                    cyc_cnt <= cyc_cnt + 1;
                    if (cyc_cnt == 2) begin
                        rdata[15:0] <= sram_dq;
                    end
                    if (cyc_cnt == 3) begin
                        cyc_cnt <= 0;
                        ce_n <= 1; oe_n <= 1;
                        state  <= ST_RD_HI;
                        addr_r <= next_word;
                    end
                end

                // ── READ HI (upper 16 bits) ────────
                ST_RD_HI: begin
                    if (cyc_cnt == 0) begin
                        ce_n <= 0; oe_n <= 0;
                    end
                    cyc_cnt <= cyc_cnt + 1;
                    if (cyc_cnt == 2) begin
                        rdata[31:16] <= sram_dq;
                    end
                    if (cyc_cnt == 3) begin
                        ce_n <= 1; oe_n <= 1;
                        lb_n <= 1; ub_n <= 1;
                        state <= ST_RD_DONE;
                    end
                end

                ST_RD_DONE: begin
                    rdata_valid <= 1;
                    done  <= 1;
                    busy  <= 0;
                    state <= ST_IDLE;
                end

                // ── WRITE LO (lower 16 bits) ───────
                ST_WR_LO: begin
                    cyc_cnt <= cyc_cnt + 1;
                    if (cyc_cnt == 2) begin
                        we_n <= 1;
                    end
                    if (cyc_cnt == 3) begin
                        cyc_cnt <= 0;
                        ce_n <= 1; we_n <= 1;
                        state  <= ST_WR_HI;
                        addr_r <= next_word;
                        dq_out <= wdata_r[31:16];
                    end
                end

                // ── WRITE HI (upper 16 bits) ───────
                ST_WR_HI: begin
                    if (cyc_cnt == 0) begin
                        ce_n <= 0; we_n <= 0;
                    end
                    cyc_cnt <= cyc_cnt + 1;
                    if (cyc_cnt == 2) begin
                        we_n <= 1;
                    end
                    if (cyc_cnt == 3) begin
                        ce_n <= 1; we_n <= 1;
                        dq_oe <= 0;
                        lb_n <= 1; ub_n <= 1;
                        state <= ST_WR_DONE;
                    end
                end

                ST_WR_DONE: begin
                    done  <= 1;
                    busy  <= 0;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
