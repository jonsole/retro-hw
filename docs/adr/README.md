# Architecture decision records

One file for each decision that shaped a core, with its context and what followed from it. Numbers are never reused; a decision that is replaced keeps its file, marked Superseded, and points to the one that replaces it.

The first 15 were written after the fact, on 8 November 2026, for the scheduler rework (PRs #2 to #4). The decisions Claude had made on its own were put to Jon one by one before they were recorded.

| # | Decision | Status |
|---|----------|--------|
| [0001](0001-owned-slots-with-priority-fallback.md) | Owned slots, with priority for spare cycles | Accepted |
| [0002](0002-programmable-slot-plan.md) | The slot plan is ports, held in a register by the machine | Accepted |
| [0003](0003-generic-numbered-requesters.md) | Generic requesters, numbered; the number is the priority | Accepted |
| [0004](0004-owner-mask-per-slot.md) | Each slot has an owner mask, so a slot can have several owners | Accepted |
| [0005](0005-lock-bit-per-slot.md) | A lock bit per slot, in place of CPU_FIRST | Accepted |
| [0006](0006-rule-order.md) | Rule order: locked owner, urgent, owner, high, any | Accepted |
| [0007](0007-no-deadline-compare.md) | Urgent ties go by number, not by deadline | Accepted |
| [0008](0008-high-goes-first-in-spare-cycles.md) | A high request goes ahead of everyone in spare cycles | Accepted |
| [0009](0009-cpu-uses-spare-cycles.md) | The CPU can use spare cycles | Accepted |
| [0010](0010-drop-cpu-share.md) | Drop the HIGH-mode CPU share | Accepted |
| [0011](0011-no-memory-tag.md) | No tag between scheduler and memory controller | Accepted |
| [0012](0012-separate-address-ports.md) | Each requester keeps its own address and data ports | Accepted |
| [0013](0013-park-12-5-ns.md) | Park the 12.5 ns memory cycle; plan revision 1.1 | Accepted (parked) |
| [0014](0014-spec-lock.md) | Lock the dmac spec | Accepted |
| [0015](0015-mask-first-winner.md) | Choose the request mask first, then find its lowest bit once | Proposed (PR #4) |
