# 0001. Owned slots, with priority for spare cycles

| | |
|---|---|
| Status | Accepted |
| Date | 8 November 2026 |
| Decided by | Jon, in review (first question of the session) |
| Applies to | `rtl/dmac.v`; spec `docs/spec/dmac.md` |

## Context

The old scheduler had fixed slots per channel. The question was whether to drop slots and serve every cycle by priority alone.

## Decision

Keep owned slots. A slot's owner gets it when it asks; a slot its owners don't use goes to the other requesters by priority, so no cycle is wasted.

## Consequences

- Each requester gets a floor of bandwidth and a worst-case wait that can be worked out from the plan (spec 4.6).
- Pure priority would let the requesters at the top starve those at the bottom, and make CPU timing depend on display and blitter load.
- A Z80 or 6502 that cannot wait needs cycles that line up with its bus; slots give it that.
