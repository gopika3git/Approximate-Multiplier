#!/usr/bin/env python3
"""
plot_results.py  (optional, needs matplotlib)

  results/error_vs_width.csv            -> results/error_vs_width.png
  results/supervisor_rtl_trace.csv      -> results/supervisor_rtl_convergence.png
  results/supervisor_rtl_trace_long.csv -> results/supervisor_rtl_convergence_long.png

Run from the project root:  python models/plot_results.py
"""
import csv
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

CEIL = 0.02
PHASES = ["uniform", "biased high", "biased low"]
SHADE = ["#eeeeee", "#fde2e2", "#e2f0fd"]


def plot_error_curve():
    path = "results/error_vs_width.csv"
    if not os.path.exists(path):
        print(f"skip: {path} not found")
        return
    w, mred, nmed = [], [], []
    with open(path) as f:
        for r in csv.DictReader(f):
            w.append(int(r["width"])); mred.append(float(r["mred"])); nmed.append(float(r["nmed"]) * 100)
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 4.2))
    a1.plot(w, mred, "o-", color="#c0392b"); a1.set_yscale("log")
    a1.set_xlabel("truncation width"); a1.set_ylabel("MRED (log)"); a1.grid(True, which="both", alpha=.3)
    a2.plot(w, nmed, "o-", color="#2471a3"); a2.axhline(CEIL * 100, ls="--", color="k", lw=1, label="2% budget")
    a2.set_xlabel("truncation width"); a2.set_ylabel("NMED (%)"); a2.grid(True, alpha=.3); a2.legend()
    fig.suptitle("approx_mult error(width), exhaustive 65536 pairs per width")
    fig.tight_layout(); fig.savefig("results/error_vs_width.png", dpi=150); plt.close(fig)
    print("Wrote results/error_vs_width.png")


def plot_trace(path, out):
    if not os.path.exists(path):
        print(f"skip: {path} not found")
        return
    rows = list(csv.DictReader(open(path)))
    op = [int(r["op"]) for r in rows]
    ph = [int(r["phase"]) for r in rows]
    fig, ax = plt.subplots(3, 1, figsize=(11, 8.5), sharex=True)

    def shade(a):
        start = 0
        for i in range(1, len(ph) + 1):
            if i == len(ph) or ph[i] != ph[start]:
                a.axvspan(op[start], op[i - 1], color=SHADE[ph[start]], zorder=0,
                          label=PHASES[ph[start]] if a is ax[0] else None)
                start = i

    for a in ax:
        shade(a)
    ax[0].plot(op, [100 * float(r["win_nmed_static"]) for r in rows], color="#c0392b", lw=1.2, label="STATIC (open loop)")
    ax[0].plot(op, [100 * float(r["win_nmed_adaptive"]) for r in rows], color="#1e8449", lw=1.2, label="ADAPTIVE (mode 11)")
    ax[0].axhline(CEIL * 100, ls="--", color="k", lw=1, label="2% budget")
    ax[0].set_ylabel("windowed NMED (%)"); ax[0].legend(loc="upper left", fontsize=8, ncol=3)
    ax[1].step(op, [int(r["width_static"]) for r in rows], color="#c0392b", where="post", label="STATIC")
    ax[1].step(op, [int(r["width_adaptive"]) for r in rows], color="#1e8449", where="post", label="ADAPTIVE")
    ax[1].set_ylabel("applied width"); ax[1].legend(loc="upper left", fontsize=8)
    ax[2].plot(op, [float(r["drift_adaptive"]) for r in rows], color="#7d3c98")
    ax[2].axhline(1.0, ls=":", color="k", lw=1)
    ax[2].set_ylabel("drift estimate (x)"); ax[2].set_xlabel("operation")
    fig.suptitle("Mode-11 RTL co-simulation: closed-loop (ADAPTIVE) vs open-loop (STATIC)")
    fig.tight_layout(); fig.savefig(out, dpi=150); plt.close(fig)
    print(f"Wrote {out}")


if __name__ == "__main__":
    plot_error_curve()
    plot_trace("results/supervisor_rtl_trace.csv", "results/supervisor_rtl_convergence.png")
    plot_trace("results/supervisor_rtl_trace_long.csv", "results/supervisor_rtl_convergence_long.png")
