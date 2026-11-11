#!/bin/sh
# Every register must have one driver. A register assigned in two always
# blocks simulates fine (the last write wins) but synthesis keeps one
# driver, or stops: Vivado's DRC MDRV-1, or a constant reset that silently
# wins over the logic (Synth 8-6859). Verilator does not report it when
# both blocks share a clock, so Yosys synthesises each core here for
# 7-series and fails on any net with more than one driver (check -assert).
#
# Each file in rtl/ is checked with its first module as the top and the
# default parameters; a core whose options change what is built is also
# checked in the machines' builds (BUILDS below).
set -e
cd "$(dirname "$0")"
YOSYS=${YOSYS:-yosys}
fail=0

check() {   # top, chparam arguments (may be empty)
    if [ -n "$2" ]; then ch="chparam $2 $1;"; else ch=""; fi
    if ! out=$($YOSYS -q -p "read_verilog -Irtl rtl/*.v; $ch synth_xilinx -family xc7 -top $1; check -assert" 2>&1); then
        echo "drivers: $1 ${2:-(defaults)}: fails:"
        printf '%s\n' "$out" | grep -iE "conflicting|error" | head -20 | sed 's/^/    /'
        fail=1
    fi
}

for f in rtl/*.v; do
    top=$(sed -n 's/^module \([A-Za-z0-9_]*\).*/\1/p' "$f" | head -1)
    check "$top" ""
done

# The machines' builds of the cores with build options
check layer_fetch "-set PLANAR 1 -set DATWRITE 1 -set PW 23"
check layer_fetch "-set PLANAR 1 -set DATWRITE 1 -set PW 23 -set DATREAD 0"
check layer_fetch "-set PLANAR 0 -set TILES 1 -set LITTLE 1"
check layer_fetch "-set NL 1 -set PLANAR 0 -set TILES 1 -set LITTLE 1"
check layer_pix   "-set PLANAR 0 -set TILES 1"
check blitter     "-set LE 1 -set MASKIMG 0"
check blitter     "-set LE 0 -set MASKIMG 1"
check raster      "-set LE 1 -set TRI 1"
check raster      "-set LE 0 -set TRI 0"
check geom        "-set AW 20"
check sigma_delta2 "-set ORDER 1"
check audio_engine "-set NCH 2 -set AW 20 -set LE 1 -set INTERP 0 -set RDBACK 0"

if [ $fail -ne 0 ]; then exit 1; fi
echo "drivers: every register has one driver"
