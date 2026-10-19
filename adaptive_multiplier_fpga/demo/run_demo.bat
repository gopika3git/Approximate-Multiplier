@echo off
REM run_demo.bat -- Review 2 live demo (Windows, oss-cad-suite terminal). Run from the package root.
if not exist build mkdir build
if not exist results mkdir results
set RTL=rtl/approx_mult.v rtl/mode11_supervisor.v rtl/adaptive_multiplier.v
echo == DEMO 1: all four modes against an independent reference ==
iverilog -g2012 -Irtl -o build/tb_adaptive_multiplier.vvp %RTL% tb/tb_adaptive_multiplier.v
vvp -n build/tb_adaptive_multiplier.vvp | findstr /R "Test PASS FAIL"
pause
echo == DEMO 2: closed loop vs open loop, 3 x 2000 ops ==
iverilog -g2012 -Irtl -o build/tb_mode11_supervisor.vvp %RTL% tb/tb_mode11_supervisor.v
vvp -n build/tb_mode11_supervisor.vvp +PHASE_LEN=2000 +TRACE=results/supervisor_rtl_trace_long.csv +VCD=build/mode11_cosim_long.vcd
pause
echo == DEMO 3: FPGA build ==
call run_all.bat fpga
pause
echo == DEMO 4: application demo (needs python, numpy, matplotlib, scikit-image) ==
python demo\image_demo.py --out demo\results_demo
echo Waveforms: gtkwave build\adaptive_multiplier.vcd  /  gtkwave build\mode11_cosim_long.vcd
