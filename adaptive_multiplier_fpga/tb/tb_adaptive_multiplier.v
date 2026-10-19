// tb_adaptive_multiplier.v
//
// Functional verification of the full 4-mode top level (adaptive_multiplier).
// Run from the project root.
//
//   Test 1  mode 00 : EXHAUSTIVE, all 65536 (a,b) pairs, must be bit-exact.
//   Test 2  mode 01 : every Pth 0..15, width must equal W/2 - ALPHA_LP*Pth,
//                     product must match an independent TB reference model.
//   Test 3  mode 10 : same with ALPHA_HA.
//   Test 4  mode 11 : supervisor-driven width; product must match the
//                     reference at the width actually used, width_used must
//                     never exceed req_width, drift must stay in its clamp.
//   Test 5  random mode switching every cycle (all four modes interleaved),
//           checks the pipeline carries mode/width/product together.
//
// Expected results are computed by a reference function written here,
// independently of the RTL (same scheme as models/golden_model.py).
// Waveform: build/adaptive_multiplier.vcd (tests 4-5 only, to keep it small).

`timescale 1ns/1ps

module tb_adaptive_multiplier;

    localparam integer N        = 8;
    localparam integer WB       = $clog2(2*N) + 1;
    localparam integer HALF     = N;            // W/2, W = 2N total operand bits
    localparam integer ALPHA_FRAC = 2;
    localparam integer ALPHA_LP = 2;            // 0.5
    localparam integer ALPHA_HA = 8;            // 2.0

    reg              clk = 0;
    reg              rst_n = 0;
    reg              in_valid = 0;
    reg  [1:0]       mode = 0;
    reg  [3:0]       pth = 0;
    reg  [WB-1:0]    req_width = 0;
    reg  [N-1:0]     a = 0, b = 0;
    wire             out_valid;
    wire [2*N-1:0]   product;
    wire [WB-1:0]    width_used;
    wire [11:0]      drift_estimate;
    wire             cal_event;

    adaptive_multiplier #(
        .N(N), .ALPHA_FRAC(ALPHA_FRAC), .ALPHA_LP(ALPHA_LP), .ALPHA_HA(ALPHA_HA)
    ) dut (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .mode(mode), .pth(pth),
        .req_width(req_width), .a(a), .b(b),
        .out_valid(out_valid), .product(product), .width_used(width_used),
        .drift_estimate(drift_estimate), .cal_event(cal_event)
    );

    always #5 clk = ~clk;   // 100 MHz

    // ---------------- independent reference model ----------------
    function [2*N-1:0] approx_ref;
        input [N-1:0] fa, fb;
        input integer fw;
        integer r;
        reg [2*N-1:0] acc, row, msk;
        begin
            acc = 0;
            msk = (fw == 0) ? {2*N{1'b1}} : ~(({{(2*N-1){1'b0}},1'b1} << fw) - 1);
            for (r = 0; r < N; r = r + 1)
                if (fb[r]) begin
                    row = {{N{1'b0}}, fa} << r;
                    acc = acc + (row & msk);
                end
            if (fw > 0) acc = acc + ({{(2*N-1){1'b0}},1'b1} << (fw - 1));
            approx_ref = acc;
        end
    endfunction

    function integer width_ref;            // modes 00/01/10 only
        input [1:0] m;
        input integer p;
        integer k;
        begin
            case (m)
                2'b00: width_ref = 0;
                2'b01: begin k = (p * ALPHA_LP) >> ALPHA_FRAC; if (k > HALF) k = HALF; width_ref = HALF - k; end
                2'b10: begin k = (p * ALPHA_HA) >> ALPHA_FRAC; if (k > HALF) k = HALF; width_ref = HALF - k; end
                default: width_ref = -1;
            endcase
        end
    endfunction

    // ---------------- 2-deep scoreboard (pipeline latency = 2) ----------------
    reg [N-1:0]  sa [0:1];
    reg [N-1:0]  sb [0:1];
    reg [1:0]    sm [0:1];
    reg [3:0]    sp [0:1];
    reg [WB-1:0] sr [0:1];
    reg          sv [0:1];

    integer errors = 0, checks = 0;
    integer ew;

    always @(posedge clk) begin
        // shift scoreboard with what is being presented this cycle
        sa[1] <= sa[0]; sb[1] <= sb[0]; sm[1] <= sm[0]; sp[1] <= sp[0]; sr[1] <= sr[0]; sv[1] <= sv[0];
        sa[0] <= a;     sb[0] <= b;     sm[0] <= mode;  sp[0] <= pth;   sr[0] <= req_width; sv[0] <= in_valid;
    end

    // check outputs on the falling edge (registered outputs are stable)
    always @(negedge clk) begin
        if (rst_n && out_valid) begin
            if (!sv[1]) begin
                errors = errors + 1;
                $display("ERROR t=%0t: out_valid without a matching input", $time);
            end else begin
                checks = checks + 1;
                if (sm[1] == 2'b11) begin
                    if (width_used > sr[1]) begin
                        errors = errors + 1;
                        if (errors <= 10) $display("ERROR mode11: width_used=%0d > req_width=%0d", width_used, sr[1]);
                    end
                    ew = width_used;
                end else begin
                    ew = width_ref(sm[1], sp[1]);
                    if (width_used !== ew[WB-1:0]) begin
                        errors = errors + 1;
                        if (errors <= 10) $display("ERROR mode%b Pth=%0d: width_used=%0d expected=%0d",
                                                   sm[1], sp[1], width_used, ew);
                    end
                end
                if (product !== approx_ref(sa[1], sb[1], ew)) begin
                    errors = errors + 1;
                    if (errors <= 10) $display("ERROR mode%b a=%0d b=%0d w=%0d: product=%0d expected=%0d",
                                               sm[1], sa[1], sb[1], ew, product, approx_ref(sa[1], sb[1], ew));
                end
                if (sm[1] == 2'b00 && product !== sa[1] * sb[1]) begin
                    errors = errors + 1;
                    if (errors <= 10) $display("ERROR mode00 not exact: a=%0d b=%0d product=%0d", sa[1], sb[1], product);
                end
            end
        end
        if (rst_n && (drift_estimate < 32 || drift_estimate > 2048)) begin
            errors = errors + 1;
            $display("ERROR drift_estimate=%0d outside clamp [32,2048]", drift_estimate);
        end
    end

    // ---------------- stimulus ----------------
    integer i, j, p, n, e0, c0;
    integer seed = 32'h1234_5678;

    task drive;            // present one operation on the next rising edge
        input [1:0] m; input [3:0] pt; input [WB-1:0] rq; input [N-1:0] x, y;
        begin
            @(negedge clk);
            in_valid = 1; mode = m; pth = pt; req_width = rq; a = x; b = y;
        end
    endtask

    task flush;
        begin
            @(negedge clk); in_valid = 0;
            repeat (3) @(negedge clk);
        end
    endtask

    initial begin
        $dumpfile("build/adaptive_multiplier.vcd");
        $dumpvars(0, tb_adaptive_multiplier);
        $dumpoff;

        repeat (3) @(negedge clk);
        rst_n = 1;

        // ---- Test 1: mode 00 exhaustive ----
        e0 = errors; c0 = checks;
        for (i = 0; i < 256; i = i + 1)
            for (j = 0; j < 256; j = j + 1)
                drive(2'b00, 4'd0, 0, i[7:0], j[7:0]);
        flush;
        $display("[Test 1] mode 00 exhaustive      : %0d ops checked, %0d errors", checks - c0, errors - e0);

        // ---- Tests 2/3: modes 01 and 10, every Pth ----
        $display("          Pth : width(mode01)  width(mode10)");
        for (p = 0; p < 16; p = p + 1)
            $display("          %3d : %6d         %6d", p, width_ref(2'b01, p), width_ref(2'b10, p));
        e0 = errors; c0 = checks;
        for (p = 0; p < 16; p = p + 1)
            for (n = 0; n < 2048; n = n + 1)
                drive(2'b01, p[3:0], 0, $random(seed), $random(seed));
        flush;
        $display("[Test 2] mode 01, Pth 0..15      : %0d ops checked, %0d errors", checks - c0, errors - e0);
        e0 = errors; c0 = checks;
        for (p = 0; p < 16; p = p + 1)
            for (n = 0; n < 2048; n = n + 1)
                drive(2'b10, p[3:0], 0, $random(seed), $random(seed));
        flush;
        $display("[Test 3] mode 10, Pth 0..15      : %0d ops checked, %0d errors", checks - c0, errors - e0);

        // ---- Test 4: mode 11 ----
        $dumpon;
        e0 = errors; c0 = checks;
        for (n = 0; n < 4000; n = n + 1)
            drive(2'b11, 4'd0, (n < 128) ? {1'b0, n[6:3]} : 5'd15, $random(seed), $random(seed));
        flush;
        $display("[Test 4] mode 11 (supervisor)    : %0d ops checked, %0d errors, final width=%0d, drift=%0d/256",
                 checks - c0, errors - e0, width_used, drift_estimate);

        // ---- Test 5: random mode switching ----
        e0 = errors; c0 = checks;
        for (n = 0; n < 4000; n = n + 1)
            drive($random(seed), $random(seed), $random(seed) & 5'h0F, $random(seed), $random(seed));
        flush;
        $display("[Test 5] random mode switching   : %0d ops checked, %0d errors", checks - c0, errors - e0);
        $dumpoff;

        if (errors == 0) $display("PASS: adaptive_multiplier, all %0d checks passed.", checks);
        else             $display("FAIL: adaptive_multiplier, %0d errors in %0d checks.", errors, checks);
        $finish;
    end

endmodule
