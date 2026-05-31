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
