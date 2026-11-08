---
status: accepted
---

# One scheduler requester for all layers, nearest deadline first inside

The fetch is one requester on the memory scheduler and picks the next layer itself by nearest deadline (round robin on a tie). Giving each layer its own requester would let the scheduler choose, but it chooses by number, so the earliest-deadline choice between layers would be lost, and it would take NL requester numbers instead of one.
