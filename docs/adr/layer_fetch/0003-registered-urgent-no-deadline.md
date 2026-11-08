---
status: accepted
---

# `urgent` is registered; there is no `deadline` output

The scheduler no longer uses a deadline, so the fetch has no `deadline` output, and `urgent` is a register rather than a combinational compare. The compare was the head of retro68k's critical path, which runs through the scheduler's decision into `sram_ctl`; registering it takes that compare off the path at the cost of one clock on the mark, which is why the machines' marks (`URG_BASE`) are their old values plus 1.
