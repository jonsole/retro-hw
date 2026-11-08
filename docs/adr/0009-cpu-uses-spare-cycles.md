# 0009. The CPU can use spare cycles

| | |
|---|---|
| Status | Accepted |
| Date | 8 November 2026 |
| Decided by | Claude; confirmed safe by the retro-z80 session |
| Applies to | `rtl/dmac.v`; spec `docs/spec/dmac.md` |

## Context

The old scheduler only gave the CPU its own cycles, even when memory was idle.

## Decision

The CPU is an ordinary requester: it gets its owned slots and also any spare cycle it wins.

## Consequences

- The CPU runs faster when memory is quiet.
- Retro-z80 confirmed its bus takes the byte whenever `rvalid` comes, so an earlier cycle is harmless.
- +3 LUTs in the Z80 build at the time.
