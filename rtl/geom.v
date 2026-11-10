// The geometry engine (docs/spec/geom.md): a list of 3D points in memory
// rotated and translated by a 3x4 matrix, projected, and written back as
// screen x, screen y and view z. One job at a time with a chain to the next
// descriptor; control, descriptor load and memory port are the blitter's.
//
// The 16 words of the view block are read once a job into a small RAM.
// Each point: three reads; nine products on the one multiplier, summed a
// row at a time into the view coordinates; with job_persp the near test,
// then for x and for y a product by d and a serial divide by view z; three
// writes. Numbers are 16-bit signed words as the memory port gives them,
// so the core has no byte-order parameter.
module geom #(
    parameter AW = 21                          // word address width, up to 23
) (
    input  wire          clk,
    input  wire          rst,

    // Control (as the blitter's)
    input  wire          enable,
    input  wire          start_ld,
    input  wire          start_run,
    input  wire          stop,
    input  wire          da_we,
    input  wire [23:0]   da_d,
    output wire [23:0]   da_q,
    output reg           busy,
    output reg           done,
    output reg           err,

    // The job
    output wire          su_v,
    output reg  [2:0]    su_i,
    input  wire [15:0]   job_count,
    input  wire [23:0]   job_vaddr,
    input  wire [23:0]   job_oaddr,
    input  wire [23:0]   job_maddr,
    input  wire          job_persp,
    input  wire          job_irq,
    input  wire [23:0]   job_next,
    input  wire          job_bad,

    // Descriptor load
    output reg           dl_v,
    output reg  [2:0]    dl_i,
    output reg  [15:0]   dl_w0,
    output reg  [15:0]   dl_w1,
    input  wire          dl_wait,

    // Memory
    output reg           mem_req,
    output reg           mem_we,
    output reg  [AW-1:0] mem_addr,
    output reg  [15:0]   mem_wdata,
    output reg  [1:0]    mem_be,
    input  wire          mem_ack,
    input  wire          mem_rvalid,
    input  wire [15:0]   mem_rdata
);
    localparam [4:0] S_IDLE = 5'd0,  S_DLR = 5'd1,  S_DLW = 5'd2,  S_SU  = 5'd3,  S_CHK = 5'd4,
                     S_VB   = 5'd5,  S_PR  = 5'd6,  S_M0  = 5'd7,  S_M1  = 5'd8,  S_M2  = 5'd9,
                     S_V    = 5'd10, S_N   = 5'd11, S_D0  = 5'd12, S_D1  = 5'd13, S_D2  = 5'd14,
                     S_DV   = 5'd15, S_DE  = 5'd16, S_W   = 5'd17, S_END = 5'd18;
    reg  [4:0]    st;
    reg  [AW:0]   da;
    assign da_q = {{(23-AW){1'b0}}, da};
    reg           stop_p;
    reg  [3:0]    dlc;
    reg  [1:0]    dl_got;
    assign su_v = (st == S_SU);
    wire          can = enable && !mem_req;

    // The view block: m00..m22, tx ty tz, d, cx, cy, znear
    reg  [15:0]   vb [0:15];
    reg  [4:0]    vq, vg;                        // words asked for, words in
    reg  [3:0]    vi;                            // the word looked at
    wire signed [15:0] vw = vb[vi];

    // The point
    reg  [AW-1:0] va, oa;                        // next word to read, to write
    reg  [15:0]   left;                          // points still to do
    reg  [1:0]    ri, di;                        // words asked for, words in (reads); words asked for (writes)
    reg  signed [15:0] px, py, pz;               // the point
    reg  signed [15:0] vx, vy, vz;               // in the view
    reg  signed [15:0] sx, sy;                   // on the screen
    reg  [3:0]    k;                             // which matrix entry
    reg           ydiv;                          // the divide in hand is y's
    reg  signed [16:0] ma, mb;                   // the multiplier
    reg  signed [33:0] mp;
    reg  signed [33:0] acc;
    wire [1:0]    kc = (k == 4'd0 || k == 4'd3 || k == 4'd6) ? 2'd0
                     : (k == 4'd1 || k == 4'd4 || k == 4'd7) ? 2'd1 : 2'd2;      // the entry's column
    wire signed [15:0] pc = (kc == 2'd0) ? px : (kc == 2'd1) ? py : pz;
    // A view coordinate: the row's sum >> 14, plus its translation, limited to 16 bits
    wire signed [33:0] sum  = acc + mp;
    wire signed [20:0] v_w  = {sum[33], sum[33:14]} + {{5{vw[15]}}, vw};          // (vw: the row's t)
    wire signed [15:0] v_s  = (v_w > 21'sd32767) ? 16'sh7FFF : (v_w < -21'sd32768) ? 16'sh8000 : v_w[15:0];

    // The divider: |product| / vz, 32 quotient bits, then the sign with rounding down
    reg  [31:0]   dv_q;
    reg  [16:0]   dv_r;
    reg  [5:0]    dv_i;
    reg           dv_neg;
    wire [33:0]   mp_abs = mp[33] ? -mp : mp;
    wire [17:0]   dv_t   = {dv_r, dv_q[31]} - {2'b00, vz};
    wire [33:0]   dv_mag = {2'b00, dv_q} + {33'd0, (dv_r != 17'd0)};
    wire signed [33:0] dv_res = dv_neg ? -$signed(dv_mag) : $signed({2'b00, dv_q});
    // A screen coordinate: the centre plus the offset, limited to +-32767
    wire signed [34:0] s_per = {{19{vw[15]}}, vw} + {dv_res[33], dv_res};         // (vw: cx or cy)
    wire signed [15:0] v_o   = (vi == 4'd13) ? vx : vy;
    wire signed [34:0] s_ort = {{19{vw[15]}}, vw} + {{19{v_o[15]}}, v_o};
    function signed [15:0] satp(input signed [34:0] v);
        satp = (v > 35'sd32767) ? 16'sh7FFF : (v < -35'sd32767) ? 16'sh8001 : v[15:0];
    endfunction

    task ask(input w, input [AW-1:0] a);
        begin
            mem_req <= 1'b1;  mem_we <= w;  mem_addr <= a;  mem_be <= 2'b11;
        end
    endtask
    task finish(input e);
        begin
            st <= S_IDLE;  busy <= 1'b0;  done <= 1'b1;  err <= e;  stop_p <= 1'b0;
        end
    endtask

    always @(posedge clk) begin
        done <= 1'b0;
        dl_v <= 1'b0;
        if (mem_ack) begin mem_req <= 1'b0;  mem_we <= 1'b0; end
        if (rst) begin
            st <= S_IDLE;  busy <= 1'b0;  err <= 1'b0;  stop_p <= 1'b0;
            da <= {(AW+1){1'b0}};
            mem_req <= 1'b0;  mem_we <= 1'b0;  mem_be <= 2'b11;
            su_i <= 3'd0;  dl_i <= 3'd0;  dlc <= 4'd0;  dl_got <= 2'd0;
        end else begin
            if (stop && busy) stop_p <= 1'b1;
            case (st)
            S_IDLE: begin
                if (da_we) da <= {da_d[AW:1], 1'b0};
                if (start_ld) begin
                    st <= S_DLR;  busy <= 1'b1;  err <= 1'b0;  dlc <= 4'd0;  dl_got <= 2'd0;  dl_i <= 3'd0;
                end else if (start_run) begin
                    st <= S_SU;  busy <= 1'b1;  err <= 1'b0;  su_i <= 3'd0;
                end
            end

            // The descriptor (as the blitter's)
            S_DLR: begin
                if (mem_rvalid) begin
                    if (dl_got == 2'd0) dl_w0 <= mem_rdata; else dl_w1 <= mem_rdata;
                    dl_got <= dl_got + 1'b1;
                end
                if (stop_p && !dlc[0]) finish(1'b0);
                else if (can) begin
                    ask(1'b0, da[AW:1] + {{(AW-4){1'b0}}, dlc});
                    dlc <= dlc + 1'b1;
                    if (dlc[0]) st <= S_DLW;
                end
            end
            S_DLW: begin
                if (mem_rvalid) begin
                    if (dl_got == 2'd0) dl_w0 <= mem_rdata; else dl_w1 <= mem_rdata;
                    dl_got <= dl_got + 1'b1;
                end
                if (dl_got == 2'd2 && !dl_wait) begin
                    dl_v   <= 1'b1;
                    dl_got <= 2'd0;
                    if (dlc == 4'd0) begin st <= S_SU;  su_i <= 3'd0; end
                    else st <= S_DLR;
                end
            end
            S_SU: begin
                su_i <= su_i + 1'b1;
                if (su_i == 3'd7) st <= S_CHK;
            end
            S_CHK: begin
                if (stop_p)        finish(1'b0);
                else if (job_bad)  finish(1'b1);
                else if (job_count == 16'd0) st <= S_END;
                else begin
                    va <= job_vaddr[AW:1];  oa <= job_oaddr[AW:1];  left <= job_count;
                    vq <= 5'd0;  vg <= 5'd0;
                    st <= S_VB;
                end
            end

            // The view block's 16 words, one request after another
            S_VB: begin
                if (can && !vq[4]) begin
                    ask(1'b0, job_maddr[AW:1] + {{(AW-4){1'b0}}, vq[3:0]});  vq <= vq + 1'b1;
                end
                if (mem_rvalid) begin vb[vg[3:0]] <= mem_rdata;  vg <= vg + 1'b1; end
                if (vg[4]) begin ri <= 2'd0;  di <= 2'd0;  st <= S_PR; end
            end

            // A point: its three words
            S_PR: begin
                if (stop_p && ri == 2'd0) finish(1'b0);
                else begin
                    if (can && ri != 2'd3) begin ask(1'b0, va);  va <= va + 1'b1;  ri <= ri + 1'b1; end
                    if (mem_rvalid) begin
                        case (di)
                            2'd0:    px <= mem_rdata;
                            2'd1:    py <= mem_rdata;
                            default: pz <= mem_rdata;
                        endcase
                        di <= di + 1'b1;
                    end
                    if (di == 2'd3) begin k <= 4'd0;  vi <= 4'd0;  acc <= 34'sd0;  st <= S_M0; end
                end
            end

            // The nine products, a row of three at a time
            S_M0: begin
                ma <= {vw[15], vw};  mb <= {pc[15], pc};
                st <= S_M1;
            end
            S_M1: begin
                mp <= ma * mb;
                vi <= (kc == 2'd2) ? ((k == 4'd2) ? 4'd9 : (k == 4'd5) ? 4'd10 : 4'd11) : k + 4'd1;   // the row's t, or the next entry
                st <= (kc == 2'd2) ? S_V : S_M2;
            end
            S_M2: begin
                acc <= sum;  k <= k + 1'b1;
                st  <= S_M0;
            end
            S_V: begin
                case (k)
                    4'd2:    vx <= v_s;
                    4'd5:    vy <= v_s;
                    default: vz <= v_s;
                endcase
                acc <= 34'sd0;  k <= k + 1'b1;
                if (k == 4'd8) begin vi <= 4'd15;  st <= S_N; end     // znear
                else           begin vi <= k + 4'd1;  st <= S_M0; end
            end

            // Behind the near plane, straight through, or two divides
            S_N: begin
                if (job_persp && vz < vw) begin
                    sx <= 16'sh8000;  sy <= 16'sh8000;
                    ri <= 2'd0;  st <= S_W;
                end else begin
                    ydiv <= 1'b0;  vi <= job_persp ? 4'd12 : 4'd13;      // d, or cx
                    st   <= S_D0;
                end
            end
            S_D0: begin
                if (!job_persp) begin
                    if (vi == 4'd13) begin sx <= satp(s_ort);  vi <= 4'd14; end
                    else             begin sy <= satp(s_ort);  ri <= 2'd0;  st <= S_W; end
                end else begin
                    ma <= ydiv ? {vy[15], vy} : {vx[15], vx};  mb <= {1'b0, vw};     // (vw: d, unsigned)
                    st <= S_D1;
                end
            end
            S_D1: begin
                mp <= ma * mb;
                vi <= ydiv ? 4'd14 : 4'd13;                              // cy or cx, for the end
                st <= S_D2;
            end
            S_D2: begin
                dv_q <= mp_abs[31:0];  dv_r <= 17'd0;  dv_neg <= mp[33];  dv_i <= 6'd0;
                st   <= S_DV;
            end
            S_DV: begin
                if (!dv_t[17]) begin dv_r <= dv_t[16:0];             dv_q <= {dv_q[30:0], 1'b1}; end
                else           begin dv_r <= {dv_r[15:0], dv_q[31]}; dv_q <= {dv_q[30:0], 1'b0}; end
                dv_i <= dv_i + 1'b1;
                if (dv_i == 6'd31) st <= S_DE;
            end
            S_DE: begin
                if (!ydiv) begin sx <= satp(s_per);  ydiv <= 1'b1;  vi <= 4'd12;  st <= S_D0; end
                else       begin sy <= satp(s_per);  ri <= 2'd0;  st <= S_W; end
            end

            // The result's three words
            S_W: begin
                if (can && ri != 2'd3) begin
                    ask(1'b1, oa);  oa <= oa + 1'b1;  ri <= ri + 1'b1;
                    mem_wdata <= (ri == 2'd0) ? sx : (ri == 2'd1) ? sy : vz;
                end
                if (ri == 2'd3 && !mem_req) begin
                    left <= left - 1'b1;
                    ri <= 2'd0;  di <= 2'd0;
                    st <= (left == 16'd1) ? S_END : S_PR;
                end
            end

            default: begin   // S_END
                if (!stop_p && job_next[AW:1] != {AW{1'b0}}) begin
                    da   <= {job_next[AW:1], 1'b0};
                    done <= job_irq;
                    st   <= S_DLR;  dlc <= 4'd0;  dl_got <= 2'd0;  dl_i <= 3'd0;
                end else finish(1'b0);
            end
            endcase

            if (dl_v) dl_i <= dl_i + 1'b1;
        end
    end
endmodule
