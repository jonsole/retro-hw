# Reference copies for the lockstep test

Frozen copies of the two machines' layer fetches, used only as the oracle
for `tb_lock68k.v` and `tb_lockz80.v`. Not built into anything.

| File | From | Commit |
|------|------|--------|
| `bpldma_68k.v` | retro68k `fpga/rtl/bpldma.v` | 709a94d |
| `bpldma_z80.v` | retro-z80 `fpga/rtl/bpldma.v` | d938197 |

Changes from the originals: the module renamed, and the `regmap.vh`
include dropped (neither file used anything from it).
