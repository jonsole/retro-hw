# Architecture decision records

One short file a decision: what was decided and why, in the style of the `domain-modeling` skill. Only decisions that are hard to reverse, surprising without context and the result of a real trade-off get one.

The records are grouped by hardware block, one folder each, numbered within the folder. A decision that spans blocks lives with the block that owns the behaviour and is listed under both. Numbers are never reused; a replaced decision keeps its file, marked superseded.

## Memory-cycle scheduler (`dmac/`)

Written after the fact on 8 November 2026, for the scheduler rework (PRs #2 to #5).

| # | Decision | Status |
|---|----------|--------|
| [0001](dmac/0001-owned-slots-with-priority-fallback.md) | Owned slots, with priority for spare cycles | accepted |
| [0002](dmac/0002-programmable-slot-plan.md) | The slot plan is ports, held in a register by the machine | accepted |
| [0003](dmac/0003-generic-numbered-requesters.md) | Generic requesters, numbered; the number is the priority | accepted |
| [0004](dmac/0004-owner-mask-per-slot.md) | Each slot has an owner mask | accepted |
| [0005](dmac/0005-lock-bit-per-slot.md) | A lock bit per slot, in place of CPU_FIRST | accepted |
| [0006](dmac/0006-rule-order.md) | Urgent requests beat the owner of an unlocked slot | accepted |
| [0007](dmac/0007-no-deadline-compare.md) | Urgent ties go by number, not by deadline | accepted |
| [0008](dmac/0008-high-goes-first-in-spare-cycles.md) | A high request goes ahead of everyone in spare cycles | accepted |
| [0009](dmac/0009-cpu-uses-spare-cycles.md) | The CPU can use spare cycles | superseded by dmac/0003 |
| [0010](dmac/0010-drop-cpu-share.md) | Drop the HIGH-mode CPU share | accepted |
| [0011](dmac/0011-no-memory-tag.md) | No tag between scheduler and memory controller | accepted |
| [0012](dmac/0012-separate-address-ports.md) | Each requester keeps its own address and data ports | accepted |
| [0013](dmac/0013-park-12-5-ns.md) | Park the 12.5 ns memory cycle | accepted (parked) |
| [0014](dmac/0014-spec-lock.md) | Lock the dmac spec | accepted |
| [0015](dmac/0015-mask-first-winner.md) | Choose the request mask first, then find its lowest bit once | accepted |

## SRAM controller (`sram_ctl/`)

No records of its own yet. Two scheduler decisions changed it: [dmac/0011](dmac/0011-no-memory-tag.md) (no tag) and [dmac/0013](dmac/0013-park-12-5-ns.md) (the parked 12.5 ns cycle).

## Layer fetch (`layer_fetch/`)

From the layers grilling and the machines' reviews of the spec, 8 November 2026 (PR #7).

| # | Decision | Status |
|---|----------|--------|
| [0001](layer_fetch/0001-one-core-no-registers.md) | One layer fetch core, with no bus registers | accepted |
| [0002](layer_fetch/0002-one-requester-nearest-deadline.md) | One scheduler requester for all layers, nearest deadline first inside | accepted |
| [0003](layer_fetch/0003-registered-urgent-no-deadline.md) | `urgent` is registered; there is no `deadline` output | accepted |
| [0004](layer_fetch/0004-live-settings.md) | Depth, scale, wrap and stride are read live, on purpose | accepted |
| [0005](layer_fetch/0005-pointers-not-reset.md) | Reset leaves the pointers and their saved starts alone | accepted |
| [0006](layer_fetch/0006-no-restart-on-enable-change.md) | A fetch-enable change does not restart a fetch | accepted |

## Sprite fetch (`sprite_fetch/`)

| # | Decision | Status |
|---|----------|--------|
| [0001](sprite_fetch/0001-scheduler-side-as-layer-fetch.md) | The sprite fetch's scheduler side matches the layer fetch's | accepted |
