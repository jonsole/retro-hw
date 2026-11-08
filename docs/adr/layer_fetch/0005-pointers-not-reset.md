---
status: accepted
---

# Reset leaves the pointers and their saved starts alone

`rst` does not clear the pointers or saved line starts. retro68k keeps them in LUT RAM, and resetting them would cost about 1,100 flip-flops in a planar build; nothing in either machine depends on a pointer being 0 after reset. Software loads them before use. A consequence for tests: a bench must load every pointer before the first line.
