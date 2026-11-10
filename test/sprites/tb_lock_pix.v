// sprite_pix.v in lockstep with a frozen copy of its earlier self
// (ref/sprite_pix_ref.v, whose span was two magnitude compares). Random
// legal settings, taken at t = 12 (HSTART 16 or more, the end not before
// the start); a FIFO that fills by spells, so underruns and empty waits
// come up; flushes; video off and on. Every output is compared every clock.
`timescale 1ns/1ps
module tb_lock_pix;
    reg clk = 1'b0;
    always #18 clk = ~clk;

    reg         en = 1'b0;
    reg  [9:0]  t = 10'd0;
    reg         act = 1'b0, dma = 1'b1;
    reg  [9:0]  hs = 10'd16, xe = 10'd16;
    reg  [1:0]  lb = 2'd1;
    reg  [15:0] xstep = 16'h0800;
    reg  [3:0]  pal = 4'd0;
    reg  [5:0]  wp = 6'd0;
    reg         flush_t = 1'b0;
    reg  [15:0] mem [0:31];

    wire [5:0]  wp_g = wp ^ (wp >> 1);
    wire [5:0]  c_rp, r_rp;
    wire        c_ack, r_ack, c_op, r_op, c_un, r_un;
    wire [7:0]  c_idx, r_idx;

    sprite_pix dut (
        .clk_pix(clk), .en(en), .t(t), .act(act), .hs(hs), .xe(xe), .lb(lb), .xstep(xstep), .pal(pal), .dma(dma),
        .head(mem[c_rp[4:0]]), .rp(c_rp), .wp_g(wp_g), .flush_t(flush_t), .flush_ack_t(c_ack),
        .opaque(c_op), .idx(c_idx), .underrun_t(c_un));
    sprite_pix_ref ref (
        .clk_pix(clk), .en(en), .t(t), .act(act), .hs(hs), .xe(xe), .lb(lb), .xstep(xstep), .pal(pal), .dma(dma),
        .head(mem[r_rp[4:0]]), .rp(r_rp), .wp_g(wp_g), .flush_t(flush_t), .flush_ack_t(r_ack),
        .opaque(r_op), .idx(r_idx), .underrun_t(r_un));

    integer errors = 0, checks = 0, n_op = 0, n_un = 0, n_fl = 0, n_edge = 0, lines = 0, i;
    reg [31:0] r;
    reg        feed = 1'b1, r_un_d = 1'b0;
    wire [5:0] cnt = wp - r_rp;

    always @(posedge clk) begin
        t <= (t == 10'd863) ? 10'd0 : t + 1'b1;
        r = $random;
        // the fetch side: words in while there is room, by spells
        if (feed && cnt < 6'd30 && r[1:0] != 2'd0) begin
            mem[wp[4:0]] <= $random;
            wp <= wp + 1'b1;
        end
        if (r[15:4] == 12'd1) feed <= ~feed;
        // a flush, now and then, when the last was acknowledged
        if (r[19:8] == 12'd2 && flush_t == r_ack) begin
            flush_t <= ~flush_t;  wp <= 6'd0;  n_fl = n_fl + 1;
        end
        if (r[31:12] == 20'd3) en <= 1'b0;
        if (t == 10'd12) begin
            // this line's settings
            lines = lines + 1;
            if (lines > 3) en <= 1'b1;
            act   <= ({$random} % 8 != 0);
            dma   <= ({$random} % 4 != 0);
            lb    <= 2'd1 + ({$random} % 3);
            pal   <= $random;
            xstep <= ({$random} % 4 == 0) ? 16'h0080 + ({$random} % 16'h7F81) : 16'h0400 + ({$random} % 16'h1800);
            case ({$random} % 6)
                0: begin hs <= 10'd16;  xe <= 10'd16 + ({$random} % 849); end           // the earliest start
                1: begin hs = 10'd16 + ({$random} % 849);  xe <= 10'd864; end           // to the line's end
                2: begin hs = 10'd16 + ({$random} % 849);  xe <= hs; end                // empty
                3: begin hs = 10'd16 + ({$random} % 848);  xe <= hs + 1'b1; end         // one pixel
                default: begin hs = 10'd16 + ({$random} % 849);  xe <= hs + ({$random} % (865 - hs)); end
            endcase
            if (hs == 10'd16 || xe == 10'd864) n_edge = n_edge + 1;
        end
    end

    always @(negedge clk) begin
        checks = checks + 1;
        if (c_rp !== r_rp || c_ack !== r_ack || c_op !== r_op || c_un !== r_un || (r_op && c_idx !== r_idx)) begin
            errors = errors + 1;
            if (errors <= 10) $display("ERROR t=%0d hs=%0d xe=%0d: core rp %h ack %b opaque %b idx %h underrun %b, reference %h %b %b %h %b",
                                       t, hs, xe, c_rp, c_ack, c_op, c_idx, c_un, r_rp, r_ack, r_op, r_idx, r_un);
        end
        if (r_op) n_op = n_op + 1;
        if (r_un !== r_un_d) n_un = n_un + 1;
        r_un_d = r_un;
    end

    initial begin
        for (i = 0; i < 32; i = i + 1) mem[i] = 16'd0;
        repeat (`ifdef SHORT 200000 `else 3000000 `endif) @(posedge clk);
        @(negedge clk);
        $display("%0d clocks, %0d lines, %0d opaque pixels, %0d underruns, %0d flushes, %0d lines at an edge", checks, lines, n_op, n_un, n_fl, n_edge);
        if (n_op < 10000 || n_un < 20 || n_fl < 20 || n_edge < 20) begin
            errors = errors + 1;
            $display("ERROR: a case never came up");
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
