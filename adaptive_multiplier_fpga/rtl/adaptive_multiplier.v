// adaptive_multiplier.v
//
// Top level of the reconfigurable approximate multiplier (FPGA/sim top).
//
//   mode = 2'b00 : EXACT              width = 0
//   mode = 2'b01 : APPROX, low power  width = W/2 - k,  k = ALPHA_LP * Pth   (small slope)
//   mode = 2'b10 : APPROX, high acc.  width = W/2 - k,  k = ALPHA_HA * Pth   (large slope)
//   mode = 2'b11 : ADAPTIVE           width = min(req_width, dynamic_ceiling)
//                                     from the closed-loop mode11_supervisor
//
// One shared datapath (approx_mult) serves all four modes; modes 01/10 are
// the same equation with two alpha tunings, and mode 11 is a small
// supervisor on top of the same datapath (not a fourth multiplier).
//
// Unifying equation:  width(Pth) = W/2 - k(Pth),  k(Pth) = alpha * Pth
//   W     = total operand bits (A and B together) = 2N, so W/2 = N
//   k     saturates at W/2, so width is in [0, W/2] for modes 01/10
//   alpha = ALPHA_xx / 2^ALPHA_FRAC  (fixed point)
//   Larger Pth -> larger k -> smaller width -> less error, more power.
//   Mode 00 is the k = W/2 endpoint (width = 0), routed via the exact path.
//
// Pipeline (2 stages, 1 op/cycle):
//   stage 1: register inputs
//   stage 2: width select + multiply (combinational) -> register outputs
// Latency = 2 clocks from in_valid to out_valid.

`timescale 1ns/1ps

module adaptive_multiplier #(
    parameter integer N             = 8,
    parameter integer PTH_W         = 4,      // Pth input width
    parameter integer ALPHA_FRAC    = 2,      // alpha fixed-point fraction bits
    parameter integer ALPHA_LP      = 2,      // mode 01: alpha = 2/4 = 0.5  (small slope)
    parameter integer ALPHA_HA      = 8,      // mode 10: alpha = 8/4 = 2.0  (large slope)
    // mode-11 supervisor knobs (see mode11_supervisor.v)
    parameter integer CAL_PERIOD    = 20,
    parameter integer DAMPING_SHIFT = 3,
    parameter integer NMED_CEIL     = 20000   // 2% NMED
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     in_valid,
    input  wire [1:0]               mode,
    input  wire [PTH_W-1:0]         pth,        // power threshold (modes 01/10)
    input  wire [$clog2(2*N):0]     req_width,  // requested width / power pressure (mode 11)
    input  wire [N-1:0]             a,
    input  wire [N-1:0]             b,
    output reg                      out_valid,
    output reg  [2*N-1:0]           product,
    output reg  [$clog2(2*N):0]     width_used,
    output wire [11:0]              drift_estimate,  // mode-11 drift, Q4.8 (256 = 1.0x)
    output wire                     cal_event        // mode-11 calibration sample taken
);

    localparam integer WB   = $clog2(2*N) + 1;
    localparam integer HALF = N;                     // W/2 with W = 2N

    // ---------------- stage 1: input registers ----------------
    reg             v_r;
    reg [1:0]       mode_r;
    reg [PTH_W-1:0] pth_r;
    reg [WB-1:0]    req_r;
    reg [N-1:0]     a_r, b_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_r <= 1'b0; mode_r <= 2'b00; pth_r <= {PTH_W{1'b0}};
            req_r <= {WB{1'b0}}; a_r <= {N{1'b0}}; b_r <= {N{1'b0}};
        end else begin
            v_r <= in_valid;
            if (in_valid) begin
                mode_r <= mode; pth_r <= pth; req_r <= req_width;
                a_r <= a; b_r <= b;
            end
        end
    end

    // ---------------- modes 01/10: width = W/2 - alpha*Pth ----------------
    localparam integer KRW = PTH_W + 8;
    /* verilator lint_off WIDTH */
    localparam [KRW-1:0] A_LP   = ALPHA_LP;
    localparam [KRW-1:0] A_HA   = ALPHA_HA;
    localparam [KRW-1:0] HALF_K = HALF;
    localparam [WB-1:0]  HALF_W = HALF;
    /* verilator lint_on WIDTH */
    wire [KRW-1:0] pth_ext  = {{(KRW-PTH_W){1'b0}}, pth_r};
    wire [KRW-1:0] k_lp_raw = (pth_ext * A_LP) >> ALPHA_FRAC;
    wire [KRW-1:0] k_ha_raw = (pth_ext * A_HA) >> ALPHA_FRAC;
    wire [WB-1:0]  k_lp = (k_lp_raw > HALF_K) ? HALF_W : k_lp_raw[WB-1:0];   // saturate k at W/2
    wire [WB-1:0]  k_ha = (k_ha_raw > HALF_K) ? HALF_W : k_ha_raw[WB-1:0];
    wire [WB-1:0]  width_lp = HALF_W - k_lp;
    wire [WB-1:0]  width_ha = HALF_W - k_ha;

    // ---------------- mode 11: closed-loop supervisor ----------------
    wire [WB-1:0]    width_m11;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [WB-1:0]    ceil_m11;          // debug: visible in waveforms
    /* verilator lint_on UNUSEDSIGNAL */
    wire [2*N-1:0]   p_approx, p_exact;

    mode11_supervisor #(
        .N(N), .CAL_PERIOD(CAL_PERIOD), .DAMPING_SHIFT(DAMPING_SHIFT),
        .NMED_CEIL(NMED_CEIL)
    ) u_sup (
        .clk(clk), .rst_n(rst_n),
        .enable(mode_r == 2'b11), .op_valid(v_r),
        .desired_width(req_r),
        .mult_product(p_approx), .mult_exact(p_exact),
        .width_out(width_m11), .dynamic_ceiling(ceil_m11),
        .drift_estimate(drift_estimate), .cal_event(cal_event)
    );

    // ---------------- width select ----------------
    reg [WB-1:0] width_sel;
    always @(*) begin
        case (mode_r)
            2'b00:   width_sel = {WB{1'b0}};
            2'b01:   width_sel = width_lp;
            2'b10:   width_sel = width_ha;
            default: width_sel = width_m11;
        endcase
    end

    // ---------------- shared datapath ----------------
    approx_mult #(.N(N)) u_mult (
        .a(a_r), .b(b_r), .width(width_sel),
        .product(p_approx), .exact_product(p_exact)
    );

    // ---------------- stage 2: output registers ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid  <= 1'b0;
            product    <= {2*N{1'b0}};
            width_used <= {WB{1'b0}};
        end else begin
            out_valid <= v_r;
            if (v_r) begin
                product    <= (mode_r == 2'b00) ? p_exact : p_approx;  // mode 00 = exact path
                width_used <= width_sel;
            end
        end
    end

endmodule
