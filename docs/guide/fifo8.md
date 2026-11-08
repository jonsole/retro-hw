# Wiring in the byte FIFO

`fifo8` is a queue of bytes in block RAM, one clock for both sides. The oldest byte is always waiting on `rdata` while `valid` is 1 (first-word-fall-through), so the reader needs no read request and no wait. It holds 2^AW + 1 bytes. The full details are in [the spec](../spec/fifo8.md).

## A minimal instantiation

A 2 KB receive buffer between a byte source and a CPU register:

```verilog
wire [7:0]  rx_byte;
wire [12:0] rx_count;          // AW + 2 bits: 0 .. 2049
wire        rx_full, rx_valid;

fifo8 #(.AW(11)) rx_fifo (
    .clk(clk), .rst(rst || rx_flush),
    .push(src_valid && !rx_full), .wdata(src_byte),
    .pop(cpu_reads_data),          // one clock per byte taken
    .rdata(rx_byte), .count(rx_count), .full(rx_full), .valid(rx_valid)
);

assign src_ready = !rx_full;       // hold the source back when full
// A register that says "bytes waiting", saturating at 2048
wire [11:0] rxcount = (rx_count > 13'd2048) ? 12'd2048 : rx_count[11:0];
```

The CPU's read of the data register returns `rx_byte` (or 0 when `!rx_valid`) and pulses `cpu_reads_data` for one clock.

## Timing sketch

Two bytes pushed into an empty FIFO, then popped. One character is a quarter of a clock.

```
edge           1   2   3   4   5
clk        ‾‾__‾‾__‾‾__‾‾__‾‾__‾‾__
push       ‾‾‾‾‾‾‾‾________________
wdata      <A==<B==
count      <0==<1==<2======<1==<0==
valid      ________‾‾‾‾‾‾‾‾‾‾‾‾____
rdata              <A======<B======
pop        ____________‾‾‾‾‾‾‾‾____
```

- A push is taken at the edge that ends its clock. `count` goes up at once.
- The byte goes through the RAM, so it reaches `rdata` one edge later; `valid` rises then.
- A pop at an edge takes the byte on `rdata`; the next byte, if the RAM holds one, is there straight after the same edge.

## Pitfalls

- **`count` runs ahead of `valid`** by a clock after a push into an empty FIFO. Test `valid` before using `rdata`, not `count`.
- **The extra byte.** The FIFO holds 2^AW + 1, so `count` can read 2049 with AW = 11. Saturate it if a register reports a power of two.
- **Pushes while full are dropped** without a flag. Hold the source back on `full`, or count drops outside.
- **Drop the oldest** by popping and pushing in the same clock while full; that works (spec, section 4.3).
- **`rdata` when `valid` is 0** still holds the last byte. Gate it if software must see 0.
- **One clock only.** Synchronise strobes from another clock domain before `push` and `pop`.
- **Reset is the flush.** It empties the queue but does not clear the RAM; that is never visible.
