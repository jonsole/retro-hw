# retro-hw

Hardware cores shared by three machines on the ZX Spectrum Next's FPGA: [retro68k](https://github.com/jonsole/retro68k) (a 68000), [retro-z80](https://github.com/jonsole/retro-z80) (a Z80) and retro-6502 (to come). They are the same machine with a different CPU.

Each machine pulls this repo in as a git submodule at `fpga/retro-hw`, pinned to a commit, and moves to a newer commit when it is ready.

## What is here

A core is the engine of a unit: the part that is the same whatever CPU drives it. The register side stays in each machine, because the buses differ (byte registers on the Z80 and 6502, 16- and 32-bit registers on the 68000). Each machine has a thin wrapper per unit that maps its registers onto a core's ports.

| Folder | What |
|--------|------|
| `rtl/` | The cores, plain Verilog-2005 |
| `platform/artix7/` | Xilinx 7-series parts: DDR output, HDMI serialiser |
| `platform/sim/` | Behavioural stand-ins for the platform parts |
| `sim/` | Models for testbenches: SRAM, FT232H, PS/2 keyboard |
| `test/` | A unit test per core, one folder each |

## Rules for a core

1. No register bus inside. Ports are plain strobes, valid flags and data; configuration comes in as plain input ports that the wrapper drives from its registers.
2. Ports are named for what they mean, not after either CPU's registers.
3. One clock domain per core, unless it has two by nature (HDMI).
4. A feature only one machine uses sits behind a parameter, so the other builds without it.
5. Every core split out of a unit has a unit test in `test/<core>/`, run by CI.
6. Lint-clean under Verilator with widths cut short as errors (`lint.sh`).

## Changes

Any machine's session may open a pull request. CI here runs the lint and every unit test. Each machine's own CI checks that it still builds and passes against a new commit before it moves its submodule.

Where a file came from is recorded in `PROVENANCE.md`.

## Running the checks

    sh lint.sh
    make -C test

Icarus Verilog 12 and Verilator 5 are needed.

## Licence

MIT, as the machines.
