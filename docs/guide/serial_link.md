# Wiring the serial link engine

`serial_link.v` is the part of a serial link to the PC that every machine shares: a receive FIFO, a transmit FIFO, and the command and escape decoder (`slip_rx.v`). A front end (`ft232h_if.v`) moves bytes to and from the chip; your wrapper puts registers on the other side. The exact rules are in `docs/spec/serial_link.md`.

```
 FT232H pins <-> ft232h_if <-fe_-> serial_link <-> your registers, DMA
                                       |
                                       +-> cmd_break, cmd_reset, cmd_upload, cmd_key
```

## What your wrapper does

- Drives the settings: `ctl_en`, `ctl_lock`, `tx_en` (link on) and `drop_oldest`, from its control register. The front end's `en` usually comes from the same link-on bit.
- Pops the receive FIFO (`rx_pop`) when software reads its data register, and pushes `tx_byte` (`tx_push`) when software writes it. If a DMA channel also uses the FIFOs, it chooses who goes first.
- Shows `rx_count` and `tx_space`, cut to its register width, and builds its interrupts from them.
- Builds a receive timeout from `rx_new` and `rx_pop`, an overflow flag from `tx_push && tx_full && !drop_oldest`, and a drop counter from `tx_dropped`.
- Decides what the command strobes do: an NMI, a reset, an upload, a key press.

## A minimal instantiation

```verilog
wire        fe_rx_valid, fe_rx_room, fe_tx_valid, fe_tx_pop, fe_tx_empty;
wire [7:0]  fe_rx_byte, fe_tx_byte;
wire        rx_valid, rx_new, tx_full, tx_dropped;
wire [7:0]  rx_byte;
wire [11:0] rx_count, tx_space;

serial_link #(.AW(11), .RX_MARGIN(18), .KEY_CMD(0)) link (
    .clk(clk100), .rst(por), .rx_clear(rst || rx_flush), .tx_clear(rst || tx_flush),
    .ctl_en(cmd_on), .ctl_lock(cmd_locked), .tx_en(link_on), .drop_oldest(drop_on_full),
    .fe_rx_valid(fe_rx_valid), .fe_rx_byte(fe_rx_byte), .fe_rx_room(fe_rx_room),
    .fe_tx_valid(fe_tx_valid), .fe_tx_byte(fe_tx_byte), .fe_tx_pop(fe_tx_pop),
    .fe_tx_empty(fe_tx_empty),
    .rx_valid(rx_valid), .rx_byte(rx_byte), .rx_pop(data_read), .rx_new(rx_new),
    .rx_count(rx_count),
    .tx_push(data_written), .tx_byte(cpu_wdata), .tx_full(tx_full),
    .tx_dropped(tx_dropped), .tx_space(tx_space),
    .cmd_break(nmi_req), .cmd_reset(reset_req), .cmd_upload(upload_req),
    .cmd_key(), .key_byte()
);

ft232h_if ft (
    .clk(clk100), .rst(por), .en(link_on),
    .rx_valid(fe_rx_valid), .rx_byte(fe_rx_byte), .rx_room(fe_rx_room),
    .tx_valid(fe_tx_valid), .tx_byte(fe_tx_byte), .tx_pop(fe_tx_pop), .tx_empty(fe_tx_empty),
    .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n), .ft_d_i(ft_d_i), .ft_d_o(ft_d_o),
    .ft_d_oe(ft_d_oe), .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n)
);
```

Reading the data register: return `rx_valid ? rx_byte : <empty value>` and pop in the same clock. The byte shown is the oldest; it changes the clock after the pop.

## Timing: a byte each way

```
clock        0 1 2 3 4 5
fe_rx_valid  --________        a byte from the front end
rx_new       __--______        the decoder passes it on, into the FIFO
rx_valid     ______----__      the FIFO shows it (it was empty) ...
rx_pop       ________--__      ... the wrapper takes it, and it is gone

tx_push      --________        the wrapper pushes a byte
fe_tx_valid  ____------        the front end sees it two clocks later
```

## Pitfalls

- **Counts lag.** `rx_count` can be a clock ahead of `rx_valid`: a byte counted is on its way to the output. Decide "a byte waits" from `rx_valid`, not from the count.
- **A push on a full FIFO.** With `drop_oldest` clear the byte is lost; with it set the oldest goes and the new one stays. A machine that may run with no PC attached should set `drop_oldest`, so the PC sees the latest output when it connects.
- **`tx_en` = 0 throws bytes away**; it does not hold them.
- **Separate resets.** Give `rst` and the front end's reset power-on only, so a terminal stays connected and a command is not cut short across a machine reset. The FIFOs may be emptied by any reset.
- **Another front end** (a UART) goes on the same `fe_` ports. Raise `RX_MARGIN` to cover the bytes still arriving after it stops the sender.
