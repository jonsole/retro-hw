// DMA scheduler: decides who gets each 20 ns memory cycle, as the Amiga's
// Agnus does. sram_ctl.v does the cycle itself. No registers: the copper's
// priority and the DMA engine's HIGH mode come in as plain ports. The
// timebase (timebase.v) and sram_ctl.v say which cycle starts next.
//
// Channels, each holding req until ack (a 1-clock pulse at the edge the
// cycle is issued); read data comes back on rdata with rvalid for that
// channel 40 ns later:
//   CPU   the CPU's bus interface
//   BPL   layer fetch: hard deadline
//   SPR   sprites: hard deadline
//   AUD   audio
//   COP   copper
//   BLT   DMA engine / blitter
//   PORT  the DMA port: a test channel, used by the simulation tests
//
// Every cycle of the 5 in a slot can have a default owner. A cycle its
// owner doesn't use goes to the next in the free order, so no cycle is
// wasted. For each cycle, the first rule that finds a request wins:
//
//   0. With CPU_FIRST: in the CPU's cycles (CPU_CYCLES) a CPU request gets
//      the cycle, and nothing overrides it: the CPU never waits.
//   1. An urgent hard-deadline request gets the cycle, whatever it is (the
//      CPU's too, without CPU_FIRST: its access then waits). Earliest
//      deadline first. Then, with NASTY, the copper at priority 2 (nasty).
//   2. The default owner: in the CPU's cycles the CPU (with HIGH, a HIGH
//      DMA engine job may take it, below); in HARD_CYCLES the hard-deadline
//      channels (earliest deadline first); in AUD_CYCLES audio.
//   3. The free order: hard-deadline channels (earliest deadline first),
//      AUD, COP, BLT, PORT; the copper at high priority (1-3) goes first.
//
// The cycle masks have bit n for cycle n; each machine sets its own plan
// (docs/spec/dmac.md). The defaults: the CPU owns cycle 0, which urgent
// requests and the nasty copper may take; the display cycles 1 and 3;
// audio cycle 2. Without NASTY, copper priorities 2 and 3 act as 1.
//
// HIGH (a DMA engine job that may take the CPU's cycle) acts only at rule
// 2, so with CPU_FIRST it never wins: leave HIGH off then.
module dmac #(
    parameter [4:0] CPU_CYCLES  = 5'b00001,   // the CPU's own cycles
    parameter [4:0] HARD_CYCLES = 5'b01010,   // the hard-deadline channels' cycles
    parameter [4:0] AUD_CYCLES  = 5'b00100,   // audio's cycles
    parameter       CPU_FIRST   = 0,          // 1: a CPU request in its cycle beats everything
    parameter       NASTY       = 1,          // 1: the copper at priority 2 beats all but urgent
    parameter       HIGH        = 1           // 1: blt_high and blt_share act
) (
    input  wire        clk,
    input  wire        rst,

    // From sram_ctl: a cycle starts at the next edge, and which one
    input  wire        start_next,
    input  wire [2:0]  next_cycle,

    // CPU
    input  wire        cpu_req,
    input  wire        cpu_we,
    input  wire [21:1] cpu_addr,
    input  wire [15:0] cpu_wdata,
    input  wire [1:0]  cpu_be,
    output reg         cpu_ack,
    output wire        cpu_rvalid,

    // Layers (reads)
    input  wire        bpl_req,
    input  wire [21:1] bpl_addr,
    input  wire [9:0]  bpl_deadline,   // system clocks until the data is needed
    input  wire        bpl_urgent,
    output reg         bpl_ack,
    output wire        bpl_rvalid,

    // Sprites (reads), audio (reads), copper (reads)
    input  wire        spr_req,
    input  wire [21:1] spr_addr,
    input  wire [9:0]  spr_deadline,
    input  wire        spr_urgent,
    output reg         spr_ack,
    output wire        spr_rvalid,
    input  wire        aud_req,
    input  wire [21:1] aud_addr,
    output reg         aud_ack,
    output wire        aud_rvalid,
    input  wire        cop_req,
    input  wire [21:1] cop_addr,
    input  wire [1:0]  cop_pri,        // the copper's priority: 0 normal, 1 high, 2 nasty (with NASTY), 3 high
    output reg         cop_ack,
    output wire        cop_rvalid,

    // DMA engine / blitter, and the DMA port (reads and writes)
    input  wire        blt_req,
    input  wire        blt_we,
    input  wire [21:1] blt_addr,
    input  wire [15:0] blt_wdata,
    input  wire [1:0]  blt_be,
    input  wire        blt_high,       // with HIGH: may take the CPU's cycle ...
    input  wire [1:0]  blt_share,      // ... leaving it 1 in 2, 4 or 8 of them
    output reg         blt_ack,
    output wire        blt_rvalid,
    input  wire        port_req,
    input  wire        port_we,
    input  wire [21:1] port_addr,
    input  wire [15:0] port_wdata,
    input  wire [1:0]  port_be,
    output reg         port_ack,
    output wire        port_rvalid,

    // To sram_ctl
    output wire        go,
    output wire        go_we,
    output wire [21:1] go_addr,
    output wire [15:0] go_wdata,
    output wire [1:0]  go_be,
    output wire [2:0]  go_tag,
    input  wire        rvalid,
    input  wire [2:0]  rtag
);
    localparam C_NONE = 3'd0, C_CPU = 3'd1, C_BPL = 3'd2, C_SPR = 3'd3,
               C_AUD  = 3'd4, C_COP = 3'd5, C_BLT = 3'd6, C_PORT = 3'd7;

    // The hard-deadline channel that is due first (layers on a tie)
    wire       hard_any = bpl_req || spr_req;
    wire [2:0] hard     = (spr_req && (!bpl_req || spr_deadline < bpl_deadline)) ? C_SPR : C_BPL;
    wire       urg_any  = (bpl_req && bpl_urgent) || (spr_req && spr_urgent);
    wire [2:0] urg      = (spr_req && spr_urgent && !(bpl_req && bpl_urgent && bpl_deadline <= spr_deadline))
                          ? C_SPR : C_BPL;

    // The free order (a copper at high priority goes first)
    wire       cop_hi = cop_req && cop_pri != 2'd0;
    wire [2:0] free = cop_hi   ? C_COP :
                      hard_any ? hard :
                      aud_req  ? C_AUD :
                      cop_req  ? C_COP :
                      blt_req  ? C_BLT :
                      port_req ? C_PORT : C_NONE;

    // The owners of the cycle that starts at the next edge (cycles 5-7 own nothing)
    wire [7:0] cyc       = 8'd1 << next_cycle;
    wire       cpu_cycle = |(cyc[4:0] & CPU_CYCLES);
    wire       hard_cyc  = |(cyc[4:0] & HARD_CYCLES);
    wire       aud_cyc   = |(cyc[4:0] & AUD_CYCLES);
    wire       nasty     = (NASTY != 0) && cop_req && cop_pri == 2'd2;
    wire       high      = (HIGH != 0) && blt_req && blt_high;

    // A HIGH DMA engine job and the CPU both want the CPU's cycle: the CPU
    // gets every 2nd, 4th or 8th of these, the engine the rest
    reg  [2:0] shc;
    wire [2:0] shmax    = (blt_share == 2'd0) ? 3'd1 : (blt_share == 2'd1) ? 3'd3 : 3'd7;
    wire       cpu_turn = (shc == shmax);
    always @(posedge clk)
        if (rst || HIGH == 0) shc <= 3'd0;
        else if (start_next && cpu_cycle && cpu_req && high && !urg_any && !nasty)
            shc <= cpu_turn ? 3'd0 : shc + 1'b1;

    // Who gets the cycle that starts at the next edge
    reg  [2:0] win;
    always @(*) begin
        if ((CPU_FIRST != 0) && cpu_cycle && cpu_req)
            win = C_CPU;                                    // 0: the CPU's own cycle
        else if (urg_any)
            win = urg;                                      // 1: urgent
        else if (nasty)
            win = C_COP;                                    //    the copper, nasty
        else if (cpu_cycle && cpu_req)
            win = (high && !cpu_turn) ? C_BLT : C_CPU;      // 2: the default owner
        else if (hard_cyc && hard_any)
            win = hard;
        else if (aud_cyc && aud_req)
            win = C_AUD;
        else
            win = free;                                     // 3: free
        if (!start_next) win = C_NONE;
    end

    assign go       = (win != C_NONE);
    assign go_tag   = win;
    assign go_we    = (win == C_CPU) ? cpu_we : (win == C_BLT) ? blt_we : (win == C_PORT) ? port_we : 1'b0;
    assign go_addr  = (win == C_CPU) ? cpu_addr : (win == C_BPL) ? bpl_addr : (win == C_SPR) ? spr_addr :
                      (win == C_AUD) ? aud_addr : (win == C_COP) ? cop_addr : (win == C_BLT) ? blt_addr : port_addr;
    assign go_wdata = (win == C_CPU) ? cpu_wdata : (win == C_BLT) ? blt_wdata : port_wdata;
    assign go_be    = (win == C_CPU) ? cpu_be : (win == C_BLT) ? blt_be : (win == C_PORT) ? port_be : 2'b11;

    always @(posedge clk) begin
        cpu_ack  <= !rst && win == C_CPU;
        bpl_ack  <= !rst && win == C_BPL;
        spr_ack  <= !rst && win == C_SPR;
        aud_ack  <= !rst && win == C_AUD;
        cop_ack  <= !rst && win == C_COP;
        blt_ack  <= !rst && win == C_BLT;
        port_ack <= !rst && win == C_PORT;
    end

    // Read data back to its channel (rdata itself is shared)
    assign cpu_rvalid  = rvalid && rtag == C_CPU;
    assign bpl_rvalid  = rvalid && rtag == C_BPL;
    assign spr_rvalid  = rvalid && rtag == C_SPR;
    assign aud_rvalid  = rvalid && rtag == C_AUD;
    assign cop_rvalid  = rvalid && rtag == C_COP;
    assign blt_rvalid  = rvalid && rtag == C_BLT;
    assign port_rvalid = rvalid && rtag == C_PORT;
endmodule
