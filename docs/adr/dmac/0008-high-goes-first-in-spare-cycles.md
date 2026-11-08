---
status: accepted
---

# A high request goes ahead of everyone in spare cycles

In spare cycles all high requests go before all others, by number. The old scheduler put a high-priority blitter ahead of the CPU only, behind the display and audio; with the suggested numbering a high blitter now also goes ahead of the display in spare cycles. The display keeps its owned slots and urgent requests, so it stays protected (spec D3).
