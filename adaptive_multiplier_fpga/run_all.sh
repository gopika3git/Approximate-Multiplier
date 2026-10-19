#!/usr/bin/env bash
# run_all.sh -- full flow with oss-cad-suite on Linux / WSL / macOS
#
#   source <path-to>/oss-cad-suite/environment     (once per terminal)
#   ./run_all.sh            everything
#   ./run_all.sh sim        simulations only
#   ./run_all.sh fpga       synthesis + iCE40 place & route only
#   ./run_all.sh n16        16-bit scaling check only
#
# Supervisor knob sweep (separate, ~3-5 min, needs python):
#   python3 models/sweep_supervisor.py        (or --quick)
#
# Run from the project root. Logs go to results/, build products to build/.
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p build results build/synth

STEP="${1:-all}"
RTL="rtl/approx_mult.v rtl/mode11_supervisor.v rtl/adaptive_multiplier.v"
FAILED=0

need() { command -v "$1" >/dev/null 2>&1; }
check() {   # check <logfile> <pass-pattern> <name>
    if grep -q "$2" "$1" && ! grep -qE "FATAL|^FAIL|ERROR" "$1"; then
        echo "  [PASS] $3"
    else
        echo "  [FAIL] $3  (see $1)"; FAILED=1
    fi
}

if [[ "$STEP" == all || "$STEP" == sim ]]; then
    echo "== 1. Lint =="
    if need verilator; then
        verilator --lint-only -Wall -Irtl --top-module adaptive_multiplier $RTL > results/lint.log 2>&1 \
            && echo "  [PASS] verilator -Wall clean" || { echo "  [FAIL] lint (see results/lint.log)"; FAILED=1; }
    else
        echo "  [skip] verilator not found"
    fi

    echo "== 2. Datapath characterization: approx_mult, all 65536 pairs x 16 widths =="
    iverilog -g2012 -o build/tb_approx_mult.vvp rtl/approx_mult.v tb/tb_approx_mult.v
    vvp -n build/tb_approx_mult.vvp > results/sim_approx_mult.log
    check results/sim_approx_mult.log "Done. Wrote results/error_vs_width.csv" "width=0 bit-exact, error_vs_width.csv written"

    echo "== 3. Top level, all four modes =="
    iverilog -g2012 -Irtl -o build/tb_adaptive_multiplier.vvp $RTL tb/tb_adaptive_multiplier.v
    vvp -n build/tb_adaptive_multiplier.vvp > results/sim_adaptive_multiplier.log
    grep -E "Test|PASS|FAIL" results/sim_adaptive_multiplier.log | sed 's/^/    /'
    check results/sim_adaptive_multiplier.log "^PASS" "adaptive_multiplier functional"

    echo "== 4. Mode-11 co-simulation: ADAPTIVE vs STATIC =="
    iverilog -g2012 -Irtl -o build/tb_mode11_supervisor.vvp $RTL tb/tb_mode11_supervisor.v
    vvp -n build/tb_mode11_supervisor.vvp > results/sim_mode11_short.log
    vvp -n build/tb_mode11_supervisor.vvp +PHASE_LEN=2000 \
        +TRACE=results/supervisor_rtl_trace_long.csv +VCD=build/mode11_cosim_long.vcd > results/sim_mode11_long.log
    echo "   short run (3 x 100 ops):";  sed -n '/^phase/,/^worst/p' results/sim_mode11_short.log | sed 's/^/    /'
    echo "   long run  (3 x 2000 ops):"; sed -n '/^phase/,/^worst/p' results/sim_mode11_long.log  | sed 's/^/    /'
    check results/sim_mode11_long.log "CO-SIM DONE" "mode-11 co-simulation"

    echo "== 5. Python cross-check + plots (optional) =="
    PY=$(command -v python3 || command -v python || true)
    if [[ -n "$PY" ]]; then
        "$PY" models/golden_model.py --n 8 --out results/error_vs_width_golden.csv \
              --compare results/error_vs_width.csv > results/golden.log 2>&1
        check results/golden.log "OK: golden model matches" "golden model == RTL (all widths)"
        if "$PY" -c "import matplotlib" 2>/dev/null; then
            "$PY" models/plot_results.py | sed 's/^/    /'
        else
            echo "  [skip] matplotlib not installed (pip install matplotlib)"
        fi
    else
        echo "  [skip] python not found"
    fi
fi

if [[ "$STEP" == all || "$STEP" == fpga ]]; then
    echo "== 6. Generic synthesis (area breakdown) =="
    for t in approx_mult mode11_supervisor adaptive_multiplier; do
        yosys -q -p "read_verilog -Irtl $RTL; synth -top $t -flatten; tee -o build/synth/generic_$t.txt stat" > /dev/null
        echo "    $t: $(grep 'Number of cells' build/synth/generic_$t.txt | tr -s ' ')"
    done

    echo "== 7. FPGA flow: Yosys synth_ice40 -> nextpnr-ice40 (HX8K CT256) -> icepack =="
    for t in approx_mult mode11_supervisor; do
        yosys -q -p "read_verilog -Irtl $RTL; synth_ice40 -top $t; tee -o build/synth/ice40_$t.txt stat" > /dev/null
    done
    yosys -q -l build/synth/ice40_top.log -p "read_verilog -Irtl $RTL; synth_ice40 -top adaptive_multiplier -json build/adaptive_multiplier_ice40.json; tee -o build/synth/ice40_adaptive_multiplier.txt stat" > /dev/null
    for t in approx_mult mode11_supervisor adaptive_multiplier; do
        echo "    $t: $(grep -E 'SB_LUT4|SB_CARRY|SB_DFF' build/synth/ice40_$t.txt | tr -s ' ' | tr '\n' ' ')"
    done
    if need nextpnr-ice40; then
        nextpnr-ice40 --hx8k --package ct256 --json build/adaptive_multiplier_ice40.json \
            --asc build/adaptive_multiplier.asc --freq 12 --timing-allow-fail > results/nextpnr.log 2>&1
        grep -E "ICESTORM_LC:|SB_IO:|Max frequency" results/nextpnr.log | tail -3 | sed 's/^Info: */    /'
        if need icepack; then icepack build/adaptive_multiplier.asc build/adaptive_multiplier.bin && echo "  [PASS] bitstream build/adaptive_multiplier.bin"; fi
    else
        echo "  [skip] nextpnr-ice40 not found"
    fi
fi

if [[ "$STEP" == all || "$STEP" == n16 ]]; then
    echo "== 8. 16-bit scaling check (N=16 RTL + N=16 LUT, compiled in build/n16) =="
    rm -rf build/n16 && mkdir -p build/n16
    cp $RTL rtl/n16/supervisor_lut.vh tb/tb_n16_smoke.v build/n16/
    ( cd build/n16 && iverilog -g2012 -I. -o tb_n16.vvp approx_mult.v mode11_supervisor.v adaptive_multiplier.v tb_n16_smoke.v \
        && vvp -n tb_n16.vvp ) > results/sim_n16.log 2>&1
    grep -E "^  |PASS|FAIL" results/sim_n16.log | sed 's/^/  /'
    check results/sim_n16.log "^PASS" "N=16 functional + budget"
    for t in approx_mult mode11_supervisor adaptive_multiplier; do
        ( cd build/n16 && yosys -q -p "read_verilog -I. approx_mult.v mode11_supervisor.v adaptive_multiplier.v; chparam -set N 16 $t; synth -top $t -flatten; tee -o generic16_$t.txt stat" > /dev/null )
        echo "    N=16 $t: $(grep 'Number of cells' build/n16/generic16_$t.txt | tr -s ' ')"
    done
fi

echo
if [[ $FAILED -eq 0 ]]; then echo "ALL STEPS PASSED"; else echo "SOME STEPS FAILED"; exit 1; fi
echo "Waveforms: gtkwave build/adaptive_multiplier.vcd   |   gtkwave build/mode11_cosim.vcd"
