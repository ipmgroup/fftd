//=============================================================================
// mul_bench — Standalone multiplier timing benchmark for ICE40HX4K
//
// Tests: signed 16×16=32-bit multiply (same as fft_core butterfly)
//        3-stage pipeline: reg → mul → reg → round+shift → reg
//
// ICE40HX4K spec: internal logic up to 275 MHz on global buffer clock
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module mul_bench (
    input  wire        clk_100mhz,
    output wire        led1,
    output wire        led2,
    output wire        led3
);

    // PLL: 100 MHz → variable (test different frequencies)
    // Start at 50 MHz, then increase towards 275 MHz limit
    wire clk;
    SB_PLL40_PAD #(
        .FEEDBACK_PATH("SIMPLE"),
        .DIVR(4'b0000),         // ÷1 → Fref=100 MHz
        .DIVF(7'b0000111),      // ×8 → Fvco=800 MHz
        .DIVQ(3'b100),          // ÷16 → Fout=50 MHz
        .FILTER_RANGE(3'b001)
    ) pll_inst (
        .PACKAGEPIN    (clk_100mhz),
        .PLLOUTGLOBAL  (clk),
        .RESETB        (1'b1),
        .BYPASS        (1'b0)
    );

    // Reset
    reg [7:0] rst_cnt = 0;
    reg       rst_n = 0;
    always @(posedge clk) begin
        if (rst_cnt != 8'hFF) rst_cnt <= rst_cnt + 1;
        rst_n <= (rst_cnt == 8'hFF);
    end

    // ═════════════════════════════════════════════
    // Multiplier pipeline: a×b → round → output
    // Same as fft_core butterfly:
    //   mul_o <= mul_a * mul_b + mul_c;
    //   mul_rnd = mul_o + 32'h00004000;
    //   result = mul_rnd >>> 15;
    // ═════════════════════════════════════════════

    reg  signed [15:0] mul_a, mul_b;
    reg  signed [15:0] mul_c;
    reg  signed [31:0] mul_o;
    wire signed [31:0] mul_rnd = mul_o + 32'sh00004000;
    reg  signed [15:0] result;

    // LFSR-based test pattern generator (pseudo-random Q1.15 values)
    reg [31:0] lfsr = 32'hDEADBEEF;
    wire [31:0] lfsr_next = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

    // Pipeline:
    // Stage 1: latch inputs + start multiply
    // Stage 2: latch multiply result + round
    // Stage 3: latch final result

    reg signed [15:0] a_s1, b_s1, c_s1;

    always @(posedge clk) begin
        if (!rst_n) begin
            {mul_a, mul_b, mul_c} <= 0;
            {a_s1, b_s1, c_s1} <= 0;
            mul_o <= 0;
            result <= 0;
            lfsr  <= 32'hDEADBEEF;
        end else begin
            // Generate new random inputs each cycle
            lfsr <= lfsr_next;

            // Stage 0 → 1: register inputs
            mul_a <= lfsr[15:0];         // Q1.15
            mul_b <= lfsr[31:16];        // Q1.15
            mul_c <= lfsr[7:0];          // small offset (simulates MAC)

            // Stage 1 → 2: multiply + round
            mul_o <= mul_a * mul_b + mul_c;

            // Stage 2 → 3: round + shift
            result <= mul_rnd >>> 15;
        end
    end

    // Prevent optimization: accumulate results
    reg [31:0] debug_acc = 0;
    always @(posedge clk) begin
        if (rst_n)
            debug_acc <= debug_acc + result;
    end

    assign led1 = debug_acc[0];
    assign led2 = debug_acc[1];
    assign led3 = rst_n;
endmodule
