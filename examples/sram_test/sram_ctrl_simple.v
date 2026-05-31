//=============================================================================
// sram_ctrl_simple — IS61WV25616BLL controller (icotools-style, fixed OE)
//
// KEY: oe_n=0 in IDLE (FPGA Hi-Z). Only oe_n=1 during WRITE data phases.
// SB_IO OUTPUT_ENABLE = oe_n (registered, 1-cycle latency).
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

    assign sram_ce_n = 1'b0;
    assign sram_lb_n = 1'b0;
    assign sram_ub_n = 1'b0;

    reg oe_n, we_n;
    assign sram_oe_n = oe_n;
    assign sram_we_n = we_n;

    localparam ST_IDLE   = 4'd0;
    localparam ST_TURN   = 4'd1;
    localparam ST_RD0    = 4'd2;
    localparam ST_RD0_W  = 4'd3;
    localparam ST_RD1    = 4'd4;
    localparam ST_RD1_W  = 4'd5;
    localparam ST_WR0    = 4'd6;
    localparam ST_WR0_W  = 4'd7;
    localparam ST_WR0_E  = 4'd8;
    localparam ST_WR1    = 4'd9;
    localparam ST_WR1_W  = 4'd10;
    localparam ST_WR1_E  = 4'd11;
    localparam ST_DONE   = 4'd12;

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
            oe_n <= 0; we_n <= 1; sram_dout <= 0;
        end else begin
            done <= 0; rdata_valid <= 0;
            case (state)
                ST_IDLE: begin
                    oe_n <= 0; we_n <= 1;
                    if (req && !busy) begin
                        addr_r <= word_addr; wdata_r <= wdata;
                        busy <= 1;
                        if (wr) begin
                            sram_dout <= wdata[15:0];
                            oe_n <= 1;
                            state <= ST_TURN;
                        end else begin
                            state <= ST_RD0;
                        end
                    end
                end
                ST_TURN: begin
                    we_n <= 0; state <= ST_WR0;
                end
                ST_WR0:   state <= ST_WR0_W;
                ST_WR0_W: state <= ST_WR0_E;
                ST_WR0_E: begin
                    we_n <= 1; addr_r <= next_word;
                    sram_dout <= wdata_r[31:16];
                    state <= ST_WR1;
                end
                ST_WR1:   begin we_n <= 0; state <= ST_WR1_W; end
                ST_WR1_W: state <= ST_WR1_E;
                ST_WR1_E: begin
                    we_n <= 1; oe_n <= 0;
                    state <= ST_DONE;
                end
                ST_RD0:   state <= ST_RD0_W;
                ST_RD0_W: begin
                    rdata[15:0] <= sram_din;
                    oe_n <= 1; addr_r <= next_word;
                    state <= ST_RD1;
                end
                ST_RD1:   begin oe_n <= 0; state <= ST_RD1_W; end
                ST_RD1_W: begin
                    rdata[31:16] <= sram_din;
                    oe_n <= 1; state <= ST_DONE;
                end
                ST_DONE: begin
                    oe_n <= 0; done <= 1; busy <= 0;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
