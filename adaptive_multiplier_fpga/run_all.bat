@echo off
REM ======================================================================
REM run_all.bat -- full flow with oss-cad-suite on Windows
REM
REM   1. Open a terminal with the oss-cad-suite environment:
REM        <path-to>\oss-cad-suite\environment.bat     (or start.bat)
REM   2. cd into this folder and run:
REM        run_all.bat          everything
REM        run_all.bat sim      simulations only
REM        run_all.bat fpga     synthesis + iCE40 place and route only
REM        run_all.bat n16      16-bit scaling check only
REM
REM   Supervisor knob sweep (separate, ~3-5 min, needs python):
REM        python models\sweep_supervisor.py      (or --quick)
REM ======================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"
if not exist build mkdir build
if not exist build\synth mkdir build\synth
if not exist results mkdir results

set STEP=%1
if "%STEP%"=="" set STEP=all
set RTL=rtl/approx_mult.v rtl/mode11_supervisor.v rtl/adaptive_multiplier.v
set FAILED=0

if /I "%STEP%"=="fpga" goto FPGA
if /I "%STEP%"=="n16" goto N16

REM ---------------------------------------------------------------- 1
echo == 1. Lint ==
where verilator >nul 2>nul
if errorlevel 1 (
    echo   [skip] verilator not found in this oss-cad-suite build
) else (
    verilator --lint-only -Wall -Irtl --top-module adaptive_multiplier %RTL% > results\lint.log 2>&1
    if errorlevel 1 ( echo   [FAIL] lint - see results\lint.log & set FAILED=1 ) else ( echo   [PASS] verilator -Wall clean )
)

REM ---------------------------------------------------------------- 2
echo == 2. Datapath characterization: approx_mult, 65536 pairs x 16 widths ==
iverilog -g2012 -o build/tb_approx_mult.vvp rtl/approx_mult.v tb/tb_approx_mult.v || (set FAILED=1 & goto END)
vvp -n build/tb_approx_mult.vvp > results\sim_approx_mult.log
findstr /C:"Done. Wrote results/error_vs_width.csv" results\sim_approx_mult.log >nul
if errorlevel 1 ( echo   [FAIL] see results\sim_approx_mult.log & set FAILED=1 ) else ( echo   [PASS] width=0 bit-exact, results\error_vs_width.csv written )

REM ---------------------------------------------------------------- 3
echo == 3. Top level, all four modes ==
iverilog -g2012 -Irtl -o build/tb_adaptive_multiplier.vvp %RTL% tb/tb_adaptive_multiplier.v || (set FAILED=1 & goto END)
vvp -n build/tb_adaptive_multiplier.vvp > results\sim_adaptive_multiplier.log
findstr /R /C:"Test" /C:"^PASS" /C:"^FAIL" results\sim_adaptive_multiplier.log
findstr /R /C:"^PASS" results\sim_adaptive_multiplier.log >nul
if errorlevel 1 ( echo   [FAIL] see results\sim_adaptive_multiplier.log & set FAILED=1 ) else ( echo   [PASS] adaptive_multiplier functional )

REM ---------------------------------------------------------------- 4
echo == 4. Mode-11 co-simulation: ADAPTIVE vs STATIC ==
iverilog -g2012 -Irtl -o build/tb_mode11_supervisor.vvp %RTL% tb/tb_mode11_supervisor.v || (set FAILED=1 & goto END)
vvp -n build/tb_mode11_supervisor.vvp > results\sim_mode11_short.log
vvp -n build/tb_mode11_supervisor.vvp +PHASE_LEN=2000 +TRACE=results/supervisor_rtl_trace_long.csv +VCD=build/mode11_cosim_long.vcd > results\sim_mode11_long.log
echo    short run (3 x 100 ops):
findstr /R /C:"^phase" /C:"^[0-2] " /C:"^TOTAL" /C:"^worst" results\sim_mode11_short.log
echo    long run (3 x 2000 ops):
findstr /R /C:"^phase" /C:"^[0-2] " /C:"^TOTAL" /C:"^worst" results\sim_mode11_long.log
findstr /C:"CO-SIM DONE" results\sim_mode11_long.log >nul
if errorlevel 1 ( echo   [FAIL] see results\sim_mode11_long.log & set FAILED=1 ) else ( echo   [PASS] mode-11 co-simulation )

REM ---------------------------------------------------------------- 5
echo == 5. Python cross-check + plots (optional) ==
set PY=
where python3 >nul 2>nul && set PY=python3
if "!PY!"=="" ( where python >nul 2>nul && set PY=python )
if "!PY!"=="" (
    echo   [skip] python not found
) else (
    !PY! models/golden_model.py --n 8 --out results/error_vs_width_golden.csv --compare results/error_vs_width.csv > results\golden.log 2>&1
    findstr /C:"OK: golden model matches" results\golden.log >nul
    if errorlevel 1 ( echo   [FAIL] see results\golden.log & set FAILED=1 ) else ( echo   [PASS] golden model == RTL, all widths )
    !PY! -c "import matplotlib" >nul 2>nul
    if errorlevel 1 ( echo   [skip] matplotlib not installed: pip install matplotlib ) else ( !PY! models/plot_results.py )
)

if /I "%STEP%"=="sim" goto END

:FPGA
REM ---------------------------------------------------------------- 6
echo == 6. Generic synthesis, area breakdown ==
for %%T in (approx_mult mode11_supervisor adaptive_multiplier) do (
    yosys -q -p "read_verilog -Irtl %RTL%; synth -top %%T -flatten; tee -o build/synth/generic_%%T.txt stat" >nul
    echo    %%T:
    findstr /C:"Number of cells" build\synth\generic_%%T.txt
)

REM ---------------------------------------------------------------- 7
echo == 7. FPGA flow: synth_ice40 -^> nextpnr-ice40 HX8K CT256 -^> icepack ==
for %%T in (approx_mult mode11_supervisor) do (
    yosys -q -p "read_verilog -Irtl %RTL%; synth_ice40 -top %%T; tee -o build/synth/ice40_%%T.txt stat" >nul
)
yosys -q -l build/synth/ice40_top.log -p "read_verilog -Irtl %RTL%; synth_ice40 -top adaptive_multiplier -json build/adaptive_multiplier_ice40.json; tee -o build/synth/ice40_adaptive_multiplier.txt stat" >nul
for %%T in (approx_mult mode11_supervisor adaptive_multiplier) do (
    echo    %%T:
    findstr /C:"SB_LUT4" /C:"SB_CARRY" /C:"SB_DFF" build\synth\ice40_%%T.txt
)
where nextpnr-ice40 >nul 2>nul
if errorlevel 1 (
    echo   [skip] nextpnr-ice40 not found
) else (
    nextpnr-ice40 --hx8k --package ct256 --json build/adaptive_multiplier_ice40.json --asc build/adaptive_multiplier.asc --freq 12 --timing-allow-fail > results\nextpnr.log 2>&1
    findstr /C:"ICESTORM_LC:" /C:"SB_IO:" /C:"Max frequency" results\nextpnr.log
    icepack build/adaptive_multiplier.asc build/adaptive_multiplier.bin && echo   [PASS] bitstream build\adaptive_multiplier.bin
)

if /I "%STEP%"=="fpga" goto END

:N16
REM ---------------------------------------------------------------- 8
echo == 8. 16-bit scaling check: N=16 RTL + N=16 LUT, compiled in build\n16 ==
if exist build\n16 rmdir /s /q build\n16
mkdir build\n16
copy /y rtl\approx_mult.v build\n16\ >nul
copy /y rtl\mode11_supervisor.v build\n16\ >nul
copy /y rtl\adaptive_multiplier.v build\n16\ >nul
copy /y rtl\n16\supervisor_lut.vh build\n16\ >nul
copy /y tb\tb_n16_smoke.v build\n16\ >nul
pushd build\n16
iverilog -g2012 -I. -o tb_n16.vvp approx_mult.v mode11_supervisor.v adaptive_multiplier.v tb_n16_smoke.v
vvp -n tb_n16.vvp > ..\..\results\sim_n16.log 2>&1
for %%T in (approx_mult mode11_supervisor adaptive_multiplier) do (
    yosys -q -p "read_verilog -I. approx_mult.v mode11_supervisor.v adaptive_multiplier.v; chparam -set N 16 %%T; synth -top %%T -flatten; tee -o generic16_%%T.txt stat" >nul
    echo    N=16 %%T:
    findstr /C:"Number of cells" generic16_%%T.txt
)
popd
findstr /C:"  " /C:"PASS" /C:"FAIL" results\sim_n16.log
findstr /R /C:"^PASS" results\sim_n16.log >nul
if errorlevel 1 ( echo   [FAIL] see results\sim_n16.log & set FAILED=1 ) else ( echo   [PASS] N=16 functional + budget )

:END
echo.
if "%FAILED%"=="0" ( echo ALL STEPS PASSED ) else ( echo SOME STEPS FAILED )
echo Waveforms:  gtkwave build\adaptive_multiplier.vcd    /    gtkwave build\mode11_cosim.vcd
endlocal
