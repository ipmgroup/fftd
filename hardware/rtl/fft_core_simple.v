//=============================================================================
// fft_core_simple — Minimal Radix-2 DIT FFT for test bench verification
//
// 64-point, 16-bit, 1 multiplier. Synchronous BRAM only.
// S_LOAD → butterflies → S_DONE.
// No external ports except what's needed for the test.
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module fft_core_simple #(
    parameter N_LOG2 = 6,
    parameter WIDTH  = 16
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                start,
    input  wire [2*WIDTH-1:0] din,
    input  wire                din_valid,
    output wire                din_ready,
    output reg                 busy,
    output reg                 frame_done,
    // Test bench read port (synchronous: set addr, wait 2 cycles, read data)
    input  wire [AW-1:0]      tb_rd_addr,
    output wire [2*WIDTH-1:0] tb_rd_data
);

    localparam N     = 1 << N_LOG2;
    localparam AW    = N_LOG2;

    // ── BRAM ──────────────────────────────────────
    reg [2*WIDTH-1:0] bram [0:N-1];
    reg [AW-1:0]      bram_ra, bram_rb;
    reg [2*WIDTH-1:0] bram_rd_a, bram_rd_b;

    // BRAM registered read port (no async reset → clean simulation)
    always @(posedge clk) begin
        bram_rd_a <= bram[bram_ra];
        bram_rd_b <= bram[bram_rb];
    end

    // ── Twiddle ROM ────────────────────────────────
    localparam TW_N = N - 1;
    wire [$clog2(TW_N)-1:0] tw_addr;
    wire [2*WIDTH-1:0] tw_data;
    wire [WIDTH-1:0]   tw_re = tw_data[WIDTH-1:0];
    wire [WIDTH-1:0]   tw_im = tw_data[2*WIDTH-1:WIDTH];

    twiddle_rom #(.N(N), .WIDTH(WIDTH), .HEX_FILE("twiddle_64.hex")) tw_inst (
        .clk(clk), .addr(tw_addr), .dout(tw_data)
    );

    // ── States ────────────────────────────────────
    localparam S_IDLE  = 3'd0;
    localparam S_LOAD  = 3'd1;
    localparam S_BF    = 3'd2;  // one butterfly pass
    localparam S_DONE  = 3'd3;

    reg [2:0] state;
    reg [AW-1:0] idx;
    reg [$clog2(N_LOG2)-1:0] pass;
    reg [$clog2(N/2)-1:0]    bf;

    assign din_ready = (state == S_LOAD);

    // ── Address generation ────────────────────────
    wire [AW-1:0] step  = 1 << pass;
    wire [AW-1:0] base  = (bf >> pass) << (pass + 1);
    wire [AW-1:0] upper = base + (bf & (step - 1));
    wire [AW-1:0] lower = upper + step;
    assign tw_addr = ((1 << pass) - 1) + (bf & ((1 << pass) - 1));

    // ── Single multiplier ─────────────────────────
    reg  signed [WIDTH-1:0] mul_a, mul_b;
    reg  signed [31:0]      mul_o;
    always @(posedge clk) mul_o <= mul_a * mul_b;

    // ── Butterfly pipeline ────────────────────────
    reg signed [WIDTH-1:0] u_re, u_im, l_re, l_im;
    reg signed [WIDTH-1:0] m0, m1, m2, m3;  // 4 partial products
    reg [AW-1:0]           wu, wl;           // write addresses

    wire signed [WIDTH-1:0] lw_re = m0 - m1;
    wire signed [WIDTH-1:0] lw_im = m2 + m3;
    wire signed [WIDTH-1:0] sum_re = u_re + lw_re;
    wire signed [WIDTH-1:0] sum_im = u_im + lw_im;
    wire signed [WIDTH-1:0] dif_re = u_re - lw_re;
    wire signed [WIDTH-1:0] dif_im = u_im - lw_im;

    // ── Butterfly sub-states ──────────────────────
    reg [3:0] bf_st;  // 0=rd, 1-4=mul, 5=wr_sum, 6=wr_dif, 7=advance

    // ── FSM ───────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            busy     <= 0;
            frame_done <= 0;
            {idx, pass, bf} <= 0;
            {mul_a, mul_b} <= 0;
            {u_re, u_im, l_re, l_im} <= 0;
            {m0, m1, m2, m3} <= 0;
            {wu, wl} <= 0;
            bf_st <= 0;
        end else begin
            frame_done <= 0;

            case (state)

                S_IDLE: begin
                    if (start) begin
                        state <= S_LOAD;
                        idx   <= 0;
                        busy  <= 1;
                    end
                end

                S_LOAD: begin
                    if (din_valid) begin
                        bram[bit_reverse(idx)] <= din;
                        if (idx == N - 1) begin
                            state <= S_BF;
                            pass  <= 0;
                            bf    <= 0;
                            bf_st <= 0;
                        end else begin
                            idx <= idx + 1;
                        end
                    end
                end

                S_BF: begin
                    case (bf_st)
                        0: begin  // read BRAM
                            bram_ra <= upper;
                            bram_rb <= lower;
                            wu <= upper;
                            wl <= lower;
                            bf_st <= 1;
                        end
                        1: begin  // latch data, start M0
                            u_re  <= bram_rd_a[WIDTH-1:0];
                            u_im  <= bram_rd_a[2*WIDTH-1:WIDTH];
                            l_re  <= bram_rd_b[WIDTH-1:0];
                            l_im  <= bram_rd_b[2*WIDTH-1:WIDTH];
                            mul_a <= bram_rd_b[WIDTH-1:0];  // l_re
                            mul_b <= tw_re;
                            bf_st <= 2;
                        end
                        2: begin m0 <= $signed(mul_o)>>>15; mul_a <= l_im;  mul_b <= tw_im; bf_st <= 3; end
                        3: begin m1 <= $signed(mul_o)>>>15; mul_a <= l_re;  mul_b <= tw_im; bf_st <= 4; end
                        4: begin m2 <= $signed(mul_o)>>>15; mul_a <= l_im;  mul_b <= tw_re; bf_st <= 5; end
                        5: begin  // latch m3, prepare write sum next cycle
                            m3    <= $signed(mul_o)>>>15;
                            bf_st <= 6;
                        end
                        6: begin  // write sum (m3 now valid)
                            bram[wu] <= {sum_im, sum_re};
                            bf_st <= 7;
                        end
                        7: begin  // write diff
                            bram[wl] <= {dif_im, dif_re};
                            bf_st <= 8;
                        end
                        8: begin  // advance
                            if (bf == (N/2) - 1) begin
                                bf <= 0;
                                if (pass == N_LOG2 - 1) begin
                                    state <= S_DONE;
                                    frame_done <= 1;
                                    busy <= 0;
                                end else begin
                                    pass <= pass + 1;
                                    bf_st <= 0;
                                end
                            end else begin
                                bf <= bf + 1;
                                bf_st <= 0;
                            end
                        end
                    endcase
                end

                S_DONE: begin
                    // Stay in S_DONE — test bench reads BRAM then pulses start for next run
                end

            endcase
        end
    end

    // ── Test bench read port ──────────────────────
    reg [AW-1:0] tb_rd_r1;
    always @(posedge clk) begin
        tb_rd_r1 <= tb_rd_addr;
    end
    assign tb_rd_data = bram[tb_rd_r1];

    function [AW-1:0] bit_reverse;
        input [AW-1:0] in; integer i;
        begin
            bit_reverse = 0;
            for (i = 0; i < N_LOG2; i = i + 1)
                bit_reverse[i] = in[N_LOG2 - 1 - i];
        end
    endfunction

endmodule

`default_nettype wire
