# 0002. The slot plan is ports, held in a register by the machine

| | |
|---|---|
| Status | Accepted |
| Date | 8 November 2026 |
| Decided by | Jon ("I would like the slots to be programmable") |
| Applies to | `rtl/dmac.v`; spec `docs/spec/dmac.md` |

## Context

The old slot plan was a set of fixed parameters (CPU_CYCLES, HARD_CYCLES, AUD_CYCLES), so it could not change at run time.

## Decision

The plan comes in on two ports, `slot_owner` and `slot_lock`. The machine drives them from a register, or ties them to constants. A change applies from the next cycle decided, even mid-round.

## Consequences

- Software can switch plans, for example giving a blit the CPU's slot for its length.
- A machine with a fixed plan ties the ports to constants and the logic folds away (the Z80 build).
- The plan register lives in the machine: 40 bits for N = 7, S = 5.
