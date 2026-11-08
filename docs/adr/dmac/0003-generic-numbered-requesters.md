---
status: accepted
---

# Generic requesters, numbered; the number is the priority

The scheduler has N requesters numbered 0 to N-1, not named channels, and wherever two meet the lower number wins. Everything that used to make a channel special (CPU, display, copper, blitter) is now an input the machine drives: its number, owned slots, and urgent and high bits. So the CPU is an ordinary requester and also wins spare cycles, which the old scheduler never gave it; retro-z80 confirmed its bus takes data whenever `rvalid` comes, so that is safe.
