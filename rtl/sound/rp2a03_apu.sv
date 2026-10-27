//============================================================================
//
//  Ricoh RP2A03 APU (sound part of the 2A03; the 6502 core is the board's pooled T65)
//  Copyright (C) 2026 Rodimus
//
//  From the die schematics (Breaks wiki APU pages + imgstore/apu), derivation in verilator/dk3/apu_derivation.md.
//  Cycle level: ce = one CPU cycle (PHI); ACLK = every second CPU cycle; the triangle timer runs every CPU cycle.
//    Frame counter: 15-bit LFSR (s13 ^ s14, reload 0x7FFF), PLA matches 0x1061 / 0x3603 / 0x2CD3 / 0x0A1F (mode 0
//      only) / 0x7185 -> LFO1 (quarter) and LFO2 (half); $4017 write reloads it, mode 1 also clocks LFO1 + LFO2.
//    Length: decoder ROM = table - 1, counts on LFO2 unless halted, the underflow stops the channel.
//    Envelope: start flag (length write) -> 15; divider from volume on LFO1; loops with the halt bit.
//    Squares: 11-bit timer, 3-bit duty counter (cleared by the length write), sweep adder (square 0 ones'
//      complement), muted by sweep overflow or period < 4 (die: NOR of bits 10..2).
//    Triangle: linear counter + reload flag, timer every CPU cycle, 5-bit up counter -> 15..0, 0..15.
//    Noise: 11-bit period LFSR (b0 ^ b2 -> b10, reload at 0x001 from the decoder ROM), 15-bit random LFSR
//      (b0 ^ (mode ? b6 : b1) -> b14, zero guard), muted while b0 = 1.
//    DMC: 9-bit rate LFSR (b0 ^ b4 -> b8, reload at 0x001), 7-bit output (6-bit up / down counter + $4011 bit 0),
//      sample buffer fetched over dmc_req / dmc_ack (the board stalls the CPU with RDY).
//    DAC: die structure (switched conductances into the board's 100 Ohm pad loads), per-channel weights and unit
//      resistance from hardware measurements -> aux_a / aux_b (tools/apu_dac.py, 20000 per volt).
//  Not modelled: debug registers $4018-$401A, LOCK, OAM DMA ($4014), joypad strobe ($4016 writes).
//
//============================================================================

module rp2a03_apu
(
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,             // CPU cycle

    // CPU bus, sampled at ce (the cycle that ends now)
    input  logic [15:0] addr,
    input  logic        rw,             // 1 = read
    input  logic  [7:0] din,
    output logic  [7:0] dout,           // $4015 status
    output logic        sel_4015,       // CPU reads $4015 this cycle
    output logic        irq_n,

    // DMC sample fetch
    output logic        dmc_req,
    output logic [15:0] dmc_addr,
    input  logic        dmc_ack,        // one clk, with dmc_data
    input  logic  [7:0] dmc_data,

    output logic [15:0] aux_a,          // squares
    output logic [15:0] aux_b           // triangle, noise, DMC
);

wire reg_wr = ce && !rw && addr[15:5] == 11'h200;                 // 4000-401F
wire rd4015 = ce &&  rw && addr == 16'h4015;
assign sel_4015 = rw && addr == 16'h4015;
wire [4:0] ra = addr[4:0];

// ------------------------------------------------------------------ ACLK
logic aclk = 1'b0;
always_ff @(posedge clk) if (reset) aclk <= 1'b0; else if (ce) aclk <= ~aclk;
wire astep = ce && aclk;                // one APU (ACLK) step

// ------------------------------------------------------------------ length counter decoder (die ROM, = table - 1)
function automatic [7:0] len_rom(input [4:0] i);
    case (i)
        5'd0:  len_rom = 8'h09; 5'd1:  len_rom = 8'hFD; 5'd2:  len_rom = 8'h13; 5'd3:  len_rom = 8'h01;
        5'd4:  len_rom = 8'h27; 5'd5:  len_rom = 8'h03; 5'd6:  len_rom = 8'h4F; 5'd7:  len_rom = 8'h05;
        5'd8:  len_rom = 8'h9F; 5'd9:  len_rom = 8'h07; 5'd10: len_rom = 8'h3B; 5'd11: len_rom = 8'h09;
        5'd12: len_rom = 8'h0D; 5'd13: len_rom = 8'h0B; 5'd14: len_rom = 8'h19; 5'd15: len_rom = 8'h0D;
        5'd16: len_rom = 8'h0B; 5'd17: len_rom = 8'h0F; 5'd18: len_rom = 8'h17; 5'd19: len_rom = 8'h11;
        5'd20: len_rom = 8'h2F; 5'd21: len_rom = 8'h13; 5'd22: len_rom = 8'h5F; 5'd23: len_rom = 8'h15;
        5'd24: len_rom = 8'hBF; 5'd25: len_rom = 8'h17; 5'd26: len_rom = 8'h47; 5'd27: len_rom = 8'h19;
        5'd28: len_rom = 8'h0F; 5'd29: len_rom = 8'h1B; 5'd30: len_rom = 8'h1F; default: len_rom = 8'h1D;
    endcase
endfunction

// noise period decoder (die ROM, NTSC), loaded into the 11-bit period LFSR
function automatic [10:0] noise_rom(input [3:0] i);
    case (i)
        4'd0:  noise_rom = 11'h002; 4'd1:  noise_rom = 11'h00A; 4'd2:  noise_rom = 11'h0AA; 4'd3:  noise_rom = 11'h2BB;
        4'd4:  noise_rom = 11'h139; 4'd5:  noise_rom = 11'h173; 4'd6:  noise_rom = 11'h063; 4'd7:  noise_rom = 11'h067;
        4'd8:  noise_rom = 11'h1A9; 4'd9:  noise_rom = 11'h106; 4'd10: noise_rom = 11'h227; 4'd11: noise_rom = 11'h062;
        4'd12: noise_rom = 11'h642; 4'd13: noise_rom = 11'h20F; 4'd14: noise_rom = 11'h300; default: noise_rom = 11'h140;
    endcase
endfunction

// DMC rate decoder (die ROM, NTSC), loaded into the 9-bit rate LFSR
function automatic [8:0] dmc_rom(input [3:0] i);
    case (i)
        4'd0:  dmc_rom = 9'h173; 4'd1:  dmc_rom = 9'h08A; 4'd2:  dmc_rom = 9'h143; 4'd3:  dmc_rom = 9'h0DB;
        4'd4:  dmc_rom = 9'h1EE; 4'd5:  dmc_rom = 9'h03F; 4'd6:  dmc_rom = 9'h07D; 4'd7:  dmc_rom = 9'h1D1;
        4'd8:  dmc_rom = 9'h009; 4'd9:  dmc_rom = 9'h0DC; 4'd10: dmc_rom = 9'h0F1; 4'd11: dmc_rom = 9'h0F9;
        4'd12: dmc_rom = 9'h08D; 4'd13: dmc_rom = 9'h189; 4'd14: dmc_rom = 9'h18E; default: dmc_rom = 9'h156;
    endcase
endfunction

logic tri_ctrl;                         // triangle control / length halt ($4008 bit 7)

// ------------------------------------------------------------------ frame counter (SoftCLK)
logic [14:0] fc_lfsr;
logic        fc_mode, fc_mask, fc_irq, fc_z1;
wire pla0 = fc_lfsr == 15'h1061, pla1 = fc_lfsr == 15'h3603, pla2 = fc_lfsr == 15'h2CD3;
wire pla3 = fc_lfsr == 15'h0A1F && !fc_mode, pla4 = fc_lfsr == 15'h7185;
wire fc_fb = (fc_lfsr[13] ^ fc_lfsr[14]) | (fc_lfsr == 15'd0);
wire lfo1  = astep && (fc_z1 ? fc_mode : (pla0 | pla1 | pla2 | pla3 | pla4));     // quarter frame
wire lfo2  = astep && (fc_z1 ? fc_mode : (pla1 | pla3 | pla4));                   // half frame

always_ff @(posedge clk) begin
    if (reset) begin
        fc_lfsr <= 15'h7FFF; fc_mode <= 1'b0; fc_mask <= 1'b0; fc_irq <= 1'b0; fc_z1 <= 1'b0;
    end else begin
        if (astep) begin
            fc_lfsr <= (fc_z1 || pla3 || pla4) ? 15'h7FFF : {fc_lfsr[13:0], fc_fb};
            fc_z1 <= 1'b0;
            if (pla3 && !fc_mask) fc_irq <= 1'b1;
        end
        if (reg_wr && ra == 5'h17) begin
            fc_mode <= din[7]; fc_mask <= din[6]; fc_z1 <= 1'b1;
            if (din[6]) fc_irq <= 1'b0;
        end
        if (rd4015) fc_irq <= 1'b0;
    end
end

// ------------------------------------------------------------------ length counters: 0 sq0, 1 sq1, 2 tri, 3 noise
logic [7:0] len_cnt[4];
logic [3:0] len_on, len_en;
logic [3:0] len_halt;
wire  [3:0] len_wr = {reg_wr && ra == 5'h0F, reg_wr && ra == 5'h0B, reg_wr && ra == 5'h07, reg_wr && ra == 5'h03};

always_ff @(posedge clk) begin
    if (reset) begin
        len_on <= 4'd0; len_en <= 4'd0;
        for (int c = 0; c < 4; c++) len_cnt[c] <= 8'd0;
    end else begin
        if (reg_wr && ra == 5'h15) len_en <= din[3:0];
        for (int c = 0; c < 4; c++) begin
            if (len_wr[c]) begin
                len_cnt[c] <= len_rom(din[7:3]);
                if (len_en[c] && !(reg_wr && ra == 5'h15 && !din[c])) len_on[c] <= 1'b1;
            end else if (lfo2 && len_on[c] && !len_halt[c]) begin
                if (len_cnt[c] == 8'd0) len_on[c] <= 1'b0;
                else len_cnt[c] <= len_cnt[c] - 8'd1;
            end
            if (!len_en[c]) len_on[c] <= 1'b0;
        end
    end
end

// ------------------------------------------------------------------ envelopes: 0 sq0, 1 sq1, 2 noise
logic [3:0] env_vol[3], env_div[3], env_dec[3];
logic [2:0] env_const, env_loop, env_start;
wire  [2:0] env_regw = {reg_wr && ra == 5'h0C, reg_wr && ra == 5'h04, reg_wr && ra == 5'h00};
wire  [2:0] env_lenw = {len_wr[3], len_wr[1], len_wr[0]};
logic [3:0] env_out[3];

always_ff @(posedge clk) begin
    if (reset) begin
        env_start <= 3'd0; env_const <= 3'd0; env_loop <= 3'd0;
        for (int e = 0; e < 3; e++) begin env_vol[e] <= 4'd0; env_div[e] <= 4'd0; env_dec[e] <= 4'd0; end
    end else for (int e = 0; e < 3; e++) begin
        if (env_regw[e]) begin env_vol[e] <= din[3:0]; env_const[e] <= din[4]; env_loop[e] <= din[5]; end
        if (env_lenw[e]) env_start[e] <= 1'b1;
        else if (lfo1) begin
            if (env_start[e]) begin
                env_start[e] <= 1'b0; env_dec[e] <= 4'd15; env_div[e] <= env_vol[e];
            end else if (env_div[e] == 4'd0) begin
                env_div[e] <= env_vol[e];
                if (env_dec[e] != 4'd0) env_dec[e] <= env_dec[e] - 4'd1;
                else if (env_loop[e]) env_dec[e] <= 4'd15;
            end else env_div[e] <= env_div[e] - 4'd1;
        end
    end
end
always_comb for (int e = 0; e < 3; e++) env_out[e] = env_const[e] ? env_vol[e] : env_dec[e];

assign len_halt = {env_loop[2], tri_ctrl, env_loop[1], env_loop[0]};

// ------------------------------------------------------------------ squares
logic [10:0] sq_f[2], sq_t[2];
logic  [1:0] sq_duty[2];
logic  [2:0] sq_dc[2];
logic        sq_swen[2], sq_neg[2], sq_swrel[2];
logic  [2:0] sq_swp[2], sq_sh[2], sq_swdiv[2];
logic  [3:0] sq_out[2];

logic [11:0] sq_tgt[2];
logic  [1:0] sq_ovf, sq_uvf, sq_duty_on;
always_comb for (int s = 0; s < 2; s++) begin
    // adder: F +/- (F >> shift); square 0 subtracts the ones' complement (die carry-in)
    sq_tgt[s] = sq_neg[s] ? {1'b0, sq_f[s]} - {1'b0, sq_f[s] >> sq_sh[s]} - (s == 0 ? 12'd1 : 12'd0)
                          : {1'b0, sq_f[s]} + {1'b0, sq_f[s] >> sq_sh[s]};
    sq_ovf[s] = !sq_neg[s] && sq_tgt[s][11];
    sq_uvf[s] = sq_f[s][10:2] == 9'd0;
    case (sq_duty[s])
        2'd0: sq_duty_on[s] = sq_dc[s] == 3'd7;
        2'd1: sq_duty_on[s] = sq_dc[s] >= 3'd6;
        2'd2: sq_duty_on[s] = sq_dc[s] >= 3'd4;
        default: sq_duty_on[s] = sq_dc[s] <= 3'd5;
    endcase
    sq_out[s] = (sq_duty_on[s] && len_on[s] && !sq_ovf[s] && !sq_uvf[s]) ? env_out[s] : 4'd0;
end

always_ff @(posedge clk) begin
    if (reset) begin
        for (int s = 0; s < 2; s++) begin
            sq_dc[s] <= 3'd0; sq_swen[s] <= 1'b0; sq_t[s] <= 11'd0; sq_f[s] <= 11'd0; sq_duty[s] <= 2'd0;
            sq_neg[s] <= 1'b0; sq_sh[s] <= 3'd0; sq_swp[s] <= 3'd0; sq_swdiv[s] <= 3'd0; sq_swrel[s] <= 1'b0;
        end
    end else for (int s = 0; s < 2; s++) begin
        if (reg_wr && ra == {2'd0, s[0], 2'd0}) sq_duty[s] <= din[7:6];
        if (reg_wr && ra == {2'd0, s[0], 2'd1}) begin
            sq_swen[s] <= din[7]; sq_swp[s] <= din[6:4]; sq_neg[s] <= din[3]; sq_sh[s] <= din[2:0]; sq_swrel[s] <= 1'b1;
        end
        // timer and duty counter
        if (astep) begin
            if (sq_t[s] == 11'd0) begin sq_t[s] <= sq_f[s]; sq_dc[s] <= sq_dc[s] - 3'd1; end
            else sq_t[s] <= sq_t[s] - 11'd1;
        end
        // sweep (LFO2)
        if (lfo2) begin
            if (sq_swdiv[s] == 3'd0 && sq_swen[s] && sq_sh[s] != 3'd0 && len_on[s] && !sq_ovf[s] && !sq_uvf[s])
                sq_f[s] <= sq_tgt[s][10:0];
            if (sq_swdiv[s] == 3'd0 || sq_swrel[s]) begin sq_swdiv[s] <= sq_swp[s]; sq_swrel[s] <= 1'b0; end
            else sq_swdiv[s] <= sq_swdiv[s] - 3'd1;
        end
        if (reg_wr && ra == {2'd0, s[0], 2'd2}) sq_f[s][7:0] <= din;
        if (reg_wr && ra == {2'd0, s[0], 2'd3}) begin sq_f[s][10:8] <= din[2:0]; sq_dc[s] <= 3'd0; end
    end
end

// ------------------------------------------------------------------ triangle
logic        tri_rel;
logic  [6:0] tri_lin_r, tri_lin;
logic [10:0] tri_f, tri_t;
logic  [4:0] tri_c;
wire   [3:0] tri_out = tri_c[4] ? tri_c[3:0] : ~tri_c[3:0];

always_ff @(posedge clk) begin
    if (reset) begin
        tri_ctrl <= 1'b0; tri_rel <= 1'b0; tri_lin <= 7'd0; tri_t <= 11'd0; tri_c <= 5'd0; tri_f <= 11'd0; tri_lin_r <= 7'd0;
    end else begin
        if (reg_wr && ra == 5'h08) begin tri_ctrl <= din[7]; tri_lin_r <= din[6:0]; end
        if (reg_wr && ra == 5'h0A) tri_f[7:0] <= din;
        if (reg_wr && ra == 5'h0B) begin tri_f[10:8] <= din[2:0]; tri_rel <= 1'b1; end
        else if (lfo1) begin
            if (tri_rel) tri_lin <= tri_lin_r;
            else if (tri_lin != 7'd0) tri_lin <= tri_lin - 7'd1;
            if (!tri_ctrl) tri_rel <= 1'b0;
        end
        if (ce) begin                                                   // timer every CPU cycle (PHI1)
            if (tri_t == 11'd0) begin
                tri_t <= tri_f;
                if (tri_lin != 7'd0 && len_on[2]) tri_c <= tri_c + 5'd1;
            end else tri_t <= tri_t - 11'd1;
        end
    end
end

// ------------------------------------------------------------------ noise
logic [10:0] nz_p;
logic [14:0] nz_r;
logic  [3:0] nz_idx;
logic        nz_mode;
wire   [3:0] nz_out = (!nz_r[0] && len_on[3]) ? env_out[2] : 4'd0;

always_ff @(posedge clk) begin
    if (reset) begin
        nz_p <= 11'd0; nz_r <= 15'd0; nz_idx <= 4'd0; nz_mode <= 1'b0;
    end else begin
        if (reg_wr && ra == 5'h0E) begin nz_mode <= din[7]; nz_idx <= din[3:0]; end
        if (astep) begin
            if (nz_p == 11'h001) begin
                nz_p <= noise_rom(nz_idx);
                nz_r <= {(nz_r[0] ^ (nz_mode ? nz_r[6] : nz_r[1])) | (nz_r == 15'd0), nz_r[14:1]};
            end else nz_p <= {(nz_p[0] ^ nz_p[2]) | (nz_p == 11'd0), nz_p[10:1]};
        end
    end
end

// ------------------------------------------------------------------ DMC
logic  [8:0] dm_rate;
logic  [3:0] dm_idx;
logic        dm_irqen, dm_loop, dm_irq;
logic  [6:0] dm_out;
logic  [7:0] dm_a_r, dm_l_r;
logic [14:0] dm_addr;                   // A15 forced high
logic [11:0] dm_left;
logic  [7:0] dm_buf, dm_sr;
logic        dm_full, dm_silent;
logic  [2:0] dm_bits;

assign dmc_req  = !dm_full && dm_left != 12'd0;
assign dmc_addr = {1'b1, dm_addr};

always_ff @(posedge clk) begin
    if (reset) begin
        dm_rate <= 9'd0; dm_idx <= 4'd0; dm_irqen <= 1'b0; dm_loop <= 1'b0; dm_irq <= 1'b0; dm_out <= 7'd0;
        dm_left <= 12'd0; dm_full <= 1'b0; dm_silent <= 1'b1; dm_bits <= 3'd0; dm_sr <= 8'd0; dm_buf <= 8'd0;
        dm_a_r <= 8'd0; dm_l_r <= 8'd0; dm_addr <= 15'h4000;
    end else begin
        if (reg_wr && ra == 5'h10) begin
            dm_irqen <= din[7]; dm_loop <= din[6]; dm_idx <= din[3:0];
            if (!din[7]) dm_irq <= 1'b0;
        end
        if (reg_wr && ra == 5'h12) dm_a_r <= din;
        if (reg_wr && ra == 5'h13) dm_l_r <= din;
        if (reg_wr && ra == 5'h15) begin
            dm_irq <= 1'b0;
            if (!din[4]) dm_left <= 12'd0;
            else if (dm_left == 12'd0) begin dm_addr <= {1'b1, dm_a_r, 6'd0}; dm_left <= {dm_l_r, 4'd0} + 12'd1; end
        end
        // sample fetch
        if (dmc_ack) begin
            dm_buf <= dmc_data; dm_full <= 1'b1;
            dm_addr <= dm_addr + 15'd1;
            if (dm_left == 12'd1) begin
                if (dm_loop) begin dm_addr <= {1'b1, dm_a_r, 6'd0}; dm_left <= {dm_l_r, 4'd0} + 12'd1; end
                else begin dm_left <= 12'd0; if (dm_irqen) dm_irq <= 1'b1; end
            end else dm_left <= dm_left - 12'd1;
        end
        // output unit on the rate LFSR reload
        if (astep) begin
            if (dm_rate == 9'h001) begin
                dm_rate <= dmc_rom(dm_idx);
                if (!dm_silent) begin
                    if (dm_sr[0]) begin if (dm_out[6:1] != 6'h3F) dm_out[6:1] <= dm_out[6:1] + 6'd1; end
                    else          begin if (dm_out[6:1] != 6'h00) dm_out[6:1] <= dm_out[6:1] - 6'd1; end
                end
                dm_sr <= {1'b0, dm_sr[7:1]};
                dm_bits <= dm_bits - 3'd1;                              // 0 = 8 bits left
                if (dm_bits == 3'd1) begin                              // last bit out: next byte
                    if (dm_full) begin dm_sr <= dm_buf; dm_full <= 1'b0; dm_silent <= 1'b0; end
                    else dm_silent <= 1'b1;
                end
            end else dm_rate <= {(dm_rate[0] ^ dm_rate[4]) | (dm_rate == 9'd0), dm_rate[8:1]};
        end
        if (reg_wr && ra == 5'h11) dm_out <= din[6:0];
    end
end

// ------------------------------------------------------------------ status, IRQ
assign dout  = {dm_irq, fc_irq, 1'b0, dm_left != 12'd0, len_on};
assign irq_n = ~(fc_irq | dm_irq);

// ------------------------------------------------------------------ DAC
// AUX A: g = sq0 + sq1 (0..30) square steps
function automatic [15:0] dac_a(input [4:0] g);
    case (g)
        5'd0: dac_a = 16'd0;
        5'd1: dac_a = 16'd255;
        5'd2: dac_a = 16'd509;
        5'd3: dac_a = 16'd761;
        5'd4: dac_a = 16'd1012;
        5'd5: dac_a = 16'd1262;
        5'd6: dac_a = 16'd1511;
        5'd7: dac_a = 16'd1758;
        5'd8: dac_a = 16'd2004;
        5'd9: dac_a = 16'd2249;
        5'd10: dac_a = 16'd2493;
        5'd11: dac_a = 16'd2736;
        5'd12: dac_a = 16'd2977;
        5'd13: dac_a = 16'd3217;
        5'd14: dac_a = 16'd3456;
        5'd15: dac_a = 16'd3694;
        5'd16: dac_a = 16'd3930;
        5'd17: dac_a = 16'd4166;
        5'd18: dac_a = 16'd4400;
        5'd19: dac_a = 16'd4633;
        5'd20: dac_a = 16'd4865;
        5'd21: dac_a = 16'd5096;
        5'd22: dac_a = 16'd5326;
        5'd23: dac_a = 16'd5554;
        5'd24: dac_a = 16'd5782;
        5'd25: dac_a = 16'd6008;
        5'd26: dac_a = 16'd6233;
        5'd27: dac_a = 16'd6458;
        5'd28: dac_a = 16'd6681;
        5'd29: dac_a = 16'd6903;
        5'd30: dac_a = 16'd7124;
        default: dac_a = 16'd0;
    endcase
endfunction
// AUX B: q = quarter square steps (0..469)
function automatic [15:0] dac_b(input [8:0] q);
    case (q)
        9'd0: dac_b = 16'd0;
        9'd1: dac_b = 16'd64;
        9'd2: dac_b = 16'd128;
        9'd3: dac_b = 16'd191;
        9'd4: dac_b = 16'd255;
        9'd5: dac_b = 16'd319;
        9'd6: dac_b = 16'd382;
        9'd7: dac_b = 16'd445;
        9'd8: dac_b = 16'd509;
        9'd9: dac_b = 16'd572;
        9'd10: dac_b = 16'd635;
        9'd11: dac_b = 16'd698;
        9'd12: dac_b = 16'd761;
        9'd13: dac_b = 16'd824;
        9'd14: dac_b = 16'd887;
        9'd15: dac_b = 16'd950;
        9'd16: dac_b = 16'd1012;
        9'd17: dac_b = 16'd1075;
        9'd18: dac_b = 16'd1138;
        9'd19: dac_b = 16'd1200;
        9'd20: dac_b = 16'd1262;
        9'd21: dac_b = 16'd1325;
        9'd22: dac_b = 16'd1387;
        9'd23: dac_b = 16'd1449;
        9'd24: dac_b = 16'd1511;
        9'd25: dac_b = 16'd1573;
        9'd26: dac_b = 16'd1635;
        9'd27: dac_b = 16'd1697;
        9'd28: dac_b = 16'd1758;
        9'd29: dac_b = 16'd1820;
        9'd30: dac_b = 16'd1882;
        9'd31: dac_b = 16'd1943;
        9'd32: dac_b = 16'd2004;
        9'd33: dac_b = 16'd2066;
        9'd34: dac_b = 16'd2127;
        9'd35: dac_b = 16'd2188;
        9'd36: dac_b = 16'd2249;
        9'd37: dac_b = 16'd2310;
        9'd38: dac_b = 16'd2371;
        9'd39: dac_b = 16'd2432;
        9'd40: dac_b = 16'd2493;
        9'd41: dac_b = 16'd2554;
        9'd42: dac_b = 16'd2615;
        9'd43: dac_b = 16'd2675;
        9'd44: dac_b = 16'd2736;
        9'd45: dac_b = 16'd2796;
        9'd46: dac_b = 16'd2856;
        9'd47: dac_b = 16'd2917;
        9'd48: dac_b = 16'd2977;
        9'd49: dac_b = 16'd3037;
        9'd50: dac_b = 16'd3097;
        9'd51: dac_b = 16'd3157;
        9'd52: dac_b = 16'd3217;
        9'd53: dac_b = 16'd3277;
        9'd54: dac_b = 16'd3337;
        9'd55: dac_b = 16'd3396;
        9'd56: dac_b = 16'd3456;
        9'd57: dac_b = 16'd3515;
        9'd58: dac_b = 16'd3575;
        9'd59: dac_b = 16'd3634;
        9'd60: dac_b = 16'd3694;
        9'd61: dac_b = 16'd3753;
        9'd62: dac_b = 16'd3812;
        9'd63: dac_b = 16'd3871;
        9'd64: dac_b = 16'd3930;
        9'd65: dac_b = 16'd3989;
        9'd66: dac_b = 16'd4048;
        9'd67: dac_b = 16'd4107;
        9'd68: dac_b = 16'd4166;
        9'd69: dac_b = 16'd4224;
        9'd70: dac_b = 16'd4283;
        9'd71: dac_b = 16'd4341;
        9'd72: dac_b = 16'd4400;
        9'd73: dac_b = 16'd4458;
        9'd74: dac_b = 16'd4517;
        9'd75: dac_b = 16'd4575;
        9'd76: dac_b = 16'd4633;
        9'd77: dac_b = 16'd4691;
        9'd78: dac_b = 16'd4749;
        9'd79: dac_b = 16'd4807;
        9'd80: dac_b = 16'd4865;
        9'd81: dac_b = 16'd4923;
        9'd82: dac_b = 16'd4981;
        9'd83: dac_b = 16'd5038;
        9'd84: dac_b = 16'd5096;
        9'd85: dac_b = 16'd5153;
        9'd86: dac_b = 16'd5211;
        9'd87: dac_b = 16'd5268;
        9'd88: dac_b = 16'd5326;
        9'd89: dac_b = 16'd5383;
        9'd90: dac_b = 16'd5440;
        9'd91: dac_b = 16'd5497;
        9'd92: dac_b = 16'd5554;
        9'd93: dac_b = 16'd5611;
        9'd94: dac_b = 16'd5668;
        9'd95: dac_b = 16'd5725;
        9'd96: dac_b = 16'd5782;
        9'd97: dac_b = 16'd5838;
        9'd98: dac_b = 16'd5895;
        9'd99: dac_b = 16'd5952;
        9'd100: dac_b = 16'd6008;
        9'd101: dac_b = 16'd6065;
        9'd102: dac_b = 16'd6121;
        9'd103: dac_b = 16'd6177;
        9'd104: dac_b = 16'd6233;
        9'd105: dac_b = 16'd6290;
        9'd106: dac_b = 16'd6346;
        9'd107: dac_b = 16'd6402;
        9'd108: dac_b = 16'd6458;
        9'd109: dac_b = 16'd6514;
        9'd110: dac_b = 16'd6569;
        9'd111: dac_b = 16'd6625;
        9'd112: dac_b = 16'd6681;
        9'd113: dac_b = 16'd6737;
        9'd114: dac_b = 16'd6792;
        9'd115: dac_b = 16'd6848;
        9'd116: dac_b = 16'd6903;
        9'd117: dac_b = 16'd6958;
        9'd118: dac_b = 16'd7014;
        9'd119: dac_b = 16'd7069;
        9'd120: dac_b = 16'd7124;
        9'd121: dac_b = 16'd7179;
        9'd122: dac_b = 16'd7234;
        9'd123: dac_b = 16'd7289;
        9'd124: dac_b = 16'd7344;
        9'd125: dac_b = 16'd7399;
        9'd126: dac_b = 16'd7454;
        9'd127: dac_b = 16'd7509;
        9'd128: dac_b = 16'd7563;
        9'd129: dac_b = 16'd7618;
        9'd130: dac_b = 16'd7672;
        9'd131: dac_b = 16'd7727;
        9'd132: dac_b = 16'd7781;
        9'd133: dac_b = 16'd7835;
        9'd134: dac_b = 16'd7890;
        9'd135: dac_b = 16'd7944;
        9'd136: dac_b = 16'd7998;
        9'd137: dac_b = 16'd8052;
        9'd138: dac_b = 16'd8106;
        9'd139: dac_b = 16'd8160;
        9'd140: dac_b = 16'd8214;
        9'd141: dac_b = 16'd8268;
        9'd142: dac_b = 16'd8322;
        9'd143: dac_b = 16'd8375;
        9'd144: dac_b = 16'd8429;
        9'd145: dac_b = 16'd8482;
        9'd146: dac_b = 16'd8536;
        9'd147: dac_b = 16'd8589;
        9'd148: dac_b = 16'd8643;
        9'd149: dac_b = 16'd8696;
        9'd150: dac_b = 16'd8749;
        9'd151: dac_b = 16'd8803;
        9'd152: dac_b = 16'd8856;
        9'd153: dac_b = 16'd8909;
        9'd154: dac_b = 16'd8962;
        9'd155: dac_b = 16'd9015;
        9'd156: dac_b = 16'd9068;
        9'd157: dac_b = 16'd9120;
        9'd158: dac_b = 16'd9173;
        9'd159: dac_b = 16'd9226;
        9'd160: dac_b = 16'd9279;
        9'd161: dac_b = 16'd9331;
        9'd162: dac_b = 16'd9384;
        9'd163: dac_b = 16'd9436;
        9'd164: dac_b = 16'd9488;
        9'd165: dac_b = 16'd9541;
        9'd166: dac_b = 16'd9593;
        9'd167: dac_b = 16'd9645;
        9'd168: dac_b = 16'd9697;
        9'd169: dac_b = 16'd9750;
        9'd170: dac_b = 16'd9802;
        9'd171: dac_b = 16'd9854;
        9'd172: dac_b = 16'd9905;
        9'd173: dac_b = 16'd9957;
        9'd174: dac_b = 16'd10009;
        9'd175: dac_b = 16'd10061;
        9'd176: dac_b = 16'd10113;
        9'd177: dac_b = 16'd10164;
        9'd178: dac_b = 16'd10216;
        9'd179: dac_b = 16'd10267;
        9'd180: dac_b = 16'd10319;
        9'd181: dac_b = 16'd10370;
        9'd182: dac_b = 16'd10421;
        9'd183: dac_b = 16'd10473;
        9'd184: dac_b = 16'd10524;
        9'd185: dac_b = 16'd10575;
        9'd186: dac_b = 16'd10626;
        9'd187: dac_b = 16'd10677;
        9'd188: dac_b = 16'd10728;
        9'd189: dac_b = 16'd10779;
        9'd190: dac_b = 16'd10830;
        9'd191: dac_b = 16'd10881;
        9'd192: dac_b = 16'd10931;
        9'd193: dac_b = 16'd10982;
        9'd194: dac_b = 16'd11033;
        9'd195: dac_b = 16'd11083;
        9'd196: dac_b = 16'd11134;
        9'd197: dac_b = 16'd11184;
        9'd198: dac_b = 16'd11235;
        9'd199: dac_b = 16'd11285;
        9'd200: dac_b = 16'd11335;
        9'd201: dac_b = 16'd11385;
        9'd202: dac_b = 16'd11436;
        9'd203: dac_b = 16'd11486;
        9'd204: dac_b = 16'd11536;
        9'd205: dac_b = 16'd11586;
        9'd206: dac_b = 16'd11636;
        9'd207: dac_b = 16'd11686;
        9'd208: dac_b = 16'd11735;
        9'd209: dac_b = 16'd11785;
        9'd210: dac_b = 16'd11835;
        9'd211: dac_b = 16'd11885;
        9'd212: dac_b = 16'd11934;
        9'd213: dac_b = 16'd11984;
        9'd214: dac_b = 16'd12033;
        9'd215: dac_b = 16'd12083;
        9'd216: dac_b = 16'd12132;
        9'd217: dac_b = 16'd12181;
        9'd218: dac_b = 16'd12231;
        9'd219: dac_b = 16'd12280;
        9'd220: dac_b = 16'd12329;
        9'd221: dac_b = 16'd12378;
        9'd222: dac_b = 16'd12427;
        9'd223: dac_b = 16'd12476;
        9'd224: dac_b = 16'd12525;
        9'd225: dac_b = 16'd12574;
        9'd226: dac_b = 16'd12623;
        9'd227: dac_b = 16'd12672;
        9'd228: dac_b = 16'd12720;
        9'd229: dac_b = 16'd12769;
        9'd230: dac_b = 16'd12818;
        9'd231: dac_b = 16'd12866;
        9'd232: dac_b = 16'd12915;
        9'd233: dac_b = 16'd12963;
        9'd234: dac_b = 16'd13011;
        9'd235: dac_b = 16'd13060;
        9'd236: dac_b = 16'd13108;
        9'd237: dac_b = 16'd13156;
        9'd238: dac_b = 16'd13205;
        9'd239: dac_b = 16'd13253;
        9'd240: dac_b = 16'd13301;
        9'd241: dac_b = 16'd13349;
        9'd242: dac_b = 16'd13397;
        9'd243: dac_b = 16'd13445;
        9'd244: dac_b = 16'd13493;
        9'd245: dac_b = 16'd13540;
        9'd246: dac_b = 16'd13588;
        9'd247: dac_b = 16'd13636;
        9'd248: dac_b = 16'd13683;
        9'd249: dac_b = 16'd13731;
        9'd250: dac_b = 16'd13779;
        9'd251: dac_b = 16'd13826;
        9'd252: dac_b = 16'd13874;
        9'd253: dac_b = 16'd13921;
        9'd254: dac_b = 16'd13968;
        9'd255: dac_b = 16'd14016;
        9'd256: dac_b = 16'd14063;
        9'd257: dac_b = 16'd14110;
        9'd258: dac_b = 16'd14157;
        9'd259: dac_b = 16'd14204;
        9'd260: dac_b = 16'd14251;
        9'd261: dac_b = 16'd14298;
        9'd262: dac_b = 16'd14345;
        9'd263: dac_b = 16'd14392;
        9'd264: dac_b = 16'd14439;
        9'd265: dac_b = 16'd14486;
        9'd266: dac_b = 16'd14532;
        9'd267: dac_b = 16'd14579;
        9'd268: dac_b = 16'd14626;
        9'd269: dac_b = 16'd14672;
        9'd270: dac_b = 16'd14719;
        9'd271: dac_b = 16'd14765;
        9'd272: dac_b = 16'd14811;
        9'd273: dac_b = 16'd14858;
        9'd274: dac_b = 16'd14904;
        9'd275: dac_b = 16'd14950;
        9'd276: dac_b = 16'd14997;
        9'd277: dac_b = 16'd15043;
        9'd278: dac_b = 16'd15089;
        9'd279: dac_b = 16'd15135;
        9'd280: dac_b = 16'd15181;
        9'd281: dac_b = 16'd15227;
        9'd282: dac_b = 16'd15273;
        9'd283: dac_b = 16'd15319;
        9'd284: dac_b = 16'd15365;
        9'd285: dac_b = 16'd15410;
        9'd286: dac_b = 16'd15456;
        9'd287: dac_b = 16'd15502;
        9'd288: dac_b = 16'd15547;
        9'd289: dac_b = 16'd15593;
        9'd290: dac_b = 16'd15638;
        9'd291: dac_b = 16'd15684;
        9'd292: dac_b = 16'd15729;
        9'd293: dac_b = 16'd15775;
        9'd294: dac_b = 16'd15820;
        9'd295: dac_b = 16'd15865;
        9'd296: dac_b = 16'd15910;
        9'd297: dac_b = 16'd15956;
        9'd298: dac_b = 16'd16001;
        9'd299: dac_b = 16'd16046;
        9'd300: dac_b = 16'd16091;
        9'd301: dac_b = 16'd16136;
        9'd302: dac_b = 16'd16181;
        9'd303: dac_b = 16'd16226;
        9'd304: dac_b = 16'd16271;
        9'd305: dac_b = 16'd16315;
        9'd306: dac_b = 16'd16360;
        9'd307: dac_b = 16'd16405;
        9'd308: dac_b = 16'd16449;
        9'd309: dac_b = 16'd16494;
        9'd310: dac_b = 16'd16539;
        9'd311: dac_b = 16'd16583;
        9'd312: dac_b = 16'd16627;
        9'd313: dac_b = 16'd16672;
        9'd314: dac_b = 16'd16716;
        9'd315: dac_b = 16'd16761;
        9'd316: dac_b = 16'd16805;
        9'd317: dac_b = 16'd16849;
        9'd318: dac_b = 16'd16893;
        9'd319: dac_b = 16'd16937;
        9'd320: dac_b = 16'd16981;
        9'd321: dac_b = 16'd17025;
        9'd322: dac_b = 16'd17069;
        9'd323: dac_b = 16'd17113;
        9'd324: dac_b = 16'd17157;
        9'd325: dac_b = 16'd17201;
        9'd326: dac_b = 16'd17245;
        9'd327: dac_b = 16'd17289;
        9'd328: dac_b = 16'd17332;
        9'd329: dac_b = 16'd17376;
        9'd330: dac_b = 16'd17420;
        9'd331: dac_b = 16'd17463;
        9'd332: dac_b = 16'd17507;
        9'd333: dac_b = 16'd17550;
        9'd334: dac_b = 16'd17594;
        9'd335: dac_b = 16'd17637;
        9'd336: dac_b = 16'd17680;
        9'd337: dac_b = 16'd17724;
        9'd338: dac_b = 16'd17767;
        9'd339: dac_b = 16'd17810;
        9'd340: dac_b = 16'd17853;
        9'd341: dac_b = 16'd17896;
        9'd342: dac_b = 16'd17939;
        9'd343: dac_b = 16'd17982;
        9'd344: dac_b = 16'd18025;
        9'd345: dac_b = 16'd18068;
        9'd346: dac_b = 16'd18111;
        9'd347: dac_b = 16'd18154;
        9'd348: dac_b = 16'd18197;
        9'd349: dac_b = 16'd18240;
        9'd350: dac_b = 16'd18282;
        9'd351: dac_b = 16'd18325;
        9'd352: dac_b = 16'd18368;
        9'd353: dac_b = 16'd18410;
        9'd354: dac_b = 16'd18453;
        9'd355: dac_b = 16'd18495;
        9'd356: dac_b = 16'd18538;
        9'd357: dac_b = 16'd18580;
        9'd358: dac_b = 16'd18622;
        9'd359: dac_b = 16'd18665;
        9'd360: dac_b = 16'd18707;
        9'd361: dac_b = 16'd18749;
        9'd362: dac_b = 16'd18791;
        9'd363: dac_b = 16'd18834;
        9'd364: dac_b = 16'd18876;
        9'd365: dac_b = 16'd18918;
        9'd366: dac_b = 16'd18960;
        9'd367: dac_b = 16'd19002;
        9'd368: dac_b = 16'd19044;
        9'd369: dac_b = 16'd19085;
        9'd370: dac_b = 16'd19127;
        9'd371: dac_b = 16'd19169;
        9'd372: dac_b = 16'd19211;
        9'd373: dac_b = 16'd19252;
        9'd374: dac_b = 16'd19294;
        9'd375: dac_b = 16'd19336;
        9'd376: dac_b = 16'd19377;
        9'd377: dac_b = 16'd19419;
        9'd378: dac_b = 16'd19460;
        9'd379: dac_b = 16'd19502;
        9'd380: dac_b = 16'd19543;
        9'd381: dac_b = 16'd19585;
        9'd382: dac_b = 16'd19626;
        9'd383: dac_b = 16'd19667;
        9'd384: dac_b = 16'd19708;
        9'd385: dac_b = 16'd19750;
        9'd386: dac_b = 16'd19791;
        9'd387: dac_b = 16'd19832;
        9'd388: dac_b = 16'd19873;
        9'd389: dac_b = 16'd19914;
        9'd390: dac_b = 16'd19955;
        9'd391: dac_b = 16'd19996;
        9'd392: dac_b = 16'd20037;
        9'd393: dac_b = 16'd20078;
        9'd394: dac_b = 16'd20118;
        9'd395: dac_b = 16'd20159;
        9'd396: dac_b = 16'd20200;
        9'd397: dac_b = 16'd20241;
        9'd398: dac_b = 16'd20281;
        9'd399: dac_b = 16'd20322;
        9'd400: dac_b = 16'd20362;
        9'd401: dac_b = 16'd20403;
        9'd402: dac_b = 16'd20443;
        9'd403: dac_b = 16'd20484;
        9'd404: dac_b = 16'd20524;
        9'd405: dac_b = 16'd20565;
        9'd406: dac_b = 16'd20605;
        9'd407: dac_b = 16'd20645;
        9'd408: dac_b = 16'd20685;
        9'd409: dac_b = 16'd20726;
        9'd410: dac_b = 16'd20766;
        9'd411: dac_b = 16'd20806;
        9'd412: dac_b = 16'd20846;
        9'd413: dac_b = 16'd20886;
        9'd414: dac_b = 16'd20926;
        9'd415: dac_b = 16'd20966;
        9'd416: dac_b = 16'd21006;
        9'd417: dac_b = 16'd21046;
        9'd418: dac_b = 16'd21085;
        9'd419: dac_b = 16'd21125;
        9'd420: dac_b = 16'd21165;
        9'd421: dac_b = 16'd21205;
        9'd422: dac_b = 16'd21244;
        9'd423: dac_b = 16'd21284;
        9'd424: dac_b = 16'd21324;
        9'd425: dac_b = 16'd21363;
        9'd426: dac_b = 16'd21403;
        9'd427: dac_b = 16'd21442;
        9'd428: dac_b = 16'd21482;
        9'd429: dac_b = 16'd21521;
        9'd430: dac_b = 16'd21560;
        9'd431: dac_b = 16'd21600;
        9'd432: dac_b = 16'd21639;
        9'd433: dac_b = 16'd21678;
        9'd434: dac_b = 16'd21717;
        9'd435: dac_b = 16'd21756;
        9'd436: dac_b = 16'd21796;
        9'd437: dac_b = 16'd21835;
        9'd438: dac_b = 16'd21874;
        9'd439: dac_b = 16'd21913;
        9'd440: dac_b = 16'd21952;
        9'd441: dac_b = 16'd21990;
        9'd442: dac_b = 16'd22029;
        9'd443: dac_b = 16'd22068;
        9'd444: dac_b = 16'd22107;
        9'd445: dac_b = 16'd22146;
        9'd446: dac_b = 16'd22185;
        9'd447: dac_b = 16'd22223;
        9'd448: dac_b = 16'd22262;
        9'd449: dac_b = 16'd22300;
        9'd450: dac_b = 16'd22339;
        9'd451: dac_b = 16'd22378;
        9'd452: dac_b = 16'd22416;
        9'd453: dac_b = 16'd22455;
        9'd454: dac_b = 16'd22493;
        9'd455: dac_b = 16'd22531;
        9'd456: dac_b = 16'd22570;
        9'd457: dac_b = 16'd22608;
        9'd458: dac_b = 16'd22646;
        9'd459: dac_b = 16'd22684;
        9'd460: dac_b = 16'd22723;
        9'd461: dac_b = 16'd22761;
        9'd462: dac_b = 16'd22799;
        9'd463: dac_b = 16'd22837;
        9'd464: dac_b = 16'd22875;
        9'd465: dac_b = 16'd22913;
        9'd466: dac_b = 16'd22951;
        9'd467: dac_b = 16'd22989;
        9'd468: dac_b = 16'd23027;
        9'd469: dac_b = 16'd23065;
        default: dac_b = 16'd23065;
    endcase
endfunction

always_ff @(posedge clk) begin
    aux_a <= dac_a({1'b0, sq_out[0]} + {1'b0, sq_out[1]});
    aux_b <= dac_b(9'((15'(tri_out) * 15'd422 + 15'(nz_out) * 15'd283 + 15'(dm_out) * 15'd153) >> 6));
end

endmodule
