---
status: accepted
---

# Each slot has an owner mask

Each slot has an N-bit owner mask rather than a single owner number, so layers and sprites can share the display slots (lower number first). The cost is a wider plan register: S x N bits instead of S x 3.
