#!/usr/bin/env bash
# run_demo.sh -- Review 2 live demo, about 2 minutes end to end.
# Run from the package root after: source <oss-cad-suite>/environment
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build results
RTL="rtl/approx_mult.v rtl/mode11_supervisor.v rtl/adaptive_multiplier.v"
pause() { echo; read -r -p "--- press Enter for: $1 ---" _; }

echo "== DEMO 1: all four modes against an independent reference =="
iverilog -g2012 -Irtl -o build/tb_adaptive_multiplier.vvp $RTL tb/tb_adaptive_multiplier.v
vvp -n build/tb_adaptive_multiplier.vvp | grep -E "Test|PASS|FAIL"

pause "closed loop vs open loop (3 x 2000 ops)"
iverilog -g2012 -Irtl -o build/tb_mode11_supervisor.vvp $RTL tb/tb_mode11_supervisor.v
vvp -n build/tb_mode11_supervisor.vvp +PHASE_LEN=2000 +TRACE=results/supervisor_rtl_trace_long.csv \
    +VCD=build/mode11_cosim_long.vcd | sed -n '/^phase/,/^worst/p'

pause "FPGA build (Yosys -> nextpnr-ice40 -> icepack)"
./run_all.sh fpga | grep -E "SB_LUT4|Max frequency|PASS|FAIL"

pause "application demo: Gaussian blur through the approximate multiplier"
PY=$(command -v python3 || command -v python)
"$PY" demo/image_demo.py --out demo/results_demo | tail -5

echo
echo "Waveforms:  gtkwave build/adaptive_multiplier.vcd   (mode switching)"
echo "            gtkwave build/mode11_cosim_long.vcd     (width_out, drift_estimate, cal_event)"
