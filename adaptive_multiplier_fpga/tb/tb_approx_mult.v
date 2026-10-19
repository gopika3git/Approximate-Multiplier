// tb_approx_mult.v   (run from the project root: writes results/error_vs_width.csv)
//
// Exhaustive characterization testbench for approx_mult.
//
// For N=8 this sweeps ALL 65536 (a,b) pairs at every truncation width
// 0..2N-1, so the error metrics below are exact population statistics,
// not sampled estimates. For each width it reports:
//   MRED  - Mean Relative Error Distance  = mean(|exact-approx|/exact)
//           over pairs where exact != 0
//   NMED  - Normalized Mean Error Distance = mean(|exact-approx|) / maxproduct
//   MAX   - maximum absolute error observed at this width
// Results are written to results/error_vs_width.csv, which becomes the
// input to the Python golden-model cross-check and the eventual
// mode-11 supervisor LUT.
//
// It also self-checks that width=0 is bit-exact against `exact_product`
// for every single pair (a required correctness property, not just a
// low-error one) and reports any mismatch as a fatal error.

`timescale 1ns/1ps

module tb_approx_mult;

    localparam N = 8;
    localparam MAXPROD = (2**N - 1) * (2**N - 1);

    reg  [N-1:0] a, b;
    reg  [$clog2(2*N):0] width;
    wire [2*N-1:0] product, exact_product;

    approx_mult #(.N(N)) dut (
        .a(a), .b(b), .width(width),
        .product(product), .exact_product(exact_product)
    );

    integer w;
    integer ai, bi;
    integer mismatches_w0;
    real sum_abs_err, sum_rel_err;
    integer rel_count;
    real max_abs_err;
    real mred, nmed;
    integer fh;

    real exact_r, approx_r, err_r;

    initial begin
        fh = $fopen("results/error_vs_width.csv", "w");
        $fwrite(fh, "width,mred,nmed,max_abs_err\n");

        for (w = 0; w < 2*N; w = w + 1) begin
            width = w[$clog2(2*N):0];
            sum_abs_err = 0.0;
            sum_rel_err = 0.0;
            rel_count = 0;
            max_abs_err = 0.0;
            mismatches_w0 = 0;

            for (ai = 0; ai < (1 << N); ai = ai + 1) begin
                for (bi = 0; bi < (1 << N); bi = bi + 1) begin
                    a = ai[N-1:0];
                    b = bi[N-1:0];
                    #1; // allow combinational settle

                    exact_r  = exact_product;
                    approx_r = product;
                    err_r    = exact_r - approx_r;
                    if (err_r < 0.0) err_r = -err_r;

                    sum_abs_err = sum_abs_err + err_r;
                    if (err_r > max_abs_err) max_abs_err = err_r;

                    if (exact_r != 0.0) begin
                        sum_rel_err = sum_rel_err + (err_r / exact_r);
                        rel_count = rel_count + 1;
                    end

                    if (w == 0 && product !== exact_product) begin
                        mismatches_w0 = mismatches_w0 + 1;
                    end
                end
            end

            mred = (rel_count > 0) ? (sum_rel_err / rel_count) : 0.0;
            // NMED defined as mean(|err|) / MAXPROD; mean(|err|) = sum_abs_err / num_pairs
            nmed = (sum_abs_err / ((1 << N) * (1 << N) * 1.0)) / MAXPROD;

            $fwrite(fh, "%0d,%.8f,%.10f,%.1f\n", w, mred, nmed, max_abs_err);
            $display("width=%0d  MRED=%.6f  NMED=%.8f  MAXERR=%.1f  (w0 mismatches=%0d)",
                      w, mred, nmed, max_abs_err, mismatches_w0);

            if (w == 0 && mismatches_w0 != 0) begin
                $display("FATAL: width=0 must be bit-exact against exact_product, found %0d mismatches", mismatches_w0);
                $finish;
            end
        end

        $fclose(fh);
        $display("Done. Wrote results/error_vs_width.csv");
        $finish;
    end

endmodule
