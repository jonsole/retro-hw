# Wiring the DMA scheduler

`dmac` shares one SRAM between the CPU and the chipset. Every 20 ns there is a memory cycle; the scheduler gives each one to a channel. It sits between the channels and `sram_ctl.v`, and with `timebase.v` it makes the memory system. The rules and ports are in `docs/spec/dmac.md`.

## What you need

- `timebase.v` for `sc`, the edge counter within the 100 ns slot.
- `sram_ctl.v`, which gives `start_next` and `next_cycle` and takes the scheduler's `go_*`.
- A channel for each master: `req` held until `ack`, the address (a word address, bits 21–1) and, for writers, the data and byte enables.

## A minimal machine

A CPU and the test port, nothing else. Every other channel is tied off.

```verilog
wire [3:0]  sc;
wire        m_start, m_rvalid;
wire [2:0]  m_cycle, m_rtag, go_tag;
wire        go, go_we;
wire [21:1] go_addr;
wire [15:0] go_wdata, mem_rdata;
wire [1:0]  go_be;

timebase tb0 (.clk(clk), .rst(por), .ph(), .sc(sc));

dmac #(.CPU_CYCLES(5'b00101), .AUD_CYCLES(5'b10000),
       .CPU_FIRST(1), .NASTY(0), .HIGH(0)) sched (
    .clk(clk), .rst(por), .start_next(m_start), .next_cycle(m_cycle),
    .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
    .cpu_be(cpu_be), .cpu_ack(cpu_ack), .cpu_rvalid(cpu_rvalid),
    .bpl_req(1'b0), .bpl_addr(21'd0), .bpl_deadline(10'd0), .bpl_urgent(1'b0), .bpl_ack(), .bpl_rvalid(),
    .spr_req(1'b0), .spr_addr(21'd0), .spr_deadline(10'd0), .spr_urgent(1'b0), .spr_ack(), .spr_rvalid(),
    .aud_req(1'b0), .aud_addr(21'd0), .aud_ack(), .aud_rvalid(),
    .cop_req(1'b0), .cop_addr(21'd0), .cop_pri(2'd0), .cop_ack(), .cop_rvalid(),
    .blt_req(1'b0), .blt_we(1'b0), .blt_addr(21'd0), .blt_wdata(16'd0), .blt_be(2'b00),
    .blt_high(1'b0), .blt_share(2'd0), .blt_ack(), .blt_rvalid(),
    .port_req(port_req), .port_we(port_we), .port_addr(port_addr), .port_wdata(port_wdata),
    .port_be(port_be), .port_ack(port_ack), .port_rvalid(port_rvalid),
    .go(go), .go_we(go_we), .go_addr(go_addr), .go_wdata(go_wdata), .go_be(go_be),
    .go_tag(go_tag), .rvalid(m_rvalid), .rtag(m_rtag)
);

sram_ctl mem (.clk(clk), .rst(por), .sc(sc),
    .go(go), .go_we(go_we), .go_addr(go_addr), .go_wdata(go_wdata), .go_be(go_be), .go_tag(go_tag),
    .start_next(m_start), .next_cycle(m_cycle), .rvalid(m_rvalid), .rtag(m_rtag), .rdata(mem_rdata),
    /* the SRAM pins */ ...);
```

Every channel reads `mem_rdata` when its own `x_rvalid` is high.

## A read, clock by clock

The CPU asks in cycle 0 of a slot:

One column per clock:

```
 sc            8    9    0    1    2    3    4
 start_next    0    1    0    1    0    1    0
 next_cycle    .    0    .    1    .    2    .
 cpu_req       1    1    1    0    0    0    0
 go_tag        .  CPU    .    .    .    .    .
 cpu_ack       0    0    1    0    0    0    0
 cpu_rvalid    0    0    0    0    0    1    0
 mem_rdata                             data
```

`cpu_req` was high in the clock with `start_next` and `next_cycle` 0, so the scheduler gave the cycle to the CPU (`go`, `go_tag` 1) in that clock. The cycle starts at the next edge, the first of the clock with sc 0. The ack is high in that clock; the CPU drops `req` after it. The data is on `mem_rdata` with `cpu_rvalid` in the clock with sc 3, 30 ns after the cycle started.

## Choosing a slot plan

- **Can the CPU wait?** If the CPU's bus waits for an ack (as a 68000's does), keep the defaults: the CPU owns cycle 0, and an urgent display fetch may take it. If the CPU cannot be held off (a Z80 or 6502 on a fixed clock, with the memory access timed by the CPU clock), set `CPU_FIRST` and give it the cycles its bus cycle lines up with in `CPU_CYCLES`.
- **Display.** Leave the display its cycles 1 and 3 (`HARD_CYCLES`). Layers and sprites fill free cycles too.
- **Audio.** Give audio a cycle the CPU does not own (`AUD_CYCLES`).
- **Extras.** `NASTY` and `HIGH` let the copper and the DMA engine take the CPU's cycle. Turn them off if the machine has no such mode; the ports are then unused.

## Pitfalls

- **Hold the request.** `req` must stay high, with the address and data still, until the ack. Changing the address while waiting gives a cycle with the new address, which is fine; dropping `req` before the ack can lose the cycle or give one nobody wants.
- **One ack, one cycle.** After the ack, a channel that wants another word puts up its next request at once. Do not leave the old `req` high for an extra clock, or it gets a second cycle.
- **Deadlines in clocks.** `bpl_deadline` and `spr_deadline` are system clocks until the data is needed, counting down. `10'h3FF` means "no deadline".
- **The urgent mark.** With `CPU_FIRST`, an urgent request still waits for the CPU's cycles. Set the channel's urgent mark early enough for that.
- **Tie everything off.** An open `req` input is X in simulation and the scheduler's decision becomes X. Tie unused channels to 0.
- **The tag is 3 bits.** Seven channels use all of it.
