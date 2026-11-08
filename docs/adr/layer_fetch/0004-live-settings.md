---
status: accepted
---

# Depth, scale, wrap and stride are read live, on purpose

Some line settings are copied at the line start (`act`, `adv`, `ngroups`, the tile settings) and others are read live (`depth`, `planar`, `hscale`, `wrap`, `stride`), as the machines did. retro68k's spec said all of CTRL applies at the blank and asked the core to copy them; Jon chose live instead, so a copper or CPU write can change them mid-line for effects. retro68k changes its spec to match (its issue #34). A stride written mid-line applies at that line's end, if the line's last word has not yet been set up.
