# FT232H interface (ft232h_if)

Status: **draft**

`rtl/ft232h_if.v` drives an FTDI FT232H in asynchronous 245 FIFO mode. It has the chip's pins on one side and a byte stream each way on the other. It holds no FIFO: what sits behind it (normally `serial_link.v`) gives it room, bytes to send, and takes the bytes it reads. Another front end, such as a UART, can take its place on the same ports.

## 1. Summary

| Item | Value |
|------|-------|
| Chip | FTDI FT232H, asynchronous 245 FIFO mode, 8-bit data bus |
| Clock | One, 100 MHz (the timing counts clocks of 10 ns) |
| Read | RD# low 8 clocks, then 8 clocks of recovery: 17 clocks a byte at most (5.9 MB/s) |
| Write | Data out, WR# high 3 clocks then low 5, then 8 clocks of recovery: 17 clocks a byte at most |
| Order | A read goes before a write when both can start |
| Send immediate | SIWU# low for 3 clocks once the bytes behind have all gone |
| Flow control | Reads only while `rx_room` is set; writes only while TXE# is low |
| Reset | `rst`, synchronous; all pins go idle |
| Parameters | None |

## 2. Ports

| Port | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | The clock, 100 MHz | – |
| `rst` | in | 1 | Reset: pins idle, no transfer under way | Synchronous, high |
| `en` | in | 1 | 0: no new read or write starts | Looked at in the idle state only; a transfer under way finishes |
| `rx_valid` | out | 1 | A byte from the PC is on `rx_byte` | 1 clock per byte, from a register |
| `rx_byte` | out | 8 | The byte read | Valid with `rx_valid`; held until the next read |
| `rx_room` | in | 1 | There is room behind for a byte | Looked at in the idle state; must stay set for at least the clock after `rx_valid` (see 4.2) |
| `tx_valid` | in | 1 | A byte waits to go to the PC | Level, as a first-word-fall-through FIFO's valid |
| `tx_byte` | in | 8 | That byte | Taken in the clock the write starts |
| `tx_pop` | out | 1 | `tx_byte` has gone: remove it | 1 clock per byte, from a register, at the end of the write |
| `tx_empty` | in | 1 | No bytes wait behind | Level; starts the SIWU# pulse |
| `ft_rxf_n` | in | 1 | RXF#: the FT232H has a byte | Asynchronous; two-flop synchroniser |
| `ft_txe_n` | in | 1 | TXE#: the FT232H can take a byte | Asynchronous; two-flop synchroniser |
| `ft_d_i` | in | 8 | The data bus, as read | Sampled at the end of RD# low |
| `ft_d_o` | out | 8 | The data bus, as driven | From a register |
| `ft_d_oe` | out | 1 | Drive `ft_d_o` onto the bus | From a register; set only during a write |
| `ft_rd_n` | out | 1 | RD# | From a register |
| `ft_wr_n` | out | 1 | WR# | From a register |
| `ft_siwu_n` | out | 1 | SIWU# (send immediate / wake up) | From a register |

The bidirectional data bus is built outside the core (a tri-state buffer in the board's top level, or `assign d = oe ? d_o : 8'hzz` in a testbench).

## 3. Parameters

None. The timing is fixed for a 100 MHz clock. A machine on another clock needs the counts changed (open point F1).

## 4. Behaviour

### 4.1 States

The core is in one of four states: idle, read, write, recovery. Each transfer is followed by 8 clocks of recovery, then at least one idle clock.

In the idle state, in this order:

1. If `en`, RXF# (synchronised) is low and there is room (`rx_room` and not `rx_valid`), RD# goes low and a read starts.
2. Otherwise, if `en`, TXE# (synchronised) is low, `tx_valid` is set and no SIWU# pulse is under way, `tx_byte` goes onto the bus (`ft_d_oe` set) and a write starts.

### 4.2 Read

| Clock (from the idle clock that starts it) | What happens |
|-------|--------------|
| 0 | Idle: RD# goes low at the end of this clock |
| 1–8 | RD# low (80 ns). At the end of clock 8 the bus is sampled into `rx_byte`, RD# goes high and `rx_valid` is set |
| 9–16 | Recovery; `rx_valid` is set in clock 9 only |
| 17 | Idle again |

The FT232H's data is valid 14 ns after RD# falls, so 80 ns is ample. RXF# rises within 14 ns of RD# rising and the synchroniser takes 2 clocks, so the recovery covers it.

### 4.3 Write

| Clock | What happens |
|-------|--------------|
| 0 | Idle: `ft_d_o` takes `tx_byte` and `ft_d_oe` is set at the end of this clock |
| 1–3 | Data on the bus, WR# high (30 ns of set-up) |
| 4–8 | WR# low (50 ns). At the end of clock 8 WR# goes high, `ft_d_oe` clears and `tx_pop` is set |
| 9–16 | Recovery; `tx_pop` is set in clock 9 only |
| 17 | Idle again |

`tx_byte` must stay the same from clock 0 until `tx_pop`, which a first-word-fall-through FIFO does: its oldest byte does not change until it is popped.

### 4.4 Send immediate

The FT232H holds bytes for the PC until its buffer fills or a latency timer runs out. SIWU# makes it send them at once. Once a byte has been written, the core waits until `tx_empty` is set in an idle clock, then holds SIWU# low for 3 clocks. No write starts during the pulse; a read may. One pulse follows each run of writes.

### 4.5 Reset

`rst` makes RD#, WR# and SIWU# high, releases the bus and returns to idle. The synchronisers, `ft_d_o` and `rx_byte` are not reset. A machine that wants the PC's terminal to stay connected while it restarts resets the core only at power-on.

## 5. How a machine uses it

The wrapper must provide:

- `en` from its link-enable setting.
- `rx_room` from the receive FIFO, kept set only while there is room for a few more bytes than one (`serial_link.v` keeps a margin).
- `tx_valid`, `tx_byte` and `tx_empty` from a first-word-fall-through transmit FIFO, and `tx_pop` back to it.
- The pins, with the tri-state buffer for the data bus in the top level.
- A reset, normally power-on only.

With `serial_link.v` these all connect port to port to its `fe_` ports.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/serial` (`tb_serial_link.v`, with `sim/ft232h_model.v`) | Bytes both ways in order; nothing read while `en` is 0; one SIWU# pulse after a run of writes; the model checks RD# only while RXF# is low, WR# only while TXE# is low, and data set-up and hold around WR# |
| Machines' system tests | The link with a running machine: a debug session, uploads, the monitor typed at over the link |

## 7. Open points

| # | Point |
|---|-------|
| F1 | The counts suit 100 MHz only. A parameter for the clock period would let a machine on another clock use the core. |
| F2 | The FT232H's synchronous 245 FIFO mode (60 MHz clock from the chip, up to 40 MB/s) is not supported. |
