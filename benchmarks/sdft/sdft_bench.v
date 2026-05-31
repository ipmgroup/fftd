// Minimal SDFT wrapper for synthesis benchmarking (ICE40HX4K)
`default_nettype none

module sdft_bench (
    input  wire        clk_100mhz,
    output wire        led1,
    output wire        led2,
    output wire        led3
);

    // PLL: 100 MHz → 50 MHz
    wire clk;
    SB_PLL40_PAD #(
        .FEEDBACK_PATH("SIMPLE"),
        .DIVR(4'b0000),
        .DIVF(7'b0000111),
        .DIVQ(3'b100),
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

    // Parameters: match kelu124 SDFT defaults
    localparam DATA_WIDTH = 8;
    localparam FREQ_BINS  = 16;
    localparam FREQ_W     = 20;
    localparam BIN_ADDR_W = $clog2(FREQ_BINS);

    wire sdft_ready;
    reg  sdf_start = 0;
    reg  [DATA_WIDTH-1:0] sample = 0;
    wire signed [FREQ_W-1:0] bin_real, bin_imag;

    sdft #(
        .data_width(DATA_WIDTH),
        .freq_bins(FREQ_BINS),
        .freq_w(FREQ_W)
    ) sdft_0 (
        .clk          (clk),
        .sample       (sample),
        .start        (sdf_start),
        .read         (1'b0),
        .ready        (sdft_ready),
        .bin_out_real (bin_real),
        .bin_out_imag (bin_imag),
        .bin_addr     (4'd0)
    );

    // Simple FSM: feed 32 samples, then hold
    reg [5:0] sample_cnt = 0;
    reg       running = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            sdf_start  <= 0;
            sample     <= 0;
            sample_cnt <= 0;
            running    <= 0;
        end else begin
            if (!running) begin
                sdf_start <= 1;
                running   <= 1;
                sample    <= 8'd10;  // DC input
            end else if (sdft_ready) begin
                sdf_start <= 0;
                if (sample_cnt < FREQ_BINS - 1) begin
                    sample_cnt <= sample_cnt + 1;
                    sample <= sample + 1;  // ramp
                end
            end
        end
    end

    // Prevent optimisation: accumulate bin outputs
    reg [31:0] debug_acc = 0;
    always @(posedge clk) begin
        if (sdft_ready)
            debug_acc <= debug_acc + bin_real + bin_imag;
    end

    // LEDs
    assign led1 = debug_acc[0];
    assign led2 = debug_acc[1];
    assign led3 = rst_n;
endmodule
