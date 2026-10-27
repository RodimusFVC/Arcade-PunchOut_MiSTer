//============================================================================
//
//  PunchOut CHP1 speech output filter (VLM5030 DAO -> MSOUND)
//  Copyright (C) 2026 Rodimus
//
//  CHP1-02 CPU schematic (sheet D), LM324 2N: DAO -> C47 330p / C32 1u -> R51 10K / R52 12K inverting stage ->
//  R55 10K, C39 10n to ground -> R56 100K -> unity Sallen-Key (R57 8.2K, C40 15n feedback, C41 330p to ground).
//  Exact network = one real pole 1604 Hz + a pole pair 2489 Hz Q 1.61 (0.5 dB Chebyshev, -3 dB ~2.65 kHz, -14 dB
//  at 4 kHz, -34 dB at 8 kHz), DC gain 1. The C32 / R51 16 Hz high-pass and the stage's -1.2 gain are not modelled.
//  Bilinear at OSC / 88 = 40.68 kHz (5 steps per VLM sample): y1 = k (x + x1) + c y1', y = g (y1 + 2 y1' + y1'') -
//  a1 y' - a2 y'', coefficients Q18. One multiplier, time-multiplexed over the 5 products.
//
//============================================================================

module chp1_speech_lpf
(
    input  logic               clk,
    input  logic               reset,
    input  logic               oscen,       // VLM5030 OSC enable (3.579545 MHz)
    input  logic signed  [9:0] x,           // VLM5030 sample (MAME units)
    output logic signed [15:0] y            // filtered, x 32 (the mix's VLM scale)
);

localparam logic signed [19:0] K = 20'sd28889, C = 20'sd204367, G = 20'sd8375, A1 = -20'sd436615, A2 = 20'sd207970;

logic  [6:0] div = 7'd0;
logic  [2:0] st = 3'd0;                         // 0 idle, 1-5 one product each
logic signed [25:0] x1 = '0, s1 = '0, v1 = '0, v2 = '0, w1 = '0, w2 = '0;
logic signed [25:0] ma;
logic signed [19:0] mb;
logic signed [47:0] acc = '0;
wire  signed [25:0] xs = 26'(x) <<< 12;
wire  signed [25:0] acc18 = 26'(acc >>> 18);
wire  signed [45:0] prod  = ma * mb;               // the one multiplier
wire  signed [47:0] sum   = acc + 48'(prod);

always_comb
    case (st)
        3'd1:    begin ma = xs + x1;               mb = K;   end
        3'd2:    begin ma = s1;                    mb = C;   end
        3'd3:    begin ma = acc18 + (v1 <<< 1) + v2; mb = G; end   // acc18 = this step's y1
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
            3'd3: begin                                             // y1 done: shift the section-1 / section-2 inputs
                s1 <= acc18; v2 <= v1; v1 <= acc18;
                acc <= 48'(prod); st <= 3'd4;
            end
            3'd4: begin acc <= sum; st <= 3'd5; end
            default: begin
                w2 <= w1; w1 <= 26'(sum >>> 18);
                y  <= 16'(sum >>> 25);             // >> 18, then x << 12 -> x << 5
                st <= 3'd0;
            end
        endcase
    end
end

endmodule
