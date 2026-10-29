//  Copyright (C) 2026 Rodimus

module chp1_speech_lpf
(
    input  logic               clk,
    input  logic               reset,
    input  logic               oscen,
    input  logic signed  [9:0] x,
    output logic signed [15:0] y
);

localparam logic signed [19:0] K = 20'sd28889, C = 20'sd204367, G = 20'sd8375, A1 = -20'sd436615, A2 = 20'sd207970;

logic  [6:0] div = 7'd0;
logic  [2:0] st = 3'd0;
logic signed [25:0] x1 = '0, s1 = '0, v1 = '0, v2 = '0, w1 = '0, w2 = '0;
logic signed [25:0] ma;
logic signed [19:0] mb;
logic signed [47:0] acc = '0;
wire  signed [25:0] xs = 26'(x) <<< 12;
wire  signed [25:0] acc18 = 26'(acc >>> 18);
wire  signed [45:0] prod  = ma * mb;
wire  signed [47:0] sum   = acc + 48'(prod);

always_comb
    case (st)
        3'd1:    begin ma = xs + x1;               mb = K;   end
        3'd2:    begin ma = s1;                    mb = C;   end
        3'd3:    begin ma = acc18 + (v1 <<< 1) + v2; mb = G; end
        3'd4:    begin ma = w1;                    mb = -A1; end
        default: begin ma = w2;                    mb = -A2; end
    endcase

always_ff @(posedge clk) begin
    if (reset) begin
        div <= 7'd0; st <= 3'd0; x1 <= '0; s1 <= '0; v1 <= '0; v2 <= '0; w1 <= '0; w2 <= '0; acc <= '0; y <= '0;
    end else begin
        if (oscen) div <= (div == 7'd87) ? 7'd0 : div + 7'd1;
        case (st)
            3'd0: if (oscen && div == 7'd87) begin acc <= '0; st <= 3'd1; end
            3'd1: begin acc <= 48'(prod); st <= 3'd2; end
            3'd2: begin acc <= sum; x1 <= xs; st <= 3'd3; end
            3'd3: begin
                s1 <= acc18; v2 <= v1; v1 <= acc18;
                acc <= 48'(prod); st <= 3'd4;
            end
            3'd4: begin acc <= sum; st <= 3'd5; end
            default: begin
                w2 <= w1; w1 <= 26'(sum >>> 18);
                y  <= 16'(sum >>> 25);
                st <= 3'd0;
            end
        endcase
    end
end

endmodule
