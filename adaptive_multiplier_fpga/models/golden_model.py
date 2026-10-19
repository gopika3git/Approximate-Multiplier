#!/usr/bin/env python3
"""
golden_model.py

Independent Python re-implementation of the approx_mult.v truncation
scheme, used to (a) cross-check the RTL exhaustively rather than trust
a single implementation, and (b) produce the error(width) characterization
that will become the mode-11 supervisor's LUT and the paper's error-model
figure.

Scheme (must match rtl/approx_mult.v exactly):
    - Full N x N AND-based partial product matrix.
    - Any partial-product bit landing in product-column < width is
      dropped (treated as 0).
    - A constant bias-compensation term EC = 2^(width-1) (0 if width==0)
      is added back to the truncated sum.

Usage:
    python3 golden_model.py --n 8 --out ../results/error_vs_width_golden.csv
    python3 golden_model.py --n 8 --compare ../results/error_vs_width.csv
"""
import argparse
import csv
import sys


def approx_multiply(a: int, b: int, width: int, n: int) -> int:
    """Column-truncated multiply with bias compensation, bit-for-bit
    matching the RTL's masking scheme."""
    total = 0
    for i in range(n):          # row i: a & (b[i] broadcast), shifted by i
        if (b >> i) & 1:
            row = a << i
            # mask out bits landing in columns < width
            if width > 0:
                row &= ~((1 << width) - 1)
            total += row
    if width > 0:
        total += 1 << (width - 1)
    return total


def exact_multiply(a: int, b: int) -> int:
    return a * b


def characterize(n: int):
    """Exhaustive sweep over all (a,b) pairs for every truncation width.
    Returns list of dicts: width, mred, nmed, max_abs_err."""
    max_val = (1 << n) - 1
    max_prod = max_val * max_val
    num_pairs = (1 << n) * (1 << n)
    results = []

    for width in range(0, 2 * n):
        sum_abs_err = 0
        sum_rel_err = 0.0
        rel_count = 0
        max_abs_err = 0
        mismatches_w0 = 0

        for a in range(1 << n):
            for b in range(1 << n):
                exact = exact_multiply(a, b)
                approx = approx_multiply(a, b, width, n)
                err = abs(exact - approx)

                sum_abs_err += err
                if err > max_abs_err:
                    max_abs_err = err
                if exact != 0:
                    sum_rel_err += err / exact
                    rel_count += 1
                if width == 0 and approx != exact:
                    mismatches_w0 += 1

        mred = sum_rel_err / rel_count if rel_count else 0.0
        nmed = (sum_abs_err / num_pairs) / max_prod

        if width == 0 and mismatches_w0 != 0:
            print(f"FATAL: golden model width=0 not bit-exact: "
                  f"{mismatches_w0} mismatches", file=sys.stderr)
            sys.exit(1)

        results.append({
            "width": width,
            "mred": mred,
            "nmed": nmed,
            "max_abs_err": float(max_abs_err),
        })
        print(f"width={width:2d}  MRED={mred:.6f}  NMED={nmed:.8f}  "
              f"MAXERR={max_abs_err:.1f}")

    return results


def write_csv(results, path):
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["width", "mred", "nmed", "max_abs_err"])
        writer.writeheader()
        for row in results:
            writer.writerow(row)
    print(f"Wrote {path}")


def compare_to_rtl(results, rtl_csv_path, tol=1e-6):
    with open(rtl_csv_path) as f:
        rtl_rows = {int(r["width"]): r for r in csv.DictReader(f)}

    mismatches = []
    for row in results:
        w = row["width"]
        if w not in rtl_rows:
            mismatches.append((w, "missing in RTL csv"))
            continue
        rtl = rtl_rows[w]
        for field in ("mred", "nmed"):
            golden_v = row[field]
            rtl_v = float(rtl[field])
            if abs(golden_v - rtl_v) > tol:
                mismatches.append((w, f"{field}: golden={golden_v:.8f} rtl={rtl_v:.8f}"))

    if mismatches:
        print("\nMISMATCHES between golden model and RTL:")
        for w, msg in mismatches:
            print(f"  width={w}: {msg}")
        sys.exit(1)
    else:
        print(f"\nOK: golden model matches RTL results in {rtl_csv_path} "
              f"for all widths (tol={tol}).")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=8, help="operand bit-width")
    ap.add_argument("--out", type=str, default=None, help="CSV output path")
    ap.add_argument("--compare", type=str, default=None,
                     help="RTL error_vs_width.csv to cross-check against")
    args = ap.parse_args()

    results = characterize(args.n)

    if args.out:
        write_csv(results, args.out)
    if args.compare:
        compare_to_rtl(results, args.compare)
