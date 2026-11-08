---
status: accepted
---

# Urgent requests beat the owner of an unlocked slot

The rules run: locked slot's owner, urgent, owner, high, any. Putting urgent above unlocked owners keeps urgent waits short, at the cost that only locked slots are fully guaranteed to their owners; an unlocked owner's wait is bounded only by how often others are urgent.

## Considered Options

- Owners always win their slot: every owned slot guaranteed and no lock bit needed, but urgent requests wait longer. Rejected.
