// approx_mult.v
//
// Runtime-configurable-truncation unsigned multiplier.
// This is the shared datapath used by modes 00/01/10 of the adaptive
// multiplier project: a fixed N x N partial-product array where the
// caller can move the exact/approximate boundary at runtime via the
// `width` input.
//
//   width = 0        -> fully exact multiplication (mode 00 endpoint)
//   width = 1 .. 2N-1 -> the `width` least-significant PRODUCT columns
//                        are approximated (dropped + bias-compensated);
//                        the remaining (2N - width) MSB columns are
//                        computed exactly.
//
// This directly implements the project's width(Pth) = W/2 - k equation:
// the supervisor (mode 11, built later) or a fixed mode 01/10 tuning
// computes `width` and drives it into this module; this module doesn't
// know or care where `width` came from.
//
// Approximation scheme: column-truncation with constant bias
// compensation (a standard technique in the approximate-multiplier
// literature - see e.g. the "reconfigurable truncation" / scaleTRIM
// family referenced in docs/adaptive-multiplier-design.md). Partial
// product bits landing in a truncated column are masked to zero rather
// than summed, and a fixed compensation constant EC = 2^(width-1) is
// added back to correct for the average value of the discarded bits.
//
// NOTE: partial-product summation here is written behaviorally (a
// generate-loop accumulation) rather than as a hand-built compressor
// tree. This is intentional for this phase: it is synthesizable and
// functionally exact for width=0 (see testbench cross-check against
// `exact_product`), and is sufficient to characterize error(k) and
// verify the mode logic. A hand-structured Wallace/compressor tree is
// a later refinement once we move to gate-level PPA characterization.

`timescale 1ns/1ps

module approx_mult #(
    parameter N = 8                    // operand bit-width
) (
    input  wire [N-1:0]        a,
    input  wire [N-1:0]        b,
    input  wire [$clog2(2*N):0] width,  // truncation boundary, 0..2N-1
    output wire [2*N-1:0]      product,       // approximate product
    output wire [2*N-1:0]      exact_product  // reference exact product
);

    // ---- exact reference (always computed, used for verification and
    //      as the "mode 00" result at the top level) ----
    assign exact_product = a * b;

    // ---- masked partial-product matrix ----
    // pp_row[i] = (a & {N{b[i]}}) with any bit landing in column < width
    // zeroed out, still aligned to its natural column i+j.
    wire [2*N-1:0] pp_row [0:N-1];

    genvar i, j;

    // Build each row as a full 2N-bit value already shifted by i, with
    // columns < width masked to zero. Done with a per-row function-style
    // generate since column index depends on both i and j (=i+j).
    generate
        for (i = 0; i < N; i = i + 1) begin : GEN_ROW
            wire [N-1:0] raw_row = a & {N{b[i]}};
            wire [2*N-1:0] shifted_row = {{N{1'b0}}, raw_row} << i;
            wire [2*N-1:0] mask;
            for (j = 0; j < 2*N; j = j + 1) begin : GEN_MASKBIT
                // column j of the shifted row survives only if j >= width
                assign mask[j] = (j >= width) ? 1'b1 : 1'b0;
            end
            assign pp_row[i] = shifted_row & mask;
        end
    endgenerate

    // ---- sum the masked rows ----
    reg [2*N-1:0] truncated_sum;
    integer k;
    always @(*) begin
        truncated_sum = {2*N{1'b0}};
        for (k = 0; k < N; k = k + 1) begin
            truncated_sum = truncated_sum + pp_row[k];
        end
    end

    // ---- bias compensation for the discarded columns ----
    // EC = 2^(width-1) for width>0, else 0. This is the expected value
    // of a uniformly-distributed discarded low-order chunk, added back
    // to reduce mean/systematic error.
    wire [2*N-1:0] ec = (width == 0) ? {2*N{1'b0}} : ({{(2*N-1){1'b0}}, 1'b1} << (width - 1));

    assign product = truncated_sum + ec;

endmodule
