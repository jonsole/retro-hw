// The rasteriser (docs/spec/raster.md): lines and flat-filled triangles
// into a bitmap in memory, from screen points, one job at a time with a
// chain to the next descriptor. Each pixel is job_minterm of A (a line's
// pattern bit; 1 in a triangle), B (the colour) and C (the old pixel),
// written only inside the clip window. Control, descriptor load and memory
// port are the blitter's.
//
// Both jobs come down to spans: n pixels from x in the current row, written
// a memory word at a time (the old word read first where the result needs
// it). A line is one span of one pixel for each pixel stepped inside the
// window; a triangle one span a row. The row's first byte is kept as the
// row steps (y times the stride is multiplied out once, at the job's start).
//
// A triangle's three slopes come from one serial divider, one after the
// other; its edges are then stepped in 16.16 fixed point.
module raster #(
    parameter AW  = 21,                        // word address width, 16 to 23
    parameter LE  = 0,                         // 1: memory words little-endian
    parameter TRI = 1                          // 0: lines only (a TRI job is an error; no divider)
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
    input  wire          job_tri,
    input  wire [7:0]    job_minterm,
    input  wire [1:0]    job_bpp,
    input  wire [7:0]    job_value,
    input  wire [15:0]   job_pattern,
    input  wire          job_nolast,
    input  wire          job_irq,
    input  wire [15:0]   job_x0, job_y0, job_x1, job_y1, job_x2, job_y2,
    input  wire [23:0]   job_daddr,
    input  wire [15:0]   job_dstride,
    input  wire [15:0]   clip_xmin, clip_xmax, clip_ymin, clip_ymax,
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
    // ---------------------------------------------------------------- helpers
    function [15:0] colour(input [7:0] k, input [1:0] lb);   // the colour in every pixel of a word
        case (lb)
            2'd3:    colour = {2{k}};
            2'd2:    colour = {4{k[3:0]}};
            2'd1:    colour = {8{k[1:0]}};
            default: colour = {16{k[0]}};
        endcase
    endfunction
    function [15:0] minterm(input [7:0] m, input [15:0] a, input [15:0] b, input [15:0] c);
        minterm = ({16{m[7]}} &  a &  b &  c) | ({16{m[6]}} &  a &  b & ~c)
                | ({16{m[5]}} &  a & ~b &  c) | ({16{m[4]}} &  a & ~b & ~c)
                | ({16{m[3]}} & ~a &  b &  c) | ({16{m[2]}} & ~a &  b & ~c)
                | ({16{m[1]}} & ~a & ~b &  c) | ({16{m[0]}} & ~a & ~b & ~c);
    endfunction

    // ---------------------------------------------------------------- state
    localparam [4:0] S_IDLE = 5'd0,  S_DLR = 5'd1,  S_DLW = 5'd2,  S_SU  = 5'd3,  S_CHK = 5'd4,
                     S_MUL  = 5'd5,  S_LP  = 5'd6,  S_LS  = 5'd7,
                     S_SRT  = 5'd8,  S_DV0 = 5'd9,  S_DV  = 5'd10, S_DVE = 5'd11,
                     S_TR   = 5'd12, S_TN  = 5'd13,
                     S_SP   = 5'd14, S_SPC = 5'd15, S_SPR = 5'd16, S_SPK = 5'd17, S_SPW = 5'd18,
                     S_END  = 5'd19, S_TR2 = 5'd20, S_TR3 = 5'd21;
    reg  [4:0]    st, sp_ret;
    reg  [AW:0]   da;
    assign da_q = {{(23-AW){1'b0}}, da};
    reg           stop_p;
    reg  [3:0]    dlc;
    reg  [1:0]    dl_got;
    assign su_v = (st == S_SU);

    wire [7:0]    mt    = job_minterm;
    wire [7:0]    mte   = job_tri ? {mt[7:4], mt[7:4]} : mt;       // a triangle's A is all ones
    wire          dep_c = (mte[7] ^ mte[6]) | (mte[5] ^ mte[4]) | (mte[3] ^ mte[2]) | (mte[1] ^ mte[0]);
    wire [1:0]    lb    = job_bpp;
    wire          can   = enable && !mem_req;
    wire          bad   = job_bad || (job_tri && TRI == 0);

    wire signed [15:0] cxmin = clip_xmin, cxmax = clip_xmax, cymin = clip_ymin, cymax = clip_ymax;
    wire signed [17:0] xmin18 = {{2{cxmin[15]}}, cxmin};           // (signed wires: a bare concatenation would compare unsigned)
    wire signed [17:0] xmax18 = {{2{cxmax[15]}}, cxmax};

    // The row: y, and the byte address of its pixel 0
    reg  signed [15:0] cy;
    reg  [AW:0]   rowb;
    wire [AW:0]   sx_d = {{(AW-15){job_dstride[15]}}, job_dstride};
    reg  [AW:0]   mul_s;                         // the stride, shifted, for the multiply
    reg  [15:0]   mul_y;
    reg  [4:0]    mul_i;
    wire          y_in = (cy >= cymin) && (cy <= cymax);

    // ---------------------------------------------------------------- the span writer
    reg  signed [16:0] sp_x;                    // first pixel
    reg  [16:0]   sp_n;                         // pixels
    reg           sp_a;                         // A for all of them
    reg  [AW-1:0] wa;
    reg  [3:0]    od;
    reg  [19:0]   rem;
    reg  [15:0]   creg;
    reg           w_up;
    wire signed [19:0] sp_p  = {{3{sp_x[16]}}, sp_x} <<< lb;             // the first pixel's bit in the row
    wire [AW:0]   sp_b  = rowb + {{(AW-16){sp_p[19]}}, sp_p[19:3]};      // ... its byte
    wire [4:0]    room = 5'd16 - {1'b0, od};
    wire [4:0]    cnt  = (rem < {15'd0, room}) ? rem[4:0] : room;
    wire [4:0]    oe   = {1'b0, od} + cnt;
    wire [16:0]   m_lo = 17'h0FFFF >> oe;
    wire [15:0]   m    = (16'hFFFF >> od) & ~m_lo[15:0];
    wire          be_e = |m[15:8];
    wire          be_o = |m[7:0];
    wire          part = (be_e && !(&m[15:8])) || (be_o && !(&m[7:0]));
    wire          rdc  = dep_c || part;
    wire [15:0]   rd_s = (LE != 0) ? {mem_rdata[7:0], mem_rdata[15:8]} : mem_rdata;
    wire [15:0]   d_w  = (minterm(mt, {16{sp_a}}, colour(job_value, lb), creg) & m) | (creg & ~m);

    // ---------------------------------------------------------------- LINE
    reg  signed [16:0] lx, ly;                  // the pixel being stepped
    reg  [16:0]   l_major, l_minor, l_left;     // lengths, and steps still to make after this pixel
    reg  signed [17:0] l_err;
    reg           l_xmaj, l_sxn, l_syn;         // x is the longer axis; x, y step down
    reg  [15:0]   l_pat;
    wire signed [15:0] jx0 = job_x0, jy0 = job_y0, jx1 = job_x1, jy1 = job_y1, jx2 = job_x2, jy2 = job_y2;
    wire signed [16:0] ddx = {jx1[15], jx1} - {jx0[15], jx0};
    wire signed [16:0] ddy = {jy1[15], jy1} - {jy0[15], jy0};
    wire [16:0]   adx = ddx[16] ? -ddx : ddx;
    wire [16:0]   ady = ddy[16] ? -ddy : ddy;
    wire          l_beyond = (jx0 < cxmin && jx1 < cxmin) || (jx0 > cxmax && jx1 > cxmax)
                          || (jy0 < cymin && jy1 < cymin) || (jy0 > cymax && jy1 > cymax);
    wire signed [17:0] lx18 = {lx[16], lx};
    wire          l_in   = (lx18 >= xmin18) && (lx18 <= xmax18) && y_in;
    wire          l_last = (l_left == 17'd0);
    wire          l_plot = l_in && !(job_nolast && l_last);
    wire signed [17:0] l_e1 = l_err - {1'b0, l_minor};

    // ---------------------------------------------------------------- TRI
    reg  signed [15:0] ax, ay, bx, by, cx, cyy;  // the points, sorted into top, middle, bottom
    reg  [1:0]    srt;
    reg  [1:0]    dvn;                           // which slope: 0 top-bottom, 1 top-middle, 2 middle-bottom
    reg  signed [33:0] s_l, s_1, s_2, xl, xs, ss;
    // The divider: |dx| x 65536 / dy, 33 quotient bits, then the sign with rounding down
    reg  [32:0]   dv_q;
    reg  [17:0]   dv_r;
    reg  [16:0]   dv_d;
    reg  [5:0]    dv_i;
    reg           dv_neg;
    wire signed [16:0] e_dx = (dvn == 2'd0) ? {cx[15], cx} - {ax[15], ax}
                            : (dvn == 2'd1) ? {bx[15], bx} - {ax[15], ax} : {cx[15], cx} - {bx[15], bx};
    wire signed [16:0] e_dy = (dvn == 2'd0) ? {cyy[15], cyy} - {ay[15], ay}
                            : (dvn == 2'd1) ? {by[15], by} - {ay[15], ay} : {cyy[15], cyy} - {by[15], by};
    wire [16:0]   e_adx = e_dx[16] ? -e_dx : e_dx;
    wire [18:0]   dv_t  = {dv_r, dv_q[32]} - {2'b00, dv_d};
    wire [33:0]   dv_mag = {1'b0, dv_q} + {33'd0, (dv_r != 18'd0)};      // rounded up, for a negative slope
    wire signed [33:0] dv_res = dv_neg ? -$signed(dv_mag) : $signed({1'b0, dv_q});
    // A row's span, over three clocks (one was too long a path at 100 MHz):
    // each edge's ceiling; the smaller and larger, cut to the window; the count
    wire signed [33:0] c_l   = xl + 34'sh0_0000_FFFF;
    wire signed [33:0] c_s   = xs + 34'sh0_0000_FFFF;
    reg  signed [17:0] r_cl, r_cs;                                       // ceil(xl), ceil(xs)
    wire signed [17:0] t_l   = (r_cl < r_cs) ? r_cl : r_cs;               // the span's first pixel
    wire signed [17:0] t_r   = (r_cl < r_cs) ? r_cs : r_cl;               // ... and one past its last
    wire signed [17:0] xend  = xmax18 + 18'sd1;
    reg  signed [17:0] t_lc, t_rc;                                       // ... cut to the window
    wire signed [17:0] t_n   = t_rc - t_lc;
    wire          t_draw = y_in && (t_n > 18'sd0);

    task ask(input w, input [AW-1:0] a);
        begin
            mem_req <= 1'b1;  mem_we <= w;  mem_addr <= a;
            if (!w) mem_be <= 2'b11;
        end
    endtask
    task finish(input e);
        begin
            st <= S_IDLE;  busy <= 1'b0;  done <= 1'b1;  err <= e;  stop_p <= 1'b0;
        end
    endtask
    task span(input signed [16:0] x, input [16:0] n, input a, input [4:0] ret);
        begin
            sp_x <= x;  sp_n <= n;  sp_a <= a;  sp_ret <= ret;  st <= S_SP;
        end
    endtask

    always @(posedge clk) begin
        done <= 1'b0;
        dl_v <= 1'b0;
        if (mem_ack) mem_req <= 1'b0;
        if (rst) begin
            st <= S_IDLE;  busy <= 1'b0;  err <= 1'b0;  stop_p <= 1'b0;
            da <= {(AW+1){1'b0}};
            mem_req <= 1'b0;  mem_we <= 1'b0;  mem_be <= 2'b11;
            su_i <= 3'd0;  dl_i <= 3'd0;  w_up <= 1'b0;  dlc <= 4'd0;  dl_got <= 2'd0;
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
                if (stop_p)   finish(1'b0);
                else if (bad) finish(1'b1);
                else if (job_tri && TRI != 0) begin
                    ax <= jx0;  ay <= jy0;  bx <= jx1;  by <= jy1;  cx <= jx2;  cyy <= jy2;
                    srt <= 2'd0;  st <= S_SRT;
                end else if (l_beyond) st <= S_END;
                else begin
                    lx <= {jx0[15], jx0};  ly <= {jy0[15], jy0};  cy <= jy0;
                    l_xmaj  <= (adx >= ady);
                    l_major <= (adx >= ady) ? adx : ady;
                    l_minor <= (adx >= ady) ? ady : adx;
                    l_left  <= (adx >= ady) ? adx : ady;
                    l_err   <= {2'b00, ((adx >= ady) ? adx[16:1] : ady[16:1])};
                    l_sxn   <= ddx[16];  l_syn <= ddy[16];
                    l_pat   <= job_pattern;
                    rowb <= job_daddr[AW:0];  mul_s <= sx_d;  mul_y <= job_y0;  mul_i <= 5'd0;
                    sp_ret <= S_LP;  st <= S_MUL;
                end
            end

            // rowb = daddr + y x stride, a bit of y a clock (y is signed)
            S_MUL: begin
                if (mul_y[0]) rowb <= (mul_i == 5'd15) ? rowb - mul_s : rowb + mul_s;
                mul_s <= mul_s << 1;  mul_y <= mul_y >> 1;  mul_i <= mul_i + 1'b1;
                if (mul_i == 5'd15) st <= sp_ret;
            end

            // LINE: plot this pixel if it is inside, then step
            S_LP: begin
                if (stop_p) finish(1'b0);
                else if (l_plot) span(lx, 17'd1, l_pat[15], S_LS);
                else st <= S_LS;
            end
            S_LS: begin
                if (l_last) st <= S_END;
                else begin
                    l_left <= l_left - 1'b1;
                    l_pat  <= {l_pat[14:0], l_pat[15]};
                    if (l_e1[17]) begin                               // the shorter axis steps too
                        l_err <= l_e1 + {1'b0, l_major};
                        if (l_xmaj) begin ly <= l_syn ? ly - 1'b1 : ly + 1'b1;  cy <= l_syn ? cy - 1'b1 : cy + 1'b1;
                                          rowb <= l_syn ? rowb - sx_d : rowb + sx_d; end
                        else              lx <= l_sxn ? lx - 1'b1 : lx + 1'b1;
                    end else l_err <= l_e1;
                    if (l_xmaj) lx <= l_sxn ? lx - 1'b1 : lx + 1'b1;
                    else begin        ly <= l_syn ? ly - 1'b1 : ly + 1'b1;  cy <= l_syn ? cy - 1'b1 : cy + 1'b1;
                                      rowb <= l_syn ? rowb - sx_d : rowb + sx_d; end
                    st <= S_LP;
                end
            end

            // TRI: sort the points by y (three compare-and-swaps)
            S_SRT: if (TRI != 0) begin
                srt <= srt + 1'b1;
                case (srt)
                    2'd0, 2'd2: if (by < ay)  begin ax <= bx;  ay <= by;  bx <= ax;  by <= ay; end
                    2'd1:       if (cyy < by) begin bx <= cx;  by <= cyy; cx <= bx;  cyy <= by; end
                    default: ;
                endcase
                if (srt == 2'd2) begin dvn <= 2'd0;  st <= S_DV0; end
            end
            // ... its three slopes, one divide after another
            S_DV0: if (TRI != 0) begin
                dv_q   <= {e_adx[16:0], 16'd0};
                dv_r   <= 18'd0;
                dv_d   <= e_dy;
                dv_neg <= e_dx[16];
                dv_i   <= 6'd0;
                st     <= (e_dy == 17'd0) ? S_DVE : S_DV;             // no height: the slope is never used
            end
            S_DV: if (TRI != 0) begin
                if (!dv_t[18]) begin dv_r <= dv_t[17:0];            dv_q <= {dv_q[31:0], 1'b1}; end
                else           begin dv_r <= {dv_r[16:0], dv_q[32]}; dv_q <= {dv_q[31:0], 1'b0}; end
                dv_i <= dv_i + 1'b1;
                if (dv_i == 6'd32) st <= S_DVE;
            end
            S_DVE: if (TRI != 0) begin
                case (dvn)
                    2'd0:    s_l <= dv_res;
                    2'd1:    s_1 <= dv_res;
                    default: s_2 <= dv_res;
                endcase
                dvn <= dvn + 1'b1;
                if (dvn == 2'd2) begin
                    cy   <= ay;
                    rowb <= job_daddr[AW:0];  mul_s <= sx_d;  mul_y <= ay;  mul_i <= 5'd0;
                    xl   <= {{2{ax[15]}}, ax, 16'd0};
                    // the short edge the first row is on
                    xs   <= (by > ay) ? {{2{ax[15]}}, ax, 16'd0} : {{2{bx[15]}}, bx, 16'd0};
                    ss   <= (by > ay) ? s_1 : dv_res;                 // (dv_res is the third slope, s_2)
                    sp_ret <= S_TR;  st <= S_MUL;
                end else st <= S_DV0;
            end
            // ... and its rows
            S_TR: if (TRI != 0) begin
                r_cl <= c_l[33:16];  r_cs <= c_s[33:16];
                if (stop_p) finish(1'b0);
                else if (cy == cyy) st <= S_END;
                else st <= S_TR2;
            end
            S_TR2: if (TRI != 0) begin
                t_lc <= (t_l < xmin18) ? xmin18 : t_l;
                t_rc <= (t_r > xend) ? xend : t_r;
                st   <= S_TR3;
            end
            S_TR3: if (TRI != 0) begin
                if (t_draw) span(t_lc[16:0], t_n[16:0], 1'b1, S_TN);
                else st <= S_TN;
            end
            S_TN: if (TRI != 0) begin
                xl <= xl + s_l;
                if (cy + 16'sd1 == by && by != ay) begin xs <= {{2{bx[15]}}, bx, 16'd0};  ss <= s_2; end   // the middle point's row
                else xs <= xs + ss;
                cy   <= cy + 16'sd1;
                rowb <= rowb + sx_d;
                st   <= S_TR;
            end

            // A span: sp_n pixels from sp_x in this row, a word at a time
            S_SP: begin
                wa  <= sp_b[AW:1];
                od  <= {sp_b[0], sp_p[2:0]};
                rem <= {3'd0, sp_n} << lb;
                st  <= S_SPC;
            end
            S_SPC: begin
                if (rdc) begin if (can) begin ask(1'b0, wa);  st <= S_SPR; end end
                else st <= S_SPK;
            end
            S_SPR: if (mem_rvalid) begin creg <= rd_s;  st <= S_SPK; end
            S_SPK: begin
                mem_wdata <= (LE != 0) ? {d_w[7:0], d_w[15:8]} : d_w;
                mem_be    <= (LE != 0) ? {be_o, be_e} : {be_e, be_o};
                st <= S_SPW;
            end
            S_SPW: begin
                if (can && !w_up) begin ask(1'b1, wa);  w_up <= 1'b1; end
                if (mem_ack && w_up) begin
                    w_up   <= 1'b0;
                    mem_we <= 1'b0;
                    rem <= rem - {15'd0, cnt};
                    wa  <= wa + 1'b1;
                    od  <= 4'd0;
                    st  <= (rem == {15'd0, cnt}) ? sp_ret : S_SPC;
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
