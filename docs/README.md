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
| Platform parts: HDMI output, DDR output register | `platform/artix7/hdmi_out.v`, `oddr.v`, `lint_stub.v`; `platform/sim/oddr.v` | [spec/platform.md](spec/platform.md) | [guide/platform.md](guide/platform.md) |

## Style

As the machines' specs: plain short sentences, British spelling, tables. A spec has the sections Summary, Ports, Parameters, Behaviour, How a machine uses it, Test plan and Open points, and starts with its status.
