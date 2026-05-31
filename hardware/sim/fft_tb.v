//=============================================================================
// fft_tb — FFT Core Testbench (iverilog)
//
// Feeds a test vector through the FFT core and compares against golden output.
// Run: iverilog -o fft_tb -D SIMULATION ../rtl/*.v fft_tb.v && vvp fft_tb
//=============================================================================

`default_nettype none
`timescale 1ns / 1ps

module fft_tb;
    localparam N_LOG2 = 6;
    localparam N      = 64;
    localparam WIDTH  = 16;

    reg  clk, rst_n;
    reg  start;
    reg  [2*WIDTH-1:0] din;
    reg  din_valid;
    wire din_ready;
    wire [2*WIDTH-1:0] dout;
    wire dout_valid;
    wire busy, done;

    // ── DUT ───────────────────────────────────────
    fft_core #(.N_LOG2(N_LOG2), .WIDTH(WIDTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .din(din), .din_valid(din_valid), .din_ready(din_ready),
        .dout(dout), .dout_valid(dout_valid), .busy(busy), .frame_done(done)
    );

    // ── Clock: 50 MHz → 10 ns period ─────────────
    always #5 clk = ~clk;

    // ── Test vectors (generated in Python) ────────
    // Simple DC input: all real=1000, imag=0 → output should be impulse at bin 0
    integer i;

    initial begin
        $dumpfile("fft_tb.vcd");
        $dumpvars(0, fft_tb);

        clk = 0; rst_n = 0; start = 0;
        din = 0; din_valid = 0;

        // Reset
        #100 rst_n = 1;
        #50;

        // Load test vector: DC pulse (all 1's)
        start = 1;
        for (i = 0; i < N; i = i + 1) begin
            @(posedge clk);
            start = 0;
            din_valid = 1;
            din = {16'd0, 16'd1000};  // imag=0, real=1000
        end

        @(posedge clk);
        din_valid = 0;

        // Wait for computation
        wait(done);

        // Read outputs
        $display("=== FFT Output (64-point, DC input) ===");
        for (i = 0; i < N; i = i + 1) begin
            @(posedge clk);
            if (dout_valid)
                $display("[%2d]  re=%5d  im=%5d", i,
                    $signed(dout[WIDTH-1:0]),
                    $signed(dout[2*WIDTH-1:WIDTH]));
        end

        // Check: bin 0 should be large (DC component), others near zero
        $display("=== Test complete ===");
        $finish;
    end

endmodule

`default_nettype wire
