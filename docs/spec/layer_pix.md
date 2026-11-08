# Layer pixel unit (layer_pix)

Status: **draft**

One layer's pixel side. It takes the layer's 16-pixel groups from its data registers (filled by the machine's layer fetch on the system clock), shows them pixel by pixel in the layer's window, with fine scroll and horizontal scaling, and gives a colour index per pixel to the priority stage. Groups cross from the system clock to the pixel clock under a full / taken handshake of toggles. A group that is not there in time makes the layer transparent for that group (overrun).

## 1. Summary

| Item | Value |
|------|-------|
| File | `rtl/layer_pix.v`, module `layer_pix` |
| Clocks | Two by nature: the pixel clock, and 5 × the pixel clock (same MMCM, edges lined up) for the fast synchroniser of "full" |
| Group | 16 source pixels: chunky 1, 2, 4 or 8 words; planar 1–8 words (one per plane) |
| Depths | Chunky 1, 2, 4, 8 bits per pixel; planar 1–8 planes (with `PLANAR`) |
| Scaling | Each source pixel 1, 2, 4 or 8 screen pixels wide |
| Fine scroll | The first pixel shown, 0–15, in the first group |
| Palette offset | 4 bits, above a pixel of up to 4 bits |
| Tiles | With `TILES`: two tile columns of 8 pixels per group, each with its own palette and priority |
| Latency | One pixel clock: the output in the clock after the beam is on the pixel |
| Registers | None |

## 2. Ports

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk_pix` | in | 1 | Pixel clock | – |
| `clk_pix5` | in | 1 | 5 × `clk_pix`, rising edges lined up with it | – |
| `en` | in | 1 | Video on. Low: nothing shown, the handshake emptied, overrun cleared | `clk_pix` |
| `hc` | in | 11 | The beam's pixel in the line (0 the first visible pixel) | `clk_pix` |
| `hn` | in | 11 | The next pixel's position (`hc` + 1, or 0 after the last) | With `hc` |
| `line_start` | in | 1 | One clock at the start of the horizontal blank: the line's setup starts | `clk_pix` |
| `ready` | in | 1 | The data registers hold this line's data (the fetch has restarted for it) | `clk_pix`, any delay |
| `active` | in | 1 | The layer shows on this line | Stable through the line |
| `xs`, `xe` | in | 11, 11 | The window: pixels `xs` to `xe` − 1 | Stable through the line |
| `planar` | in | 1 | With `PLANAR`: a planar layer | Stable through the line |
| `lb` | in | 2 | Chunky: log2 of the bits per pixel | Stable through the line |
| `planes` | in | 3 | With `PLANAR`: planes − 1 | Stable through the line |
| `hs` | in | 2 | log2 of the horizontal scale | Stable through the line |
| `pos0` | in | 4 | The first source pixel shown in the first group (fine scroll) | Stable through the line |
| `transp` | in | 1 | Colour value 0 is transparent | Stable through the line |
| `palofs` | in | 4 | Palette offset: the top 4 bits of the index for a pixel of up to 4 bits | Stable through the line |
| `tile` | in | 1 | With `TILES`: a tile layer, palette and priority from `attr` | Stable through the line |
| `dat` | in | 128 | The 8 data registers, register 0 in bits 15–0 | Stable while full |
| `attr` | in | 10 | With `TILES`: {PRI, PAL} of tile column 1 (bits 9–5) and column 0 (bits 4–0) | With `dat` |
| `fill_t` | in | 1 | Toggles when a group is complete in the data registers | System clock |
| `take_t` | out | 1 | Toggles when the unit takes a group into its shifters | `clk_pix` |
| `opaque` | out | 1 | This pixel shows | `clk_pix`, one clock after the beam pixel |
| `idx` | out | 8 | Its colour index | With `opaque` |
| `pri` | out | 1 | With `TILES`: a tile pixel whose column has PRI set; else 0 | With `opaque` |
| `raw` | out | 8 | The pixel value itself, 0 outside the window (for direct colour) | With `opaque` |
| `overrun_t` | out | 1 | Toggles each time a group was not there when needed | `clk_pix` |

## 3. Parameters

| Name | Default | Meaning | For example |
|------|---------|---------|-------------|
| `PLANAR` | 1 | 1: planar layers built (`planar`, `planes` used) | 0 in a machine with chunky layers only |
| `TILES` | 0 | 1: tile layers' palette and priority built (`tile`, `attr` used, `pri` driven) | 1 in a machine whose layer fetch reads tile maps |

With a feature off, its inputs are not used and synthesis builds nothing for it.

## 4. Behaviour

### 4.1 The group

A group is 16 source pixels.

| Kind | Words | Layout |
|------|-------|--------|
| Chunky, 2^lb bits per pixel | 2^lb, in data registers 2^lb − 1 down to 0 | Packed pixels. The leftmost pixel is in the top bits of the first word, which is in the highest data register used; data register 0 holds the last word |
| Planar, `planes` + 1 planes | One per plane: plane p in data register p | The leftmost pixel in bit 15 of each word; plane p gives bit p of the value |

The pixel's value is 1–8 bits. The colour index is:

| Depth | Index |
|-------|-------|
| Up to 4 bits (chunky 1, 2, 4 bits; planar 1–4 planes) | {`palofs`, value[3:0]}; for a tile layer {`palofs` + PAL, value[3:0]} (4-bit sum) |
| More than 4 bits (chunky 8 bits; planar 5–8 planes) | The value itself |

For a tile layer, source pixels 0–7 of a group are tile column 0 and use `attr` bits 4–0; pixels 8–15 are column 1 and use bits 9–5. Bit 4 (or 9) is PRI, bits 3–0 (or 8–5) PAL. `pri` is PRI for every pixel of a tile layer, whatever its depth.

### 4.2 The handshake

- "Full" is `fill_t` != `take_t`. `fill_t` crosses to the unit through two flip-flops on `clk_pix5`, so a new group is seen 2–3 fast clocks after `fill_t` toggles; the second flip-flop is then read on `clk_pix` as a related clock.
- Taking a group copies all 8 data registers (and `attr`) into the shifters and toggles `take_t`. The fetch side may then fill the next group.
- The fetch side must not change `dat` or `attr` while full.

### 4.3 A line

| When | What happens |
|------|--------------|
| `line_start` | The line ends: nothing shown, the first group not yet taken |
| After it, when `ready` and full | The first group is taken, ahead of the window |
| The clock with `hn` = `xs` | The pixel counter goes to `pos0`, the scale counter to 0. If the first group was not taken, it is taken now, or an overrun is counted |
| Each clock with `xs` ≤ `hc` < `xe` | One screen pixel. After 2^hs screen pixels the next source pixel; after source pixel 15 the next group is taken (if `hn` < `xe`), or an overrun is counted |
| Outside the window | `opaque` 0, `raw` 0 |

Each output is registered: the pixel the beam is on in one clock (`hc`) comes out in the next. So the window's first pixel is out in the clock with `hc` = `xs` + 1.

A pixel is opaque when it is in the window, its group arrived, and not (`transp` and value 0). After an overrun the layer is transparent until the next group boundary, where the unit tries again.

### 4.4 Video off

While `en` is low, `opaque` and `overrun_t` are 0 and `take_t` follows "full" in, so nothing is waiting when video comes back on.

## 5. How a machine uses it

The machine gives each layer a unit and:

- A beam on the pixel clock: `hc`, `hn` and `line_start` one clock long at the start of the horizontal blank.
- The line's settings, worked out in the blank and held through the line.
- A layer fetch on the system clock, with 8 data registers per layer (and the tile attributes with `TILES`). At the line's start it empties the handshake (sets `fill_t` to the `take_t` it sees, so a spare group from the last line is dropped) and fetches the line's first group; then it fills a group each time one is taken. It gives `ready` once it has restarted for the line, through a synchroniser.
- A per-group deadline on its side: a group lasts 16 × 2^hs pixel clocks once the window has started.
- Something that counts `overrun_t` toggles, if the machine reports overruns.

The unit has no registers: what the settings are called and where they live is the machine's.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/layer_pix` | Two units (the defaults; and `TILES` without `PLANAR`), a 200-pixel beam and a fetch stand-in that fills a group whenever one is taken. Every pixel of every line against a model: `opaque` in the window only, `idx` (and `pri`) of the right source pixel. Lines: chunky 1, 2, 4, 8 bits; planar 1, 3, 5, 8 planes; fine scroll 5, 9 and 15; scale 2, 4, 8; the palette offset; transparent colour 0 (chunky and planar); a later window; a window that ends one pixel into a group; a layer not active; tiles at 1, 2, 4, 8 bits with PAL and PRI per column; a planar unit ignoring `tile`; a fetch that stops after 2 or 3 groups (the rest transparent, `overrun_t` toggles); a full line after that |
| The machines' system tests | The machines' video tests (frames compared with a model) and the overrun reports |

## 7. Open points

| # | Point |
|---|-------|
| L1 | Planar tiles (tile layers with planar patterns) are not built: `TILES` assumes chunky patterns |
| L2 | The palette offset is added to PAL in 4 bits: a sum past 15 wraps. Should it saturate? |
| L3 | `raw` is the value before the palette, for direct colour; neither machine uses it yet |
