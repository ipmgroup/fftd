//=============================================================================
// sram_ctrl — IS61WV25616BLL-10TLI 256K×16 SRAM (10 ns, icotools-style)
//
// CE#, LB#, UB# always asserted. WE#/OE# toggle per operation.
// 32-bit word = 2 × 16-bit SRAM accesses.
//
// Timing @ 50 MHz (20 ns/cycle), SRAM tAA=10 ns:
//   Write: WE# low 2 cycles (40 ns) >> tWP min 8 ns ✓
//   Read:  OE# low → latch after 2 cycles (40 ns) >> tAA 10 ns ✓
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module sram_ctrl (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         req,            // 1 = start read/write
    input  wire         wr,             // 1 = write, 0 = read
    input  wire [18:0]  addr,           // 19-bit byte addr (A18 ignored by 256K×16)
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

    // ── CE#, LB#, UB# always asserted (icotools pattern) ──
    assign sram_ce_n = 1'b0;
    assign sram_lb_n = 1'b0;
    assign sram_ub_n = 1'b0;

    reg oe_n, we_n;
    assign sram_oe_n = oe_n;
    assign sram_we_n = we_n;

    localparam ST_IDLE    = 3'd0;
    localparam ST_WR_LO   = 3'd1;
    localparam ST_WR_HI   = 3'd2;
    localparam ST_WR_DONE = 3'd3;
    localparam ST_RD_LO   = 3'd4;
    localparam ST_RD_HI   = 3'd5;
    localparam ST_RD_DONE = 3'd6;

    reg [2:0]  state;
    reg [2:0]  cyc;
    reg [18:0] addr_r;
    reg [31:0] wdata_r;

    wire [18:0] word_addr = addr[18:1];
    wire [18:0] next_word = word_addr + 19'd1;

    assign sram_a = addr_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE; cyc <= 0;
            addr_r <= 0; wdata_r <= 0; rdata <= 0;
            busy <= 0; done <= 0; rdata_valid <= 0;
            oe_n <= 1; we_n <= 1;
            sram_dout <= 0;
        end else begin
            done <= 0; rdata_valid <= 0;

            case (state)
                ST_IDLE: begin
                    oe_n <= 1; we_n <= 1; sram_dq_oe <= 0;
                    if (req && !busy) begin
                        addr_r <= word_addr; wdata_r <= wdata;
                        busy <= 1; cyc <= 0;
                        if (wr) begin
                            sram_dout <= wdata[15:0];
                            oe_n <= 1;  // OE#=1 → FPGA drives bus
                            we_n <= 0;
                            state <= ST_WR_LO;
                        end else begin
                            oe_n <= 0;
                            state <= ST_RD_LO;
                        end
                    end
                end

                ST_WR_LO: begin
                    cyc <= cyc + 1;
                    if (cyc == 1) we_n <= 1;
                    if (cyc == 2) begin
                        cyc <= 0; addr_r <= next_word;
                        sram_dout <= wdata_r[31:16];
                        state <= ST_WR_HI;
                    end
                end

                ST_WR_HI: begin
                    if (cyc == 0) we_n <= 0;
                    cyc <= cyc + 1;
                    if (cyc == 1) we_n <= 1;
                    if (cyc == 2) begin
                        oe_n <= 1; state <= ST_WR_DONE;
                    end
                end

                ST_WR_DONE: begin done <= 1; busy <= 0; state <= ST_IDLE; end

                ST_RD_LO: begin
                    cyc <= cyc + 1;
                    if (cyc == 1) rdata[15:0] <= sram_din;
                    if (cyc == 2) begin
                        cyc <= 0; oe_n <= 1; addr_r <= next_word;
                        state <= ST_RD_HI;
                    end
                end

                ST_RD_HI: begin
                    if (cyc == 0) oe_n <= 0;
                    cyc <= cyc + 1;
                    if (cyc == 1) rdata[31:16] <= sram_din;
                    if (cyc == 2) begin
                        oe_n <= 1; state <= ST_RD_DONE;
                    end
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
