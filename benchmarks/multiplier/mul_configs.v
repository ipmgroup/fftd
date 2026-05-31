//=============================================================================
// mul_configs — Compare 4 multiplier configurations for ICE40HX4K Fmax
//
// Config 0: a*b only (pure multiply, no MAC)
// Config 1: a*b + c (MAC, current fft_core)
// Config 2: a*b then +c (2-stage pipelined MAC)
// Config 3: a*b with SB_MAC16 hint
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module mul_configs #(
    parameter CONFIG = 1      // 0=mult, 1=mac, 2=pipelined, 3=sb_mac16
) (
    input  wire        clk_100mhz,
    output wire        led1, led2, led3
);

    wire clk;
    SB_PLL40_PAD #(
        .FEEDBACK_PATH("SIMPLE"),
        .DIVR(4'b0000), .DIVF(7'b0000111), .DIVQ(3'b100),
        .FILTER_RANGE(3'b001)
    ) pll_inst (.PACKAGEPIN(clk_100mhz), .PLLOUTGLOBAL(clk), .RESETB(1'b1), .BYPASS(1'b0));

    reg [7:0] rst_cnt = 0; reg rst_n = 0;
    always @(posedge clk) begin
        if (rst_cnt != 8'hFF) rst_cnt <= rst_cnt + 1;
        rst_n <= (rst_cnt == 8'hFF);
    end

    // Test pattern: LFSR
    reg [31:0] lfsr = 32'hDEADBEEF;
    wire [31:0] lfsr_next = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

    reg signed [15:0] a, b, c;
    reg signed [31:0] result = 0;
    reg [31:0] debug_acc = 0;

    generate
        if (CONFIG == 0) begin : mult_only
            // Pure multiply: a*b
            reg signed [31:0] mul_o;
            always @(posedge clk) begin
                if (!rst_n) begin
                    {a, b} <= 0; mul_o <= 0; debug_acc <= 0;
                end else begin
                    lfsr <= lfsr_next;
                    a <= lfsr[15:0];
                    b <= lfsr[31:16];
                    mul_o <= a * b;
                    debug_acc <= debug_acc + mul_o[31:16];
                end
            end
        end else if (CONFIG == 1) begin : mac
            // MAC: a*b + c (same as fft_core butterfly)
            reg signed [31:0] mul_o;
            always @(posedge clk) begin
                if (!rst_n) begin
                    {a, b, c} <= 0; mul_o <= 0; debug_acc <= 0;
                end else begin
                    lfsr <= lfsr_next;
                    a <= lfsr[15:0];
                    b <= lfsr[31:16];
                    c <= lfsr[7:0];
                    mul_o <= a * b + c;
                    debug_acc <= debug_acc + mul_o[31:16];
                end
            end
        end else if (CONFIG == 2) begin : pipelined
            // 2-stage pipelined MAC: Stage1=multiply, Stage2=accumulate
            reg signed [31:0] mul_tmp;
            reg signed [15:0] c_s1;
            reg signed [31:0] mul_o;
            always @(posedge clk) begin
                if (!rst_n) begin
                    {a, b, c} <= 0; c_s1 <= 0; mul_tmp <= 0; mul_o <= 0; debug_acc <= 0;
                end else begin
                    lfsr <= lfsr_next;
                    a <= lfsr[15:0];
                    b <= lfsr[31:16];
                    c <= lfsr[7:0];
                    c_s1 <= c;
                    mul_tmp <= a * b;              // Stage 1: multiply
                    mul_o <= mul_tmp + c_s1;       // Stage 2: accumulate
                    debug_acc <= debug_acc + mul_o[31:16];
                end
            end
        end else if (CONFIG == 3) begin : sb_mac16
            // SB_MAC16 inference attempt
            (* mul2dsp *) reg signed [31:0] mul_o;
            always @(posedge clk) begin
                if (!rst_n) begin
                    {a, b, c} <= 0; mul_o <= 0; debug_acc <= 0;
                end else begin
                    lfsr <= lfsr_next;
                    a <= lfsr[15:0];
                    b <= lfsr[31:16];
                    c <= lfsr[7:0];
                    mul_o <= a * b + c;
                    debug_acc <= debug_acc + mul_o[31:16];
                end
            end
        end
    endgenerate

    assign led1 = debug_acc[0];
    assign led2 = debug_acc[1];
    assign led3 = rst_n;
endmodule
