# Documents

Every core in retro-hw has a spec and a guide here.

- A **spec** (`spec/`) says exactly what a core does: its ports, parameters, behaviour clock by clock, what the machine around it must provide, how it is tested and what is still open.
- A **guide** (`guide/`) is for wiring the core into a machine: what it does, a minimal instantiation, a timing sketch of a typical transaction, and the pitfalls.

Each machine documents its own instantiation: the registers that drive a core, their addresses, the parameter values it builds with, and how it is wired. Those stay in that machine's repo, not here. Values the specs mention from a machine are examples only.

| Core | Files | Spec | Guide |
|------|-------|------|-------|
| SRAM controller | `rtl/sram_ctl.v` | [spec/sram_ctl.md](spec/sram_ctl.md) | [guide/sram_ctl.md](guide/sram_ctl.md) |
| Byte FIFO | `rtl/fifo8.v` | [spec/fifo8.md](spec/fifo8.md) | [guide/fifo8.md](guide/fifo8.md) |
| TMDS encoder | `rtl/tmds_encoder.v` | [spec/tmds_encoder.md](spec/tmds_encoder.md) | [guide/tmds_encoder.md](guide/tmds_encoder.md) |
| PS/2 keyboard engine | `rtl/ps2_core.v` | [spec/ps2_core.md](spec/ps2_core.md) | [guide/ps2_core.md](guide/ps2_core.md) |
| Sigma-delta modulator | `rtl/sigma_delta2.v` | [spec/sigma_delta2.md](spec/sigma_delta2.md) | [guide/sigma_delta2.md](guide/sigma_delta2.md) |
| FT232H interface | `rtl/ft232h_if.v` | [spec/ft232h_if.md](spec/ft232h_if.md) | [guide/ft232h_if.md](guide/ft232h_if.md) |
| Link command and escape decoder | `rtl/slip_rx.v` | [spec/slip_rx.md](spec/slip_rx.md) | [guide/slip_rx.md](guide/slip_rx.md) |
| Serial link (FIFOs and decoder) | `rtl/serial_link.v` | [spec/serial_link.md](spec/serial_link.md) | [guide/serial_link.md](guide/serial_link.md) |
| Sprite fetcher | `rtl/sprite_fetch.v` | [spec/sprite_fetch.md](spec/sprite_fetch.md) | [guide/sprite_fetch.md](guide/sprite_fetch.md) |
| Sprite pixel unit | `rtl/sprite_pix.v` | [spec/sprite_pix.md](spec/sprite_pix.md) | [guide/sprite_pix.md](guide/sprite_pix.md) |
| Memory-cycle scheduler (generic: N requesters, S slots) | `rtl/dmac.v` | [spec/dmac.md](spec/dmac.md) | [guide/dmac.md](guide/dmac.md) |
| Time base | `rtl/timebase.v` | [spec/timebase.md](spec/timebase.md) | [guide/timebase.md](guide/timebase.md) |
| Layer pixel unit | `rtl/layer_pix.v` | [spec/layer_pix.md](spec/layer_pix.md) | [guide/layer_pix.md](guide/layer_pix.md) |
| Layer fetch | `rtl/layer_fetch.v` | [spec/layer_fetch.md](spec/layer_fetch.md) | [guide/layer_fetch.md](guide/layer_fetch.md) |
| Copper engine | `rtl/copper_engine.v` | [spec/copper_engine.md](spec/copper_engine.md) | [guide/copper_engine.md](guide/copper_engine.md) |
| Blitter, first design (being replaced) | `rtl/blitter.v` | [spec/blitter_v1.md](spec/blitter_v1.md) | [guide/blitter.md](guide/blitter.md) |
| Blitter, redesign (spec only) | – | [spec/blitter.md](spec/blitter.md) | – |
| Rasteriser: lines and triangles (spec only) | – | [spec/raster.md](spec/raster.md) | – |
| Geometry engine (spec only) | – | [spec/geom.md](spec/geom.md) | – |
| Platform parts: HDMI output, DDR output register | `platform/artix7/hdmi_out.v`, `oddr.v`, `lint_stub.v`; `platform/sim/oddr.v` | [spec/platform.md](spec/platform.md) | [guide/platform.md](guide/platform.md) |

## Decisions

The reasons behind the cores' design are in [adr/](adr/README.md), one folder a block and one file a decision.

## Style

As the machines' specs: plain short sentences, British spelling, tables. A spec has the sections Summary, Ports, Parameters, Behaviour, How a machine uses it, Test plan and Open points, and starts with its status.
