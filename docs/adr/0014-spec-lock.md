# 0014. Lock the dmac spec

| | |
|---|---|
| Status | Accepted |
| Date | 8 November 2026 |
| Decided by | Jon ("lock the spec") |
| Applies to | `rtl/dmac.v`; spec `docs/spec/dmac.md` |

## Context

Three machines (retro68k, retro-z80, retro-6502) depend on the scheduler's interface.

## Decision

The ports, parameters and rules are fixed. A change needs a new revision agreed with the machines. Open points stay open and do not change the interface.

## Consequences

- The first locked spec in the repo, so this sets the convention.
- Corrections to analysis (the urgent worst case) and new open points are allowed without a revision.
