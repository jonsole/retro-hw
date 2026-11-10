---
status: accepted
---

# Lines and triangles in `raster`; point transforms in `geom`

Lines and edges moved out of the blitter into what Jon called a 3D accelerator, to be rethought rather than moved as they were. It is two cores, because drawing and arithmetic share nothing and the KS2 has no room for both: `raster` draws lines and flat-filled triangles from screen points (filling directly replaces the old edges-then-fill), and `geom` rotates, translates and projects a list of points by a 3×4 matrix in 16-bit fixed point. Jon chose triangle points over ready-made slopes for `raster`, so it carries a small serial divider and every machine can use it from a plain CPU. The KS2 builds `raster` alone and its Z80 does the geometry; the KS3 and retro68k can build `geom`.
