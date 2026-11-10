---
status: accepted
---

# One job at a time, with a chain to the next

The first blitter interleaved four channels on one datapath: a scheduler, saved and restored progress for each, and a fast path for a channel running alone. No software ran more than one channel at once. The new cores run one job at a time; a job names a next descriptor, which the core loads itself when the job ends, so lists of jobs (retro-z80's demos chain up to 54) still run with no CPU in between. Pause, per-job priority and timer and copper starts go with the channels; control is start, stop, busy, an error flag and one done strobe.
