#!/usr/bin/env bash
################################################################################
# FuseSoC entry point for the pyUVM/cocotb vip_mc example.
################################################################################
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -x "$HOME/.local/verilator/bin/verilator" ]; then
  export PATH="$HOME/.local/verilator/bin:$PATH"
fi

# cocotb imports mc_tb_top from tb/; that top bootstraps the remaining paths.
export PYTHONPATH="$HERE/tb${PYTHONPATH:+:$PYTHONPATH}"

CORE="akerlund::vip_mc_example_py:0"

if [ "$#" -eq 0 ]; then
  fusesoc --cores-root "$HERE" run --target lint "$CORE"
  fusesoc --cores-root "$HERE" run --target sim "$CORE"
else
  fusesoc --cores-root "$HERE" run "$@" "$CORE"
fi
