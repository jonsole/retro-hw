# 0005. A lock bit per slot, in place of CPU_FIRST

| | |
|---|---|
| Status | Accepted |
| Date | 8 November 2026 |
| Decided by | Claude, confirmed by Jon in the retrospective grilling |
| Applies to | `rtl/dmac.v`; spec `docs/spec/dmac.md` |

## Context

A CPU that cannot be held off must get its cycles even when the display is urgent. The old scheduler had a CPU_FIRST mode for this.

## Decision

Each slot has a lock bit. In a locked slot, an owner that asks beats urgent requests.

## Consequences

- The same mechanism works for any requester, not only a CPU.
- Locks lengthen the worst-case wait of urgent requests (spec 4.6); lock only what must be locked.
