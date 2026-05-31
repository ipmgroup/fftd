//=============================================================================
// sram_ctrl_simple — Minimal IS61WV25616BLL controller (icotools-style)
//
// CE#, LB#, UB# = always 0 (asserted)
// WE#/OE# toggle for writes/reads
// 32-bit word = 2×16-bit accesses
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module sram_ctrl_simple (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         req,
    input  wire         wr,
    input  wire [18:0]  addr,
    input  wire [31:0]  wdata,
    output reg  [31:0]  rdata,
    output reg          busy,
    output reg          done,
    output reg          rdata_valid,

    output wire [18:0]  sram_a,
    input  wire [15:0]  sram_din,
    output reg  [15:0]  sram_dout,
    output wire         sram_ce_n,
    output wire         sram_oe_n,
    output wire         sram_we_n,
    output wire         sram_lb_n,
    output wire         sram_ub_n
);

    // Always asserted (icotools pattern)
    assign sram_ce_n = 1'b0;
    assign sram_lb_n = 1'b0;
    assign sram_ub_n = 1'b0;

    reg oe_n, we_n;
    assign sram_oe_n = oe_n;
    assign sram_we_n = we_n;

    localparam ST_IDLE    = 0;
    localparam ST_WR0     = 1;  // assert WE#, drive lo word
    localparam ST_WR0_WAIT = 2;
    localparam ST_WR0_END = 3;  // deassert WE#
    localparam ST_WR1     = 4;  // assert WE#, drive hi word
    localparam ST_WR1_WAIT = 5;
    localparam ST_WR1_END = 6;  // deassert WE#
    localparam ST_WR_DONE = 7;
    localparam ST_RD0     = 8;  // assert OE#, latch lo word
    localparam ST_RD0_WAIT = 9;
    localparam ST_RD1     = 10; // assert OE#, latch hi word
    localparam ST_RD1_WAIT = 11;
    localparam ST_RD_DONE = 12;

    reg [3:0]  state;
    reg [18:0] addr_r;
    reg [31:0] wdata_r;

    wire [18:0] word_addr = addr[18:1];
    wire [18:0] next_word = word_addr + 19'd1;

    assign sram_a = addr_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            addr_r <= 0; wdata_r <= 0; rdata <= 0;
            busy <= 0; done <= 0; rdata_valid <= 0;
            oe_n <= 1; we_n <= 1;
            sram_dout <= 0;
        end else begin
            done <= 0; rdata_valid <= 0;

            case (state)
                ST_IDLE: begin
                    oe_n <= 1; we_n <= 1;
                    if (req && !busy) begin
                        addr_r <= word_addr;
                        wdata_r <= wdata;
                        busy <= 1;
                        if (wr) begin
                            // Start write: OE#=1 (FPGA drives), WE#=0
                            sram_dout <= wdata[15:0];
                            oe_n <= 1;
                            we_n <= 0;
                            state <= ST_WR0;
                        end else begin
                            // Start read: OE#=0 (SRAM drives), WE#=1
                            oe_n <= 0;
                            we_n <= 1;
                            state <= ST_RD0;
                        end
                    end
                end

                // ── Write lo word ──────────────────
                ST_WR0:     begin state <= ST_WR0_WAIT; end
                ST_WR0_WAIT: begin state <= ST_WR0_END; end
                ST_WR0_END: begin
                    we_n <= 1;
                    addr_r <= next_word;
                    sram_dout <= wdata_r[31:16];
                    state <= ST_WR1;
                end

                // ── Write hi word ──────────────────
                ST_WR1:     begin we_n <= 0; state <= ST_WR1_WAIT; end
                ST_WR1_WAIT: begin state <= ST_WR1_END; end
                ST_WR1_END: begin we_n <= 1; state <= ST_WR_DONE; end
                ST_WR_DONE: begin
                    oe_n <= 1;  // back to default
                    done <= 1; busy <= 0; state <= ST_IDLE;
                end

                // ── Read lo word ───────────────────
                ST_RD0:     begin state <= ST_RD0_WAIT; end
                ST_RD0_WAIT: begin
                    rdata[15:0] <= sram_din;
                    oe_n <= 1;
                    addr_r <= next_word;
                    state <= ST_RD1;
                end

                // ── Read hi word ───────────────────
                ST_RD1:     begin oe_n <= 0; state <= ST_RD1_WAIT; end
                ST_RD1_WAIT: begin
                    rdata[31:16] <= sram_din;
                    oe_n <= 1;
                    state <= ST_RD_DONE;
                end
                ST_RD_DONE: begin
                    rdata_valid <= 1; done <= 1; busy <= 0;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
