// Stub for iverilog simulation — SB_PLL40_PAD bypass
`timescale 1ns / 1ps

module SB_PLL40_PAD #(
    parameter FEEDBACK_PATH = "SIMPLE",
    parameter DIVR = 4'b0000,
    parameter DIVF = 7'b0000000,
    parameter DIVQ = 3'b000,
    parameter FILTER_RANGE = 3'b001
) (
    input  PACKAGEPIN,
    output PLLOUTGLOBAL,
    output PLLOUTCORE,
    input  RESETB,
    input  BYPASS
);
    assign PLLOUTGLOBAL = PACKAGEPIN;
    assign PLLOUTCORE   = PACKAGEPIN;
endmodule

// Stub for SB_PLL40_2F_PAD: port A = passthrough (GENCLK), port B = /2
// (GENCLK_HALF). Phase-aligned divide-by-two on PACKAGEPIN.
module SB_PLL40_2F_PAD #(
    parameter FEEDBACK_PATH = "SIMPLE",
    parameter DIVR = 4'b0000,
    parameter DIVF = 7'b0000000,
    parameter DIVQ = 3'b000,
    parameter FILTER_RANGE = 3'b001,
    parameter PLLOUT_SELECT_PORTA = "GENCLK",
    parameter PLLOUT_SELECT_PORTB = "GENCLK_HALF"
) (
    input  PACKAGEPIN,
    output PLLOUTGLOBALA,
    output PLLOUTCOREA,
    output PLLOUTGLOBALB,
    output PLLOUTCOREB,
    input  RESETB,
    input  BYPASS
);
    assign PLLOUTGLOBALA = PACKAGEPIN;
    assign PLLOUTCOREA   = PACKAGEPIN;

    reg div2 = 1'b0;
    always @(posedge PACKAGEPIN) div2 <= ~div2;
    assign PLLOUTGLOBALB = div2;
    assign PLLOUTCOREB   = div2;
endmodule
