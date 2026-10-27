//============================================================================
//
//  PunchOut: CHP1 CPU board (Z80 + RP2A03 + VLM5030) around the CHP1 video (rtl/boards/chp1/chp1_video.sv)
//  Copyright (C) 2026 Rodimus
//
//  MAME nintendo/punchout.cpp (reference) + CHP1-02 schematic facts. Drives the dispatcher's pools only (never its
//  own CPU / ROM / RAM). Variant 0 Punch-Out!! map; Super Punch-Out!! protection (RP5C01 / RP5H01, ports 05-07) and
//  the Arm Wrestling map are TODO.
//  Clock enables from CLK_SYS 40.32 MHz (= 2 x the 20.16 MHz video xtal):
//    Z80 4 MHz (8 MHz xtal / 2): half-cycle ticks at 8 MHz = 40.32 x 25 / 126, exact
//    RP2A03 CPU cycle 1.789773 MHz (21.47727 MHz / 12) = 40.32 x 125 / 2816, exact
//  Speech (VLM5030): pooled rtl/sound/vlm5030_lpc.sv (MAME port); its ROM is read on ROM port B phase 7.
//  Not modelled (MAME ignores them too): watchdog (LS161A 2A counting VB), Z80 BUSRQ from VB, latch Q1 / Q2 / Q7.
//
//============================================================================

module chp1_board
(
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,
    input  logic  [7:0] variant,

    input  logic  [7:0] in0,
    input  logic  [7:0] in1,
    input  logic  [7:0] dsw1,
    input  logic  [7:0] dsw2,

    input  logic        crt_flip,
    input  logic  [3:0] h_adj,
    input  logic  [3:0] v_adj,

    // shared CPU / sound chip pool (chip_pool_pkg): the shared T80pa, T65 (RP2A03 core) and VLM5030
    output chip_pool_pkg::z80pa_i_t   z80pa_0_i,
    input  chip_pool_pkg::z80pa_o_t   z80pa_0_o,
    output chip_pool_pkg::t65_i_t     t65_0_i,
    input  chip_pool_pkg::t65_o_t     t65_0_o,
    output chip_pool_pkg::vlm5030_i_t vlm5030_0_i,
    input  chip_pool_pkg::vlm5030_o_t vlm5030_0_o,

    // shared ROM blocks: rom0 = packed store (region slot + region offset, d one clock later), port B = rom0_*,
    // port A = rom0b_* (second reader); rom1 = colour PROMs, port B = rom1_* (bottom monitor), port A = rom1b_* (top)
    output logic  [2:0] rom0_slot,
    output logic [17:0] rom0_a,
    input  logic  [7:0] rom0_d,
    output logic  [2:0] rom0b_slot,
    output logic [17:0] rom0b_a,
    input  logic  [7:0] rom0b_d,
    output logic [12:0] rom1_a,
    input  logic  [7:0] rom1_d,
    output logic [12:0] rom1b_a,
    input  logic  [7:0] rom1b_d,

    // shared board RAM pool (ram_pool_pkg, Universal's RAMPOOL convention): block n = pr_i[n] / pr_o[n], see below
    output ram_pool_pkg::pram_i_t [6:0] pr_i,
    input  ram_pool_pkg::pram_o_t [6:0] pr_o,

    // battery RAM save / load (MRA index 4): port B of pool block 1
    input  logic  [9:0] nvs_addr,
    input  logic  [7:0] nvs_din,
    input  logic        nvs_we,
    output logic  [7:0] nvs_dout,

    output logic        ce_pix,
    output logic  [7:0] top_r,
    output logic  [7:0] top_g,
    output logic  [7:0] top_b,
    output logic  [7:0] bot_r,
    output logic  [7:0] bot_g,
    output logic  [7:0] bot_b,
    output logic        video_hs,
    output logic        video_vs,
    output logic        video_hblank,
    output logic        video_vblank,

    output logic signed [15:0] audio,
    input  logic  [3:0] vol_speech,     // gain in eighths (8 = Default, 0 = Off)
    input  logic  [3:0] vol_music
);

localparam logic [2:0] SLOT_MAIN = 3'd0, SLOT_SND = 3'd1, SLOT_VLM = 3'd6;

chip_pool_pkg::z80pa_i_t z80_i;
chip_pool_pkg::z80pa_o_t z80_o;
assign z80pa_0_i = z80_i;
assign z80_o     = z80pa_0_o;
logic [2:0]  roma_slot, romb_slot;
logic [17:0] roma_off, romb_off;
logic [7:0]  roma_q, romb_q;
assign rom0b_slot = roma_slot; assign rom0b_a = roma_off; assign roma_q = rom0b_d;
// VLMPORT-2026-10-27: port B phase 7 = VLM5030 ROM (assigns below the video); original:
// assign rom0_slot  = romb_slot; assign rom0_a  = romb_off; assign romb_q = rom0_d;
assign romb_q = rom0_d;

// Board RAM pool blocks (port A = CPU, port B = video engine / save path); sizes set by the dispatcher per block:
//   0 work RAM 2K (D000-D7FF)          1 battery RAM 1K (C000-C3FF; B = MRA index 4)
//   2 top bg map 2K (D800-DFFF)        3 bottom bg map + row scroll 4K (F000-FFFF)
//   4 big sprite 1 map 2K (E000-E7FF)  5 big sprite 2 map 2K (E800-EFFF)   6 RP2A03 RAM 2K (0000-07FF)
logic [10:0] wram_a, vtop_a, spr1_a, spr2_a, snd_a, vtop_ab, spr1_ab, spr2_ab;
logic  [9:0] nv_a;
logic [11:0] vbot_a, vbot_ab;
logic  [7:0] wram_d, nv_d, vtop_d, vbot_d, spr1_d, spr2_d, snd_d;
logic        wram_we, nv_we, vtop_we, vbot_we, spr1_we, spr2_we, snd_we;
logic  [7:0] wram_q, nv_q, vtop_q, vbot_q, spr1_q, spr2_q, snd_q, vtop_qb, vbot_qb, spr1_qb, spr2_qb;
assign pr_i[0] = '{a_addr: {4'd0, wram_a}, a_d: wram_d, a_we: wram_we, b_addr: 15'd0, b_d: 8'd0, b_we: 1'b0};
assign pr_i[1] = '{a_addr: {5'd0, nv_a},   a_d: nv_d,   a_we: nv_we,   b_addr: {5'd0, nvs_addr}, b_d: nvs_din, b_we: nvs_we};
assign pr_i[2] = '{a_addr: {4'd0, vtop_a}, a_d: vtop_d, a_we: vtop_we, b_addr: {4'd0, vtop_ab}, b_d: 8'd0, b_we: 1'b0};
assign pr_i[3] = '{a_addr: {3'd0, vbot_a}, a_d: vbot_d, a_we: vbot_we, b_addr: {3'd0, vbot_ab}, b_d: 8'd0, b_we: 1'b0};
assign pr_i[4] = '{a_addr: {4'd0, spr1_a}, a_d: spr1_d, a_we: spr1_we, b_addr: {4'd0, spr1_ab}, b_d: 8'd0, b_we: 1'b0};
assign pr_i[5] = '{a_addr: {4'd0, spr2_a}, a_d: spr2_d, a_we: spr2_we, b_addr: {4'd0, spr2_ab}, b_d: 8'd0, b_we: 1'b0};
assign pr_i[6] = '{a_addr: {4'd0, snd_a},  a_d: snd_d,  a_we: snd_we,  b_addr: 15'd0, b_d: 8'd0, b_we: 1'b0};
assign wram_q = pr_o[0].a_q;
assign nv_q   = pr_o[1].a_q;  assign nvs_dout = pr_o[1].b_q;
assign vtop_q = pr_o[2].a_q;  assign vtop_qb  = pr_o[2].b_q;
assign vbot_q = pr_o[3].a_q;  assign vbot_qb  = pr_o[3].b_q;
assign spr1_q = pr_o[4].a_q;  assign spr1_qb  = pr_o[4].b_q;
assign spr2_q = pr_o[5].a_q;  assign spr2_qb  = pr_o[5].b_q;
assign snd_q  = pr_o[6].a_q;

/////////////////////////////  Video  /////////////////////////////

logic [2:0]  ph;
logic        vreg_we, vb;
logic        v_roma_req;
logic [2:0]  v_roma_slot;
logic [17:0] v_roma_off;

chp1_video video
(
    .clk(clk), .flip(crt_flip), .h_adj(h_adj), .v_adj(v_adj),
    .reg_we(vreg_we), .reg_a(z80_o.a[3:0]), .reg_d(z80_o.dout),
    .vtop_a(vtop_ab), .vtop_q(vtop_qb), .vbot_a(vbot_ab), .vbot_q(vbot_qb),
    .spr1_a(spr1_ab), .spr1_q(spr1_qb), .spr2_a(spr2_ab), .spr2_q(spr2_qb),
    .ph(ph), .romb_slot(romb_slot), .romb_off(romb_off), .romb_q(romb_q),
    .roma_req(v_roma_req), .roma_slot(v_roma_slot), .roma_off(v_roma_off), .roma_q(roma_q),
    .prom_top_a(rom1b_a), .prom_top_q(rom1b_d), .prom_bot_a(rom1_a), .prom_bot_q(rom1_d),
    .ce_pix(ce_pix), .top_r(top_r), .top_g(top_g), .top_b(top_b), .bot_r(bot_r), .bot_g(bot_g), .bot_b(bot_b),
    .hs(video_hs), .vs(video_vs), .hblank(video_hblank), .vblank(video_vblank), .vb(vb)
);
// ROM port B phase 7 is not read by the video (its result would land at phase 0): VLM5030 speech ROM (6P, 16K)
assign rom0_slot = (ph == 3'd7) ? SLOT_VLM : romb_slot;
assign rom0_a    = (ph == 3'd7) ? {4'd0, vlm5030_0_o.a[13:0]} : romb_off;

/////////////////////////////  Clock enables  /////////////////////////////

logic [6:0]  zacc = 7'd0;
logic        zhalf = 1'b0, z_cen_p = 1'b0, z_cen_n = 1'b0;
logic [11:0] sacc = 12'd0;
logic        s_ce = 1'b0;
logic [10:0] vacc = 11'd0;
logic        v_ce = 1'b0;
always_ff @(posedge clk) begin
    z_cen_p <= 1'b0; z_cen_n <= 1'b0; s_ce <= 1'b0; v_ce <= 1'b0;
    if (!pause) begin
        if (zacc >= 7'd101) begin                       // + 25 reaches 126
            zacc <= zacc - 7'd101;
            zhalf <= ~zhalf;
            z_cen_p <= ~zhalf; z_cen_n <= zhalf;
        end else
            zacc <= zacc + 7'd25;
        if (sacc >= 12'd2691) begin                     // + 125 reaches 2816
            sacc <= sacc - 12'd2691;
            s_ce <= 1'b1;
        end else
            sacc <= sacc + 12'd125;
        if (vacc >= 11'd1283) begin                     // + 125 reaches 1408: VLM5030 OSC 3.579545 MHz
            vacc <= vacc - 11'd1283;
            v_ce <= 1'b1;
        end else
            vacc <= vacc + 11'd125;
    end
end

/////////////////////////////  Z80 bus  /////////////////////////////

wire [15:0] za   = z80_o.a;
wire        mreq = ~z80_o.mreq_n & z80_o.rfsh_n;
wire        iorq = ~z80_o.iorq_n & z80_o.m1_n;             // not INTA (no INT on this board)
wire        zrd  = ~z80_o.rd_n, zwr = ~z80_o.wr_n;

wire cs_rom  = za[15:14] != 2'b11;                         // 0000-BFFF
wire cs_nv   = za[15:10] == 6'b110000;                     // C000-C3FF battery RAM
wire cs_wram = za[15:11] == 5'b11010;                      // D000-D7FF
wire cs_vtop = za[15:11] == 5'b11011;                      // D800-DFFF (DFF0-DFFF also the video registers)
wire cs_spr1 = za[15:11] == 5'b11100;                      // E000-E7FF
wire cs_spr2 = za[15:11] == 5'b11101;                      // E800-EFFF
wire cs_vbot = za[15:12] == 4'hF;                          // F000-FFFF (row scroll in the first 64 bytes)
wire mw      = mreq & zwr;

assign wram_a = za[10:0]; assign wram_d = z80_o.dout; assign wram_we = mw & cs_wram;
assign nv_a   = za[9:0];  assign nv_d   = z80_o.dout; assign nv_we   = mw & cs_nv;
assign vtop_a = za[10:0]; assign vtop_d = z80_o.dout; assign vtop_we = mw & cs_vtop;
assign spr1_a = za[10:0]; assign spr1_d = z80_o.dout; assign spr1_we = mw & cs_spr1;
assign spr2_a = za[10:0]; assign spr2_d = z80_o.dout; assign spr2_we = mw & cs_spr2;
assign vbot_a = za[11:0]; assign vbot_d = z80_o.dout; assign vbot_we = mw & cs_vbot;
assign vreg_we = mw & (za[15:4] == 12'hDFF);

// I/O (global mask 0xFF): reads 00 IN0, 01 IN1, 02 DSW2, 03 DSW1 (bit 4 = VLM5030 BSY through the inverting
// buffer: 1 = idle); writes 02 / 03 sound latches, 04 VLM5030 data, 08-0F main latch LS259 2B (data bit 0)
wire io_wr = iorq & zwr;
logic [7:0] snd_lat1 = 8'd0, snd_lat2 = 8'd0, vlm_lat = 8'd0;
logic [7:0] mlatch = 8'd0;                                 // Q0 NMI mask, Q3 2A03 reset, Q4-Q6 VLM RST / START / VCU
always_ff @(posedge clk) begin
    if (reset) mlatch <= 8'd0;
    else if (io_wr && za[7:3] == 5'b00001) mlatch[za[2:0]] <= z80_o.dout[0];
    if (io_wr && za[7:0] == 8'h02) snd_lat1 <= z80_o.dout;
    if (io_wr && za[7:0] == 8'h03) snd_lat2 <= z80_o.dout;
    if (io_wr && za[7:0] == 8'h04) vlm_lat  <= z80_o.dout;
end
// VLM5030 pool port: RST / START / VCU = main latch Q4-Q6. One D bus: the 6L data latch, or the speech ROM while
// /ME is low (ROM byte from port B phase 7, valid at phase 0)
logic [7:0] vlm_rom_q = 8'hFF;
always_ff @(posedge clk) if (ph == 3'd0) vlm_rom_q <= rom0_d;
// VLMPORT-2026-10-27: original (no model, OSC off):
// assign vlm5030_0_i = '{rst: mlatch[4], oscen: 1'b0, start: mlatch[5], vcu: mlatch[6], d: vlm_lat};
assign vlm5030_0_i = '{rst: mlatch[4], oscen: v_ce, start: mlatch[5], vcu: mlatch[6],
                       d: vlm5030_0_o.me_l ? vlm_lat : vlm_rom_q};
wire   vlm_bsy     = vlm5030_0_o.bsy;

// NMI: set at vblank start while Q0 = 1, cleared by Q0 = 0 (MAME vblank_irq / nmi_mask_w)
logic vb_d = 1'b0, nmi = 1'b0;
always_ff @(posedge clk) begin
    vb_d <= vb;
    if (reset || !mlatch[0]) nmi <= 1'b0;
    else if (vb && !vb_d) nmi <= 1'b1;
end

// ROM port A: Z80 on phases 0 / 2 / 4 / 7, RP2A03 on 1 / 3, big sprite 2 (video) on 5 / 6
wire [15:0] sa;                                            // RP2A03 external address
wire sel_t = ph == 3'd1 || ph == 3'd3;
assign roma_slot = v_roma_req ? v_roma_slot : sel_t ? SLOT_SND : SLOT_MAIN;
assign roma_off  = v_roma_req ? v_roma_off  : {2'b00, sel_t ? sa : za};

logic [7:0] zrom_q = 8'hFF, srom_q = 8'hFF;
logic       z_slot = 1'b0, s_slot = 1'b0;
always_ff @(posedge clk) begin
    z_slot <= ~v_roma_req & ~sel_t;
    s_slot <= sel_t;
    if (z_slot) zrom_q <= roma_q;
    if (s_slot) srom_q <= roma_q;
end

// SPNCH-2026-10-27: Super Punch-Out!! (variant 1) CHS1-01-EXP security board: RP5H01 at 05 / 06, RP5C01 at x7
wire       is_spnch = variant == 8'd1;
wire [7:0] exp_q;
chs1_exp exp_board (.clk(clk), .reset(reset), .io_wr(io_wr && is_spnch), .a(za[7:0]), .d(z80_o.dout), .q(exp_q));

logic [7:0] zdi = 8'hFF;
always_ff @(posedge clk) begin
    // SPNCH-2026-10-27: port x7 (select F0) on Super Punch-Out!!; original first line: if (iorq) case (za[7:0])
    if (iorq && is_spnch && za[3:0] == 4'd7) zdi <= exp_q;
    else if (iorq) case (za[7:0])
        8'h00:   zdi <= in0;
        8'h01:   zdi <= in1;
        8'h02:   zdi <= dsw2;
        8'h03:   zdi <= {dsw1[7:5], ~vlm_bsy, dsw1[3:0]};
        default: zdi <= 8'hFF;
    endcase
    else if (cs_rom)  zdi <= zrom_q;
    else if (cs_nv)   zdi <= nv_q;
    else if (cs_wram) zdi <= wram_q;
    else if (cs_vtop) zdi <= vtop_q;
    else if (cs_spr1) zdi <= spr1_q;
    else if (cs_spr2) zdi <= spr2_q;
    else if (cs_vbot) zdi <= vbot_q;
    else              zdi <= 8'hFF;
end

assign z80_i = '{reset_n: 1'b1, cen_p: z_cen_p, cen_n: z_cen_n, wait_n: 1'b1, int_n: 1'b1, nmi_n: ~nmi, di: zdi};

/////////////////////////////  RP2A03 (sound board part of the CPU board)  /////////////////////////////

// 0000-07FF RAM (4L), 4016 / 4017 sound latches, E000-FFFF ROM (4K); NMI = vblank (MAME: top screen vblank)
logic        s_rw;
logic  [7:0] s_do, s_di;
logic [15:0] s_aux_a, s_aux_b;

rp2a03 apu2a03
(
    .clk(clk), .reset(reset | mlatch[3]), .ce(s_ce), .nmi_n(~vb),
    .t65_i(t65_0_i), .t65_o(t65_0_o),
    .ext_a(sa), .ext_rw(s_rw), .ext_dout(s_do), .ext_din(s_di), .aux_a(s_aux_a), .aux_b(s_aux_b)
);

assign snd_a  = sa[10:0];
assign snd_d  = s_do;
assign snd_we = s_ce & ~s_rw & (sa[15:11] == 5'd0);
always_comb
    s_di = (sa[15:13] == 3'b111) ? srom_q : (sa == 16'h4016) ? snd_lat1 : (sa == 16'h4017) ? snd_lat2 :
           (sa[15:11] == 5'd0) ? snd_q : 8'h00;

// mix (Nintendo core DK3 lineage): AUX A + AUX B, DC blocker (~9 Hz at the CPU clock rate), plus the VLM5030 at half
// scale (MAME routes each at 0.50; HW is one mono amp, level by ear #unverified)
logic [16:0] mix_sum;
logic signed [31:0] mix_lp = 32'sd0;
logic signed [18:0] mix_hp;
always_ff @(posedge clk) begin
    mix_sum <= {1'b0, s_aux_a} + {1'b0, s_aux_b};
    if (s_ce) mix_lp <= mix_lp + (((32'($signed({2'b00, mix_sum})) <<< 15) - mix_lp) >>> 15);
end
assign mix_hp = $signed({2'b00, mix_sum}) - 19'(mix_lp >>> 15);
// VLMPORT-2026-10-27: original (no speech):
// assign audio  = (mix_hp > 19'sd32767) ? 16'sd32767 : (mix_hp < -19'sd32768) ? -16'sd32768 : mix_hp[15:0];
// VLMLPF-TEST-2026-10-27: speech through the schematic's 2N output filter (chp1_speech_lpf.sv); original:
// wire signed [18:0] mix_all = mix_hp + (19'($signed(vlm5030_0_o.audio)) <<< 5);
logic signed [15:0] vlm_lpf;
chp1_speech_lpf speech_lpf (.clk(clk), .reset(reset), .oscen(v_ce), .x(vlm5030_0_o.audio), .y(vlm_lpf));
// VLMLVL-2026-10-27: speech x1.5 (user on HW: "just a little quiet ... maybe half more volume"); original:
// wire signed [18:0] mix_all = mix_hp + 19'(vlm_lpf);
// wire signed [18:0] mix_all = mix_hp + 19'(vlm_lpf) + (19'(vlm_lpf) >>> 1);
// LAYOUT-STEP1-2026-10-27: Game Options Speech / Music Volume (Exidy form): x vol / 8, shift-adds (no multiplier);
// Default (8) = the line above
function automatic logic signed [22:0] vgain(input logic signed [18:0] v, input logic [3:0] g);
    vgain = (g[0] ? 23'(v) : 23'sd0) + (g[1] ? 23'(v) <<< 1 : 23'sd0) + (g[2] ? 23'(v) <<< 2 : 23'sd0)
          + (g[3] ? 23'(v) <<< 3 : 23'sd0);
endfunction
wire signed [18:0] sp15    = 19'(vlm_lpf) + (19'(vlm_lpf) >>> 1);
wire signed [22:0] sp_v    = vgain(sp15, vol_speech);
wire signed [22:0] mus_v   = vgain(mix_hp, vol_music);
wire signed [22:0] mix_v   = (sp_v + mus_v) >>> 3;
wire signed [18:0] mix_all = (mix_v > 23'sd262143) ? 19'sd262143 : (mix_v < -23'sd262144) ? -19'sd262144 : 19'(mix_v);
assign audio  = (mix_all > 19'sd32767) ? 16'sd32767 : (mix_all < -19'sd32768) ? -16'sd32768 : mix_all[15:0];

/* verilator lint_off UNUSED */
// VLMPORT-2026-10-27: original:
// wire unused_ok = &{1'b0, variant, zrd, pr_o[0].b_q, pr_o[6].b_q, mlatch[7], mlatch[2:1], vlm5030_0_o.a, vlm5030_0_o.me_l, vlm5030_0_o.mte,
//                    vlm5030_0_o.dao, vlm5030_0_o.audio};
wire unused_ok = &{1'b0, variant, zrd, pr_o[0].b_q, pr_o[6].b_q, mlatch[7], mlatch[2:1], vlm5030_0_o.a[15:14],
                   vlm5030_0_o.mte, vlm5030_0_o.dao};
/* verilator lint_on UNUSED */

endmodule
