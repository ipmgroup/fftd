//=============================================================================
// twiddle_rom — 64-point FFT Twiddle Factor ROM (BRAM, synchronous read)
//
// N=64 → 63 unique twiddle factors (W^1 .. W^{N/2-1}, DC/Nyquist)
// Values: Q1.15  {imag[15:0], real[15:0]}
// Uses SB_RAM40_4K via $readmemh — 0 LUT cost.
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module twiddle_rom #(
    parameter N        = 32,
    parameter WIDTH    = 16,
    parameter HEX_FILE = "twiddle.hex"
) (
    input  wire                  clk,
    input  wire [$clog2(N-1)-1:0] addr,
    output reg  [2*WIDTH-1:0]    dout
);

    localparam DEPTH = N - 1;  // 63 entries

    (* syn_ramstyle = "block_ram" *)
    reg [2*WIDTH-1:0] mem [0:DEPTH-1];

    // Initialize BRAM from hex file at synthesis time
    initial $readmemh(HEX_FILE, mem);

    always @(posedge clk)
        dout <= mem[addr];

endmodule

`default_nettype wire
