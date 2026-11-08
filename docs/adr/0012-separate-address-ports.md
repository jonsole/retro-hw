# 0012. Each requester keeps its own address and data ports

| | |
|---|---|
| Status | Accepted |
| Date | 8 November 2026 |
| Decided by | Jon, after the trade-off was laid out |
| Applies to | `rtl/dmac.v`; spec `docs/spec/dmac.md` |

## Context

Proposed: share one address bus, with the requester putting its address up when it gets its ack.

## Decision

Keep separate ports. The ack comes the clock after the decision, too late for the address. Sharing would need the grant a cycle earlier, adding 20 ns to every access, and inside an FPGA a shared bus is still a mux or OR tree.

## Consequences

- Saving would have been about 40-60 LUTs at best.
- Revisit only if LUTs get tight on the Z80 board.
