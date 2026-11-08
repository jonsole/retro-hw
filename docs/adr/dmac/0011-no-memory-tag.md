---
status: accepted
---

# No tag between scheduler and memory controller

`sram_ctl`'s read latency is fixed, so the scheduler keeps each cycle's winner for `RD_DELAY` clocks (4) and routes `rvalid` itself, instead of passing a 3-bit tag through the controller and back. This removes the 8-requester limit, at the price that the scheduler must know the memory's latency. A memory whose latency varies per access (SDRAM) would need a tag again; one fixed per slot needs only a table (dmac/0013).
