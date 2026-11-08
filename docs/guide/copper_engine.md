# Wiring in the copper engine

`copper_engine` runs a copper list: it fetches 16-bit words from memory, runs one instruction at a time, waits for the beam, and looks after jumps, the stack, the starts and the frame restart. It does not know what the words mean. Your machine decodes them: for the instruction at the front of the buffer, you tell the engine how many words it needs, how many it takes up, and what it does. You keep the registers and make the register write. The full details are in [the spec](../spec/copper_engine.md).

## What you write

A copper for a new machine is the engine plus a wrapper with three parts:

1. **Registers.** The control bits, two list pointers, status, and any index, general and flag registers your instruction set has. Bus writes to the start and stack registers become one-clock strobes.
2. **A decoder.** Combinational, from `word0`–`word2` and your registers: `need`, `len`, `skip_len`, `op`, `target`, the position fields, `cc`.
3. **The work.** On `exec`: latch the write's address and data, step an index register. On `more`: the ALU. On `error`: set a status bit. On `save2`: write `save2_at` into the list 2 pointer.

## A minimal instantiation

A made-up set with fixed two-word instructions: the first word's top 4 bits are the op, a WRITE carries an 8-bit register number and 8 bits of data, WAIT and SKIP carry a line and a pixel, JUMP and CALL a place.

```verilog
wire [15:0] w0, w1, w2;
wire        exec, more, error, save2, stopped, waiting, wr_req;
wire [21:1] save2_at, pc, cop_addr;
wire [3:0]  sp;

// The decoder: every instruction is two words
reg [3:0] op;
always @(*) case (w0[15:12])
    4'h0: op = 4'd1;                          // WRITE
    4'h1: op = (w0[10:0] == 11'h7FF) ? 4'd8   // WAIT for the impossible: the end
                                     : 4'd2;  // WAIT
    4'h2: op = 4'd3;                          // SKIP
    4'h3: op = 4'd5;                          // JUMP
    4'h4: op = 4'd8;                          // STOP
    default: op = 4'd9;                       // reserved: error
endcase

copper_engine #(.AW(21), .WR_HANDSHAKE(0)) cop (
    .clk(clk), .rst(rst),
    .run(cop_on && dma_on), .frame(frame_start),
    .start1(wr_strobe_start1), .start2(wr_strobe_start2),
    .list1(list1_ptr), .list2(list2_ptr),
    .resume(ctrl_resume), .stack_keep(1'b0), .stack_clear(1'b0),
    .save2(save2), .save2_at(save2_at),
    .word0(w0), .word1(w1), .word2(w2),
    .need(2'd2), .len(2'd2), .skip_len(2'd2), .op(op),
    .target({w0[5:0], w1[15:1]}),
    .pos_line(w0[10:0]), .pos_px(w1[10:0]), .pos_rel(1'b0), .wait_blt(w1[15]),
    .cc(4'd0), .flags(3'd0),
    .exec(exec), .more(more), .error(error),
    .wr_req(wr_req), .wr_go(1'b1),
    .stopped(stopped), .waiting(waiting), .pc(pc), .sp(sp),
    .mem_req(cop_req), .mem_addr(cop_addr),
    .mem_ack(cop_ack), .mem_rvalid(cop_rvalid), .mem_rdata(cop_rdata),
    .beam_v(beam_v), .beam_h(beam_h), .blt_idle(blt_idle)
);

// The write: latched when the instruction runs, on the bus with wr_req
always @(posedge clk) if (exec && op == 4'd1) begin
    wr_reg  <= w0[7:0];
    wr_data <= w1[7:0];
end
// List 2's place over a frame start; the bus's own write comes after
always @(posedge clk) if (save2) list2_ptr <= save2_at;
```

The op codes are the engine's: 1 WRITE, 2 WAIT, 3 SKIP, 5 JUMP, 8 STOP, 9 ERR (the spec, section 4.2).

## Timing sketch

A WAIT, then two writes, with `WR_HANDSHAKE` = 0. The words are already in the buffer.

One clock is six characters; the edges are where `clk` rises.

```
edge         0     1     2     3     4     5     6
clk          ‾‾‾___‾‾‾___‾‾‾___‾‾‾___‾‾‾___‾‾‾___‾‾‾
state        Wait  Wait  Run   Gap   Run   Gap   Run
reached      ______‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
exec         ____________‾‾‾‾‾‾______‾‾‾‾‾‾_________
wr_req       __________________‾‾‾‾‾‾______‾‾‾‾‾‾___
wr_reg,data                    <A==========<B=======
```

- The beam reaches the WAIT's position in the clock after edge 1. The WAIT ends at edge 2.
- The first write runs at edge 3: the wrapper latches its register and data there, and `wr_req` is high in the next clock. That clock is the write on the bus.
- The next instruction runs no sooner than two edges after a write (edge 5): the spare clock lets a write to the copper's own registers act first.

With `WR_HANDSHAKE` = 1, `wr_req` stays high until a clock with `wr_go`, then the spare clock follows.

## Pitfalls

- **The decoder must not look at `exec` or `more`.** They are made from `need`, so that would be a loop.
- **`need` is read while the buffer fills.** It is made from `word0`, which is only valid once one word is in. The engine ignores `need` while the buffer is empty, so an old `word0` does no harm.
- **Variable lengths need a look ahead for skips.** A skip must know how long the next instruction is. Make the skip's `need` one more than its `len`, and make `skip_len` from the next instruction's first word (`word1` or `word2`).
- **`save2` and the bus.** If the CPU writes the list 2 pointer in the same clock as `save2`, let the CPU's write win (put it after in the same block).
- **The frame clock runs nothing.** A start or frame strobe holds `exec` and `more` low for that clock. Do not count on an instruction finishing in it.
- **`run` low is not reset.** It stops the copper and forgets list 2, but the registers and the stack keep their values. An instruction can still run in the clock `run` falls.
- **A write with no handshake must be taken at once.** With `WR_HANDSHAKE` = 0, the write is on the bus in the one clock `wr_req` is high. If your bus can be busy then, use `WR_HANDSHAKE` = 1 and drive `wr_go`.
- **End of list.** The engine has no end marker. Decode one (a WAIT for a position that is never reached, say) as STOP if you want the copper to stop there rather than wait.
- **Beam lines count from the frame start.** `beam_v` must be 0 at the `frame` strobe, so that lines only go up through a frame.
