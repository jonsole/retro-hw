---
status: accepted
---

# Drop the HIGH-mode CPU share

In retro68k's HIGH mode a blit took the CPU's cycle but left the CPU 1 in 2, 4 or 8 of them, so it could still run interrupts. The programmable plan has no share counter: a high-priority blit owns the CPU's slot for its length and the CPU gets spare cycles only, so a long blit can stall the CPU completely. This was the retro68k user's call; retro68k updates its specs 5, 6, 10 and 11.
