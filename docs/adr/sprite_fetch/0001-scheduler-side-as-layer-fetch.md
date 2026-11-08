---
status: accepted
---

# The sprite fetch's scheduler side matches the layer fetch's

The sprite fetch loses its `mem_deadline` output (the scheduler orders requesters by number now) and its `mem_urgent` becomes a register, taking an 8:1 mux and compare off the path into the scheduler's decision; retro-z80's KS2 build had its worst path in `sprite_fetch` once the layer fetch was adopted. The `URGENT` mark is left as it was: it counts in units of 8 clocks, and a registered compare is at most one clock later, so raising the mark by a unit would make sprites urgent 8 clocks sooner than needed and take CPU cycles for nothing. The byte-swap parameter is renamed `LITTLE` and an `AW` parameter added, so the two fetch cores read the same.

## Considered Options

- Raise `URGENT` by one unit for the registered compare: rejected, as above.
- Rework the sprite deadline into the layer fetch's clocks-and-words form: rejected; a sprite fetches one word at a time into a 32-word FIFO, so "words still to come" has no meaning here, and the 8-clock unit is already right for it.
