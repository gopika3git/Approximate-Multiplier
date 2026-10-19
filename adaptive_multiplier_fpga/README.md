# Adaptive Approximate Multiplier — oss-cad-suite package

8-bit reconfigurable approximate multiplier with four modes, for simulation
(Icarus Verilog + GTKWave) and an FPGA flow (Yosys + nextpnr-ice40 + icepack),
all from oss-cad-suite.

| mode | behaviour | width (LSB product columns approximated) |
|---|---|---|
| `00` | exact | `0` |
| `01` | approx, low-power priority | `W/2 − k`, `k = α_LP·Pth`, α_LP = 0.5 (small slope) |
| `10` | approx, high-accuracy priority | `W/2 − k`, `k = α_HA·Pth`, α_HA = 2.0 (large slope) |
| `11` | adaptive, closed loop | `min(req_width, dynamic_ceiling)` from the mode-11 supervisor |

`W = 2N = 16` total operand bits, so `W/2 = 8`; `k` saturates at `W/2`.
One shared datapath (`approx_mult`) serves all modes; mode 11 is a small
supervisor on top of it, not a fourth multiplier.

## Files

```
rtl/approx_mult.v          shared datapath: column truncation + 2^(width-1) bias compensation
rtl/mode11_supervisor.v    closed-loop supervisor: LUT ceiling scan + periodic calibration + EMA drift
rtl/supervisor_lut.vh      offline error model NMED(width) (generated, N=8 version included)
rtl/adaptive_multiplier.v  top level: mode select, alpha tunings, 2-stage pipeline
tb/tb_approx_mult.v        exhaustive error(width) characterization -> results/error_vs_width.csv
tb/tb_adaptive_multiplier.v  all four modes vs an independent reference model
tb/tb_mode11_supervisor.v  ADAPTIVE vs STATIC co-simulation, 3 operand-distribution phases
tb/tb_n16_smoke.v          16-bit scaling check (mode 11, with rtl/n16/supervisor_lut.vh)
rtl/n16/supervisor_lut.vh  N=16 error model (Monte-Carlo, 1M pairs)
models/golden_model.py     independent Python model, cross-checks the RTL CSV
models/gen_supervisor_lut.py regenerates rtl/supervisor_lut.vh (only needed if N changes)
models/plot_results.py     figures (needs matplotlib)
models/sweep_supervisor.py CAL_PERIOD x EMA damping x guard-band sweep, 5 seeds (needs python)
run_all.bat / run_all.sh   whole flow, Windows / Linux-WSL
```

## Running

Windows: open the oss-cad-suite terminal (`environment.bat` or `start.bat`), `cd` here, then
`run_all.bat` (or `run_all.bat sim`, `run_all.bat fpga`).

Linux / WSL: `source <oss-cad-suite>/environment`, then `./run_all.sh` (or `sim`, `fpga`, `n16`).

Knob sweep (about 3-5 minutes): `python models/sweep_supervisor.py` (or `--quick`).
Single configuration by hand: compile the co-sim with e.g.
`-Ptb_mode11_supervisor.CAL_P=12 -Ptb_mode11_supervisor.DAMP=4 -Ptb_mode11_supervisor.CTRL_CEIL=18000`.
`CTRL_CEIL` is the NMED (x1e6) the supervisors steer to; below 20000 it is a guard band under
the 2% budget they are scored against.

Manual commands (run from this folder):

```
iverilog -g2012 -Irtl -o build/tb_adaptive_multiplier.vvp rtl/approx_mult.v rtl/mode11_supervisor.v rtl/adaptive_multiplier.v tb/tb_adaptive_multiplier.v
vvp -n build/tb_adaptive_multiplier.vvp
gtkwave build/adaptive_multiplier.vcd
```

Co-simulation options: `vvp -n build/tb_mode11_supervisor.vvp +PHASE_LEN=2000 +SEED=3 +REQ=15`

Python is optional. Everything except the golden-model cross-check and the plots runs on
oss-cad-suite alone.

## FPGA target

`iCE40 HX8K (CT256)` is used because it is fully supported by the open toolchain inside
oss-cad-suite and has enough I/O for the 65 top-level pins without a pin-constraint file.
nextpnr assigns pins automatically; add a `.pcf` before programming a real board.

## Reference results

`reference_results/` holds the logs, CSVs and figures from a clean run of this exact
package (Linux, oss-cad-suite tools), so you can diff your own run against them.
