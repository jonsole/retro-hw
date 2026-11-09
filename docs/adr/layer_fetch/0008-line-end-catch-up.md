---
status: proposed
---

# A pointer that started a line always gets its line-end move

A pointer moves to its next line's start with the last word it gives on a line. Until revision 3 a line that ended before that word (a starved fetch, `dma_en` cleared mid-line) left the pointer where it stopped, which both machines' `bpldma.v` did and the spec accepted. Revision 2 made a mid-line scale increase a normal effect, and it leaves groups owed at the window's end every time, so every later line of the layer started from the wrong address (retro-z80's #100). Now a pointer that gave its first word on a line but not its last is moved at the next `line_go`: to its saved start, plus the stride if that line's `adv`, with the stride and wrap of the clock the move is made in. It is judged per pointer, as retro68k asked, so a plane that gave no word (its `dma_en` bit off) or a tile layer's pointer is left alone, and a `ptr_wr` before the move cancels it. The moves are made one a clock through the pointer RAM's own write port while stage A waits, so a line that finished costs nothing; the price is a flag a pointer and a small sequencer. Doing the move lazily at the pointer's first use in the new line would cost no clocks, but `ptr_rdata` would show the stale pointer in the blank, and both machines asked for every move before the first group is set up.
