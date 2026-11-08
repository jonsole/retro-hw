// DMA scheduler: decides who gets each 20 ns memory cycle, as the Amiga's
// Agnus does. sram_ctl.v does the cycle itself. No registers: the slot
// table and the priority bits come in as plain ports, so the machine holds
// them in its own registers and can change them at any time. The timebase
// (timebase.v) and sram_ctl.v say which cycle starts next.
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
// The slot table (slot_owner) names an owner for each of the 5 cycles in a
// slot, 3 bits a cycle, coded as go_tag; 0 is no owner. BPL or SPR as owner
// means the display: the one of the two that is due first. slot_lock marks
// the cycles an urgent request may not take from their owner. For each
// cycle, the first rule that finds a request wins:
//
//   1. In a locked cycle, the owner.
//   2. An urgent hard-deadline request, earliest deadline first.
//   3. The owner.
//   4. The free order: COP (with cop_high), the display (earliest deadline
//      first), AUD, COP, BLT (with blt_high), CPU, BLT, PORT.
//
// A cycle its owner doesn't use goes to the free order, so none is wasted.
module dmac (
    input  wire        clk,
    input  wire        rst,

    // From sram_ctl: a cycle starts at the next edge, and which one
    input  wire        start_next,
    input  wire [2:0]  next_cycle,

    // The slot plan: an owner for each cycle (bits 3n+2..3n for cycle n),
    // and the cycles an urgent request may not take from their owner
    input  wire [14:0] slot_owner,
    input  wire [4:0]  slot_lock,

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
    input  wire        cop_high,       // the copper goes first in the free order
    output reg         cop_ack,
    output wire        cop_rvalid,

    // DMA engine / blitter, and the DMA port (reads and writes)
    input  wire        blt_req,
    input  wire        blt_we,
    input  wire [21:1] blt_addr,
    input  wire [15:0] blt_wdata,
    input  wire [1:0]  blt_be,
    input  wire        blt_high,       // the DMA engine goes before the CPU in the free order
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

    // The free order
    wire [2:0] free = (cop_req && cop_high) ? C_COP :
                      hard_any              ? hard :
                      aud_req               ? C_AUD :
                      cop_req               ? C_COP :
                      (blt_req && blt_high) ? C_BLT :
                      cpu_req               ? C_CPU :
                      blt_req               ? C_BLT :
                      port_req              ? C_PORT : C_NONE;

    // The owner of the cycle that starts at the next edge (cycles 5-7 have none)
    wire [23:0] owners = {9'd0, slot_owner};
    wire [7:0]  locks  = {3'd0, slot_lock};
    wire [2:0]  owner  = owners[next_cycle * 3 +: 3];
    wire        locked = locks[next_cycle];
    reg        own_req;
    reg  [2:0] own;
    always @(*) begin
        own = owner;
        case (owner)
            C_CPU:        own_req = cpu_req;
            C_BPL, C_SPR: begin own_req = hard_any; own = hard; end
            C_AUD:        own_req = aud_req;
            C_COP:        own_req = cop_req;
            C_BLT:        own_req = blt_req;
            C_PORT:       own_req = port_req;
            default:      own_req = 1'b0;
        endcase
    end

    // Who gets the cycle that starts at the next edge
    reg  [2:0] win;
    always @(*) begin
        if (!start_next)            win = C_NONE;
        else if (locked && own_req) win = own;     // 1: a locked cycle's owner
        else if (urg_any)           win = urg;     // 2: urgent
        else if (own_req)           win = own;     // 3: the owner
        else                        win = free;    // 4: free
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
