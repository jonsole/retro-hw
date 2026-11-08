---
status: accepted
---

# The slot plan is ports, held in a register by the machine

The plan (`slot_owner`, `slot_lock`) comes in on ports, not parameters, so software can change it at run time, for example giving a blit the CPU's slot for its length. A machine with a fixed plan ties the ports to constants and the logic folds away; the plan register itself (40 bits for N = 7, S = 5) belongs to the machine.
