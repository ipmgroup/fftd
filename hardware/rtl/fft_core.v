//=============================================================================
// fft_core — Radix-2 DIT FFT. SINGLE always block — no races.
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module fft_core #(
    parameter N_LOG2 = 5,
    parameter WIDTH  = 16
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                start,
    input  wire [2*WIDTH-1:0] din,
    input  wire                din_valid,
    output wire                din_ready,
    output reg  [2*WIDTH-1:0] dout,
    output reg                 dout_valid,
    output reg                 busy,
    output reg                 frame_done,
    input  wire [N_LOG2-1:0]   ext_rd_addr,
    output reg  [2*WIDTH-1:0]  ext_rd_data
);

    localparam N     = 1 << N_LOG2;
    localparam AW    = N_LOG2;
    localparam BF_N  = N / 2;

    (* syn_ramstyle = "block_ram" *) reg [2*WIDTH-1:0] bram [0:N-1];
    reg [AW-1:0]      bram_rd_a, bram_rd_b, bram_wr;
    reg [2*WIDTH-1:0] bram_wdata;
    reg               bram_we;
    reg [2*WIDTH-1:0] rd_a, rd_b;

    // BRAM port A/B — separate always block (no async reset) so Yosys infers SB_RAM40_4K
    always @(posedge clk) begin
        if (bram_we) bram[bram_wr] <= bram_wdata;
        rd_a <= bram[bram_rd_a];
        rd_b <= bram[bram_rd_b];
    end

    // External read port — separate BRAM instance
    (* syn_ramstyle = "block_ram" *) reg [2*WIDTH-1:0] bram_ext [0:N-1];
    reg [AW-1:0]  bram_ext_wr;
    reg [2*WIDTH-1:0] bram_ext_wdata;
    reg               bram_ext_we;
    always @(posedge clk) begin
        if (bram_ext_we) bram_ext[bram_ext_wr] <= bram_ext_wdata;
        ext_rd_data <= bram_ext[ext_rd_addr];
    end

    localparam TW_N = N - 1;
    localparam TW_AW = $clog2(TW_N);
    wire [TW_AW-1:0]   tw_addr;
    wire [2*WIDTH-1:0] tw_data;
    wire [WIDTH-1:0]   tw_re = tw_data[WIDTH-1:0];
    wire [WIDTH-1:0]   tw_im = tw_data[2*WIDTH-1:WIDTH];

    twiddle_rom #(.N(N), .WIDTH(WIDTH)) tw_inst (
        .clk(clk), .addr(tw_addr), .dout(tw_data)
    );

    localparam S_IDLE    = 4'd0;
    localparam S_LOAD    = 4'd1;
    localparam S_LOAD_DONE = 4'd2;
    localparam S_BF_RD   = 4'd3;
    localparam S_BF_M0   = 4'd4;
    localparam S_BF_M1   = 4'd5;
    localparam S_BF_M2   = 4'd6;
    localparam S_BF_M3   = 4'd7;
    localparam S_BF_M4   = 4'd8;
    localparam S_BF_M5   = 4'd9;
    localparam S_BF_SUM  = 4'd10;
    localparam S_BF_WR   = 4'd11;
    localparam S_BF_WR2  = 4'd12;
    localparam S_UNLOAD  = 4'd13;

    reg [3:0]   state;
    reg [AW-1:0] idx;
    reg [$clog2(N_LOG2+1)-1:0] pass;
    reg [$clog2(BF_N+1)-1:0]   bf_idx;

    assign din_ready = (state == S_LOAD);

    // Counter-based butterfly addressing (no barrel shifters!)
    reg [AW-1:0] upper, lower;      // current butterfly addresses
    reg [AW-1:0] step;              // = 1 << pass
    reg [AW-1:0] tw_cnt;            // twiddle offset within group
    reg [AW-1:0] bf_in_group;       // butterflies done in current group

    assign tw_addr = ((1 << pass) - 1) + tw_cnt;

    reg  signed [WIDTH-1:0] mul_a, mul_b;
    reg  signed [WIDTH-1:0] mul_c;
    reg  signed [31:0]      mul_o;
    wire signed [31:0]      mul_rnd = mul_o + 32'sh00004000;  // round 0.5 LSB for >>15
    reg signed [WIDTH-1:0] u_re, u_im, l_re, l_im;
    reg signed [WIDTH-1:0] acc0, acc1, acc2, acc3;
    reg [AW-1:0]           wr_upper, wr_lower;  // write-back addresses (upper/lower delayed)

    wire signed [WIDTH-1:0] lw_re = acc0 - acc1;
    wire signed [WIDTH-1:0] lw_im = acc2 + acc3;
    wire signed [WIDTH-1:0] sum_re = u_re + lw_re;
    wire signed [WIDTH-1:0] sum_im = u_im + lw_im;
    wire signed [WIDTH-1:0] dif_re = u_re - lw_re;
    wire signed [WIDTH-1:0] dif_im = u_im - lw_im;

    // FSM + multiplier (no direct BRAM access — uses bram_we/wr/wdata signals)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            idx      <= 0; pass <= 0; bf_idx <= 0;
            bram_we  <= 0; dout <= 0; dout_valid <= 0;
            frame_done <= 0; busy <= 0;
            {mul_a, mul_b, mul_c} <= 0;
            {u_re, u_im, l_re, l_im} <= 0;
            {acc0, acc1, acc2, acc3} <= 0;
            {wr_upper, wr_lower} <= 0;
            {upper, lower, step, tw_cnt, bf_in_group} <= 0;
            mul_o <= 0;
            {bram_rd_a, bram_rd_b, bram_wr} <= 0;
            bram_wdata <= 0;
            bram_ext_we <= 0; bram_ext_wr <= 0; bram_ext_wdata <= 0;
        end else begin
            frame_done <= 0; dout_valid <= 0;
            bram_we <= 0; bram_ext_we <= 0;

            mul_o <= mul_a * mul_b + mul_c;

            case (state)
                S_IDLE: if (start) begin state <= S_LOAD; idx <= 0; busy <= 1; end
                S_LOAD: if (din_valid) begin
                    bram_wr <= bit_reverse(idx); bram_wdata <= din; bram_we <= 1;
                    bram_ext_wr <= bit_reverse(idx); bram_ext_wdata <= din; bram_ext_we <= 1;
                    if (idx == N - 1) state <= S_LOAD_DONE; else idx <= idx + 1;
                end
                S_LOAD_DONE: begin
                    bram_rd_a<=0; bram_rd_b<=1; pass<=0; bf_idx<=0;
                    upper<=0; lower<=1; step<=1; tw_cnt<=0; bf_in_group<=0;
                    state<=S_BF_RD;
                end
                S_BF_RD: begin wr_upper<=upper; wr_lower<=lower; state<=S_BF_M0; end
                S_BF_M0: begin
                    u_re<=rd_a[15:0]; u_im<=rd_a[31:16];
                    l_re<=rd_b[15:0]; l_im<=rd_b[31:16];
                    mul_a<=rd_b[15:0]; mul_b<=tw_re; mul_c<=0;
                    if (bf_in_group == step - 1) begin
                        bram_rd_a <= lower + 1;
                        bram_rd_b <= lower + 1 + step;
                    end else begin
                        bram_rd_a <= upper + 1;
                        bram_rd_b <= lower + 1;
                    end
                    state<=S_BF_M1;
                end
                S_BF_M1: begin mul_a<=l_im; mul_b<=tw_im; state<=S_BF_M2; end
                S_BF_M2: begin acc0<=mul_rnd>>>15; mul_a<=l_re; mul_b<=tw_im; state<=S_BF_M3; end
                S_BF_M3: begin acc1<=mul_rnd>>>15; mul_a<=l_im; mul_b<=tw_re; state<=S_BF_M4; end
                S_BF_M4: begin acc2<=mul_rnd>>>15; state<=S_BF_M5; end
                S_BF_M5: begin acc3<=mul_rnd>>>15; state<=S_BF_SUM; end
                S_BF_SUM: begin
                    bram_wr<=wr_upper; bram_wdata<={sum_im,sum_re}; bram_we<=1;
                    bram_ext_wr<=wr_upper; bram_ext_wdata<={sum_im,sum_re}; bram_ext_we<=1;
                    state<=S_BF_WR;
                end
                S_BF_WR: begin
                    bram_wr<=wr_lower; bram_wdata<={dif_im,dif_re}; bram_we<=1;
                    bram_ext_wr<=wr_lower; bram_ext_wdata<={dif_im,dif_re}; bram_ext_we<=1;
                    state<=S_BF_WR2;
                end
                S_BF_WR2: begin
                    if (bf_idx == BF_N - 1) begin
                        bf_idx<=0;
                        if (pass==N_LOG2-1) begin state<=S_UNLOAD; idx<=0; end
                        else begin
                            pass<=pass+1; step<=step<<1;
                            upper<=0; lower<=step<<1;
                            tw_cnt<=0; bf_in_group<=0;
                            bram_rd_a<=0; bram_rd_b<=step<<1;
                            state<=S_BF_RD;
                        end
                    end else begin
                        if (bf_in_group == step - 1) begin
                            upper <= lower + 1;
                            lower <= lower + 1 + step;
                            bf_in_group <= 0;
                            tw_cnt <= 0;
                        end else begin
                            upper <= upper + 1;
                            lower <= lower + 1;
                            bf_in_group <= bf_in_group + 1;
                            tw_cnt <= tw_cnt + 1;
                        end
                        bf_idx<=bf_idx+1;
                        state<=S_BF_RD;
                    end
                end
                S_UNLOAD: begin dout<=rd_a; dout_valid<=1; bram_rd_a<=idx+1; idx<=idx+1;
                    if (idx==N-1) begin state<=S_IDLE; frame_done<=1; busy<=0; end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // External read port — separate BRAM
    always @(posedge clk)
        ext_rd_data <= bram_ext[ext_rd_addr];

    function [AW-1:0] bit_reverse;
        input [AW-1:0] in; integer i;
        begin bit_reverse=0; for(i=0;i<N_LOG2;i=i+1) bit_reverse[i]=in[N_LOG2-1-i]; end
    endfunction
endmodule
`default_nettype wire
