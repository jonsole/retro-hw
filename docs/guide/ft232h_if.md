# Wiring the FT232H interface

`ft232h_if.v` talks to an FT232H in asynchronous 245 FIFO mode. Give it the chip's pins and two byte streams, and it moves bytes between them: a byte from the PC comes out as a one-clock strobe, a byte for the PC goes when the chip can take it. It has no FIFO of its own. Normally it sits in front of `serial_link.v`, port to port. The exact rules are in `docs/spec/ft232h_if.md`.

## What you need

- A 100 MHz clock. The read and write timing is counted in 10 ns clocks.
- A tri-state buffer for the data bus in the top level.
- A first-word-fall-through transmit FIFO behind it (its valid, oldest byte and pop), and a receive side that says when there is room.

## A minimal instantiation

```verilog
// Top level: the bus pins
wire [7:0] ft_d_o, ft_d_i;
wire       ft_d_oe;
assign ft_d   = ft_d_oe ? ft_d_o : 8'hzz;
assign ft_d_i = ft_d;

// The machine: the front end beside the engine
ft232h_if ft (
    .clk(clk100), .rst(por), .en(link_on),
    .rx_valid(fe_rx_valid), .rx_byte(fe_rx_byte), .rx_room(fe_rx_room),
    .tx_valid(fe_tx_valid), .tx_byte(fe_tx_byte), .tx_pop(fe_tx_pop),
    .tx_empty(fe_tx_empty),
    .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n), .ft_d_i(ft_d_i), .ft_d_o(ft_d_o),
    .ft_d_oe(ft_d_oe), .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n)
);
```

The `fe_` wires go to the same-named ports of `serial_link.v`.

## A read and a write

Two characters per clock; `-` is high, `_` is low. A read starts in idle clock 0. A write starts the same way, in an idle clock with nothing to read.

```
clock     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7
state     I R R R R R R R R C C C C C C C C I
RD#       --\_______________/-----------------
rx_valid  __________________/-\_______________
                            (rx_byte holds the byte from here)

clock     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7
state     I W W W W W W W W C C C C C C C C I
ft_d_oe   __/---------------\_________________
WR#       --------\_________/-----------------
tx_pop    __________________/-\_______________
```

I idle, R read (RD# low for 8 clocks), W write (3 clocks of set-up, then WR# low for 5), C recovery (8 clocks). Each byte takes 17 clocks, so the link moves at most about 5.9 MB/s each way, and less when both directions are busy. When the transmit FIFO has emptied after a run of writes, SIWU# goes low for 3 clocks so the chip sends its bytes to the PC at once.

## Pitfalls

- **Keep `tx_byte` still.** The byte is put on the bus in the idle clock, but it is popped only at the end of the write. A plain FIFO whose output changes before the pop would send the wrong byte; a first-word-fall-through FIFO is right.
- **`tx_empty` is not `!tx_valid`.** A FIFO's valid can lag its count by a clock. Give `tx_empty` the count being zero, or SIWU# can pulse while a byte is still on its way out.
- **Room before the last place.** The core reads only when `rx_room` is set, and stops at once, but the byte read goes through the decoder before it reaches the FIFO. Clear `rx_room` a few places before full (`serial_link.v` keeps 18).
- **`en` does not cut a transfer short.** It stops new reads and writes; one under way finishes.
- **Reset it only at power-on**, if the PC's terminal should stay connected while the machine restarts. Bytes the PC sends meanwhile wait in the chip.
- **Another clock** needs the counts changed: the core assumes 10 ns clocks.
