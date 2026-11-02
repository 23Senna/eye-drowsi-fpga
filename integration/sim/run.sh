#!/usr/bin/env bash
# run.sh - Icarus regression.  Usage (from anywhere):  bash sim/run.sh [tb_name ...]
#   no args = all testbenches; prints one PASS/FAIL line per testbench.
#   GEN=1 bash sim/run.sh   rebuilds mem/*.mem, rtl/model_params.vh, vectors and the sim/*.mem ROM copies
#   from the CNN team's repo (../eye-drowsi-fpga/ml/export) first - do this after a git pull.
#   tb_top_real runs the team's cnn_top (~76k cycles per image), so it takes a few minutes.
set -u
cd "$(dirname "$0")"
IV="${IVERILOG_BIN:-/d/iverilog/bin}"
PY="${PYTHON:-py -3.11}"
RTL=../rtl
# CNN team's RTL (cnn_top.v, rom_weights.v): <repo>/rtl when this folder is <repo>/integration
if [ -f ../../rtl/cnn_top.v ]; then TEAM_DEF=../../rtl; else TEAM_DEF=../../eye-drowsi-fpga/rtl; fi
TEAM="${TEAM_RTL:-$TEAM_DEF}"
TEAM_SRC=""; for m in cnn_top rom_weights conv1_layer conv2_layer fc_layer mac_pipe relu_requant maxpool2x2; do TEAM_SRC="$TEAM_SRC $TEAM/$m.v"; done
mkdir -p build

# generated files missing (fresh clone) -> generate them first
[ -f vectors/drowsy_trace.mem ] && [ -f conv1_w.mem ] && [ -f ../mem/images.mem ] || GEN=1
[ "${GEN:-0}" = "1" ] && { $PY ../scripts/gen_sim_data.py || exit 1; }

declare -A SRC=(
  [tb_input_control]="$RTL/input_control.v"
  [tb_alert_control]="$RTL/alert_control.v"
  [tb_drowsy_fsm]="$RTL/drowsy_fsm.v"
  [tb_roms]="$RTL/image_rom.v $RTL/weight_bias_rom.v"
  [tb_cnn_control]="$RTL/cnn_control.v"
  [tb_top]="-DUSE_STUB $RTL/drowsiness_top.v $RTL/input_control.v $RTL/drowsy_fsm.v $RTL/alert_control.v $RTL/image_rom.v $RTL/weight_bias_rom.v $RTL/cnn_core_stub.v"
  [tb_top_real]="$RTL/drowsiness_top.v $RTL/input_control.v $RTL/drowsy_fsm.v $RTL/alert_control.v $TEAM_SRC"
)
SERIAL=""; for m in uart_rx uart_tx uart_command uart_ascii_tx uart_monitor; do SERIAL="$SERIAL $RTL/$m.v"; done
SRC[tb_top]="${SRC[tb_top]} $SERIAL"
SRC[tb_top_real]="${SRC[tb_top_real]} $SERIAL"
SRC[tb_uart_phy]="$RTL/uart_rx.v $RTL/uart_tx.v"
SRC[tb_uart_command]="$RTL/uart_command.v"
SRC[tb_uart_format]="$SERIAL"
SRC[tb_uart_latency]="$SERIAL"
SRC[tb_uart_system]="${SRC[tb_top_real]}"
TBS="${*:-tb_input_control tb_alert_control tb_drowsy_fsm tb_roms tb_cnn_control tb_top tb_top_real tb_uart_phy tb_uart_command tb_uart_format tb_uart_latency tb_uart_system}"

fail=0
for tb in $TBS; do
  [ -f "$tb.v" ] || { echo "SKIP $tb (no $tb.v)"; continue; }
  opts=""; files=""
  for w in ${SRC[$tb]}; do case "$w" in -*) opts="$opts $w" ;; *) files="$files $w" ;; esac; done
  if ! "$IV/iverilog" -g2012 -Wall -s "$tb" -I"$RTL" -I. $opts -o "build/$tb.vvp" "$tb.v" $files 2> "build/$tb.compile.log"; then
    echo "FAIL $tb (compile, see sim/build/$tb.compile.log)"; fail=1; continue
  fi
  grep -v "timescale" "build/$tb.compile.log" | grep -i -E "warning|error" | head -3
  "$IV/vvp" -n "build/$tb.vvp" > "build/$tb.log" 2>&1
  res=$(grep -E "^(PASS|FAIL)" "build/$tb.log" | tail -1)
  echo "${res:-FAIL $tb (no result, see sim/build/$tb.log)}"
  case "$res" in PASS*) ;; *) fail=1; grep "^FAIL" "build/$tb.log" | head -5 ;; esac
done
exit $fail
