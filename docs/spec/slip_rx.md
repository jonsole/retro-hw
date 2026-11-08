# Command and escape decoder (slip_rx)

Status: **draft**

`rtl/slip_rx.v` decodes the bytes that come from the PC over the serial link. A few SLIP-style rules let the PC send control commands (break into the machine, reset it, start an upload) among ordinary data, with any data byte still possible. The decoder sits between the front end and the receive FIFO; `serial_link.v` instantiates it.

## 1. Summary

| Item | Value |
|------|-------|
| Kept byte values | `C0` (END, starts a command) and `DB` (ESC) |
| Escapes | `DB DC` is a data `C0`; `DB DD` is a data `DB` |
| Commands | `C0 c ~c`: 1 BREAK, 2 RESET, 3 UPLOAD; with `KEY_CMD = 1` also 4 KEY, `C0 04 b ~b` |
| Latency | A data byte comes out 1 clock after it comes in; no byte waits for the next one |
| Broken commands | Dropped; a `C0` always starts a command again |
| Recognition off | Every byte goes out as it is, `C0` and `DB` too |
| Reset | `rst`, synchronous: back to plain data |
| Parameters | `KEY_CMD` |

## 2. Ports

| Port | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | The clock | – |
| `rst` | in | 1 | Reset: forget any half-received command or escape | Synchronous, high |
| `ctl_en` | in | 1 | Recognise commands and escapes; BREAK and KEY allowed | Level, looked at with each byte |
| `ctl_lock` | in | 1 | Recognise commands and escapes; BREAK and KEY ignored | Level, looked at with each byte |
| `in_valid` | in | 1 | A byte from the front end | 1 clock per byte |
| `in_byte` | in | 8 | That byte | With `in_valid` |
| `out_valid` | out | 1 | A data byte | 1 clock, the clock after its `in_valid`; from a register |
| `out_byte` | out | 8 | That byte, unescaped | With `out_valid` |
| `cmd_break` | out | 1 | BREAK received | 1 clock, the clock after the command's last byte |
| `cmd_reset` | out | 1 | RESET received | As `cmd_break` |
| `cmd_upload` | out | 1 | UPLOAD received | As `cmd_break` |
| `cmd_key` | out | 1 | KEY received (`KEY_CMD = 1`; else always 0) | As `cmd_break` |
| `key_byte` | out | 8 | KEY's byte b | With `cmd_key`; also changes at the end of a broken KEY, so use it only with `cmd_key` |

Recognition is on while `ctl_en` or `ctl_lock` is set.

## 3. Parameters

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `KEY_CMD` | 0 | 1: the KEY command, `C0 04 b ~b`, gives `cmd_key` with b. 0: code 4 is unknown, so `C0 04 x` is dropped as a broken command and the bytes after it are data. For example, a machine that lets the PC type on its keyboard builds it with 1 |

## 4. Behaviour

### 4.1 With recognition on

The decoder works on one byte at a time, as it arrives:

| State | Byte | What happens | Next state |
|-------|------|--------------|------------|
| any | `C0` | Nothing goes out | command |
| data | `DB` | Nothing goes out | escape |
| data | other | The byte goes out | data |
| escape | `DC` / `DD` / other | `C0` / `DB` / the byte itself goes out | data |
| command | c (not `C0`) | c kept | inverse; key (if `KEY_CMD` and c = 4) |
| inverse | x | If x = ~c and c is 1–3: the command's strobe. Otherwise dropped | data |
| key | `DB` | – | key, escaped |
| key | b | b kept | key inverse |
| key, escaped | y | b = y unescaped | key inverse |
| key inverse | `DB` | – | key inverse, escaped |
| key inverse | x | If x = ~b and `ctl_en`: `cmd_key` with b | data |
| key inverse, escaped | y | If y unescaped = ~b and `ctl_en`: `cmd_key` with b | data |

Points that follow from the table:

- A data byte never waits for the next byte: a frame ending in any byte is all out as soon as its last byte has arrived.
- In a command, c and ~c are not escaped (none of 1–3 or their inverses is `C0` or `DB`). In KEY, b and ~b are escaped like data.
- An escape followed by a byte other than `DC` or `DD` gives that byte. The PC must not send that, but the decoder does not drop it.
- A lone `C0` takes the next two bytes as a command, which is then dropped (unless they happen to form one).
- BREAK and KEY need `ctl_en`. With `ctl_lock` alone, RESET and UPLOAD still work, so a program that turns `ctl_en` off cannot lock the PC out.

### 4.2 With recognition off

With `ctl_en` and `ctl_lock` both clear, each byte goes out as it is and the decoder returns to the data state. A program can then run its own protocol on the link; the PC must not escape.

### 4.3 Timing

Everything is registered. `out_valid` and the command strobes are set in the clock after the `in_valid` of the byte that completes them. `ctl_en` and `ctl_lock` are looked at in the clock of `in_valid`. The decoder accepts a byte every clock.

## 5. How a machine uses it

Normally through `serial_link.v`. Used alone, the wrapper must provide:

- `in_valid` and `in_byte` from a front end.
- `ctl_en` and `ctl_lock` from its control register. A lock that software cannot clear, short of a reset, is the wrapper's job.
- Somewhere for `out_byte`: the receive FIFO.
- What the strobes do: BREAK usually raises an NMI or a debugger break, RESET and UPLOAD reset the machine (UPLOAD with a flag the boot ROM reads), KEY feeds the keyboard path.
- A reset. Resetting only at power-on keeps a command that resets the machine from being cut short.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/serial` (`tb_serial_link.v`) | A frame ending in `00` all there at once; BREAK, RESET and UPLOAD among data, one pulse each and nothing in the FIFO; a wrong inverse and an unknown code dropped; `DB DC`, `DB DD` and an escape before another byte; a lone `C0` takes two bytes; a `C0` inside a command starts it again; KEY with b escaped and with ~b escaped; a broken KEY dropped; with `KEY_CMD = 0` no `cmd_key` and the bytes after `C0 04 b` arrive as data; `ctl_lock` alone keeps RESET but not BREAK or KEY; with recognition off every byte raw |
| Machines' system tests | BREAK gives an NMI; RESET and UPLOAD reset the machine; KEY reaches the keyboard; commands work with the CPU stuck |

## 7. Open points

| # | Point |
|---|-------|
| S1 | Codes 5–255 are unknown and dropped. A new command takes a new code; the machines should agree on the codes here before using one. |
| S2 | Nothing reports a dropped command or a bad escape. A counter could, if a machine wants one. |
