# 0015. Choose the request mask first, then find its lowest bit once

| | |
|---|---|
| Status | Accepted (merged with PR #4; confirmed in retro68k's Vivado build) |
| Date | 8 November 2026 |
| Decided by | Claude, from the RTL review; Jon asked for the PR |
| Applies to | `rtl/dmac.v`; spec `docs/spec/dmac.md` |

## Context

The scheduler found the lowest set bit of each of four masks in parallel, then chose between them.

## Decision

Choose the mask by the rules first, then find its lowest bit once. Same winner in every case; no port or behaviour change.

## Consequences

- One more LUT level on the decision path.
- Measured in retro68k's full Vivado build (XC7A35T, 40-bit programmable plan): 16,482 → 16,406 Slice LUTs (76 fewer), and setup slack +0.148 → +0.187 ns. Yosys had estimated about 50 fewer.
- Synthesised on its own (out of context) in Vivado, the scheduler is *larger*: 141 → 151 LUTs. The saving only appears once Vivado merges the decision logic with its neighbours in the full build. So don't judge a change to this logic by an out-of-context count, and don't revert this one because of it.
- No change expected for a constant plan (retro-z80); its KS2 numbers are still to come.
- The scheduler decision is now retro68k's critical path (bpldma's urgent compare → dmac → `sram_ctl`). If its slack gets tight, try `sram_ctl` open point S7 first.
