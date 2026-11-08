#!/bin/sh
# Lint every core with Verilator. A value cut short to fit where it goes
# (WIDTHTRUNC) is an error; where cutting is meant, slice it or waive the line:
#   /* verilator lint_off WIDTHTRUNC */ ... /* verilator lint_on WIDTHTRUNC */
# Style warnings are left out; other warnings are shown but do not fail.
# Each file in rtl/ is linted with its first module as the top, against
# rtl/ alone, so a core never leans on a machine's files.
set -e
cd "$(dirname "$0")"
VERILATOR=${VERILATOR:-verilator}
LINT="$VERILATOR --lint-only --default-language 1364-2005 -Wall -Wno-style -Wno-fatal -Werror-WIDTHTRUNC -Irtl"
for f in rtl/*.v; do
    top=$(sed -n 's/^module \([A-Za-z0-9_]*\).*/\1/p' "$f" | head -1)
    $LINT --top-module "$top" rtl/*.v
done
$LINT --top-module hdmi_out platform/artix7/hdmi_out.v platform/artix7/lint_stub.v
$LINT --top-module oddr platform/artix7/oddr.v platform/artix7/lint_stub.v
$LINT --no-timing --top-module oddr platform/sim/oddr.v
echo "lint: no widths cut short"
