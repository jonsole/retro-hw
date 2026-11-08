---
status: accepted
---

# Owned slots, with priority for spare cycles

Each slot of the plan has owners, who get it when they ask; a slot its owners don't use goes to the other requesters by priority, so no cycle is wasted. We kept slots instead of serving every cycle by priority alone, because owned slots give each requester a bandwidth floor and a worst-case wait that can be worked out from the plan, stop the top of a priority order starving the bottom, and give a Z80 or 6502 that cannot wait cycles that line up with its bus.
