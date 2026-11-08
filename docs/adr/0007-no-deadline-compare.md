# 0007. Urgent ties go by number, not by deadline

| | |
|---|---|
| Status | Accepted |
| Date | 8 November 2026 |
| Decided by | Claude, confirmed by Jon in the retrospective grilling |
| Applies to | `rtl/dmac.v`; spec `docs/spec/dmac.md` |

## Context

The old scheduler compared the layers' and sprites' deadlines (two 10-bit comparators) and served the one due first. A generic scheduler would need a deadline per requester.

## Decision

No deadline inputs. When two requests meet in a rule, the lower number wins. Each requester still uses its own deadline to decide when to raise `urgent`.

## Consequences

- No comparators.
- The sprites' worst case on the Z80 plan is 12 clocks (6 + 2W, W = 3), found by the retro-z80 session; its urgent mark must allow for that.
- `sprite_fetch.v`'s `mem_deadline` output is now unused (spec D2).
