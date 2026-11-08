# 0015. Choose the request mask first, then find its lowest bit once

| | |
|---|---|
| Status | Proposed (PR #4) |
| Date | 8 November 2026 |
| Decided by | Claude, from the RTL review; Jon asked for the PR |
| Applies to | `rtl/dmac.v`; spec `docs/spec/dmac.md` |

## Context

The scheduler found the lowest set bit of each of four masks in parallel, then chose between them.

## Decision

Choose the mask by the rules first, then find its lowest bit once. Same winner in every case; no port or behaviour change.

## Consequences

- About 50 fewer LUTs for a build with a plan register (Yosys); no change for a constant plan.
- One more LUT level on the decision path.
- To be confirmed in retro68k's Vivado build.
