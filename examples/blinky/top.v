//===========================================================================
// Blinky — Running LED (ping-pong) for ICEZero (ICE40HX4K-TQ144)
//
// LEDs: FPGA pins 110 (red), 93 (green), 94 (blue) — on-board user LEDs
// Clock: 100 MHz on-board oscillator on pin 49 (GBIN6)
//
// Pattern: red → green → blue → green → red → ...  (~6 steps/sec)
//===========================================================================

module top (
    input  clk,            // 100 MHz (pin 49, GBIN6)
    output led1,           // Red   — FPGA pin 110
    output led2,           // Green — FPGA pin 93
    output led3            // Blue  — FPGA pin 94
);

    // ── Counter: each LED step lasts 2^24 clocks = ~168 ms @ 100 MHz ──
    reg [25:0] counter = 0;

    always @(posedge clk)
        counter <= counter + 1;

    // ── 4-state ping-pong using top 2 bits ─────────
    // 00 → led1 (red)
    // 01 → led2 (green)
    // 10 → led3 (blue)
    // 11 → led2 (green)  ← reverse
    wire [1:0] state = counter[25:24];

    assign led1 = (state == 2'b00);
    assign led2 = (state == 2'b01) || (state == 2'b11);
    assign led3 = (state == 2'b10);

endmodule
