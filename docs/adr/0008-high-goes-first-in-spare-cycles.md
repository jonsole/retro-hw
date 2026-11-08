# 0008. A high request goes ahead of everyone in spare cycles

| | |
|---|---|
| Status | Accepted |
| Date | 8 November 2026 |
| Decided by | Claude, confirmed by Jon in the retrospective grilling |
| Applies to | `rtl/dmac.v`; spec `docs/spec/dmac.md` |

## Context

The old scheduler put a high-priority blitter ahead of the CPU only, behind the display and audio.

## Decision

In rule 4, all high requests go before all others, by number.

## Consequences

- Simple: one more mask.
- With the suggested numbering, a high blitter now goes ahead of the display in spare cycles. The display keeps its owned slots and its urgent requests (spec D3).
