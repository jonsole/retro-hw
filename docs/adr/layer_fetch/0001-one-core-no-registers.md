---
status: accepted
---

# One layer fetch core, with no bus registers

retro68k's and retro-z80's `bpldma.v` become one core, `layer_fetch`. It has no bus registers: each machine keeps its register file and bus and drives the settings as ports, and the live pointers, which must be inside because they count on with every word read, are behind one addressed load/read port. Planar layers, tile layers and data-register writes are build options (`PLANAR`, `TILES`, `DATWRITE`) that cost nothing when off; `NL` layers, `PW` pointer bits and `LITTLE` byte order are parameters. This follows the repo's convention (what settings are called and where they live is the machine's) and keeps the 32-bit and 8-bit buses out of the shared core.
