# Wiring in the PS/2 core

`rtl/ps2_core.v` is a PS/2 keyboard port without registers: it receives bytes from the keyboard into a 16-byte FIFO and sends command bytes to it. Your machine adds the registers. The full description is in `docs/spec/ps2_core.md`.

## What you add

- An "on" bit, which drives `en` (and `rx_en`).
- A status register: `fifo_count`, and `tx_busy`.
- A data register: a read returns `fifo_byte` and pulses `fifo_pop`.
- A send register: a write pulses `tx_req` with the byte on `tx_byte`.
- Sticky flags for the four error strobes, an enable mask and an interrupt.
- Two open-drain pads.

## A minimal instantiation

```verilog
reg  kb_on;                                 // your "on" bit
wire [7:0] kb_byte;
wire [4:0] kb_count;
wire       kb_busy, kb_ferr, kb_perr, kb_ovf, kb_tout;
wire       clk_low, data_low;

ps2_core kb (
    .clk(clk), .rst(rst),
    .en(kb_on), .rx_en(kb_on),
    .ps2_clk_i(ps2_clk_pin), .ps2_data_i(ps2_data_pin),
    .ps2_clk_low(clk_low), .ps2_data_low(data_low),
    .rx_stb(), .rx_byte(),                  // every good byte, if you want them
    .rx_frame_err(kb_ferr), .rx_parity_err(kb_perr),
    .ins_stb(1'b0), .ins_byte(8'h00),       // nothing from elsewhere
    .fifo_byte(kb_byte), .fifo_count(kb_count),
    .fifo_pop(rd_strobe && addr == DATA),
    .fifo_overflow(kb_ovf),
    .tx_req(wr_strobe && addr == SEND), .tx_byte(wdata[7:0]),
    .tx_busy(kb_busy), .tx_timeout(kb_tout)
);

// open drain: drive 0 or let go
assign ps2_clk_pin  = clk_low  ? 1'b0 : 1'bz;
assign ps2_data_pin = data_low ? 1'b0 : 1'bz;

// sticky flags, write 1 to clear
always @(posedge clk)
    if (rst) flags <= 4'd0;
    else begin
        if (kb_perr) flags[0] <= 1'b1;
        if (kb_ferr) flags[1] <= 1'b1;
        if (kb_ovf)  flags[2] <= 1'b1;
        if (kb_tout) flags[3] <= 1'b1;
        if (wr_strobe && addr == FLAGS) flags <= flags & ~wdata[3:0];
    end
```

On an FPGA board, use the pads' pull-ups (a keyboard needs the lines high when nobody pulls them).

## A byte from the keyboard

`kclk` is the filtered clock inside the core; a bit is taken at each of its falling edges. Times are at 100 MHz.

```
line clk  ‾‾‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
line data ‾‾\_S_X_0_X_1_X ... _7_X_P_/‾‾stop‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
                                         ^ the 11th falling edge
                                         |<- about 67 clocks ->|
clk       _/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_
error strobes                       ________/‾‾‾\______________  (bad frame: on clock T)
rx_stb                              ____________/‾‾‾\__________  (good: on clock T+1)
fifo_count                          3333333333333333334444444444 (one clock after rx_stb)
```

## Sending a command

```
tx_req      _/‾\____________________________________________________________
tx_busy     ___/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_______
line clk    ‾‾‾\____100 us_____/‾‾‾\_/‾\_/‾\_ ... _/‾\_/‾\_/‾\_/‾‾‾\_/‾‾‾‾‾‾
                               (the keyboard clocks from here)
line data   ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_start__X_0_X_1_ ... X_P_/‾stop‾‾\_ack_/‾‾‾
```

Then the keyboard sends its answer (`0xFA`, or `0xFE` to ask again), which comes into the FIFO as any other byte.

## Pitfalls

- **The clock is fixed at 100 MHz.** The filter and timeouts count clocks. At another clock they are wrong (spec open point P1).
- **The frame flag while off.** With `rx_en` 0, every falling clock edge with data high gives `rx_frame_err`. Clear the flags when you turn the port on, or set them only while on.
- **Turning off empties the FIFO** and stops a send, with no timeout.
- **One send at a time.** `tx_req` while `tx_busy` is ignored, not queued. Wait for `tx_busy` to fall, then for the answer byte.
- **`fifo_byte` is 0x00 when empty**, which is also a byte a keyboard can send. Read `fifo_count` first, or make your data register return an "empty" bit from `fifo_count == 0`.
- **Pop with the read.** `fifo_pop` should pulse once per read of your data register: a read that takes two clocks must pulse it only once.
- **`rx_stb` comes for every good byte**, whether or not it went into the FIFO. Use it for anything that watches the keys (a key mapper) without taking bytes from the FIFO.
- **`ins_stb`**: tie it to 0 if you have nothing to feed in. If you do, keep two of them at least 2 clocks apart.
