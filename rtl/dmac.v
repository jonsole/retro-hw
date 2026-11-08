// Memory-cycle scheduler: decides which requester gets each memory cycle,
// as the Amiga's Agnus does. sram_ctl.v does the cycle itself.
//
// N generic requesters, numbered 0 to N-1. A lower number goes first
// wherever two requesters tie. Each holds req until ack (a 1-clock pulse
// the clock after the cycle is given); read data comes back on the shared
// rdata with that requester's rvalid line. The scheduler keeps the number
// of each cycle's winner for RD_DELAY clocks, so it knows whose read data
// the memory controller's rvalid is for: the controller needs no tag.
//
// The slot plan: S slots, numbered 0 to S-1, one memory cycle each. The
// machine says which slot the next cycle is (next_slot). For each slot,
// slot_owner has a mask of the requesters that own it, and slot_lock says
// whether an urgent request may take it from them. Both are ports, so the
// machine can hold them in a register and change them at any time.
//
// For each cycle, the first rule that finds a request wins; within a rule
// the lowest-numbered requester wins:
//
//   1. In a locked slot, an owner.
//   2. An urgent request.
//   3. An owner.
//   4. A high request (high), then any request.
//
// A slot whose owners don't ask goes to rule 4, so no cycle is wasted.
// No registers but the acks.
module dmac #(
    parameter N  = 7,                 // requesters, 1 or more
    parameter S  = 5,                 // slots in the plan
    parameter AW = 21,                // word address width
    parameter DW = 16,                // data width (a multiple of 8)
    parameter RD_DELAY = 4,           // clocks from a cycle's issue edge to the
                                      // edge at which its read data is taken (rvalid
                                      // is high in the last of them); 4 for sram_ctl
    parameter SW = (S > 1) ? $clog2(S) : 1    // next_slot width
) (
    input  wire              clk,
    input  wire              rst,

    // From the memory controller: a cycle starts at the next edge, and
    // which slot of the plan it is (S or more: no slot, no owner)
    input  wire              start_next,
    input  wire [SW-1:0]     next_slot,

    // The slot plan: bits n*N .. n*N+N-1 are slot n's owners (bit k for
    // requester k); bit n of slot_lock locks slot n against urgent requests
    input  wire [S*N-1:0]    slot_owner,
    input  wire [S-1:0]      slot_lock,

    // The requesters: bit k, or field k, is requester k
    input  wire [N-1:0]      req,
    input  wire [N-1:0]      urgent,     // the request must not wait
    input  wire [N-1:0]      high,       // first among the spare-cycle requests
    input  wire [N-1:0]      we,         // 1 write, 0 read
    input  wire [N*AW-1:0]   addr,
    input  wire [N*DW-1:0]   wdata,
    input  wire [N*DW/8-1:0] be,         // byte enables, for writes
    output reg  [N-1:0]      ack,
    output wire [N-1:0]      rvalid_o,   // read data for requester k is on rdata

    // To the memory controller
    output wire              go,
    output wire              go_we,
    output wire [AW-1:0]     go_addr,
    output wire [DW-1:0]     go_wdata,
    output wire [DW/8-1:0]   go_be,
    input  wire              rvalid     // read data is on rdata: whose, the scheduler knows
);
    localparam TW = (N > 1) ? $clog2(N) : 1;   // width of a requester's number

    // The lowest set bit of a mask, alone
    function [N-1:0] first;
        input [N-1:0] m;
        first = m & (~m + 1'b1);
    endfunction

    // The slot being decided: its owners and lock (none past the plan's end)
    wire [31:0]   slot = {{(32-SW){1'b0}}, next_slot};
    reg  [N-1:0]  owners;
    reg           locked;
    integer n;
    always @(*) begin
        owners = {N{1'b0}};
        locked = 1'b0;
        for (n = 0; n < S; n = n + 1)
            if (slot == n) begin
                owners = slot_owner[n*N +: N];
                locked = slot_lock[n];
            end
    end

    wire [N-1:0]  own_req = owners & req;
    wire [N-1:0]  urg_req = urgent & req;
    wire [N-1:0]  hi_req  = high & req;

    // The mask the rules pick, then its lowest bit: the winner, one-hot.
    // Rules 1 and 3 both pick the owners; the lock only decides whether
    // urgent comes between them. One lowest-bit pick after the choice is
    // cheaper than one for each mask before it.
    wire [N-1:0]  pick = (|own_req && (locked || !(|urg_req))) ? own_req :   // 1, 3: an owner
                         (|urg_req)                            ? urg_req :   // 2: urgent
                         (|hi_req)                             ? hi_req  :   // 4: high,
                                                                 req;        //    then any
    wire [N-1:0]  win  = start_next ? first(pick) : {N{1'b0}};

    // The winner's number, and its cycle: an AND-OR mux, as win is one-hot
    reg  [TW-1:0]   tag;
    reg             w_we;
    reg  [AW-1:0]   w_addr;
    reg  [DW-1:0]   w_wdata;
    reg  [DW/8-1:0] w_be;
    integer k;
    always @(*) begin
        tag = {TW{1'b0}};
        w_we = 1'b0;
        w_addr = {AW{1'b0}};
        w_wdata = {DW{1'b0}};
        w_be = {(DW/8){1'b0}};
        for (k = 0; k < N; k = k + 1) begin
            tag     = tag     | ({TW{win[k]}} & k[TW-1:0]);
            w_we    = w_we    | (win[k] & we[k]);
            w_addr  = w_addr  | ({AW{win[k]}} & addr[k*AW +: AW]);
            w_wdata = w_wdata | ({DW{win[k]}} & wdata[k*DW +: DW]);
            w_be    = w_be    | ({(DW/8){win[k]}} & be[k*(DW/8) +: DW/8]);
        end
    end

    assign go       = start_next && |req;
    assign go_we    = w_we;
    assign go_addr  = w_addr;
    assign go_wdata = w_wdata;
    assign go_be    = w_be;

    always @(posedge clk)
        ack <= rst ? {N{1'b0}} : win;

    // Each cycle's winner, kept until its read data comes back. A cycle
    // with no winner, or a write, keeps a number too, but the memory
    // controller gives no rvalid for it.
    reg  [RD_DELAY*TW-1:0] kept;
    wire [TW-1:0]          back = kept[RD_DELAY*TW-1 -: TW];
    generate
        if (RD_DELAY > 1) begin : shift
            always @(posedge clk) kept <= {kept[(RD_DELAY-1)*TW-1:0], tag};
        end else begin : one
            always @(posedge clk) kept <= tag;
        end
    endgenerate

    // Read data back to its requester (rdata itself is shared)
    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : rv
            assign rvalid_o[g] = rvalid && back == g;
        end
    endgenerate
endmodule
