# Wiring the layer fetch

`layer_fetch` reads each layer's 16-pixel groups from memory into the data registers that `layer_pix.v` shows. It sits between the machine's register file and video beam on one side, and the memory scheduler (`dmac.v`) and the layer pixel units on the other. The rules and ports are in `docs/spec/layer_fetch.md`.

The core has no bus registers. The machine keeps its own register file and drives the settings as ports; the live pointers are inside the core, behind one load/read port.

## What you need

- `dmac.v`: one requester for the fetch (`req`, `urgent`, `addr`, `ack`, and that requester's `rvalid_o` bit), with `rdata` from `sram_ctl.v`.
- `layer_pix.v`, one a layer: `dat`, `attr`, `gset` and `fill_t` to it, `take_t` back.
- A beam that toggles `line_t` at the start of each horizontal blank (pixel clock; the core synchronises it).
- The line settings, worked out for the next line before `line_go`: `act`, `adv`, `ngroups`, and for tiles the map row and column.
- The layer settings `depth`, `planar` and `hscale`, straight from the register file: the core takes them at each group's start and passes them on to `layer_pix` with the group.
- A register file with the pointers' addresses, stride, wrap, the tile pointers and the rest.

## Choosing the build

| Parameter | Set it to |
|-----------|-----------|
| `NL` | The layers |
| `PLANAR` | 1 if any layer can be planar (one pointer a plane) |
| `TILES` | 1 if any layer can be a tile map |
| `DATWRITE` | 1 if software or a copper writes the data registers, or turns the fetch of single registers off |
| `LITTLE` | 1 on a little-endian machine: a word's even byte is its low byte and holds the pixels further left |
| `PW` | The pointer width: 23 to address 8 MB, 22 for 4 MB |
| `URG_BASE`, `URG_WORD` | The urgent mark, from the scheduler's worst case for this requester (below) |

`PLANAR` and `TILES` together is not supported.

## A minimal machine

Three chunky layers, no tiles, no writes to the data registers, a fixed plan on the scheduler. The register file holds three pointers (loaded through the core), three strides and three wrap settings:

```verilog
wire        lf_go, lf_gen, lf_req, lf_urg;
wire [20:0] lf_addr;
wire [383:0] lf_dat;
wire [17:0]  lf_gset;
wire [2:0]  lf_fill, lf_take;

layer_fetch #(.NL(3), .PW(22), .PLANAR(0), .TILES(0), .DATWRITE(0), .LITTLE(1),
              .URG_BASE(17), .URG_WORD(5)) fetch (
    .clk(clk), .rst(por), .enable(video_on && dma_on),
    .line_t(line_t), .line_go(lf_go), .line_gen(lf_gen),
    .act(act), .adv(adv), .depth(depth), .planar(3'd0), .hscale(hscale), .wrap(wrap),
    .stride(stride), .ngroups(ngroups),
    .tile(3'd0), .mapw(6'd0), .ty(30'd0), .tcol(21'd0), .mappt(66'd0), .patpt(66'd0),
    .ptr_sel({ptr_layer, 3'd0}), .ptr_wr(ptr_wr), .ptr_wdata(ptr_wdata), .ptr_rdata(ptr_rdata),
    .dat_wr(1'b0), .dat_sel(5'd0), .dat_wdata(16'd0), .dat_be(2'd0), .dma_en(24'hFFFFFF), .dat_rdata(),
    .dat(lf_dat), .attr(), .gset(lf_gset), .fill_t(lf_fill), .take_t(lf_take),
    .req(lf_req), .urgent(lf_urg), .addr(lf_addr), .ack(sched_ack[FETCH]), .rvalid(sched_rvalid[FETCH]),
    .rdata(mem_rdata)
);
```

`depth` is words a group − 1: 0, 1, 3 or 7 for chunky 1, 2, 4 or 8 bits a pixel (planes − 1 for a planar layer). `lf_gset[6n +: 6]` goes to layer n's `layer_pix` as its `gset`. A read-only requester on the scheduler: tie its `we`, `wdata` and `be` to 0 there.

## The register file

The core owns the pointers because they count on with every word read. Your register file:

- **Writes a pointer** with `ptr_sel` = {layer, plane}, `ptr_wr` and the whole value in `ptr_wdata`. For a byte or word write, read the current value from `ptr_rdata` (combinational from `ptr_sel`) and merge in the same clock:

```verilog
assign ptr_wdata = {be[2] ? bus_wdata[21:16] : ptr_rdata[21:16],
                    be[1] ? bus_wdata[15:8]  : ptr_rdata[15:8],
                    be[0] ? bus_wdata[7:1]   : ptr_rdata[7:1], 1'b0};
```

  Any write to a pointer, whatever bytes it carries, also sets the pointer's saved line start and restarts a fetch being set up.
- **Reads a pointer** from `ptr_rdata`. If your bus reads a clock later, register it.
- **Holds** stride, wrap, the tile pointers, map width and the rest, and drives them as ports. The spec's port table says for each whether the core copies it at the line start or reads it live.
- With `DATWRITE`, writes the data registers through `dat_wr`, `dat_sel`, `dat_wdata` and `dat_be`, and drives `dma_en` from its fetch-enable register.

## A line, clock by clock

```
 line_t        toggles ─┐
 line_go                └─ 2 clocks later, one clock high: settings copied, fetch starts
 req                       ... words of each layer's first group, nearest deadline first ...
 fill_t[n]                 toggles when layer n's group is complete; gset[n] is the group's settings
 take_t[n]                 layer_pix takes it (ahead of the window), the next group starts
```

- `line_go` also tells the machine the line has started on the system clock side; `line_gen` toggles with it and is what `layer_pix` gets as `ready`, through a synchroniser.
- The first group of each layer is fetched in the blank, ahead of the window.
- Read data comes back `RD_DELAY` clocks after the scheduler's ack (4 with `sram_ctl.v`); the scheduler routes `rvalid` to this requester.

## The urgent mark

A request is urgent when its layer's deadline is under `URG_BASE` + `URG_WORD` × (words of the group still to come). Work it out from the scheduler spec (section 4.6): the worst-case wait for this requester in every slot plan the machine uses, plus one clock because `urgent` is registered. `URG_WORD` is the clocks between this requester's words when it has the slots it owns: 5 for two owned slots in a 5-slot round. retro68k uses 15 and 5 (nothing locked); retro-z80 17 and 5 (the CPU's two slots locked).

## Pitfalls

- **Load the pointers before use.** Reset leaves them as they are.
- **Settings copied at the line start must be ready before `line_go`,** two clocks after `line_t` toggles. Work them out in the blank.
- **Live settings change at once.** A stride written any time before a pointer's reset applies at that line's end; wrap on the next pointer move. That is deliberate, for copper effects.
- **Depth, planar and scale belong to the group.** A write applies from the layer's next group start, and travels to `layer_pix` in `gset`, so the two sides always agree about a group. The fetch works a group ahead: the change shows one or two groups (16–32 source pixels) past where the beam was. A scale change mid-line also changes how many groups the window needs, and `ngroups` was fixed at the line start: the line ends with groups unshown, or runs out early (`layer_pix` spec 4.3).
- **The line end resets the pointers.** At each `line_go` every pointer read from since its last reset or write goes to its line start + stride, however much of the line was fetched (a starved fetch, `dma_en` cleared mid-line, a scale made wider mid-line), so the next line starts where it should. The resets take one clock a pointer (NL + 1, or 8 × NL + 1 with `PLANAR`) at the start of the blank. The short line itself is still short: give the display enough owned slots.
- **Split screens: write the pointer after the layer's last fetch.** A pointer written after its last read on a line, any time before its reset, starts the next line as written. One written while the line still has words to read from it gets the stride added at the line's end.
- **Tile patterns are chunky.** `PLANAR` and `TILES` are not built together.
- **`LITTLE` swaps data words, not map entries.** An entry is the word as read.
- **One requester, in order.** The scheduler returns this requester's reads in the order they were given; up to four can be on their way.
