---
status: accepted
---

# A fetch-enable change does not restart a fetch

retro68k restarted a fetch being set up on any write to BPLDMA, but the enables reach the fetch through a register and a group keeps its own list of words, so the restart changed nothing. The core has no restart for `dma_en`: a group uses the enables registered the clock before it starts. With `DATWRITE` the depth reaches a group start through the same register, a clock late, which matches retro68k exactly and is what the lockstep test showed.
