---
status: accepted
---

# The full minterm stays; the blitter does not clip or range-check

Jon kept the Amiga's 8-bit minterm of mask, source and destination rather than a short list of operations: it is a few LUTs a bit, and both machines' guides and tests are written in it. All four depths at any pixel position stay too, since placing an object at any pixel is the point of a blitter. What goes is everything around the datapath that software can do: rectangles are clipped by software, as they always were; addresses are not checked against the memory size (a 24-bit compare on every address, one of the old core's carry chains); and rows are worked bottom-up by giving negative strides, leaving only right-to-left within a row as a core mode.
