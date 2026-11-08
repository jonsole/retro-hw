# 0011. No tag between scheduler and memory controller

| | |
|---|---|
| Status | Accepted |
| Date | 8 November 2026 |
| Decided by | Jon ("drop the tag") |
| Applies to | `rtl/dmac.v`, `rtl/sram_ctl.v`; spec `docs/spec/dmac.md` |

## Context

`sram_ctl` carried a 3-bit tag through each cycle and handed it back with the read data, which limited the scheduler to 8 requesters.

## Decision

The read latency is fixed, so the scheduler keeps each cycle's winner in a shift register `RD_DELAY` clocks long and routes `rvalid` itself. `go_tag` and `rtag` are gone.

## Consequences

- No requester limit.
- The scheduler must know the memory's latency: `RD_DELAY`, 4 for `sram_ctl`.
- A memory with a varying latency would need a tag again (spec D1); one fixed per slot needs only a table (ADR 0013).
