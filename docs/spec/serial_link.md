# Serial link engine (serial_link)

Status: **draft**

`rtl/serial_link.v` is the engine of a machine's serial link to the PC: a receive FIFO, a transmit FIFO and the command and escape decoder (`slip_rx.v`), between a front end and the machine's registers. The front end, `ft232h_if.v` today, sits on the `fe_` ports, so the engine is the same whatever carries the bytes. The registers (control, status, levels, interrupts, counters) stay in each machine's wrapper.

## 1. Summary

| Item | Value |
|------|-------|
| Receive FIFO | 2^`AW` bytes, first-word-fall-through, block RAM (`fifo8.v`) |
| Transmit FIFO | The same |
| Decoder | `slip_rx.v`: commands `C0 c ~c`, escapes `DB DC`, `DB DD` |
| Flow control | `fe_rx_room` clears while fewer than `RX_MARGIN` places are free |
| Full transmit FIFO | A push is lost, or drops the oldest byte (`drop_oldest`) |
| Counts | Bytes waiting (receive) and room left (transmit), 0 to 2^`AW` |
| Resets | `rst` for the decoder; `rx_clear` and `tx_clear` empty the FIFOs |
| Clock | One; no timing of its own (the front end has that) |
| Parameters | `AW`, `RX_MARGIN`, `KEY_CMD` |

## 2. Ports

| Port | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | The clock | – |
| `rst` | in | 1 | Resets the decoder | Synchronous, high |
| `rx_clear` | in | 1 | Empties the receive FIFO | Synchronous, high; one clock is enough |
| `tx_clear` | in | 1 | Empties the transmit FIFO | As `rx_clear` |
| `ctl_en` | in | 1 | Recognise commands and escapes; BREAK and KEY allowed (`slip_rx.v`) | Level |
| `ctl_lock` | in | 1 | Recognise commands and escapes; BREAK and KEY ignored | Level |
| `tx_en` | in | 1 | 0: pushed bytes are thrown away | Level, with `tx_push` |
| `drop_oldest` | in | 1 | A push on a full transmit FIFO drops its oldest byte to make room | Level, with `tx_push` |
| `fe_rx_valid` | in | 1 | A byte from the front end | 1 clock per byte |
| `fe_rx_byte` | in | 8 | That byte | With `fe_rx_valid` |
| `fe_rx_room` | out | 1 | The receive FIFO has more than `RX_MARGIN` places free | Combinational from the FIFO's count |
| `fe_tx_valid` | out | 1 | A byte waits for the front end | The transmit FIFO's valid |
| `fe_tx_byte` | out | 8 | The oldest byte | Stays until popped |
| `fe_tx_pop` | in | 1 | The front end has sent it | 1 clock |
| `fe_tx_empty` | out | 1 | The transmit FIFO is empty | Combinational from the count |
| `rx_valid` | out | 1 | A data byte waits | The receive FIFO's valid |
| `rx_byte` | out | 8 | The oldest data byte | Stays until popped |
| `rx_pop` | in | 1 | Take it | 1 clock per byte; ignored while `rx_valid` is clear |
| `rx_new` | out | 1 | A data byte went into the receive FIFO | 1 clock, from a register (the decoder's output) |
| `rx_count` | out | `AW`+1 | Bytes waiting, 0 to 2^`AW` | Combinational; see 4.1 |
| `tx_push` | in | 1 | Send `tx_byte` | 1 clock per byte |
| `tx_byte` | in | 8 | The byte | With `tx_push` |
| `tx_full` | out | 1 | No room: a push now is lost, or drops the oldest byte | Combinational |
| `tx_dropped` | out | 1 | This push dropped the oldest byte | Combinational: `tx_push`, `tx_full` and `drop_oldest` |
| `tx_space` | out | `AW`+1 | Room left, 0 to 2^`AW` | Combinational; see 4.1 |
| `cmd_break`, `cmd_reset`, `cmd_upload` | out | 1 | Control commands | 1 clock each, from registers |
| `cmd_key`, `key_byte` | out | 1, 8 | KEY and its byte (`KEY_CMD = 1`) | As `slip_rx.v` |

## 3. Parameters

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `AW` | 11 | Each FIFO holds 2^`AW` bytes in its RAM, plus one in its output register. For example 11: 2 KB each, one 18 Kb block RAM each |
| `RX_MARGIN` | 18 | `fe_rx_room` clears while fewer than this many places are free. For example 18 for the FT232H, which stops in 1 byte; a UART with RTS needs enough for the bytes already on their way |
| `KEY_CMD` | 0 | Passed to `slip_rx.v`: 1 builds the KEY command. For example 1 on a machine where the PC can type on its keyboard |

## 4. Behaviour

### 4.1 FIFOs

Both FIFOs are `fifo8.v`: first-word-fall-through, so the oldest byte shows on the output whenever valid is set. A byte pushed is valid at the output 2 clocks later if the FIFO was empty. A pop removes the oldest byte in the same clock; the next one shows the clock after.

The raw count of a `fifo8` runs from 0 to 2^`AW` + 1 (the RAM and the output register), and can be a clock ahead of valid. The engine gives:

- `rx_count` = the raw receive count, held at 2^`AW` (2049 reads as 2048).
- `tx_space` = 2^`AW` − the raw transmit count, 0 when that count is 2^`AW` or more.
- `fe_tx_empty` = the raw transmit count is 0 (no byte in the RAM or on its way out).
- `tx_full` = the transmit RAM is full (2^`AW` bytes behind the output register).

### 4.2 Receive path

`fe_rx_valid` → the decoder → `rx_new`, one clock later, with the byte pushed into the receive FIFO in that clock. Command bytes and escapes never reach the FIFO. If the FIFO is full the byte is lost, but `fe_rx_room` keeps the front end from reading long before that.

### 4.3 Transmit path

In a clock with `tx_push`:

| `tx_en` | `tx_full` | `drop_oldest` | What happens | `tx_dropped` |
|---------|-----------|---------------|--------------|--------------|
| 0 | 0 | – | The byte is thrown away | 0 |
| 0 | 1 | 0 | The byte is thrown away | 0 |
| 0 | 1 | 1 | The oldest byte is dropped; the new one is thrown away | 1 |
| 1 | 0 | – | The byte goes in | 0 |
| 1 | 1 | 0 | The byte is lost | 0 |
| 1 | 1 | 1 | The oldest byte is dropped and the new one goes in, in the same clock | 1 |

A push and `fe_tx_pop` in the same clock both happen. The wrapper counts drops from `tx_dropped`, and an overflow (a lost byte) from `tx_push` with `tx_full` and not `drop_oldest`.

### 4.4 Resets

`rst` resets only the decoder. `rx_clear` and `tx_clear` empty the FIFOs; the bytes in them are lost, and a byte being written by the front end is still popped from the now empty FIFO, which does nothing. The front end has its own reset.

## 5. How a machine uses it

The wrapper provides:

- A front end on the `fe_` ports (`ft232h_if.v`, port to port).
- `ctl_en`, `ctl_lock`, `tx_en` and `drop_oldest` from its control register.
- `rx_pop` and `tx_push` with `tx_byte`, from its data register and from any DMA port, with its own rule for which goes first when both want the same clock.
- Its status from `rx_count` and `tx_space` (cut to its register width), its level interrupts from comparing them with its levels, a receive timeout from `rx_new` and `rx_pop` (the receive side was busy), an overflow flag and a drop counter from the transmit signals (4.3).
- What the command strobes do (`slip_rx.md`, section 5).
- The resets. For the link to survive a machine reset, `rst` (the decoder) and the front end's reset come from power-on only; the FIFOs may be emptied by a machine reset and by a flush the software asks for.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/serial` (`tb_serial_link.v`, with `ft232h_if.v` and `sim/ft232h_model.v`) | Data both ways; `rx_new` once per data byte; `tx_space` and `fe_tx_empty` after a send; the decoder's cases (`slip_rx.md`, section 6), with a second engine built with `KEY_CMD = 0` fed the same bytes; `tx_en` = 0 throws a push away; a full transmit FIFO (2049 bytes), then a push with `drop_oldest` drops the oldest byte and keeps the new one last |
| Machines' system tests | The registers on top: status counts, levels and interrupts, the receive timeout, flushes, drops, DMA through the FIFOs |

## 7. Open points

| # | Point |
|---|-------|
| L1 | Flow control by `fe_rx_room` alone. A UART front end with RTS/CTS will show whether `RX_MARGIN` is enough or a second, lower mark is wanted. |
| L2 | `rx_count` is held at 2^`AW` though the FIFO can hold one more byte; machines read 2^`AW` as "full". |
