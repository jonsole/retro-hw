---
status: accepted
---

# Urgent ties go by number, not by deadline

When two urgent requests meet, the lower number wins; there are no deadline inputs. The old scheduler compared the layers' and sprites' deadlines with two 10-bit comparators, and a generic version would need one per requester. Each requester still uses its own deadline to decide when to raise `urgent`.

## Consequences

- The sprites' worst case on the Z80 plan is 12 clocks (6 + 2W, W = 3, found by retro-z80); their urgent mark must allow for it.
- `sprite_fetch.v`'s `mem_deadline` output is now unused (spec D2).
