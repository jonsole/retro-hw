// Second-order sigma-delta modulator: x (16 bits signed) at half of full
// scale, so it stays stable for every input. The average of y is
// 1/2 + x / 2^17.
module sigma_delta2 (
    input  wire               clk,
    input  wire               rst,
    input  wire signed [15:0] x,
    output reg                y
);
    reg signed [23:0] i1, i2;
    wire signed [23:0] fb = y ? 24'sd65536 : -24'sd65536;
    wire signed [23:0] n1 = i1 + x - fb;
    wire signed [23:0] n2 = i2 + n1 - fb;
    always @(posedge clk) begin
        if (rst) begin
            i1 <= 24'sd0;
            i2 <= 24'sd0;
            y  <= 1'b0;
        end else begin
            i1 <= n1;
            i2 <= n2;
            y  <= !n2[23];
        end
    end
endmodule
