# 0010. Drop the HIGH-mode CPU share

| | |
|---|---|
| Status | Accepted |
| Date | 8 November 2026 |
| Decided by | The retro68k user, relayed by the retro68k session |
| Applies to | `rtl/dmac.v`; spec `docs/spec/dmac.md` |

## Context

In retro68k's HIGH mode, a blit took the CPU's cycle but left the CPU 1 in 2, 4 or 8 of them, so it could still run interrupts. The programmable plan has no share counter.

## Decision

No share. A high-priority blit owns the CPU's slot for its length; the CPU gets spare cycles only.

## Consequences

- One counter and its special case gone.
- retro68k updates its specs 5, 6, 10 and 11; a long blit can now stall the CPU completely.
