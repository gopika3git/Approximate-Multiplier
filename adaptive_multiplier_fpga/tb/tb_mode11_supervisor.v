// tb_mode11_supervisor.v
//
// Closed-loop vs open-loop co-simulation (the paper's headline experiment).
// Run from the project root.
//
// Two complete adaptive_multiplier instances, both in mode 11, run side by
// side on the SAME operand stream:
//
//   ADAPTIVE : supervisor with periodic calibration (CAL_PERIOD = 20)
//   STATIC   : identical RTL, calibration effectively disabled
//              (CAL_PERIOD = 1_000_000) -> LUT ceiling computed once and
//              never revisited, i.e. the open-loop behaviour of every
//              published configurable multiplier.
//
// Both receive the same power pressure (req_width, default 15 = "save as
// much power as you can"); each supervisor clamps it to what it believes is
// safe for a 2% NMED budget.
//
// Operand statistics shift in three phases, so drift between the offline
// LUT (built under uniform operands) and reality EMERGES from the data
// rather than being injected:
//     phase 0: uniform        a,b in [0,255]    (LUT assumption holds)
//     phase 1: biased high    a,b in [128,255]  (true error > LUT)
//     phase 2: biased low     a,b in [0,127]    (true error < LUT)
// Operands come from a fixed-seed 32-bit LCG (reproducible across simulators).
//
// Metric: windowed NMED = mean(|exact - approx|) / MAXPROD over the last
// WIN operations; a "breach" is any cycle where it exceeds NMED_CEIL.
// Average applied width is reported as the power proxy (larger = cheaper).
//
// Plusargs (optional):  +PHASE_LEN=<ops per phase>  +REQ=<req_width>  +SEED=<n>
//                       +TRACE=<csv path>  +VCD=<vcd path>  +NOVCD
// Parameters (iverilog -P): CAL_P, DAMP, CTRL_CEIL  (see below)
// Defaults: 3 x 100 ops, outputs results/supervisor_rtl_trace.csv and
// build/mode11_cosim.vcd. With only ~15 calibration samples in 300 ops the
// short run is seed-sensitive; use +PHASE_LEN=2000 for statistically
// meaningful numbers (run_all does both).

`timescale 1ns/1ps

module tb_mode11_supervisor;

    localparam integer N         = 8;
    localparam integer WB        = $clog2(2*N) + 1;
    localparam integer MAXPROD   = 255 * 255;
    localparam real    CEIL      = 0.02;          // EVALUATION budget (2% NMED)

    // Controller knobs, overridable from the iverilog command line, e.g.
    //   iverilog -Ptb_mode11_supervisor.CAL_P=40 -Ptb_mode11_supervisor.CTRL_CEIL=18000 ...
    // CTRL_CEIL < 20000 gives the controller a guard band below the budget
    // it is evaluated against; it is applied to BOTH instances so the
    // comparison stays like-for-like.
    parameter integer  CAL_P     = 20;            // ADAPTIVE calibration period
    parameter integer  DAMP      = 3;             // EMA weight = 1/2^DAMP
    parameter integer  CTRL_CEIL = 20000;         // ceiling the supervisors steer to
    localparam integer WIN       = 64;            // window for windowed NMED

    integer PHASE_LEN = 100;                      // 3 x 100 = 300 ops by default
    integer REQ       = 15;
    integer SEED      = 1;

    reg            clk = 0, rst_n = 0, in_valid = 0;
    reg  [N-1:0]   a = 0, b = 0;
    reg  [WB-1:0]  req_width = 0;

    wire           v_ad, v_st;
    wire [2*N-1:0] p_ad, p_st;
    wire [WB-1:0]  w_ad, w_st;
    wire [11:0]    d_ad, d_st;
    wire           cal_ad, cal_st;

    adaptive_multiplier #(.N(N), .CAL_PERIOD(CAL_P), .DAMPING_SHIFT(DAMP), .NMED_CEIL(CTRL_CEIL)) u_adaptive (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .mode(2'b11), .pth(4'd0),
        .req_width(req_width), .a(a), .b(b),
        .out_valid(v_ad), .product(p_ad), .width_used(w_ad),
        .drift_estimate(d_ad), .cal_event(cal_ad));

    adaptive_multiplier #(.N(N), .CAL_PERIOD(1000000), .DAMPING_SHIFT(DAMP), .NMED_CEIL(CTRL_CEIL)) u_static (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .mode(2'b11), .pth(4'd0),
        .req_width(req_width), .a(a), .b(b),
        .out_valid(v_st), .product(p_st), .width_used(w_st),
        .drift_estimate(d_st), .cal_event(cal_st));

    always #5 clk = ~clk;

    // ---------------- LCG operand generator ----------------
    reg [31:0] lcg;
    function [31:0] lcg_next; input [31:0] x; lcg_next = x * 32'd1664525 + 32'd1013904223; endfunction

    // ---------------- operand history (pipeline latency 2) ----------------
    reg [N-1:0] ha0, hb0, ha1, hb1;
    integer     hph0, hph1;
    integer     phase;
    always @(posedge clk) begin
        ha1 <= ha0; hb1 <= hb0; hph1 <= hph0;
        ha0 <= a;   hb0 <= b;   hph0 <= phase;
    end

    // ---------------- metrics ----------------
    real    err_ad_w [0:WIN-1];
    real    err_st_w [0:WIN-1];
    real    sum_ad, sum_st, nmed_ad, nmed_st;
    integer wi, filled, op;
    integer breach_ad [0:2], breach_st [0:2];
    real    worst_ad, worst_st;
    real    wsum_ad [0:2], wsum_st [0:2], dsum [0:2];
    real    esum_ad [0:2], esum_st [0:2];              // per-phase true mean NMED
    reg [8*128:1] trace_file, vcd_file;
    integer cnt [0:2], cals [0:2];
    integer exact, e_ad, e_st, k, fh;

    initial begin
        for (k = 0; k < WIN; k = k + 1) begin err_ad_w[k] = 0.0; err_st_w[k] = 0.0; end
        for (k = 0; k < 3; k = k + 1) begin
            breach_ad[k] = 0; breach_st[k] = 0; wsum_ad[k] = 0; wsum_st[k] = 0;
            dsum[k] = 0; cnt[k] = 0; cals[k] = 0; esum_ad[k] = 0; esum_st[k] = 0;
        end
        sum_ad = 0; sum_st = 0; wi = 0; filled = 0; op = 0;
        worst_ad = 0; worst_st = 0;
    end

    always @(negedge clk) begin
        if (rst_n && v_ad && v_st) begin
            exact = ha1 * hb1;
            e_ad  = (exact > p_ad) ? exact - p_ad : p_ad - exact;
            e_st  = (exact > p_st) ? exact - p_st : p_st - exact;

            // sliding window of |err|/MAXPROD
            sum_ad = sum_ad - err_ad_w[wi] + (e_ad * 1.0) / MAXPROD;
            sum_st = sum_st - err_st_w[wi] + (e_st * 1.0) / MAXPROD;
            err_ad_w[wi] = (e_ad * 1.0) / MAXPROD;
            err_st_w[wi] = (e_st * 1.0) / MAXPROD;
            wi = (wi + 1) % WIN;
            if (filled < WIN) filled = filled + 1;
            nmed_ad = sum_ad / filled;
            nmed_st = sum_st / filled;

            if (nmed_ad > CEIL) breach_ad[hph1] = breach_ad[hph1] + 1;
            if (nmed_st > CEIL) breach_st[hph1] = breach_st[hph1] + 1;
            if (nmed_ad > worst_ad) worst_ad = nmed_ad;
            if (nmed_st > worst_st) worst_st = nmed_st;
            wsum_ad[hph1] = wsum_ad[hph1] + w_ad;
            wsum_st[hph1] = wsum_st[hph1] + w_st;
            dsum[hph1]    = dsum[hph1] + d_ad / 256.0;
            cnt[hph1]     = cnt[hph1] + 1;
            esum_ad[hph1] = esum_ad[hph1] + (e_ad * 1.0) / MAXPROD;
            esum_st[hph1] = esum_st[hph1] + (e_st * 1.0) / MAXPROD;

            $fwrite(fh, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%.6f,%.6f,%.4f\n",
                    op, hph1, ha1, hb1, w_ad, w_st, e_ad, e_st, nmed_ad, nmed_st, d_ad / 256.0);
            op = op + 1;
        end
    end

    always @(posedge clk) if (cal_ad) cals[phase] = cals[phase] + 1;

    // ---------------- stimulus ----------------
    integer n;
    initial begin
        if ($value$plusargs("PHASE_LEN=%d", PHASE_LEN)) ;
        if ($value$plusargs("REQ=%d", REQ)) ;
        if ($value$plusargs("SEED=%d", SEED)) ;
        trace_file = "results/supervisor_rtl_trace.csv";
        vcd_file   = "build/mode11_cosim.vcd";
        if ($value$plusargs("TRACE=%s", trace_file)) ;
        if ($value$plusargs("VCD=%s", vcd_file)) ;
        lcg = SEED;
        phase = 0;

        fh = $fopen(trace_file, "w");
        $fwrite(fh, "op,phase,a,b,width_adaptive,width_static,err_adaptive,err_static,win_nmed_adaptive,win_nmed_static,drift_adaptive\n");
        if (!$test$plusargs("NOVCD")) begin
            $dumpfile(vcd_file);
            $dumpvars(0, tb_mode11_supervisor);
        end

        repeat (3) @(negedge clk);
        rst_n = 1;

        for (n = 0; n < 3 * PHASE_LEN; n = n + 1) begin
            @(negedge clk);
            phase = n / PHASE_LEN;
            lcg = lcg_next(lcg);
            case (phase)
                0: begin a = lcg[31:24];          b = lcg[23:16];          end  // uniform
                1: begin a = {1'b1, lcg[30:24]};  b = {1'b1, lcg[22:16]};  end  // [128,255]
                default: begin a = {1'b0, lcg[30:24]}; b = {1'b0, lcg[22:16]}; end // [0,127]
            endcase
            req_width = REQ[WB-1:0];
            in_valid  = 1;
        end
        @(negedge clk); in_valid = 0;
        repeat (4) @(negedge clk);
        $fclose(fh);

        $display("");
        $display("=== Mode-11 co-simulation: ADAPTIVE (CAL_PERIOD=%0d, EMA 1/%0d, steer-to %.2f%%) vs STATIC (no calibration) ===",
                 CAL_P, 1 << DAMP, CTRL_CEIL / 10000.0);
        $display("ops per phase = %0d, req_width = %0d, NMED budget = %.1f%%, window = %0d ops", PHASE_LEN, REQ, CEIL*100, WIN);
        $display("phase          | breaches AD | breaches ST | mean NMED AD | mean NMED ST | avg width AD | avg width ST | avg drift AD | cal samples");
        for (k = 0; k < 3; k = k + 1)
            $display("%-14s | %11d | %11d | %11.3f%% | %11.3f%% | %12.2f | %12.2f | %12.3f | %11d",
                     (k == 0) ? "0 uniform" : (k == 1) ? "1 biased high" : "2 biased low",
                     breach_ad[k], breach_st[k], 100.0 * esum_ad[k] / cnt[k], 100.0 * esum_st[k] / cnt[k],
                     wsum_ad[k] / cnt[k], wsum_st[k] / cnt[k], dsum[k] / cnt[k], cals[k]);
        $display("TOTAL          | %5d/%0d | %5d/%0d |", breach_ad[0]+breach_ad[1]+breach_ad[2], op,
                 breach_st[0]+breach_st[1]+breach_st[2], op);
        $display("worst windowed NMED: ADAPTIVE %.4f   STATIC %.4f", worst_ad, worst_st);
        $display("Trace written to %0s", trace_file);
        // one machine-readable line for models/sweep_supervisor.py
        $fwrite(32'h8000_0001, "SUMMARY,%0d,%0d,%0d,%0d,%0d", CAL_P, DAMP, CTRL_CEIL, SEED, PHASE_LEN);
        for (k = 0; k < 3; k = k + 1)
            $fwrite(32'h8000_0001, ",%0d,%0d,%.6f,%.6f,%.4f,%.4f", breach_ad[k], breach_st[k],
                    esum_ad[k] / cnt[k], esum_st[k] / cnt[k], wsum_ad[k] / cnt[k], wsum_st[k] / cnt[k]);
        $fwrite(32'h8000_0001, ",%.6f,%.6f\n", worst_ad, worst_st);
        $display("CO-SIM DONE");
        $finish;
    end

endmodule
