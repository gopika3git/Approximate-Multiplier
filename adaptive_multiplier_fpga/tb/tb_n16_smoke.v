// tb_n16_smoke.v -- 16-bit scaling check of the full design (mode 11).
//
// Must be compiled together with the N=16 table rtl/n16/supervisor_lut.vh
// (run_all copies the RTL and that table into build/n16 and compiles there).
//
//   phase A: 3000 ops, uniform operands      (LUT assumption holds)
//   phase B: 3000 ops, operands >= 2^15      (true error > LUT -> must back off)
// Checks every product against an independent reference at the width used,
// and that the supervisor keeps the phase-mean NMED under the 2% budget.

`timescale 1ns/1ps
module tb_n16_smoke;
    localparam integer N = 16, WB = $clog2(2*N) + 1;
    localparam real MAXPROD = 4294836225.0;           // (2^16-1)^2

    reg clk = 0, rst_n = 0, v = 0;
    reg [N-1:0] a = 0, b = 0;
    wire ov, c;
    wire [2*N-1:0] p;
    wire [WB-1:0] w;
    wire [11:0] d;

    adaptive_multiplier #(.N(N)) dut (
        .clk(clk), .rst_n(rst_n), .in_valid(v), .mode(2'b11), .pth(4'd0),
        .req_width({WB{1'b1}} >> 1),                   // 2N-1 = max power pressure
        .a(a), .b(b), .out_valid(ov), .product(p), .width_used(w),
        .drift_estimate(d), .cal_event(c));

    always #5 clk = ~clk;

    function [2*N-1:0] refm;
        input [N-1:0] x, y; input integer fw;
        integer r; reg [2*N-1:0] acc, row, m;
        begin
            acc = 0;
            m = (fw == 0) ? {2*N{1'b1}} : ~(({{(2*N-1){1'b0}},1'b1} << fw) - 1);
            for (r = 0; r < N; r = r + 1)
                if (y[r]) begin row = {{N{1'b0}}, x} << r; acc = acc + (row & m); end
            if (fw > 0) acc = acc + ({{(2*N-1){1'b0}},1'b1} << (fw - 1));
            refm = acc;
        end
    endfunction

    reg [N-1:0] a1, b1, a2, b2;
    reg [2*N-1:0] ex;
    integer n, errs = 0, seed = 7, cnt = 0, bad_budget = 0;
    real s = 0.0, wsum = 0.0;
    always @(posedge clk) begin a1 <= a; b1 <= b; a2 <= a1; b2 <= b1; end
    always @(negedge clk) if (ov) begin
        ex = a2 * b2;
        if (p !== refm(a2, b2, w)) errs = errs + 1;
        s = s + ((ex > p) ? ex - p : p - ex) / MAXPROD;
        wsum = wsum + w;
        cnt = cnt + 1;
    end

    task report; input [8*24:1] name;
        begin
            $display("  %0s: mean width %.2f, drift %.3fx, mean NMED %.3f%%",
                     name, wsum / cnt, d / 256.0, 100.0 * s / cnt);
            if (s / cnt > 0.02) bad_budget = bad_budget + 1;
            s = 0; wsum = 0; cnt = 0;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk); rst_n = 1;
        for (n = 0; n < 6000; n = n + 1) begin
            @(negedge clk); v = 1;
            a = $random(seed); b = $random(seed);
            if (n >= 3000) begin a[15] = 1'b1; b[15] = 1'b1; end
            if (n == 2999) report("uniform    ");
        end
        @(negedge clk); v = 0; repeat (3) @(negedge clk);
        report("biased high");
        if (errs == 0 && bad_budget == 0)
            $display("PASS: N=16 products match reference, phase-mean NMED within 2%%");
        else
            $display("FAIL: N=16 %0d product mismatches, %0d phases over budget", errs, bad_budget);
        $finish;
    end
endmodule
