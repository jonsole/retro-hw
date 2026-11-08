---
status: accepted
---

# Choose the request mask first, then find its lowest bit once

The rules choose one of four request masks and the winner is its lowest set bit, found once, instead of finding the lowest bit of every mask and then choosing. In retro68k's full Vivado build this saved 76 LUTs and gained 0.039 ns of setup slack, for one more LUT level on the decision path.

## Consequences

- Out of context in Vivado the scheduler is 10 LUTs *larger* (141 to 151); the saving only appears once it merges with its neighbours. Don't judge or revert this logic on an out-of-context count.
- The decision is now retro68k's critical path; if its slack gets tight, try `sram_ctl` open point S7 first.
