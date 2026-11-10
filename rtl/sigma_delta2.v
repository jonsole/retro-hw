// Sigma-delta modulator, second order (or first: ORDER 1): x (16 bits
// signed) at half of full scale, so it stays stable for every input. The
// average of y is 1/2 + x / 2^17.
//
//   ORDER  2: two integrators. 1: one (smaller; more noise in the audio band)
//   DSP    1: ask the tools to build the adders in DSP blocks (the Xilinx
//             use_dsp attribute; other tools ignore it). The same stream
module sigma_delta2 #(
    parameter ORDER = 2,
    parameter DSP   = 0
) (
    input  wire               clk,
    input  wire               rst,
    input  wire signed [15:0] x,
    output reg                y
);
    reg signed [23:0] i1, i2;
    wire signed [23:0] fb = y ? 24'sd65536 : -24'sd65536;
    wire signed [23:0] n1, n2;
    generate if (DSP != 0) begin : dsp
        (* use_dsp = "yes" *) wire signed [23:0] a1 = i1 + x - fb;
        (* use_dsp = "yes" *) wire signed [23:0] a2 = i2 + a1 - fb;
        assign n1 = a1;
        assign n2 = (ORDER == 1) ? a1 : a2;
    end else begin : lut
        assign n1 = i1 + x - fb;
        assign n2 = (ORDER == 1) ? n1 : i2 + n1 - fb;
    end endgenerate
    always @(posedge clk) begin
        if (rst) begin
            i1 <= 24'sd0;
            i2 <= 24'sd0;
            y  <= 1'b0;
        end else begin
            i1 <= n1;
            i2 <= (ORDER == 1) ? 24'sd0 : n2;
            y  <= !n2[23];
        end
    end
endmodule
