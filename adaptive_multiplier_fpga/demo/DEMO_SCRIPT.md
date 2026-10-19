# Review 2 — Live Demo Script (about 6 minutes)

Run everything from the package root in an oss-cad-suite terminal
(Windows: `environment.bat`; Linux/WSL: `source <oss-cad-suite>/environment`).
One command does all four parts with a pause between each:

    ./demo/run_demo.sh          (Linux / WSL)
    demo\run_demo.bat           (Windows)

If anything fails on the day, show the matching file in `review2_results/`
(clean run of 18 Oct 2026) and `reference_results/` instead.

---

## Part 1 — Four modes work (≈1 min)

Shows: `tb_adaptive_multiplier.v` checks every mode against an independent reference model.

Expected output:

    [Test 1] mode 00 exhaustive      : 65536 ops checked, 0 errors
    [Test 2] mode 01, Pth 0..15      : 32768 ops checked, 0 errors
    [Test 3] mode 10, Pth 0..15      : 32768 ops checked, 0 errors
    [Test 4] mode 11 (supervisor)    : 4000 ops checked, 0 errors, final width=10, drift=166/256
    [Test 5] random mode switching   : 4000 ops checked, 0 errors
    PASS: adaptive_multiplier, all 139072 checks passed.

Say: "Mode 00 is exhaustive over all 65,536 input pairs and bit-exact. Modes 01 and 10
are the same circuit with α = 0.5 and α = 2.0. Test 5 switches modes at random every
cycle through the 2-stage pipeline."

Optional: `gtkwave build/adaptive_multiplier.vcd` — add `mode`, `pth`, `width_used`,
`product`; point at width changing with mode two cycles after the input.

## Part 2 — Closed loop vs open loop (≈2 min) — the core result

Shows: two identical RTL instances; STATIC has calibration disabled. Operands go
uniform → biased high → biased low, 2,000 ops each.

Expected totals: `1009/6000` (ADAPTIVE) vs `2310/6000` (STATIC).

Say, phase by phase:
- Biased high: true error is above the LUT. Drift estimate rises to 1.27×, width drops
  to 9.14, mean NMED 1.44% vs STATIC 2.45%. Breaches 222 vs 1,957.
- Biased low: true error is below the LUT. Drift falls to 0.60×, width rises to 10.73 to
  save power — and it overshoots: 678 vs 16 breaches. Name this honestly; the fix
  (guard band, asymmetric damping) is on the problems slide.

Optional: `gtkwave build/mode11_cosim_long.vcd` — `width_out`, `drift_estimate`, `cal_event`
for both instances; zoom on a phase boundary to show the estimator moving every 20 ops.

## Part 3 — It synthesizes and meets timing on an FPGA (≈1 min)

Expected:

    adaptive_multiplier:  SB_CARRY 312 ... SB_LUT4 875
    Max frequency ... 34.41 MHz (PASS at 12.00 MHz)
    [PASS] bitstream build/adaptive_multiplier.bin

Say: "Full open toolchain, iCE40 HX8K. No board yet, so this is a bitstream and timing
report, not measured power. The supervisor is 458 LUT4 vs 375 for the 8-bit datapath — at
16 bits it drops to 57% of the datapath."

## Part 4 — Application demo (≈1 min)

Shows: Gaussian blur where every multiply goes through the bit-accurate approx_mult model.
Open `demo/results_demo/image_demo_grid.png`.

Say: "Same width, three images, up to 4 dB apart — that is the operand drift the supervisor
tracks. And width 10, our 2% NMED setting, gives only ~19 dB here, so the budget has to come
from the application target; about 0.2% NMED (width 7) gives over 30 dB."

---

## Likely questions

**Why is the supervisor bigger than the multiplier?** Fixed cost (2N comparators, a 10-bit
calibration multiplier, the EMA register) against a tiny 8-bit datapath. It scales ~N while
the datapath scales ~N², and one supervisor can serve a whole MAC array.

**Isn't the exact product per cycle defeating the purpose?** In this prototype `approx_mult`
computes both for verification. Calibration needs the exact product only once every
CAL_PERIOD (20) ops; the plan is to gate the exact path to those cycles in the
compressor-tree version.

**How is this different from Wu et al. 2026?** Theirs is autonomous on energy and picks k
from an offline LUT. Ours feeds back measured error against the exact result and corrects the
LUT's drift. Their style of controller is being added as a third baseline.

**Is width a fair power proxy?** Only until the SKY130 numbers are in (week 3). Each width step
removes a column of partial-product bits, so power is monotone in width, but not linear.

**Where is the supply-shortfall fallback?** Not built yet; week 2.
