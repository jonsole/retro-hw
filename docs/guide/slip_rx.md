# Wiring the command and escape decoder

`slip_rx.v` lets the PC send control commands among ordinary data on the serial link. Two byte values are kept: `C0` starts a command, `DB` escapes. `C0 c ~c` is a command; `DB DC` and `DB DD` are a data `C0` and `DB`. Everything else passes straight through, one clock late. The exact rules are in `docs/spec/slip_rx.md`.

You will rarely instantiate it yourself: `serial_link.v` does, between the front end and the receive FIFO. Use it alone only for a link with no FIFO of its own.

## The commands

| Bytes from the PC | Strobe | Needs |
|-------------------|--------|-------|
| `C0 01 FE` | `cmd_break` | `ctl_en` |
| `C0 02 FD` | `cmd_reset` | `ctl_en` or `ctl_lock` |
| `C0 03 FC` | `cmd_upload` | `ctl_en` or `ctl_lock` |
| `C0 04 b ~b` (b and ~b escaped) | `cmd_key`, `key_byte` = b | `ctl_en`, and `KEY_CMD = 1` |

## A minimal instantiation

```verilog
slip_rx #(.KEY_CMD(0)) dec (
    .clk(clk), .rst(por), .ctl_en(cmd_on), .ctl_lock(cmd_locked),
    .in_valid(byte_in), .in_byte(byte_in_data),
    .out_valid(byte_out), .out_byte(byte_out_data),
    .cmd_break(nmi_req), .cmd_reset(reset_req), .cmd_upload(upload_req),
    .cmd_key(), .key_byte()
);
```

## Timing

The PC sends `41 C0 02 FD 42`. Each byte arrives as a one-clock `in_valid`, here 17 clocks apart (the FT232H's rate); the dots are the clocks in between.

```
in_valid    -_ .. -_ .. -_ .. -_ .. -_
in_byte     41    C0    02    FD    42
out_valid   _-_ ......................._-
out_byte     41                         42
cmd_reset   ___ ................... _-_
```

The data byte `41` comes out the clock after it went in. `C0` and `02` give nothing; `FD` completes RESET, and `cmd_reset` is set for the clock after it. `42` is data again.

## Pitfalls

- **The PC must escape.** With recognition on, a data `C0` or `DB` must be sent as `DB DC` or `DB DD`. A bare `C0` in data starts a command and takes the next two bytes with it.
- **Recognition off means raw.** With `ctl_en` and `ctl_lock` both clear, nothing is decoded, and the PC must not escape.
- **Make the lock stick.** `ctl_lock` is there so RESET and UPLOAD keep working when a program turns `ctl_en` off. The register that drives it should be set-only, cleared only by a reset.
- **Reset it only at power-on.** A reset drops a command or escape half-received. Kept out of the machine's other resets, the decoder reads the PC's bytes the same way across a restart.
- **`key_byte` only with `cmd_key`.** It also changes at the end of a broken KEY.
- **KEY_CMD = 0 is not "ignore KEY".** Without it, `C0 04 b` is a broken command and ~b arrives as data. The PC should not send KEY to a machine built without it.
