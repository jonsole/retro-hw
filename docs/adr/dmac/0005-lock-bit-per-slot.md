---
status: accepted
---

# A lock bit per slot, in place of CPU_FIRST

In a locked slot, an owner that asks beats urgent requests. This replaces the old CPU_FIRST mode with something any requester can use, for a CPU that cannot be held off. Locks lengthen urgent requests' worst-case wait (spec 4.6), so lock only what must be locked.
