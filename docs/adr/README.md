# Architecture decision records

One short file a decision: what was decided and why, in the style of the `domain-modeling` skill. Only decisions that are hard to reverse, surprising without context and the result of a real trade-off get one. Numbers are never reused; a replaced decision keeps its file, marked superseded.

The first 15 were written after the fact on 8 November 2026, for the scheduler rework (PRs #2 to #5).

| # | Decision | Status |
|---|----------|--------|
| [0001](0001-owned-slots-with-priority-fallback.md) | Owned slots, with priority for spare cycles | accepted |
| [0002](0002-programmable-slot-plan.md) | The slot plan is ports, held in a register by the machine | accepted |
| [0003](0003-generic-numbered-requesters.md) | Generic requesters, numbered; the number is the priority | accepted |
| [0004](0004-owner-mask-per-slot.md) | Each slot has an owner mask | accepted |
| [0005](0005-lock-bit-per-slot.md) | A lock bit per slot, in place of CPU_FIRST | accepted |
| [0006](0006-rule-order.md) | Urgent requests beat the owner of an unlocked slot | accepted |
| [0007](0007-no-deadline-compare.md) | Urgent ties go by number, not by deadline | accepted |
| [0008](0008-high-goes-first-in-spare-cycles.md) | A high request goes ahead of everyone in spare cycles | accepted |
| [0009](0009-cpu-uses-spare-cycles.md) | The CPU can use spare cycles | superseded by ADR-0003 |
| [0010](0010-drop-cpu-share.md) | Drop the HIGH-mode CPU share | accepted |
| [0011](0011-no-memory-tag.md) | No tag between scheduler and memory controller | accepted |
| [0012](0012-separate-address-ports.md) | Each requester keeps its own address and data ports | accepted |
| [0013](0013-park-12-5-ns.md) | Park the 12.5 ns memory cycle | accepted (parked) |
| [0014](0014-spec-lock.md) | Lock the dmac spec | accepted |
| [0015](0015-mask-first-winner.md) | Choose the request mask first, then find its lowest bit once | accepted |
