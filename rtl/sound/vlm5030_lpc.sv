//  Copyright (C) 2026 Rodimus
//  Port of MAME src/devices/sound/vlm5030.cpp (BSD-3-Clause, Tatsuyuki Satoh) with the VLM5030 tables of

//  ROM data is sampled 3 OSC ticks after o_a is set
module vlm5030_lpc
(
    input  logic        clk,
    input  logic        reset,
    input  logic        i_oscen,
    input  logic        i_rst,
    input  logic        i_start,
    input  logic        i_vcu,
    input  logic  [7:0] i_d,
    output logic [15:0] o_a,
    output logic        o_me_l,
    output logic        o_mte,
    output logic        o_bsy,
    output logic  [5:0] o_dao,
    output logic signed [9:0] o_audio
);

localparam int W = 24;

function automatic logic [6:0] etab(input logic [4:0] i);
    case (i)
        5'd0: etab = 7'd0;    5'd1: etab = 7'd1;    5'd2: etab = 7'd2;    5'd3: etab = 7'd3;
        5'd4: etab = 7'd5;    5'd5: etab = 7'd6;    5'd6: etab = 7'd7;    5'd7: etab = 7'd9;
        5'd8: etab = 7'd11;   5'd9: etab = 7'd13;   5'd10: etab = 7'd15;  5'd11: etab = 7'd17;
        5'd12: etab = 7'd19;  5'd13: etab = 7'd22;  5'd14: etab = 7'd24;  5'd15: etab = 7'd27;
        5'd16: etab = 7'd31;  5'd17: etab = 7'd34;  5'd18: etab = 7'd38;  5'd19: etab = 7'd42;
        5'd20: etab = 7'd47;  5'd21: etab = 7'd51;  5'd22: etab = 7'd57;  5'd23: etab = 7'd62;
        5'd24: etab = 7'd68;  5'd25: etab = 7'd75;  5'd26: etab = 7'd82;  5'd27: etab = 7'd89;
        5'd28: etab = 7'd98;  5'd29: etab = 7'd107; 5'd30: etab = 7'd116; default: etab = 7'd127;
    endcase
endfunction

function automatic logic [6:0] ptab(input logic [4:0] i);
    case (i)
        5'd0: ptab = 7'd0;    5'd1: ptab = 7'd21;   5'd2: ptab = 7'd22;   5'd3: ptab = 7'd23;
        5'd4: ptab = 7'd24;   5'd5: ptab = 7'd25;   5'd6: ptab = 7'd26;   5'd7: ptab = 7'd27;
        5'd8: ptab = 7'd28;   5'd9: ptab = 7'd29;   5'd10: ptab = 7'd31;  5'd11: ptab = 7'd33;
        5'd12: ptab = 7'd35;  5'd13: ptab = 7'd37;  5'd14: ptab = 7'd39;  5'd15: ptab = 7'd41;
        5'd16: ptab = 7'd43;  5'd17: ptab = 7'd45;  5'd18: ptab = 7'd49;  5'd19: ptab = 7'd53;
        5'd20: ptab = 7'd57;  5'd21: ptab = 7'd61;  5'd22: ptab = 7'd65;  5'd23: ptab = 7'd69;
        5'd24: ptab = 7'd73;  5'd25: ptab = 7'd77;  5'd26: ptab = 7'd85;  5'd27: ptab = 7'd93;
        5'd28: ptab = 7'd101; 5'd29: ptab = 7'd109; 5'd30: ptab = 7'd117; default: ptab = 7'd125;
    endcase
endfunction

function automatic logic signed [9:0] k1tab(input logic [5:0] i);
    case (i)
        6'd0:  k1tab = 10'sd390;  6'd1:  k1tab = 10'sd403;  6'd2:  k1tab = 10'sd414;  6'd3:  k1tab = 10'sd425;
        6'd4:  k1tab = 10'sd434;  6'd5:  k1tab = 10'sd443;  6'd6:  k1tab = 10'sd450;  6'd7:  k1tab = 10'sd457;
        6'd8:  k1tab = 10'sd463;  6'd9:  k1tab = 10'sd469;  6'd10: k1tab = 10'sd474;  6'd11: k1tab = 10'sd478;
        6'd12: k1tab = 10'sd482;  6'd13: k1tab = 10'sd485;  6'd14: k1tab = 10'sd488;  6'd15: k1tab = 10'sd491;
        6'd16: k1tab = 10'sd494;  6'd17: k1tab = 10'sd496;  6'd18: k1tab = 10'sd498;  6'd19: k1tab = 10'sd499;
        6'd20: k1tab = 10'sd501;  6'd21: k1tab = 10'sd502;  6'd22: k1tab = 10'sd503;  6'd23: k1tab = 10'sd504;
        6'd24: k1tab = 10'sd505;  6'd25: k1tab = 10'sd506;  6'd26: k1tab = 10'sd507;  6'd27: k1tab = 10'sd507;
        6'd28: k1tab = 10'sd508;  6'd29: k1tab = 10'sd508;  6'd30: k1tab = 10'sd509;  6'd31: k1tab = 10'sd509;
        6'd32: k1tab = -10'sd390; 6'd33: k1tab = -10'sd376; 6'd34: k1tab = -10'sd360; 6'd35: k1tab = -10'sd344;
        6'd36: k1tab = -10'sd325; 6'd37: k1tab = -10'sd305; 6'd38: k1tab = -10'sd284; 6'd39: k1tab = -10'sd261;
        6'd40: k1tab = -10'sd237; 6'd41: k1tab = -10'sd211; 6'd42: k1tab = -10'sd183; 6'd43: k1tab = -10'sd155;
        6'd44: k1tab = -10'sd125; 6'd45: k1tab = -10'sd95;  6'd46: k1tab = -10'sd64;  6'd47: k1tab = -10'sd32;
        6'd48: k1tab = 10'sd0;    6'd49: k1tab = 10'sd32;   6'd50: k1tab = 10'sd64;   6'd51: k1tab = 10'sd95;
        6'd52: k1tab = 10'sd125;  6'd53: k1tab = 10'sd155;  6'd54: k1tab = 10'sd183;  6'd55: k1tab = 10'sd211;
        6'd56: k1tab = 10'sd237;  6'd57: k1tab = 10'sd261;  6'd58: k1tab = 10'sd284;  6'd59: k1tab = 10'sd305;
        6'd60: k1tab = 10'sd325;  6'd61: k1tab = 10'sd344;  6'd62: k1tab = 10'sd360;  default: k1tab = 10'sd376;
    endcase
endfunction

function automatic logic signed [9:0] k2tab(input logic [4:0] i);
    case (i)
        5'd0:  k2tab = 10'sd0;    5'd1:  k2tab = 10'sd50;   5'd2:  k2tab = 10'sd100;  5'd3:  k2tab = 10'sd149;
        5'd4:  k2tab = 10'sd196;  5'd5:  k2tab = 10'sd241;  5'd6:  k2tab = 10'sd284;  5'd7:  k2tab = 10'sd325;
        5'd8:  k2tab = 10'sd362;  5'd9:  k2tab = 10'sd396;  5'd10: k2tab = 10'sd426;  5'd11: k2tab = 10'sd452;
        5'd12: k2tab = 10'sd473;  5'd13: k2tab = 10'sd490;  5'd14: k2tab = 10'sd502;  5'd15: k2tab = 10'sd510;
        5'd16: k2tab = 10'sd0;    5'd17: k2tab = -10'sd510; 5'd18: k2tab = -10'sd502; 5'd19: k2tab = -10'sd490;
        5'd20: k2tab = -10'sd473; 5'd21: k2tab = -10'sd452; 5'd22: k2tab = -10'sd426; 5'd23: k2tab = -10'sd396;
        5'd24: k2tab = -10'sd362; 5'd25: k2tab = -10'sd325; 5'd26: k2tab = -10'sd284; 5'd27: k2tab = -10'sd241;
        5'd28: k2tab = -10'sd196; 5'd29: k2tab = -10'sd149; 5'd30: k2tab = -10'sd100; default: k2tab = -10'sd50;
    endcase
endfunction

function automatic logic signed [10:0] lerp(input logic signed [10:0] o, input logic signed [10:0] t, input logic [2:0] ie);
    logic signed [13:0] d, m;
    d = 14'(t) - 14'(o);
    case (ie)
        3'd1:    m = d;
        3'd2:    m = d <<< 1;
        3'd3:    m = d + (d <<< 1);
        default: m = d <<< 2;
    endcase
    lerp = o + 11'((m < 0 ? m + 14'sd3 : m) >>> 2);
endfunction

function automatic logic signed [W-1:0] div512(input logic signed [W+9:0] p);
    div512 = W'((p < 0 ? p + (W+10)'(511) : p) >>> 9);
endfunction

localparam logic [1:0] PH_IDLE = 2'd0, PH_RUN = 2'd1, PH_STOP = 2'd2;

typedef enum logic [3:0] {
    S_IDLE, S_RD, S_TBL0, S_TBL1, S_SAMP, S_CMD, S_FBYTE, S_DEC, S_STEP, S_EXC, S_FA, S_FB, S_FC, S_FD, S_OUT
} st_t;
st_t         st = S_IDLE, rd_ret = S_IDLE;

logic        pin_rst = 1'b0, pin_st = 1'b0;
logic  [7:0] prm = 8'd0;
logic [15:0] addr = 16'd0;
logic  [7:0] vh = 8'd0;
logic        vh_v = 1'b0;
logic  [1:0] phase = PH_IDLE;
logic        bsy = 1'b0;
logic  [5:0] sc = 6'd0;
logic  [9:0] ic = 10'd0;
logic  [7:0] pc = 8'd0;
logic  [2:0] ie = 3'd4;
logic  [6:0] old_e = 7'd0, new_e = 7'd0;
logic  [7:0] old_p = 8'd0, new_p = 8'd0;
logic signed [9:0] old_k [10];
logic signed [9:0] new_k [10];
logic signed [W-1:0] x [10];
logic signed [W-1:0] u = '0;
logic signed [W+9:0] prod = '0;
logic  [3:0] j = 4'd0;
logic [47:0] fb = 48'd0;
logic  [2:0] bi = 3'd0;
logic  [7:0] rdq = 8'd0;
logic  [1:0] rd_wait = 2'd0;
logic  [8:0] tbl = 9'd0;
logic  [8:0] osc = 9'd0;
logic        tick = 1'b0;
logic [16:0] lfsr = 17'd1;

initial for (int n = 0; n < 10; n++) begin old_k[n] = '0; new_k[n] = '0; x[n] = '0; end

wire  [2:0] istep = prm[1] ? 3'd4 : prm[0] ? 3'd2 : 3'd1;
logic [5:0] fsize;
always_comb
    case (prm[5:3])
        3'd1:       fsize = 6'd30;
        3'd2, 3'd3: fsize = 6'd20;
        3'd5:       fsize = 6'd60;
        3'd6, 3'd7: fsize = 6'd50;
        default:    fsize = 6'd40;
    endcase
wire signed [8:0] poff = prm[7] ? -9'sd8 : prm[6] ? 9'sd8 : 9'sd0;

wire        tgt_old = old_e == 7'd0;
wire  [6:0] cur_e   = 7'(lerp(11'(old_e), tgt_old ? 11'd0 : 11'(new_e), ie));
wire  [7:0] cur_p   = (old_p > 8'd1) ? 8'(lerp(11'(old_p), tgt_old ? 11'(old_p) : 11'(new_p), ie)) : old_p;
wire signed [9:0] kc = 10'(lerp(11'(old_k[j]), tgt_old ? 11'(old_k[j]) : 11'(new_k[j]), ie));

wire  [9:0] ic_nx = ic - 10'(istep);
wire  [8:0] pc_nx = {1'b0, pc} + 9'd1;

wire  [4:0] f_p  = fb[5:1];
wire  [4:0] f_e  = fb[10:6];
wire  [7:0] f_p8 = {1'b0, ptab(f_p)};

always_ff @(posedge clk) begin
    if (i_oscen) begin
        osc <= (osc == 9'd439) ? 9'd0 : osc + 9'd1;
        if (osc == 9'd439) tick <= 1'b1;
    end

    if (reset) begin
        st <= S_IDLE; o_a <= 16'd0; o_me_l <= 1'b1; pin_rst <= 1'b0; pin_st <= 1'b0; prm <= 8'd0;
        addr <= 16'd0; vh_v <= 1'b0; phase <= PH_IDLE; bsy <= 1'b0; sc <= 6'd0; ic <= 10'd0; pc <= 8'd0;
        old_e <= 7'd0; new_e <= 7'd0; old_p <= 8'd0; new_p <= 8'd0; o_audio <= 10'sd0; osc <= 9'd0; tick <= 1'b0;
        for (int n = 0; n < 10; n++) begin old_k[n] <= '0; new_k[n] <= '0; x[n] <= '0; end
    end else case (st)
        S_IDLE:
            if (tick) begin
                tick <= 1'b0;
                if (phase != PH_IDLE) st <= S_SAMP;
                else                  o_audio <= 10'sd0;
            end else if (i_rst != pin_rst) begin
                pin_rst <= i_rst;
                if (!i_rst) prm <= i_d;
                else if (bsy) begin
                    addr <= 16'd0; vh_v <= 1'b0; phase <= PH_IDLE; bsy <= 1'b0; sc <= 6'd0; ic <= 10'd0; pc <= 8'd0;
                    old_e <= 7'd0; new_e <= 7'd0; old_p <= 8'd0; new_p <= 8'd0; prm <= 8'd0;
                    for (int n = 0; n < 10; n++) begin old_k[n] <= '0; new_k[n] <= '0; x[n] <= '0; end
                end
            end else if (i_start != pin_st) begin
                pin_st <= i_start;
                if (i_start) begin
                    phase <= PH_IDLE; bsy <= 1'b1;
                end else if (i_vcu) begin
                    vh <= i_d; vh_v <= 1'b1;
                end else if (vh_v) begin
                    addr <= {vh, i_d}; vh_v <= 1'b0;
                    sc <= fsize; ic <= 10'd4; phase <= PH_RUN;
                end else begin
                    tbl <= {i_d[0], i_d[7:1], 1'b0};
                    o_a <= {7'd0, i_d[0], i_d[7:1], 1'b0}; o_me_l <= 1'b0; rd_wait <= 2'd2; rd_ret <= S_TBL0; st <= S_RD;
                end
            end

        S_RD:
            if (i_oscen) begin
                if (rd_wait == 2'd0) begin rdq <= i_d; o_me_l <= 1'b1; st <= rd_ret; end
                else rd_wait <= rd_wait - 2'd1;
            end

        S_TBL0: begin
            addr[15:8] <= rdq;
            o_a <= {7'd0, tbl | 9'd1}; o_me_l <= 1'b0; rd_wait <= 2'd2; rd_ret <= S_TBL1; st <= S_RD;
        end
        S_TBL1: begin
            addr[7:0] <= rdq;
            sc <= fsize; ic <= 10'd4; phase <= PH_RUN;
            st <= S_IDLE;
        end

        S_SAMP:
            if (sc == 6'd0) begin
                if (phase == PH_STOP) begin
                    phase <= PH_IDLE; bsy <= 1'b0; o_audio <= 10'sd0;
                    st <= S_IDLE;
                end else begin
                    sc <= fsize;
                    if (ic == 10'd0) begin
                        old_e <= new_e; old_p <= new_p;
                        for (int n = 0; n < 10; n++) old_k[n] <= new_k[n];
                        o_a <= addr; o_me_l <= 1'b0; rd_wait <= 2'd2; rd_ret <= S_CMD; st <= S_RD;
                    end else
                        st <= S_STEP;
                end
            end else
                st <= S_EXC;

        S_CMD:
            if (rdq[0]) begin
                new_e <= 7'd0; new_p <= 8'd0;
                for (int n = 0; n < 10; n++) new_k[n] <= '0;
                addr <= addr + 16'd1;
                if (rdq[1]) begin ic <= 10'd4; phase <= PH_STOP; end
                else        ic <= {1'b0, 3'd0, rdq[7:2]} + 10'd1 << 3;
                st <= S_STEP;
            end else begin
                fb[7:0] <= rdq; bi <= 3'd1;
                o_a <= addr + 16'd1; o_me_l <= 1'b0; rd_wait <= 2'd2; rd_ret <= S_FBYTE; st <= S_RD;
            end
        S_FBYTE: begin
            fb[{bi, 3'b000} +: 8] <= rdq;
            if (bi == 3'd5) st <= S_DEC;
            else begin
                bi <= bi + 3'd1;
                o_a <= addr + 16'(bi) + 16'd1; o_me_l <= 1'b0; rd_wait <= 2'd2; rd_ret <= S_FBYTE; st <= S_RD;
            end
        end
        S_DEC: begin
            new_p <= (f_p8 != 8'd0) ? 8'($signed({1'b0, f_p8}) + poff) : 8'd0;
            new_e <= etab(f_e);
            new_k[9] <= {fb[13:11], 7'd0};
            new_k[8] <= {fb[16:14], 7'd0};
            new_k[7] <= {fb[19:17], 7'd0};
            new_k[6] <= {fb[22:20], 7'd0};
            new_k[5] <= {fb[25:23], 7'd0};
            new_k[4] <= {fb[28:26], 7'd0};
            new_k[3] <= {fb[32:29], 6'd0};
            new_k[2] <= {fb[36:33], 6'd0};
            new_k[1] <= k2tab(fb[41:37]);
            new_k[0] <= k1tab(fb[47:42]);
            addr <= addr + 16'd6;
            ic <= 10'd4;
            st <= S_STEP;
        end

        S_STEP: begin
            ic <= ic_nx;
            ie <= (ic_nx[1:0] == 2'd0) ? 3'd4 : 3'd4 - {1'b0, ic_nx[1:0]};
            st <= S_EXC;
        end

        S_EXC: begin
            if (old_e == 7'd0)      u <= '0;
            else if (old_p <= 8'd1) u <= lfsr[0] ? W'(cur_e) : -(W'(cur_e));
            // Quartus 17: no unary minus straight onto a cast
            else                    u <= (pc == 8'd0) ? W'(cur_e) : '0;
            j <= 4'd9;
            st <= S_FA;
        end
        S_FA: begin prod <= kc * x[j]; st <= S_FB; end
        S_FB: begin
            u <= u + div512(prod);
            if (j == 4'd9) begin j <= 4'd8; st <= S_FA; end
            else st <= S_FC;
        end
        S_FC: begin prod <= kc * u; st <= S_FD; end
        S_FD: begin
            x[j + 4'd1] <= x[j] - div512(prod);
            if (j == 4'd0) st <= S_OUT;
            else begin j <= j - 4'd1; st <= S_FA; end
        end
        S_OUT: begin
            x[0] <= u;
            o_audio <= (u < -(W'(512))) ? -10'sd512 : (u > W'(511)) ? 10'sd511 : u[9:0];
            sc <= sc - 6'd1;
            pc <= (pc_nx >= {1'b0, cur_p}) ? 8'd0 : pc_nx[7:0];
            lfsr <= {lfsr[15:0], lfsr[16] ^ lfsr[13]};
            st <= S_IDLE;
        end
        default: st <= S_IDLE;
    endcase
end

assign o_bsy = bsy;
assign o_mte = 1'b0;
assign o_dao = {~o_audio[9], o_audio[8:4]};

`ifdef VERILATOR
always_ff @(posedge clk)
    if (st == S_OUT && (u > W'(1 << 22) || u < -(W'(1 << 22)))) $display("vlm5030_lpc: lattice %0d past 2^22", u);
`endif

endmodule
