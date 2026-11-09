---
status: accepted
---

# Depth, planar and scale travel with the group

A layer's depth, planar flag and scale are taken at each group's start, from a one-clock register of the inputs, and go to `layer_pix` beside the group's data as `gset`; `layer_pix` keeps no settings of its own for them. With 0004 the fetch read them live and `layer_pix` read the machine's registers, so a mid-line write reached the two sides at different pixels and a group could be fetched at one depth and shown at another. Both machines asked for the change (retro68k #34, retro-z80 design plan branch 26) and Jon chose it over copying the settings at the line start, which would have lost mid-line copper effects. The group's deadline is loaded from its own scale; a map entry's deadline, a group further on, still uses the live scale. `transp` and `palofs` stay raw inputs of `layer_pix` (its spec 4.4). Wrap and stride stay live as in 0004. Cost: about 100 LUTs and 30 flip-flops in retro-z80's build, 10 and 30 in retro68k's, 15 and 6 a `layer_pix`.
