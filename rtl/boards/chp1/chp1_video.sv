//============================================================================
//
//  PunchOut: CHP1 VIDEO + BAK boards: one timing chain, two screens (top "S" / bottom "M" monitor)
//  Copyright (C) 2026 Rodimus
//
//  From MAME nintendo/punchout.cpp (reference) + the CHP1-02 schematic facts (Claude/punchout_schematic_facts.md):
//    top    = bg 32x32 (gfx1, 2bpp)            + big sprite 1 if DFF7.0
//    bottom = bg 64x32 + row scroll (gfx2)      + big sprite 1 if DFF7.1 + big sprite 2 (gfx4, 2bpp)
//    big sprite 1 = 16x32-tile map (gfx3, 3bpp), 12-bit zoom, MAME draw_roz; ONE engine feeds both screens (the
//    schematic fans CMP* out to both colour muxes), only the palette half differs
//  Every layer is fetched per pixel (no line buffers): 8 CLK_SYS per 5.04 MHz pixel (CLK_SYS = 40.32 MHz).
//  Pipeline, one pixel period each: S1 video RAM reads, S2 ROM reads, S3 pens + colour PROM reads, then out.
//  Output x = fetch x - 3, so the blanking window is shifted by 3 pixels against the fetch counter.
//  Raster 320 x 262 (#unverified: H / V totals not traced; 5.04 MHz / 320 = 15.75 kHz, 60.1 Hz), visible 256 x 224 =
//  MAME rows 16-239.
//  ARMW-2026-10-27: Arm Wrestling (aw, variant 2; MAME armwrest_state): top bg at F800 (gfx1, attr b7 = code b10, no
//    flip), bottom bg 32x32 at F000 (gfx1, no scroll, bottom palette), fg text layer at D800 (gfx2 3bpp, over everything,
//    pen 7 clear), big sprite 1 = 32x16-tile map in two 16x16 halves (x flip swaps them). The three tilemaps do not
//    scroll, so their ROM bytes are prefetched once per 8-pixel tile during the previous tile (7 reads per 8 pixels, on
//    the port B slots 3-6 that Punch-Out's two bg layers use per pixel). Bottom-screen priority = MAME's fixed order
//    (bg < big sprite 1 < big sprite 2 < fg); the CHV1-BAK board selects it through PROM 3C (82S129) with PRTY0-1 from
//    latch 2H — not modelled yet (#unverified which strobe clocks 2H and which output pair the CL / SL pads select).
//
//============================================================================

module chp1_video
(
    input  logic        clk,            // CLK_SYS 40.32 MHz
    input  logic        flip,           // Flip Screen: 180 degrees, both screens
    input  logic        aw,             // ARMW-2026-10-27: Arm Wrestling video (variant 2)
    input  logic  [3:0] h_adj,
    input  logic  [3:0] v_adj,

    // Z80 writes to DFF0-DFFD (sprite / palette-bank registers)
    input  logic        reg_we,
    input  logic  [3:0] reg_a,
    input  logic  [7:0] reg_d,

    // video RAM pool, port B
    output logic [10:0] vtop_a,
    input  logic  [7:0] vtop_q,
    output logic [11:0] vbot_a,
    input  logic  [7:0] vbot_q,
    output logic [10:0] spr1_a,
    input  logic  [7:0] spr1_q,
    output logic [10:0] spr2_a,
    input  logic  [7:0] spr2_q,

    // ROM store (region slot + region offset, q one clock later): port B every phase, port A on phases 5 / 6
    output logic  [2:0] ph,
    output logic  [2:0] romb_slot,
    output logic [17:0] romb_off,
    input  logic  [7:0] romb_q,
    output logic        roma_req,
    output logic  [2:0] roma_slot,
    output logic [17:0] roma_off,
    input  logic  [7:0] roma_q,

    // colour PROMs (proms region offset): port A = top monitor, port B = bottom monitor
    output logic [12:0] prom_top_a,
    input  logic  [7:0] prom_top_q,
    output logic [12:0] prom_bot_a,
    input  logic  [7:0] prom_bot_q,

    output logic        ce_pix,
    output logic  [7:0] top_r,
    output logic  [7:0] top_g,
    output logic  [7:0] top_b,
    output logic  [7:0] bot_r,
    output logic  [7:0] bot_g,
    output logic  [7:0] bot_b,
    output logic        hs,
    output logic        vs,
    output logic        hblank,
    output logic        vblank,
    output logic        vb              // MAME vblank (rows 240-15): Z80 NMI source, RP2A03 NMI
);

localparam logic [2:0] SLOT_GFX1 = 3'd2, SLOT_GFX2 = 3'd3, SLOT_GFX3 = 3'd4, SLOT_GFX4 = 3'd5;

/////////////////////////////  Timing  /////////////////////////////

logic [2:0] phc = 3'd0;
logic [8:0] hc = 9'd0, vc = 9'd0;
wire        pend = phc == 3'd7;                         // last clock of a pixel period
wire        hlast = hc == 9'd319;
wire  [8:0] vnext = (vc == 9'd261) ? 9'd0 : vc + 9'd1;

always_ff @(posedge clk) begin
    phc <= phc + 3'd1;
    if (pend) begin
        hc <= hlast ? 9'd0 : hc + 9'd1;
        if (hlast) vc <= vnext;
    end
end
assign ph     = phc;
assign ce_pix = phc == 3'd3;                            // mid-period: the output registers change at pend

// fetch coordinates (MAME bitmap x / y); Flip Screen mirrors both (visible rows 16-239 map onto themselves)
wire [7:0] fx  = flip ? ~hc[7:0] : hc[7:0];
wire [7:0] fy  = flip ? ~vc[7:0] : vc[7:0];
wire [7:0] fyn = flip ? ~vnext[7:0] : vnext[7:0];      // next line, for the per-line set-up during hc 319

/////////////////////////////  Registers DFF0-DFFD  /////////////////////////////

logic [7:0] r[14];
always_ff @(posedge clk) if (reg_we && reg_a < 4'd14) r[reg_a] <= reg_d;
initial for (int i = 0; i < 14; i++) r[i] = 8'h00;

wire [11:0] zoom   = {r[1][3:0], r[0]};
wire        bs1_on = zoom != 12'd0;
wire  [1:0] bs1_mon = r[7][1:0];                        // [0] top, [1] bottom
wire        pbank_bot = r[13][0], pbank_top = r[13][1];

/////////////////////////////  Big sprite 1 (MAME punchout_state::draw_big_sprite)  /////////////////////////////

// sx = 4096 - X; if (sx > 4096 - 4*127) sx -= 4096;  sy = -Y; if (sy <= -256 + zoom/0x40) sy += 512; sy += 12
wire        [11:0] sxr = {r[3][3:0], r[2]};
wire signed [13:0] sx0 = 14'sd4096 - $signed({2'b00, sxr});
// Arm Wrestling: if (sx > 2048) sx -= 4096
wire signed [13:0] sx  = (sx0 > (aw ? 14'sd2048 : 14'sd3588)) ? sx0 - 14'sd4096 : sx0;
wire signed [13:0] nsx = -sx;
wire         [8:0] syr = {r[5][0], r[4]};
wire signed [11:0] sy0 = -$signed({3'b000, syr});
wire signed [11:0] sy1 = (sy0 <= -12'sd256 + $signed({6'b000000, zoom[11:6]})) ? sy0 + 12'sd512 : sy0;
wire signed [11:0] nsy = -(sy1 + 12'sd12);

// startx = -sx * 0x4000 + 3740 * zoom; starty = -sy * 0x10000 - 178 * zoom (+ 0x400 * zoom passed to draw_roz)
wire [31:0] incxx0  = {14'd0, zoom, 6'd0};
wire [31:0] startx0 = ({{18{nsx[13]}}, nsx} << 14) + 32'(zoom) * 32'd3740;
// x flip: (16*8 << 16) - startx - 1; Arm Wrestling (32*8 << 16) - startx - 1
wire [31:0] startx  = r[6][0] ? (aw ? 32'h0100_0000 : 32'h0080_0000) - startx0 - 32'd1 : startx0;
wire [31:0] incxx   = r[6][0] ? -incxx0 : incxx0;
wire [31:0] starty  = ({{20{nsy[11]}}, nsy} << 16) - 32'(zoom) * 32'd178 + {10'd0, zoom, 10'd0};
// Flip Screen: the line runs from bitmap x 255 down to 0
wire [31:0] cx_step = flip ? -incxx : incxx;
wire [31:0] cx_line = flip ? startx + (incxx << 8) - incxx : startx;
wire [19:0] yzoom   = fyn * zoom;

logic [31:0] cx = 32'd0, cy = 32'd0;                    // roz source position of the pixel being fetched (16.16)
always_ff @(posedge clk) if (pend) begin
    if (hlast) begin
        cx <= cx_line;
        cy <= starty + {6'd0, yzoom, 6'd0};
    end else
        cx <= cx + cx_step;
end
// u32 compare with the map size: 128 x 256 (Punch-Out), 256 x 128 (Arm Wrestling)
wire       bs1_in = aw ? (cx[31:24] == 8'd0 && cy[31:23] == 9'd0) : (cx[31:23] == 9'd0 && cy[31:24] == 8'd0);
wire [7:0] bs1_x  = aw ? cx[23:16] : {1'b0, cx[22:16]};
wire [7:0] bs1_y  = aw ? {1'b0, cy[22:16]} : cy[23:16];
// Arm Wrestling bs1_scan: tile (col, row) at (col / 16) * 256 + row * 16 + col % 16; the x-flip map takes col ^ 16
wire [4:0] bs1_col = bs1_x[7:3] ^ ((aw && r[6][0]) ? 5'h10 : 5'h00);

/////////////////////////////  Big sprite 2 (MAME punchout_state::drawbs2: no zoom)  /////////////////////////////

// sx = 512 - X; if (sx > 512 - 127) sx -= 512; sx -= 55;  sy = -Y + 256 * (YH & 1) + 3
wire        [8:0] sx2r = {r[9][0], r[8]};
wire signed [11:0] sx2a = 12'sd512 - $signed({3'b000, sx2r});
wire signed [11:0] sx2  = ((sx2a > 12'sd385) ? sx2a - 12'sd512 : sx2a) - 12'sd55;
wire signed [11:0] sy2  = -$signed({4'b0000, r[10]}) + (r[11][0] ? 12'sd256 : 12'sd0) + 12'sd3;
wire signed [11:0] fx_s = $signed({4'b0000, fx});
wire signed [11:0] fy_s = $signed({4'b0000, fy});
wire signed [11:0] dx2  = r[12][0] ? 12'sd127 + sx2 - fx_s : fx_s - sx2;   // x flip: 127 + sx - x
wire signed [11:0] dy2  = fy_s - sy2;
wire        bs2_in = dx2 >= 12'sd0 && dx2 < 12'sd128 && dy2 >= 12'sd0 && dy2 < 12'sd256;

/////////////////////////////  S1: video RAM reads (phase 0-2; row scroll at hc 319, phase 2-3)  /////////////////////////////

// bottom bg row scroll: scrollx(row) = 58 + ram[2 row] + 256 * (ram[2 row + 1] & 1); tilemap x = (x + scroll) & 511
logic [7:0] sc_lo = 8'd0;
logic       sc_hi = 1'b0;
wire  [8:0] bscroll = 9'd58 + {sc_hi, sc_lo};
wire  [8:0] btx = {1'b0, fx} + bscroll;

wire [1:0] sb = (phc == 3'd2) ? 2'b11 : {1'b0, phc[0]};             // sprite maps: bytes 0, 1, 3 of a 4-byte cell
// Arm Wrestling: the tile after this one in raster order (tile groups are hc 8n .. 8n+7; 320 = 40 groups), read during
// group pixel 0: fg (D800) code / attr at phases 0 / 1, top bg (F800) at 0 / 1, bottom bg (F000) at 2 / 3
wire  [8:0] tg_h0 = {hc[8:3], 3'b000} + 9'd8;
wire        tg_wr = tg_h0 >= 9'd320;
wire  [8:0] tg_h  = tg_wr ? tg_h0 - 9'd320 : tg_h0;
wire  [8:0] tg_v  = tg_wr ? vnext : vc;
wire  [7:0] tg_fx = flip ? ~tg_h[7:0] : tg_h[7:0];
wire  [7:0] tg_fy = flip ? ~tg_v[7:0] : tg_v[7:0];
// ARMW-2026-10-27: original vtop_a / vbot_a / spr1_a:
// assign vtop_a = {fy[7:3], fx[7:3], phc[0]};
// assign vbot_a = phc[1] ? {6'd0, fyn[7:3], phc[0]} : {fy[7:3], btx[8:3], phc[0]};
// assign spr1_a = {bs1_y[7:3], bs1_x[6:3], sb};
assign vtop_a = aw ? {tg_fy[7:3], tg_fx[7:3], phc[0]} : {fy[7:3], fx[7:3], phc[0]};
assign vbot_a = aw ? {~phc[1], tg_fy[7:3], tg_fx[7:3], phc[0]}
              : phc[1] ? {6'd0, fyn[7:3], phc[0]} : {fy[7:3], btx[8:3], phc[0]};
assign spr1_a = aw ? {bs1_col[4], bs1_y[6:3], bs1_col[3:0], sb} : {bs1_y[7:3], bs1_x[6:3], sb};
assign spr2_a = {dy2[7:3], dx2[6:3], sb};

logic [7:0] t1_code, t1_attr, b1_code, b1_attr, p1_b0, p1_b1, p1_b3, q1_b0, q1_b1, q1_b3;
always_ff @(posedge clk) begin
    case (phc)
        3'd1: begin t1_code <= vtop_q; b1_code <= vbot_q; p1_b0 <= spr1_q; q1_b0 <= spr2_q; end
        3'd2: begin t1_attr <= vtop_q; b1_attr <= vbot_q; p1_b1 <= spr1_q; q1_b1 <= spr2_q; end
        3'd3: begin p1_b3 <= spr1_q; q1_b3 <= spr2_q; if (hlast && !aw) sc_lo <= vbot_q; end
        3'd4: if (hlast && !aw) sc_hi <= vbot_q[0];
        default: ;
    endcase
end

/////////////////////////////  S2: ROM reads  /////////////////////////////

// gfx_8x8x2_planar / 8x8x3_planar: plane k at k * region / planes, the highest plane = pen MSB; byte bit 7 = pixel 0
logic [9:0]  t2_code, b2_code;
logic [4:0]  t2_col, b2_col, p2_col;
logic [12:0] p2_code;
logic [11:0] q2_code;
logic [5:0]  q2_col;
logic [2:0]  t2_px, t2_py, b2_px, b2_py, p2_px, p2_py, q2_px, q2_py;
logic        t2_fl, b2_fl, p2_fl, q2_fl, p2_in, q2_in;
always_ff @(posedge clk) if (pend) begin
    t2_code <= {t1_attr[1:0], t1_code}; t2_col <= t1_attr[6:2]; t2_fl <= t1_attr[7]; t2_px <= fx[2:0]; t2_py <= fy[2:0];
    b2_code <= {b1_attr[1:0], b1_code}; b2_col <= b1_attr[6:2]; b2_fl <= b1_attr[7]; b2_px <= btx[2:0]; b2_py <= fy[2:0];
    p2_code <= {p1_b1[4:0], p1_b0};     p2_col <= p1_b3[4:0];   p2_fl <= p1_b3[7]; p2_px <= bs1_x[2:0]; p2_py <= bs1_y[2:0];   // (both maps)
    p2_in   <= bs1_in;
    q2_code <= {q1_b1[3:0], q1_b0};     q2_col <= q1_b3[5:0];   q2_fl <= q1_b3[7]; q2_px <= dx2[2:0]; q2_py <= dy2[2:0];
    q2_in   <= bs2_in;
end

// port B: 0-2 big sprite 1 planes 0-2, 3-4 top bg planes, 5-6 bottom bg planes; port A: 5-6 big sprite 2 planes
// Arm Wrestling prefetch (group pixel 1: top bg planes at 3 / 4, bottom bg planes at 5 / 6, both gfx1 0x8000 = plane
// at 0x4000; group pixel 2: fg planes at 3 / 4 / 5, gfx2 0xC000 = planes at 0 / 0x4000 / 0x8000)
logic [7:0] aw_fc, aw_fa, aw_tc, aw_ta, aw_bc, aw_ba;   // next tile: fg / top / bottom code + attr
wire  [2:0] grp = hc[2:0];
logic [17:0] aw_off;
logic  [2:0] aw_slot;
always_comb begin
    aw_slot = SLOT_GFX1;
    aw_off  = 18'd0;
    if (grp == 3'd2) begin
        aw_slot = SLOT_GFX2;
        aw_off  = {2'b00, (phc == 3'd5) ? 2'd2 : (phc == 3'd4) ? 2'd1 : 2'd0, aw_fa[2:0], aw_fc, tg_fy[2:0]};
    end else if (phc == 3'd3 || phc == 3'd4)
        aw_off  = {3'b000, phc == 3'd4, aw_ta[7], aw_ta[1:0], aw_tc, tg_fy[2:0]};
    else
        aw_off  = {3'b000, phc == 3'd6, 1'b0, aw_ba[1:0], aw_bc, tg_fy[2:0]};
end
always_comb begin
    case (phc)
        3'd0, 3'd1, 3'd2: begin romb_slot = SLOT_GFX3; romb_off = {phc[1:0], p2_code, p2_py}; end
        3'd3, 3'd4:       begin romb_slot = aw ? aw_slot : SLOT_GFX1; romb_off = aw ? aw_off : {4'd0, phc == 3'd4, t2_code, t2_py}; end
        default:          begin romb_slot = aw ? aw_slot : SLOT_GFX2; romb_off = aw ? aw_off : {4'd0, phc == 3'd6, b2_code, b2_py}; end
    endcase
end

// Arm Wrestling: next tile's video RAM bytes (group pixel 0) and plane bytes (pixels 1 / 2); current tile from the
// group boundary on, then down the pixel pipeline with the other layers
logic [7:0] an_t0, an_t1, an_b0, an_b1, an_f0, an_f1, an_f2;
logic [7:0] ac_t0, ac_t1, ac_b0, ac_b1, ac_f0, ac_f1, ac_f2, ac_ta, ac_ba, ac_fa;
always_ff @(posedge clk) begin
    if (grp == 3'd0) case (phc)
        3'd1: begin aw_fc <= vtop_q; aw_tc <= vbot_q; end
        3'd2: begin aw_fa <= vtop_q; aw_ta <= vbot_q; end
        3'd3: aw_bc <= vbot_q;
        3'd4: aw_ba <= vbot_q;
        default: ;
    endcase
    if (grp == 3'd1) case (phc)
        3'd4: an_t0 <= romb_q;
        3'd5: an_t1 <= romb_q;
        3'd6: an_b0 <= romb_q;
        3'd7: an_b1 <= romb_q;
        default: ;
    endcase
    if (grp == 3'd2) case (phc)
        3'd4: an_f0 <= romb_q;
        3'd5: an_f1 <= romb_q;
        3'd6: an_f2 <= romb_q;
        default: ;
    endcase
    if (pend && grp == 3'd7) begin
        ac_t0 <= an_t0; ac_t1 <= an_t1; ac_b0 <= an_b0; ac_b1 <= an_b1; ac_f0 <= an_f0; ac_f1 <= an_f1; ac_f2 <= an_f2;
        ac_ta <= aw_ta; ac_ba <= aw_ba; ac_fa <= aw_fa;
    end
end
assign roma_req  = phc == 3'd5 || phc == 3'd6;
assign roma_slot = SLOT_GFX4;
assign roma_off  = {2'd0, phc == 3'd6, q2_code, q2_py};

logic [7:0] p2_d0, p2_d1, p2_d2, t2_d0, t2_d1, b2_d0, q2_d0;
always_ff @(posedge clk) begin
    case (phc)
        3'd1: p2_d0 <= romb_q;
        3'd2: p2_d1 <= romb_q;
        3'd3: p2_d2 <= romb_q;
        3'd4: t2_d0 <= romb_q;
        3'd5: t2_d1 <= romb_q;
        3'd6: begin b2_d0 <= romb_q; q2_d0 <= roma_q; end
        default: ;
    endcase
end

// Arm Wrestling layers down the pipeline (S2 = the pixel's tile, S3 = with the other layers' S3)
logic [7:0] a2_t0, a2_t1, a2_b0, a2_b1, a2_f0, a2_f1, a2_f2, a2_ta, a2_ba, a2_fa;
logic [7:0] a3_t0, a3_t1, a3_b0, a3_b1, a3_f0, a3_f1, a3_f2;
logic [4:0] a3_tcol, a3_bcol, a3_fcol;
logic [2:0] a2_px, a3_tbit, a3_bbit, a3_fbit;
always_ff @(posedge clk) if (pend) begin
    a2_t0 <= ac_t0; a2_t1 <= ac_t1; a2_b0 <= ac_b0; a2_b1 <= ac_b1; a2_f0 <= ac_f0; a2_f1 <= ac_f1; a2_f2 <= ac_f2;
    a2_ta <= ac_ta; a2_ba <= ac_ba; a2_fa <= ac_fa; a2_px <= fx[2:0];
    a3_t0 <= a2_t0; a3_t1 <= a2_t1; a3_b0 <= a2_b0; a3_b1 <= a2_b1; a3_f0 <= a2_f0; a3_f1 <= a2_f1; a3_f2 <= a2_f2;
    a3_tcol <= a2_ta[6:2]; a3_bcol <= a2_ba[6:2]; a3_fcol <= a2_fa[7:3];
    a3_tbit <= ~a2_px;                                  // top bg: no flip
    a3_bbit <= a2_ba[7] ? a2_px : ~a2_px;
    a3_fbit <= a2_fa[7] ? a2_px : ~a2_px;
end

/////////////////////////////  S3: pens, priority, colour PROMs  /////////////////////////////

logic [7:0] p3_d0, p3_d1, p3_d2, t3_d0, t3_d1, b3_d0, b3_d1, q3_d0, q3_d1;
logic [4:0] t3_col, b3_col, p3_col;
logic [5:0] q3_col;
logic [2:0] t3_bit, b3_bit, p3_bit, q3_bit;
logic       p3_in, q3_in;
always_ff @(posedge clk) if (pend) begin
    p3_d0 <= p2_d0; p3_d1 <= p2_d1; p3_d2 <= p2_d2; t3_d0 <= t2_d0; t3_d1 <= t2_d1;
    b3_d0 <= b2_d0; b3_d1 <= romb_q;                    // phase 6 read, valid now
    q3_d0 <= q2_d0; q3_d1 <= roma_q;
    t3_col <= t2_col; b3_col <= b2_col; p3_col <= p2_col; q3_col <= q2_col;
    p3_in <= p2_in; q3_in <= q2_in;
    // TILE_FLIPX: pixel px reads byte bit px, else bit 7 - px
    t3_bit <= t2_fl ? t2_px : ~t2_px;
    b3_bit <= b2_fl ? b2_px : ~b2_px;
    p3_bit <= p2_fl ? p2_px : ~p2_px;
    q3_bit <= q2_fl ? q2_px : ~q2_px;
end

wire [1:0] t_pix = {t3_d1[t3_bit], t3_d0[t3_bit]};
wire [1:0] b_pix = {b3_d1[b3_bit], b3_d0[b3_bit]};
wire [2:0] p_pix = {p3_d2[p3_bit], p3_d1[p3_bit], p3_d0[p3_bit]};
wire [1:0] q_pix = {q3_d1[q3_bit], q3_d0[q3_bit]};
wire       p_opq = p3_in && bs1_on && p_pix != 3'd7;  // transparent pen 7
wire       q_opq = q3_in && q_pix != 2'd3;             // transparent pen 3

// palette index within the screen's 256 pens (MAME pens 0x000-0x0FF top, 0x100-0x1FF bottom)
wire [1:0] at_pix = {a3_t1[a3_tbit], a3_t0[a3_tbit]};
wire [1:0] ab_pix = {a3_b1[a3_bbit], a3_b0[a3_bbit]};
wire [2:0] af_pix = {a3_f2[a3_fbit], a3_f1[a3_fbit], a3_f0[a3_fbit]};
wire       f_opq  = aw && af_pix != 3'd7;              // fg transparent pen 7
// ARMW-2026-10-27: original top_idx / bot_idx (Punch-Out layers only):
// wire [7:0] top_idx = (p_opq && bs1_mon[0]) ? {p3_col, p_pix} : {1'b0, t3_col, t_pix};
// wire [7:0] bot_idx = q_opq ? {q3_col, q_pix} : (p_opq && bs1_mon[1]) ? {p3_col, p_pix} : {1'b0, b3_col, b_pix};
wire [7:0] top_bg  = aw ? {1'b0, a3_tcol, at_pix} : {1'b0, t3_col, t_pix};
wire [7:0] bot_bg  = aw ? {1'b0, a3_bcol, ab_pix} : {1'b0, b3_col, b_pix};
wire [7:0] top_idx = (p_opq && bs1_mon[0]) ? {p3_col, p_pix} : top_bg;
wire [7:0] bot_idx = f_opq ? {a3_fcol, af_pix} : q_opq ? {q3_col, q_pix} : (p_opq && bs1_mon[1]) ? {p3_col, p_pix} : bot_bg;

// proms: R / G / B of the top monitor at 0x000 / 0x200 / 0x400, bottom at 0x600 / 0x800 / 0xA00; A8 = palette bank
wire [2:0] gun = (phc == 3'd1) ? 3'd1 : (phc == 3'd2) ? 3'd2 : 3'd0;
assign prom_top_a = {1'b0, gun,          pbank_top, top_idx};
assign prom_bot_a = {1'b0, gun + 3'd3,   pbank_bot, bot_idx};

logic [3:0] tr, tg, tb, br, bg, bb;
always_ff @(posedge clk) begin
    case (phc)
        3'd1: begin tr <= prom_top_q[3:0]; br <= prom_bot_q[3:0]; end
        3'd2: begin tg <= prom_top_q[3:0]; bg <= prom_bot_q[3:0]; end
        3'd3: begin tb <= prom_top_q[3:0]; bb <= prom_bot_q[3:0]; end
        default: ;
    endcase
end

/////////////////////////////  Output  /////////////////////////////

// next period's counters: the pixel shown then was fetched 3 periods earlier
wire  [8:0] hcn = hlast ? 9'd0 : hc + 9'd1;
wire  [8:0] vcn = hlast ? vnext : vc;
wire        hvis = hcn >= 9'd3 && hcn <= 9'd258;
wire        vvis = vcn >= 9'd16 && vcn <= 9'd239;
wire signed [9:0] hs0 = 10'sd275 + {{6{h_adj[3]}}, h_adj};
wire signed [9:0] vs0 = 10'sd244 + {{6{v_adj[3]}}, v_adj};
wire signed [9:0] hcn_s = $signed({1'b0, hcn});
wire signed [9:0] vcn_s = $signed({1'b0, vcn});

always_ff @(posedge clk) if (pend) begin
    hblank <= ~hvis;
    vblank <= ~vvis;
    vb     <= ~(vcn >= 9'd16 && vcn < 9'd240);
    hs     <= hcn_s >= hs0 && hcn_s < hs0 + 10'sd24;
    if (hlast) vs <= vcn_s >= vs0 && vcn_s < vs0 + 10'sd3;
    // outputs are active low on the BAK board (MAME 255 - pal4bit)
    {top_r, top_g, top_b} <= (hvis && vvis) ? ~{tr, tr, tg, tg, tb, tb} : 24'd0;
    {bot_r, bot_g, bot_b} <= (hvis && vvis) ? ~{br, br, bg, bg, bb, bb} : 24'd0;
end

endmodule
