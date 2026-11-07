# PS/2 core (`rtl/ps2_core.v`)

Status: **draft**

The PS/2 core is the engine of a PS/2 keyboard port: it receives frames from the keyboard, sends command bytes to it, and keeps received bytes in a 16-byte FIFO. It has no registers. Each machine's wrapper turns its own registers into the core's ports, keeps the sticky error flags and makes the interrupt.

## 1. Summary

| Item | Value |
|------|-------|
| Clock | One clock, 100 MHz (the filter and timeouts count clocks) |
| Lines | PS/2 clock and data, open collector: two inputs, two "pull low" outputs |
| Frames | 11 bits: start 0, 8 data bits lowest first, odd parity, stop 1 |
| Glitch filter | The clock line must hold a new level for 64 clocks (0.64 µs) |
| Frame timeout | 2 ms without a bit: the frame is dropped |
| Errors | Frame (no start bit, bad stop bit), parity, FIFO overflow, send timeout: one-clock strobes |
| FIFO | 16 bytes, emptied while the core is off |
| Sending | One byte at a time; 100 µs clock hold, then the keyboard clocks it in; 15 ms limit |
| Extra input | A byte from elsewhere (a debug link, a test) taken as if received |
| Parameters | None |

## 2. Ports

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | The clock, 100 MHz | – |
| `rst` | in | 1 | Synchronous reset | FIFO empty, not sending, lines let go, frame counter 0 |
| `en` | in | 1 | The core is on: the FIFO fills, sending is allowed | 0 empties the FIFO and stops a send at the next edge |
| `rx_en` | in | 1 | The receiver runs | 0 holds the frame counter at 0. Normally `en`, or `en` or-ed with another user of the bytes |
| `ps2_clk_i` | in | 1 | The clock line as read at the pin | Asynchronous; two flip-flops (ASYNC_REG) inside |
| `ps2_data_i` | in | 1 | The data line as read at the pin | Asynchronous; two flip-flops inside |
| `ps2_clk_low` | out | 1 | Pull the clock line low | Registered |
| `ps2_data_low` | out | 1 | Pull the data line low | Registered |
| `rx_stb` | out | 1 | A good byte was received (or taken from `ins_stb`) | One clock, registered |
| `rx_byte` | out | 8 | That byte | Valid with `rx_stb`, held until the next |
| `rx_frame_err` | out | 1 | A falling clock edge with data high where a start bit was due, or a stop bit of 0 | One clock, the clock the edge is taken (combinational from registers) |
| `rx_parity_err` | out | 1 | Data and parity bits not odd | One clock, as `rx_frame_err` |
| `ins_stb` | in | 1 | Take `ins_byte` as if received | One clock; tie to 0 if unused |
| `ins_byte` | in | 8 | The byte | With `ins_stb` |
| `fifo_byte` | out | 8 | The oldest byte in the FIFO; `0x00` when empty | Combinational from the FIFO's head |
| `fifo_count` | out | 5 | Bytes in the FIFO, 0–16 | Registered |
| `fifo_pop` | in | 1 | Take the oldest byte | One clock; ignored when the FIFO is empty |
| `fifo_overflow` | out | 1 | A byte was dropped because the FIFO was full | One clock, the clock `rx_stb` is high |
| `tx_req` | in | 1 | Send `tx_byte` | One clock; taken only when `en` is 1 and `tx_busy` is 0 |
| `tx_byte` | in | 8 | The byte to send | With `tx_req` |
| `tx_busy` | out | 1 | Sending | Registered; 1 from the clock after `tx_req` |
| `tx_timeout` | out | 1 | The keyboard did not answer within 15 ms | One clock, the last clock of `tx_busy` |

## 3. Parameters

None. The clock is taken to be 100 MHz: the filter (64 clocks), the 100 µs hold (10 000), the frame timeout (200 000) and the send limit (1 500 000) are constants (open point P1).

## 4. Behaviour

### 4.1 The lines

- Each line passes two flip-flops. The clock line then passes a filter: the filtered clock takes the line's level only after the line has held it for 64 clocks in a row. A pulse shorter than 0.64 µs is lost.
- A falling edge of the filtered clock is a bit. From the pin's falling edge to the bit is about 67 clocks.
- Data is sampled (after its two flip-flops) on the clock the bit is taken.

### 4.2 Receiving

- Receiving happens while not sending. A frame counter counts the bits.
- At a bit with the counter at 0: data low is a start bit (the counter goes to 1); data high is a frame error (`rx_frame_err`). This check is made even while `rx_en` is 0 (open point P2).
- Bits 1–9 (8 data bits, parity) are shifted in. At bit 10 (the stop bit) the counter goes back to 0, and on that clock:
  - stop bit 0: `rx_frame_err`;
  - else data and parity not odd: `rx_parity_err`;
  - else the byte is good.
- A good byte: on the next clock `rx_stb` is high with `rx_byte`. If `en` was 1 on the clock the byte was taken, it goes into the FIFO; `fifo_count` rises one clock after `rx_stb`. If the FIFO is full, the byte is dropped and `fifo_overflow` is high on the clock `rx_stb` is high. `rx_stb` comes for every good byte, in the FIFO or not.
- A frame begun and then left for 200 000 clocks (2 ms) without a bit is dropped: the counter goes to 0. No error is flagged.
- While `rx_en` is 0 the counter is held at 0.

### 4.3 A byte from elsewhere

- `ins_stb` with `rx_en` 1: on the next clock `rx_stb` is high with `ins_byte`, and the byte goes into the FIFO if `en` is 1, as a received byte.
- If the receiver takes a good byte on the same clock, the keyboard's byte goes first; the other is held and goes out one clock later. Two `ins_stb` must be at least 2 clocks apart.
- `ins_stb` with `rx_en` 0 is ignored.

### 4.4 The FIFO

- 16 bytes. `fifo_byte` shows the oldest byte (`0x00` when empty). `fifo_pop` removes it at the next edge; a pop and a push on the same clock both happen.
- `en` 0 empties it (at every edge while 0).

### 4.5 Sending

| Clock | What happens |
|-------|--------------|
| `tx_req` taken (edge 0) | `tx_busy` 1, clock pulled low, data let go, frame counter 0; the parity bit is made (odd) |
| 10 000 clocks later (100 µs) | Data pulled low (the start bit), clock let go |
| Each falling edge from the keyboard | The next bit out: 8 data bits lowest first, then parity |
| The 10th falling edge | Data let go (the stop bit) |
| The 11th falling edge | The keyboard holds data low (its answer); `tx_busy` 0 |
| 1 500 000 clocks after edge 0 (15 ms), if still busy | `tx_timeout` for one clock; `tx_busy` 0, both lines let go |

- Nothing is received while sending. The keyboard answers a command with a byte of its own (for example `0xFA`), which is received as usual.
- The answer bit is not checked: any 11th falling edge ends the send.
- `tx_req` while busy, or with `en` 0, is ignored. `en` 0 stops a send at once and lets both lines go, with no timeout.

### 4.6 Reset

`rst` empties the FIFO, stops sending, lets both lines go and clears the frame counter and the held byte. The filtered clock starts high.

## 5. How a machine uses it

The wrapper provides:

- `en` from its "keyboard on" control; `rx_en` the same, or-ed with anything else that needs the bytes while the FIFO is off (a key mapper, for example).
- `fifo_pop` from a read of its data register; the read returns `fifo_byte`, or its own "empty" value built from `fifo_count == 0`.
- `tx_req` and `tx_byte` from a write to its send register.
- Sticky flags set by `rx_frame_err`, `rx_parity_err`, `fifo_overflow` and `tx_timeout`, cleared as its registers say. Because the strobes come on the clock the event is found, a flag set by `if (strobe) flag <= 1` lands on the same edge a register written in the core itself would.
- A "data waiting" status and interrupt from `fifo_count != 0`, and a busy status from `tx_busy`.
- The pins: each "low" output drives an open-drain pad (or an IOBUF with the output tied to 0 and the enable from the "low" signal); each input reads the pad.
- `ins_stb`, `ins_byte` from a debug link, or tied to 0.

## 6. Test plan

`test/ps2` (`tb_ps2_core.v`, with `sim/ps2_model.v`) checks:

| Check | How |
|-------|-----|
| A byte received | `rx_stb`, `rx_byte`, `fifo_count`, `fifo_byte`; pop empties; pop when empty does nothing |
| Bad parity | `rx_parity_err` once, no byte |
| Overflow | 17 bytes: 17 `rx_stb`, count 16, one `fifo_overflow`, oldest first |
| `en` 0 | The FIFO empties; with `rx_en` alone bytes come on `rx_stb` but not into the FIFO |
| A byte from elsewhere | On `rx_stb` and in the FIFO; on the same clock as a real byte: both kept, the keyboard's first |
| Glitch filter | A 0.3 µs pulse on the clock is ignored; a real edge with data high is a frame error |
| Frame timeout | 3 bits, then 2.1 ms of nothing: the counter is back to 0 and the next frame is taken |
| Sending | The model gets `0xED` with good parity, answers; `0xFA` is received; no timeout |
| Send timeout | No keyboard: still busy at 14.9 ms, `tx_timeout` by 15.1 ms, lines let go |
| `en` 0 while sending | The send stops, lines let go; `tx_req` with `en` 0 ignored |

Each machine's own tests check its wrapper: its registers, the sticky flags and interrupt, and the keyboard through its whole system.

## 7. Open points

| # | Point |
|---|-------|
| P1 | The timings assume a 100 MHz clock. A machine with another clock would need them as parameters. |
| P2 | While `rx_en` is 0, every falling clock edge with data high still gives `rx_frame_err` (the counter is at 0, so a start bit is due). A keyboard typing while the port is off sets a machine's frame flag. Both machines have always behaved so; gating the check with `rx_en` would be a change for both. |
| P3 | The send does not check the keyboard's answer bit: any 11th falling edge ends it as taken. |
| P4 | The FIFO depth is fixed at 16. |
