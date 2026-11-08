# Wiring in the SRAM controller

`sram_ctl` runs the Next's 10 ns SRAM: one 16-bit read or write every 20 ns, five in each 100 ns slot. It does the pins and nothing else. Your machine decides who gets each cycle, and hands the controller one request per cycle. The full details are in [the spec](../spec/sram_ctl.md).

## What you need around it

| Part | What it does |
|------|--------------|
| A slot counter | `sc`, 0–9, one step per 100 MHz clock |
| A scheduler | In each clock with `start_next` 1, picks who gets cycle `next_cycle` and drives `go` and `go_*`; sends `rvalid` to the channel named by `rtag` |
| Pad registers | One flip-flop in the pad for the address, /CE, the byte selects and the write data; an `oddr` for /OE, /WE and the data enable |
| A constraint | Puts `rdata` in the input pad flip-flops |

## A minimal instantiation

One channel (the CPU) that always gets the cycle it asks for, tag 1:

```verilog
// Slot counter
reg [3:0] sc;
always @(posedge clk100) sc <= (rst || sc == 4'd9) ? 4'd0 : sc + 4'd1;

wire        start_next;
wire [2:0]  next_cycle;
wire        rvalid;
wire [2:0]  rtag;
wire [15:0] rdata;

// The cycle starts at the next edge if the CPU asks now
wire go     = start_next && cpu_req;
wire cpu_ack = go;                          // granted at the issue edge
wire cpu_rvalid = rvalid && rtag == 3'd1;   // data in rdata, take it at this edge

wire [20:0] a;  wire ce_n, ub_n, lb_n, oe_r, oe_f, we_r, we_f, t_r, t_f;
wire [15:0] dq_o, dq_i;

sram_ctl mem (
    .clk(clk100), .rst(rst), .sc(sc),
    .go(go), .go_we(cpu_we), .go_addr(cpu_addr), .go_wdata(cpu_wdata),
    .go_be(cpu_be), .go_tag(3'd1),
    .start_next(start_next), .next_cycle(next_cycle),
    .rvalid(rvalid), .rtag(rtag), .rdata(rdata),
    .sram_a(a), .sram_ce_n(ce_n), .sram_ub_n(ub_n), .sram_lb_n(lb_n),
    .sram_oe_n_r(oe_r), .sram_oe_n_f(oe_f), .sram_we_n_r(we_r), .sram_we_n_f(we_f),
    .sram_dq_o(dq_o), .sram_dq_t_r(t_r), .sram_dq_t_f(t_f), .sram_dq_i(dq_i)
);

// Pads (board top level)
(* IOB = "TRUE" *) reg [20:0] pad_a = 0;
(* IOB = "TRUE" *) reg        pce_n = 1, pub_n = 1, plb_n = 1;
(* IOB = "TRUE" *) reg [15:0] pdq = 0;
always @(posedge clk100) begin
    pad_a <= a;  pce_n <= ce_n;  pub_n <= ub_n;  plb_n <= lb_n;  pdq <= dq_o;
end
assign ram_addr_o = pad_a;  assign ram_cs_n_o = pce_n;
assign ram_ub_n_o = pub_n;  assign ram_lb_n_o = plb_n;
oddr #(.INIT(1'b1)) o_oe (.clk(clk100), .d_r(oe_r), .d_f(oe_f), .q(ram_oe_n_o));
oddr #(.INIT(1'b1)) o_we (.clk(clk100), .d_r(we_r), .d_f(we_f), .q(ram_we_n_o));
genvar i;
generate for (i = 0; i < 16; i = i + 1) begin : dq
    wire t;
    oddr #(.INIT(1'b1)) o_t (.clk(clk100), .d_r(t_r), .d_f(t_f), .q(t));
    IOBUF io (.IO(ram_data_io[i]), .I(pdq[i]), .O(dq_i[i]), .T(t));
end endgenerate
```

And in the constraints, with the instance path of your machine:

```tcl
set_property IOB TRUE [get_cells -hier -filter {NAME =~ */mem/rdata_reg*}]
```

A real machine has several channels and a rule for each cycle number (CPU cycles, display cycles, a free pool); that is the scheduler's job and stays in the machine.

## Timing sketch

A read issued at 0 ns, a write issued at 20 ns, then an idle cycle. One character is 2.5 ns. The `pin` rows are the SRAM pins, after the pad registers.

```
ns         -10 0   10  20  30  40  50
clk        ‾‾__‾‾__‾‾__‾‾__‾‾__‾‾__‾‾__
start_next ‾‾‾‾____‾‾‾‾____‾‾‾‾____‾‾‾‾
go         ‾‾‾‾____‾‾‾‾________________
go_we      ________‾‾‾‾________________
pin A              <R======<W======
pin /CE    ‾‾‾‾‾‾‾‾________________‾‾‾‾
pin /OE    ‾‾‾‾‾‾‾‾‾‾______‾‾‾‾‾‾‾‾‾‾‾‾
pin /WE    ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾____‾‾‾‾‾‾
pin DQ                 <S==  <F====
rvalid     ________________‾‾‾‾________
```

- `go` is looked at only while `start_next` is 1; the cycle is issued at the edge that ends that clock.
- The read is on the pins from 10 to 30 ns. The SRAM drives (S) once /OE is low; `rdata` captures at 30 ns, and `rvalid` is high from 30 to 40 ns, so the channel takes the data at the 40 ns edge.
- The write is on the pins from 30 to 50 ns. The FPGA drives (F) from 35 ns, /WE is low from 35 to 45 ns.

## Pitfalls

- **`rdata` not in the input pads.** Without the IOB constraint the read data has the fabric delay on top, and reads fail on the board while the simulation passes.
- **A missing pad register.** The controller's timing counts one register in the pad on every output. Leave one out and that signal is a clock early.
- **`oddr` without INIT 1.** /WE or the data enable may be active before the first clock.
- **`go` outside `start_next`.** It is ignored, not queued. A channel must hold its request until it sees its grant.
- **`next_cycle` in an even clock.** It is not meaningful there (it even reads 5).
- **The slot counter.** It must run 0–9 without stopping. Everything in the machine that knows "cycle 0" should take it from the same counter.
- **Reset in the middle of a write.** /WE is cut short; that word may be wrong. Reset the controller with the power-on reset if a soft reset must leave memory intact.
- **In simulation,** use `platform/sim/oddr.v` and the same pad registers with a 1 ns delay, and `sim/sram_model.v`, which checks the datasheet timing on every cycle.
