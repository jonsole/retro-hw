# 0004. Each slot has an owner mask, so a slot can have several owners

| | |
|---|---|
| Status | Accepted |
| Date | 8 November 2026 |
| Decided by | Jon, in the retrospective grilling |
| Applies to | `rtl/dmac.v`; spec `docs/spec/dmac.md` |

## Context

Each slot needs owners. A single owner number per slot is smaller (3 bits a slot for 7 requesters); a mask is wider (7 bits a slot).

## Decision

Each slot has an N-bit owner mask. Among owners that ask, the lower number wins.

## Consequences

- Layers and sprites share the display slots, as they did before.
- The plan register is wider: S x N bits of owners.
