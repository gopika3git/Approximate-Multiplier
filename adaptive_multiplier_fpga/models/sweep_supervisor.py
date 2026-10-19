#!/usr/bin/env python3
"""
sweep_supervisor.py  -- sensitivity analysis of the mode-11 supervisor

Sweeps the three controller knobs of the RTL co-simulation
(tb/tb_mode11_supervisor.v) over several seeds:

    CAL_P      calibration period (ops between samples), must be > MW+1 = 11
    DAMP       EMA weight 1/2^DAMP
    CTRL_CEIL  NMED the supervisors steer to (x1e6); < 20000 = guard band
               below the 2% budget they are evaluated against. Applied to
               BOTH ADAPTIVE and STATIC so the comparison is like-for-like.

For every configuration it reports, averaged over seeds:
    breach %         share of ops whose 64-op windowed NMED exceeds 2%
    worst-phase NMED the highest per-phase MEAN NMED (a phase-level budget check)
    avg width        mean applied truncation width = power-saving proxy

Needs oss-cad-suite (iverilog, vvp) on PATH; matplotlib optional (plot).
Run from the project root:
    python models/sweep_supervisor.py                 (full grid, ~5 min)
    python models/sweep_supervisor.py --quick         (small grid)
Outputs: results/sweep_supervisor.csv, results/sweep_supervisor_runs.csv,
         results/sweep_pareto.png
"""
import argparse
import csv
import itertools
import os
import statistics
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

RTL = ["rtl/approx_mult.v", "rtl/mode11_supervisor.v", "rtl/adaptive_multiplier.v",
       "tb/tb_mode11_supervisor.v"]
TB = "tb_mode11_supervisor"


def compile_cfg(cal_p, damp, ceil, outdir):
    out = os.path.join(outdir, f"c_{cal_p}_{damp}_{ceil}.vvp")
    cmd = ["iverilog", "-g2012", "-Irtl",
           f"-P{TB}.CAL_P={cal_p}", f"-P{TB}.DAMP={damp}", f"-P{TB}.CTRL_CEIL={ceil}",
           "-o", out] + RTL
    subprocess.run(cmd, check=True)
    return out


def run(vvp, seed, phase_len, outdir):
    trace = os.path.join(outdir, f"t_{os.path.basename(vvp)}_{seed}.csv")
    r = subprocess.run(["vvp", "-n", vvp, f"+SEED={seed}", f"+PHASE_LEN={phase_len}",
                        "+NOVCD", f"+TRACE={trace}"],
                       capture_output=True, text=True, check=True)
    line = next(l for l in r.stdout.splitlines() if l.startswith("SUMMARY,"))
    v = line.split(",")[1:]
    cal_p, damp, ceil, sd, plen = map(int, v[:5])
    ph = []
    for k in range(3):
        b = v[5 + 6 * k: 11 + 6 * k]
        ph.append(dict(br_ad=int(b[0]), br_st=int(b[1]), nmed_ad=float(b[2]), nmed_st=float(b[3]),
                       w_ad=float(b[4]), w_st=float(b[5])))
    total = 3 * plen
    return dict(
        cal_p=cal_p, damp=damp, ceil=ceil, seed=sd,
        breach_ad=100.0 * sum(p["br_ad"] for p in ph) / total,
        breach_st=100.0 * sum(p["br_st"] for p in ph) / total,
        worst_phase_nmed_ad=100.0 * max(p["nmed_ad"] for p in ph),
        worst_phase_nmed_st=100.0 * max(p["nmed_st"] for p in ph),
        width_ad=sum(p["w_ad"] for p in ph) / 3,
        width_st=sum(p["w_st"] for p in ph) / 3,
        **{f"breach_ad_ph{k}": 100.0 * ph[k]["br_ad"] / plen for k in range(3)},
        **{f"breach_st_ph{k}": 100.0 * ph[k]["br_st"] / plen for k in range(3)},
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--seeds", type=int, default=5)
    ap.add_argument("--phase-len", type=int, default=2000)
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    a = ap.parse_args()

    if a.quick:
        grid = dict(cal_p=[20, 40], damp=[3, 4], ceil=[20000, 18000])
        a.seeds = min(a.seeds, 3)
    else:
        grid = dict(cal_p=[12, 20, 40, 80], damp=[2, 3, 4, 5],
                    ceil=[20000, 19000, 18000, 17000, 16000])
    cfgs = list(itertools.product(grid["cal_p"], grid["damp"], grid["ceil"]))
    seeds = list(range(1, a.seeds + 1))
    os.makedirs("results", exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        print(f"compiling {len(cfgs)} configurations ...")
        with ThreadPoolExecutor(a.jobs) as ex:
            vvps = list(ex.map(lambda c: compile_cfg(*c, tmp), cfgs))
        jobs = [(v, s) for v in vvps for s in seeds]
        print(f"running {len(jobs)} co-simulations ({a.phase_len} ops/phase) ...")
        with ThreadPoolExecutor(a.jobs) as ex:
            runs = list(ex.map(lambda j: run(j[0], j[1], a.phase_len, tmp), jobs))

    with open("results/sweep_supervisor_runs.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(runs[0].keys()))
        w.writeheader(); w.writerows(runs)

    # aggregate over seeds
    agg = []
    for c in cfgs:
        rs = [r for r in runs if (r["cal_p"], r["damp"], r["ceil"]) == c]
        row = dict(cal_p=c[0], damp=c[1], ceil=c[2])
        for key in ("breach_ad", "breach_st", "worst_phase_nmed_ad", "worst_phase_nmed_st",
                    "width_ad", "width_st", "breach_ad_ph0", "breach_ad_ph1", "breach_ad_ph2"):
            vals = [r[key] for r in rs]
            row[key] = statistics.mean(vals)
            if key in ("breach_ad", "width_ad"):
                row[key + "_min"] = min(vals); row[key + "_max"] = max(vals)
        agg.append(row)
    with open("results/sweep_supervisor.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(agg[0].keys()))
        w.writeheader(); w.writerows(agg)
    print("Wrote results/sweep_supervisor.csv and results/sweep_supervisor_runs.csv")

    # console summary
    print("\nSTATIC baseline (depends only on the steer-to ceiling):")
    for ceil in grid["ceil"]:
        r = next(x for x in agg if x["ceil"] == ceil)
        print(f"  steer-to {ceil/1e4:.2f}%  width {r['width_st']:.2f}  breach {r['breach_st']:5.1f}%  "
              f"worst-phase mean NMED {r['worst_phase_nmed_st']:.2f}%")
    print("\nADAPTIVE configurations whose worst-phase MEAN NMED stays <= 2.00%, best power first:")
    print("  CAL_P DAMP ceil%  | width (min-max)      | breach% (min-max)     | worst-phase NMED%")
    ok = sorted([r for r in agg if r["worst_phase_nmed_ad"] <= 2.0], key=lambda r: -r["width_ad"])
    for r in ok[:12]:
        print(f"  {r['cal_p']:5d} {r['damp']:4d} {r['ceil']/1e4:5.2f} | "
              f"{r['width_ad']:5.2f} ({r['width_ad_min']:.2f}-{r['width_ad_max']:.2f}) | "
              f"{r['breach_ad']:5.1f} ({r['breach_ad_min']:4.1f}-{r['breach_ad_max']:4.1f}) | "
              f"{r['worst_phase_nmed_ad']:.2f}")

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib not installed -> no plot"); return

    fig, ax = plt.subplots(1, 2, figsize=(12, 4.8))
    cmap = plt.get_cmap("viridis")
    ceils = grid["ceil"]
    for i, ceil in enumerate(ceils):
        rs = [r for r in agg if r["ceil"] == ceil]
        col = cmap(i / max(1, len(ceils) - 1))
        ax[0].scatter([r["width_ad"] for r in rs], [r["breach_ad"] for r in rs], color=col, s=22,
                      label=f"ADAPTIVE, steer {ceil/1e4:.1f}%")
        ax[1].scatter([r["width_ad"] for r in rs], [r["worst_phase_nmed_ad"] for r in rs], color=col, s=22)
    st = {}
    for r in agg:
        st[round(r["width_st"], 3)] = (r["breach_st"], r["worst_phase_nmed_st"])
    xs = sorted(st)
    ax[0].plot(xs, [st[x][0] for x in xs], "s--", color="#c0392b", ms=8, label="STATIC (open loop)")
    ax[1].plot(xs, [st[x][1] for x in xs], "s--", color="#c0392b", ms=8)
    ax[0].set_xlabel("average applied width  (higher = more power saved)")
    ax[0].set_ylabel("ops with windowed NMED > 2%  (%)")
    ax[0].legend(fontsize=7); ax[0].grid(alpha=.3)
    ax[1].axhline(2.0, ls="--", color="k", lw=1)
    ax[1].set_xlabel("average applied width  (higher = more power saved)")
    ax[1].set_ylabel("worst per-phase mean NMED (%)"); ax[1].grid(alpha=.3)
    fig.suptitle(f"Mode-11 knob sweep: CAL_P x DAMP x steer-to ceiling, mean of {len(seeds)} seeds")
    fig.tight_layout(); fig.savefig("results/sweep_pareto.png", dpi=150)
    print("Wrote results/sweep_pareto.png")


if __name__ == "__main__":
    sys.exit(main())
