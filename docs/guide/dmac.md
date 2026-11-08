# Wiring the memory-cycle scheduler

`dmac` shares one SRAM between a number of requesters. Every 20 ns there is a memory cycle; the scheduler gives each one to a requester. It sits between the requesters and `sram_ctl.v`, and with `timebase.v` it makes the memory system. The rules and ports are in `docs/spec/dmac.md`.

The scheduler does not know what its requesters are. You choose how many there are (N) and how many slots the plan has (S), and you number the requesters: a lower number goes first wherever two meet.

## What you need

- `timebase.v` for `sc`, the edge counter within the 100 ns round.
- `sram_ctl.v`, which gives `start_next` and `next_cycle` and takes the scheduler's `go_*`.
- For each requester: `req` held until `ack`, the address (a word address) and, for writers, the data and byte enables.
- A slot plan: a register, or constants.

## A minimal machine

Two requesters: the CPU (0) and the test port (1). Five slots, so `next_cycle` from `sram_ctl.v` is the slot number. The CPU owns slot 0; the rest are free.

```verilog
wire [3:0]  sc;
wire        m_start, m_rvalid;
wire [2:0]  m_cycle;
wire        go, go_we;
wire [20:0] go_addr;
wire [15:0] go_wdata, mem_rdata;
wire [1:0]  go_be;
wire [1:0]  ack, rvalid_o;

timebase tb0 (.clk(clk), .rst(por), .ph(), .sc(sc));

dmac #(.N(2), .S(5)) sched (
    .clk(clk), .rst(por), .start_next(m_start), .next_slot(m_cycle),
    // Slot plan: slot 0 owned by requester 0 (the CPU), slots 1-4 by nobody
    .slot_owner({2'b00, 2'b00, 2'b00, 2'b00, 2'b01}), .slot_lock(5'b00000),
    .req({port_req, cpu_req}), .urgent(2'b00), .high(2'b00),
    .we({port_we, cpu_we}), .addr({port_addr, cpu_addr}),
    .wdata({port_wdata, cpu_wdata}), .be({port_be, cpu_be}),
    .ack(ack), .rvalid_o(rvalid_o),
    .go(go), .go_we(go_we), .go_addr(go_addr), .go_wdata(go_wdata), .go_be(go_be),
    .rvalid(m_rvalid)
);
assign {port_ack, cpu_ack}       = ack;
assign {port_rvalid, cpu_rvalid} = rvalid_o;

sram_ctl mem (.clk(clk), .rst(por), .sc(sc),
    .go(go), .go_we(go_we), .go_addr(go_addr), .go_wdata(go_wdata), .go_be(go_be),
    .start_next(m_start), .next_cycle(m_cycle), .rvalid(m_rvalid), .rdata(mem_rdata),
    /* the SRAM pins */ ...);
```

Every requester reads `mem_rdata` when its own `rvalid_o` bit is high.

## A read, clock by clock

The CPU (requester 0) asks in the clock before slot 0:

```
 sc            8    9    0    1    2    3    4
 start_next    0    1    0    1    0    1    0
 next_slot     .    0    .    1    .    2    .
 req[0]        1    1    1    0    0    0    0
 ack[0]        0    0    1    0    0    0    0
 rvalid_o[0]   0    0    0    0    0    1    0
 mem_rdata                             data
```

`req[0]` was high in the clock with `start_next` and slot 0, and the CPU owns slot 0, so the scheduler gave it the cycle (`go`) in that clock. The cycle starts at the next edge. The ack is high in the clock after; the CPU drops `req` then. The data is on `mem_rdata` with `rvalid_o[0]` in the clock with `sc` 3: the scheduler kept the CPU's number for those 4 clocks, so it knows the controller's `rvalid` is the CPU's.

## Numbering the requesters

The number is the priority. Put first those that suffer most from waiting: display fetches (they have deadlines), then audio, then the copper, then the CPU, then the DMA engine, and the test port last. A requester that must go ahead of lower numbers only sometimes uses `high` (rule 4) or a slot plan that makes it owner of a slot.

## Choosing a slot plan

The plan is two ports: `slot_owner`, one N-bit mask a slot (slot 0 in the low bits), and `slot_lock`, one bit a slot. Put them in a register the CPU can write, and the plan is programmable.

- **Can the CPU wait?** If the CPU's bus waits for an ack (as a 68000's does), make it owner of a slot and leave the slot unlocked: an urgent display fetch may take it. If the CPU cannot be held off (a Z80 or 6502 on a fixed clock), make it owner of the slots its bus cycle lines up with and lock them.
- **Display.** Give the layers and the sprites shared slots (both bits set in the mask). The lower number goes first there; the other takes the slot when the first doesn't ask, or by being urgent elsewhere.
- **Audio.** Give it a slot nobody else owns.
- **Spare cycles** go to high requests first, then by number.
- **A big blit, or a busy copper.** Make it owner of the CPU's slot while it runs, then put the CPU back.

## Slots other than 5

With S = 5, `next_cycle` from `sram_ctl.v` is the slot number. For another S, count the cycles yourself:

```verilog
reg [SW-1:0] slot;
always @(posedge clk)
    if (por)          slot <= 0;
    else if (m_start) slot <= (slot == S - 1) ? 0 : slot + 1'b1;
```

and drive `next_slot` from `slot`. If a requester's timing is tied to the round (a CPU on a fixed bus clock), line the counter up with it.

## Pitfalls

- **Hold the request.** `req` must stay high, with the address and data still, until the ack. Changing the address while waiting gives a cycle with the new address, which is fine; dropping `req` before the ack can lose the cycle or give one nobody wants.
- **One ack, one cycle.** After the ack, a requester that wants another word puts up its next request at once. Do not leave the old `req` high for an extra clock, or it gets a second cycle.
- **Tie off read-only requesters.** `we`, `wdata` and `be` 0. Left open, they cost LUTs in the mux and are X in simulation.
- **Tie everything off, and reset the rest.** An open `req` bit is X in simulation and the scheduler's decision becomes X. Tie unused bits to 0, and make sure every requester's `req`, `urgent` and `high` come from reset flip-flops: the decision is a chain of `?:` choices, so one X input spreads into the winner (retro68k's DMA test hung on an unreset high flag; the old if-chain had read the X as false).
- **The urgent mark.** An urgent request still waits for locked slots and for urgent requests from lower numbers. Set each requester's mark early enough for that (spec 4.6).
- **Changing the plan.** It applies from the next cycle decided. Software must not take a locked slot away from a CPU that cannot wait.
- **The read delay.** `RD_DELAY` must be the memory controller's read latency in clocks: 4 for `sram_ctl.v`. Wrong by one, and read data goes to the wrong requester. `test/dmac`'s `tb_dmac_sram` checks the pair together.
