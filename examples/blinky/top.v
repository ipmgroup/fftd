//===========================================================================
// Blinky — Test project for ICEZero (ICE40HX4K-TQ144)
// Adapted from cliffordwolf/icotools examples/blinky
//
// LEDs: FPGA pins 120 (red), 117 (green), 121 (blue) — XTRA header J1
// Clock: 100 MHz on-board oscillator on pin 35
//===========================================================================

module top (
    input  clk,            // 100 MHz (pin 35)
    output led1,           // Red   — FPGA pin 120
    output led2,           // Green — FPGA pin 117
    output led3            // Blue  — FPGA pin 121
);

    // ── 26-bit Counter ─────────────────────────────
    // 100 MHz / 2^26 ≈ 1.49 Hz toggle on bit 25
    reg [25:0] counter = 0;

    always @(posedge clk) begin
        counter <= counter + 1;
    end

    // ── LED Drivers (different blink patterns) ──────
    assign led1 = counter[25];                     // ~0.75 Hz
    assign led2 = counter[24];                     // ~1.49 Hz
    assign led3 = counter[25] ^ counter[24];       // alternating pattern

endmodule
