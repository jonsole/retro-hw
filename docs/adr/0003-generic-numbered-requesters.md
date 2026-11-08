# 0003. Generic requesters, numbered; the number is the priority

| | |
|---|---|
| Status | Accepted |
| Date | 8 November 2026 |
| Decided by | Jon ("requestors should be generic, not assigned to particular functions") |
| Applies to | `rtl/dmac.v`; spec `docs/spec/dmac.md` |

## Context

The scheduler had seven named channels (CPU, layers, sprites, audio, copper, blitter, test port), each with its own special rules.

## Decision

N requesters and S slots are parameters. Requesters are numbered 0 to N-1, and wherever two meet, the lower number wins. Everything special about a requester is an input the machine drives: its number, its owned slots, its urgent and high bits.

## Consequences

- Any machine can use the scheduler with any set of masters.
- The machine chooses priority by how it numbers its requesters.
- Read-only requesters tie their write inputs to 0, which costs nothing in the mux.
