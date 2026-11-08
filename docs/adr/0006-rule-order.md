# 0006. Rule order: locked owner, urgent, owner, high, any

| | |
|---|---|
| Status | Accepted |
| Date | 8 November 2026 |
| Decided by | Claude, confirmed by Jon in the retrospective grilling |
| Applies to | `rtl/dmac.v`; spec `docs/spec/dmac.md` |

## Context

With owners, locks, urgent and high flags, the order of the rules decides which guarantees hold.

## Decision

For each cycle: an owner of a locked slot; then an urgent request; then an owner; then a high request; then any request. Within a rule, the lowest number wins. Urgent requests beat the owner of an unlocked slot.

## Consequences

- Urgent waits stay short; only locked slots are fully guaranteed to their owners.
- An unlocked owner's wait is bounded only by how often others are urgent.
