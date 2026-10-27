//============================================================================
//
//  PunchOut: the two CHP1 monitors on MiSTer's two outputs (OSD Game Options "Screen Layout")
//  Copyright (C) 2026 Rodimus
//
//  The board drives both monitors from one timing chain: top and bottom pixel N of line L arrive together.
//  Native stream (analog / CRT, and HDMI when the framebuffer is off) and the HDMI framebuffer are separate paths:
//  in the split layouts the native stream carries only the CRT screen and the framebuffer holds only the HDMI
//  screen (never a composite). MiSTer.ini vga_scaler=1 (scaler to VGA) or direct_video=1 (native to HDMI) put one
//  picture on both outputs; direct video turns the framebuffer off here.
//
//  layout (OSD order, 0 = default):
//    0 Vertical, Top above      1 Horizontal, Top left       2 Horizontal, Bottom left    3 Vertical, Bottom above
//    4 Top only                 5 Bottom only                6 Split: Top HDMI, Bottom CRT  7 Split: Top CRT, Bottom HDMI
//  LAYOUT-STEP3-2026-10-27: all eight layouts on both outputs (steps 3 + 4: native Horz. 15 kHz and Vert. 31 kHz).
//
//  Native stream:
//    Single / Split: the board's raster, one screen.
//    Horz. (1, 2): the board's 15 kHz raster at twice the pixel rate (10.08 MHz, 640 periods per line): the 512-pixel
//      line fills the original visible window, one board line after its capture (line store slots {line[0], screen}).
//    Vert. (0, 3): 31 kHz progressive, 524 lines of 320 periods at 10.08 MHz per board frame (60.11 Hz), 448 visible.
//      Out-line m = 2 x board line + half shows the first screen's line t at m = 258 + t and the second's at
//      482 + t (mod 524). A line is captured by m = 34 + 2t, so 257 is the earliest start (+1 margin). The lines
//      waiting at once (both screens, peak ~226) share a pool of 232 line slots: free list + map[screen][line].
//    15 kHz-only monitors cannot show the Vert. layouts (README). No scandoubler / fx on a 31 kHz stream (nat31).
//
//  Framebuffer (HDMI): 32bpp {0, B, G, R}, 2048-byte rows, triple-buffered at 33000000 / 34000000 / 35000000 (the
//  fleet artwork.sv region; PunchOut has no artwork). Each visible line is captured into a ping-pong line buffer (both
//  screens, pixel pairs = 64-bit words), then burst-written (64 words, artwork.sv's DDR handshake) at its screen's
//  place in the layout. A finished frame becomes the shown buffer at the scaler's next FB_VBL.
//
//============================================================================

module punchout_layout
(
    input  logic        clk,
    input  logic  [2:0] layout,
    input  logic        direct_video,
    input  logic        dim,                // pause dim: applied to the framebuffer (pause dims the native stream itself)

    // board video: both monitors, one timing
    input  logic        ce_pix,
    input  logic        hs_in, vs_in, hblank_in, vblank_in,
    input  logic [23:0] top_rgb,            // {R, G, B}
    input  logic [23:0] bot_rgb,

    // native stream (arcade_video: analog, and HDMI when fb_en = 0)
    output logic        ce_out,
    output logic        hs_out, vs_out, hblank_out, vblank_out,
    output logic [23:0] rgb_out,
    output logic        nat31,              // native stream is 31 kHz (Vert.): scandoubler / fx off

    // HDMI framebuffer
    output logic        fb_en,
    output logic [11:0] fb_w,
    output logic [11:0] fb_h,
    output logic [11:0] ar_x,               // aspect of the framebuffer picture (VIDEO_ARX / ARY, Original)
    output logic [11:0] ar_y,
    output logic [31:0] fb_base,
    input  logic        fb_vbl,

    output logic        DDRAM_CLK,
    input  logic        DDRAM_BUSY,
    output logic  [7:0] DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    output logic        DDRAM_RD,
    output logic [63:0] DDRAM_DIN,
    output logic  [7:0] DDRAM_BE,
    output logic        DDRAM_WE
);

localparam [28:0] FB0_W = 29'h06600000;       // byte 33000000 >> 3; buffer n at + n * 01000000 bytes

/////////////////////////////  Layout decode  /////////////////////////////

// native stream screen: Top only / Split Top CRT; everything else Bottom (LAYOUT-STEP2: 0-3 too, until steps 3-4)
wire nat_top = layout == 3'd4 || layout == 3'd7;
// LAYOUT-STEP2-2026-10-27: the framebuffer composes 0-3 (both screens) and the splits (the HDMI screen alone); the
// single layouts leave HDMI on the native stream. Step 1 (splits only) was:
//   fb_on = (layout == 6 || layout == 7) && !direct_video; en_top = layout == 6; en_bot = layout == 7; 256 x 224, (0, 0)
wire fb_on   = (layout != 3'd4 && layout != 3'd5) && !direct_video;
wire en_top  = layout != 3'd7;
wire en_bot  = layout != 3'd6;
wire horz    = layout == 3'd1 || layout == 3'd2;
wire vert    = layout == 3'd0 || layout == 3'd3;
wire bot_1st = layout == 3'd2 || layout == 3'd3;          // Bottom left / above
assign fb_w  = horz ? 12'd512 : 12'd256;
assign fb_h  = vert ? 12'd448 : 12'd224;
// picture aspect for the scaler (Original): two 4:3 screens side by side 8:3, stacked 4:6
assign ar_x  = horz ? 12'd8 : 12'd4;
assign ar_y  = vert ? 12'd6 : 12'd3;
wire  [7:0] xoff_w [2];                        // per screen {0 top, 1 bottom}: x offset in 64-bit words, y offset in rows
wire  [8:0] yoff   [2];
assign xoff_w[0] = (horz &&  bot_1st) ? 8'd128 : 8'd0;   assign yoff[0] = (vert &&  bot_1st) ? 9'd224 : 9'd0;
assign xoff_w[1] = (horz && !bot_1st) ? 8'd128 : 8'd0;   assign yoff[1] = (vert && !bot_1st) ? 9'd224 : 9'd0;

/////////////////////////////  Native stream  /////////////////////////////

wire nat_h = horz;
wire nat_v = vert;
assign nat31 = nat_v;
wire scr_1st = bot_1st;                        // screen index (0 top, 1 bottom) shown left / above

// board raster: lc = clock within the board line (8 per pixel period, 2560 per line), bl = board line (0-261)
logic [11:0] lc = 12'd0;
logic  [8:0] bl = 9'd0;
logic        hb_d = 1'b1, vb_d = 1'b1, hs_d = 1'b0, vs_d = 1'b0;
logic [11:0] hs_lc = 12'd2200;                 // lc of the board's HSync start (includes H Position)
logic  [8:0] vs_bl = 9'd244;                   // board line of the VSync start (includes V Position)
always_ff @(posedge clk) begin
    hb_d <= hblank_in; vb_d <= vblank_in; hs_d <= hs_in; vs_d <= vs_in;
    lc <= (lc == 12'd2559) ? 12'd0 : lc + 12'd1;
    if (lc == 12'd2559) bl <= (bl == 9'd261) ? 9'd0 : bl + 9'd1;
    if (!hblank_in && hb_d) lc <= 12'd25;                  // period 3 starts the visible line: lc 24 now
    if (!vblank_in && vb_d) bl <= 9'd16;                   // first visible line (vblank falls at its lc 0)
    if (hs_in && !hs_d) hs_lc <= lc;
    if (vs_in && !vs_d) vs_bl <= bl;
end

// next 4-clock period (both native modes run at 10.08 MHz): its index in the board line and the board line
wire  [9:0] lp  = lc[11:2];
wire  [9:0] np  = (lp == 10'd639) ? 10'd0 : lp + 10'd1;
wire  [8:0] nbl = (lp == 10'd639) ? ((bl == 9'd261) ? 9'd0 : bl + 9'd1) : bl;

// Horz.: line nbl shows captured line nbl - 17; x2 = 0-511 across the original window (periods 6-517)
wire        h_vis_l = nbl >= 9'd17 && nbl <= 9'd240;
wire  [8:0] h_t     = nbl - 9'd17;
wire  [9:0] h_x2    = np - 10'd6;
wire        h_vis   = h_vis_l && np >= 10'd6 && np <= 10'd517;
wire        h_scr   = h_x2[8] ? ~scr_1st : scr_1st;
wire        h_hs    = {1'b0, np, 2'b00} >= {1'b0, hs_lc} && {1'b0, np, 2'b00} < {1'b0, hs_lc} + 13'd192;
wire        h_vs    = nbl >= vs_bl + 9'd1 && nbl < vs_bl + 9'd4;

// Vert.: out-line m (0-523), period opv (0-319) in it; rr = line within the output frame (visible 0-447)
wire        v_half  = np >= 10'd320;
wire  [8:0] v_opv   = v_half ? 9'(np - 10'd320) : np[8:0];
wire  [9:0] v_m     = {nbl, v_half};
wire  [9:0] v_rr    = (v_m >= 10'd258) ? v_m - 10'd258 : v_m + 10'd266;
wire        v_vis   = v_rr < 10'd448 && v_opv >= 9'd3 && v_opv <= 9'd258;
wire        v_hs    = {v_opv, 3'b000} >= hs_lc && {v_opv, 3'b000} < hs_lc + 12'd192;   // board HSync at 2x
wire  [9:0] v_vsm   = {vs_bl, 1'b0} - 10'd32;              // 448 + 2 x (VSync line - 240)
wire        v_vs    = v_rr >= v_vsm && v_rr < v_vsm + 10'd6;

// current out-line (Vert.): line map lookup at its start, slot freed after its last pixel
wire        c_half  = lc >= 12'd1280;
wire [10:0] c_olc   = c_half ? 11'(lc - 12'd1280) : lc[10:0];
wire  [9:0] c_m     = {bl, c_half};
wire  [9:0] c_rr    = (c_m >= 10'd258) ? c_m - 10'd258 : c_m + 10'd266;
wire        c_sord  = c_rr >= 10'd224;
wire  [7:0] c_t     = 8'(c_sord ? c_rr - 10'd224 : c_rr);
wire        c_scr   = c_sord ? ~scr_1st : scr_1st;

// line store: 256 slots x 256 pixels x 12 bits (4-bit guns, as the board's PROMs give them)
localparam [7:0] NS = 8'd232;
logic [15:0] ls_wa, ls_ra;
logic [11:0] ls_wd, lsb_d;
logic        ls_we = 1'b0, lsb_pend = 1'b0;
logic  [7:0] lsb_slot;
wire  [11:0] ls_q;
dpram_dc #(.widthad_a(16), .width_a(12)) linestore
(
    .clock_a(clk), .address_a(ls_wa), .data_a(ls_wd), .wren_a(ls_we), .q_a(),
    .clock_b(clk), .address_b(ls_ra), .data_b(12'd0), .wren_b(1'b0), .q_b(ls_q)
);

// Vert. pool: free list (FIFO of slots) and map[{screen, line}] = {valid, slot}
logic  [7:0] fl_head = 8'd0, fl_tail = 8'd0, fl_wa, fl_wd;
logic        fl_we;
wire   [7:0] fl_q;
dpram_dc #(.widthad_a(8), .width_a(8)) freelist
(
    .clock_a(clk), .address_a(fl_wa), .data_a(fl_wd), .wren_a(fl_we), .q_a(),
    .clock_b(clk), .address_b(fl_head), .data_b(8'd0), .wren_b(1'b0), .q_b(fl_q)
);
logic  [8:0] mp_wa, mp_wd, mp_ra;
logic        mp_we;
wire   [8:0] mp_q;
dpram_dc #(.widthad_a(9), .width_a(9)) linemap
(
    .clock_a(clk), .address_a(mp_wa), .data_a(mp_wd), .wren_a(mp_we), .q_a(),
    .clock_b(clk), .address_b(mp_ra), .data_b(9'd0), .wren_b(1'b0), .q_b(mp_q)
);

logic        ini = 1'b1;                       // pool (re)initialisation (also at power-up): free list = 0..NS-1, map all invalid
logic  [9:0] ini_c = 10'd0;
logic  [2:0] lay_q = 3'd0;
logic        cap_ok_t = 1'b0, cap_ok_b = 1'b0; // Vert.: this board line has its top / bottom slot
logic  [7:0] v_slot_t, v_slot_b, rd_slot;
logic        rd_valid = 1'b0;
wire   [7:0] fl_cnt = fl_tail - fl_head;
wire   [8:0] cap_t  = bl - 9'd16;
wire         cap_line = bl >= 9'd16 && bl <= 9'd239;

always_ff @(posedge clk) begin
    fl_we <= 1'b0;
    mp_we <= 1'b0;
    lay_q <= layout;
    if (layout != lay_q && (layout == 3'd0 || layout == 3'd3)) begin ini <= 1'b1; ini_c <= 10'd0; end
    if (ini) begin
        ini_c <= ini_c + 10'd1;
        if (ini_c < {2'd0, NS}) begin fl_we <= 1'b1; fl_wa <= ini_c[7:0]; fl_wd <= ini_c[7:0]; end
        mp_we <= 1'b1; mp_wa <= ini_c[8:0]; mp_wd <= 9'd0;
        if (ini_c == 10'd511) begin ini <= 1'b0; fl_head <= 8'd0; fl_tail <= NS; cap_ok_t <= 1'b0; cap_ok_b <= 1'b0; rd_valid <= 1'b0; end
    end else if (nat_v) begin
        // the two slots of a visible board line, before its first pixel (lc 27): a line that still holds a slot
        // (never shown, e.g. the raster resyncing at start-up) keeps it, so no slot can leak; else one from the free list
        if (lc == 12'd8 && cap_line) mp_ra <= {1'b0, cap_t[7:0]};
        if (lc == 12'd10 && cap_line) begin
            if (mp_q[8])                    begin v_slot_t <= mp_q[7:0]; cap_ok_t <= 1'b1; end
            else if (fl_cnt != 8'd0)        begin v_slot_t <= fl_q; fl_head <= fl_head + 8'd1; cap_ok_t <= 1'b1; end
            else                                  cap_ok_t <= 1'b0;
            mp_ra <= {1'b1, cap_t[7:0]};
        end
        if (lc == 12'd12 && cap_line) begin
            if (mp_q[8])                    begin v_slot_b <= mp_q[7:0]; cap_ok_b <= 1'b1; end
            else if (fl_cnt != 8'd0)        begin v_slot_b <= fl_q; fl_head <= fl_head + 8'd1; cap_ok_b <= 1'b1; end
            else                                  cap_ok_b <= 1'b0;
        end
        if (lc == 12'd13 && cap_line) begin mp_we <= 1'b1; mp_wa <= {1'b0, cap_t[7:0]}; mp_wd <= {cap_ok_t, v_slot_t}; end
        if (lc == 12'd14 && cap_line) begin mp_we <= 1'b1; mp_wa <= {1'b1, cap_t[7:0]}; mp_wd <= {cap_ok_b, v_slot_b}; end
        // out-line start: look up its slot; after its last pixel: give the slot back
        if (c_olc == 11'd0) mp_ra <= {c_scr, c_t};
        if (c_olc == 11'd2) begin rd_slot <= mp_q[7:0]; rd_valid <= mp_q[8] && c_rr < 10'd448; end
        if (c_olc == 11'd1040 && rd_valid) begin
            fl_we <= 1'b1; fl_wa <= fl_tail; fl_wd <= rd_slot; fl_tail <= fl_tail + 8'd1;
            mp_we <= 1'b1; mp_wa <= {c_scr, c_t}; mp_wd <= 9'd0; rd_valid <= 1'b0;
        end
    end
end

`ifdef VERILATOR
// pool margin: the fewest free slots each frame (reported when under 4; a 0 means a line was dropped)
logic [7:0] fl_min = 8'd255;
always_ff @(posedge clk) if (nat_v && !ini) begin
    if (fl_cnt < fl_min) fl_min <= fl_cnt;
    if (!vblank_in && vb_d) begin
        if (fl_min < 8'd4) $display("punchout_layout: pool low, %0d free slots this frame", fl_min);
        fl_min <= 8'd255;
    end
end
`endif

// native output registers (Horz. / Vert.): the line-store address one clock before the RAM latches it, the
// outputs for the next 4-clock period at its last clock
logic        n_vis_a = 1'b0;
logic        n_hb = 1'b1, n_vb = 1'b1, n_hs = 1'b0, n_vs = 1'b0;
logic [23:0] n_rgb = 24'd0;
always_ff @(posedge clk) begin
    if (lc[1:0] == 2'd1) begin
        if (nat_v) begin
            ls_ra <= {rd_slot, 8'(v_opv - 9'd3)}; n_vis_a <= v_vis && rd_valid;
        end else begin
            ls_ra <= {6'd0, h_t[0], h_scr, h_x2[7:0]}; n_vis_a <= h_vis;
        end
    end
    if (lc[1:0] == 2'd3) begin
        n_rgb <= n_vis_a ? {ls_q[11:8], ls_q[11:8], ls_q[7:4], ls_q[7:4], ls_q[3:0], ls_q[3:0]} : 24'd0;
        n_hb  <= nat_v ? !(v_opv >= 9'd3 && v_opv <= 9'd258) : !(np >= 10'd6 && np <= 10'd517);
        n_vb  <= nat_v ? !(v_rr < 10'd448) : !h_vis_l;
        n_hs  <= nat_v ? v_hs : h_hs;
        n_vs  <= nat_v ? v_vs : h_vs;
    end
end

wire nat_2x = nat_h || nat_v;
assign ce_out     = nat_2x ? lc[1:0] == 2'd1 : ce_pix;
assign hs_out     = nat_2x ? n_hs : hs_in;
assign vs_out     = nat_2x ? n_vs : vs_in;
assign hblank_out = nat_2x ? n_hb : hblank_in;
assign vblank_out = nat_2x ? n_vb : vblank_in;
assign rgb_out    = nat_2x ? n_rgb : nat_top ? top_rgb : bot_rgb;

/////////////////////////////  Line capture  /////////////////////////////

logic  [7:0] cx = 8'd0;                        // pixel within the visible line
logic  [8:0] cy = 9'd0;                        // visible line
logic        cpp = 1'b0;                       // line buffer being filled
logic        old_hb = 1'b1, old_vb = 1'b1;
logic [31:0] ev_top, ev_bot;                   // even pixel of the pair
logic        wa_we = 1'b0, wb_pend = 1'b0;
logic  [8:0] wa_a;                             // {pp, screen, word}
logic [63:0] wa_d, wb_d;
logic        line_req = 1'b0;                  // a captured line waits for the writer
logic        req_pp;
logic  [8:0] req_y;

// framebuffer pixels {0, B, G, R}, dimmed with the native stream during a long pause
wire  [23:0] top_dm = dim ? {1'b0, top_rgb[23:17], 1'b0, top_rgb[15:9], 1'b0, top_rgb[7:1]} : top_rgb;
wire  [23:0] bot_dm = dim ? {1'b0, bot_rgb[23:17], 1'b0, bot_rgb[15:9], 1'b0, bot_rgb[7:1]} : bot_rgb;
wire  [31:0] top_px = {8'd0, top_dm[7:0], top_dm[15:8], top_dm[23:16]};
wire  [31:0] bot_px = {8'd0, bot_dm[7:0], bot_dm[15:8], bot_dm[23:16]};
// line store slots of the line being captured: Horz. ping-pong {line[0], screen}, Vert. the pool's two slots
wire   [7:0] cap_st = nat_v ? v_slot_t : {6'd0, cy[0], 1'b0};
wire   [7:0] cap_sb = nat_v ? v_slot_b : {6'd0, cy[0], 1'b1};
wire         cap_en_t = nat_h || (nat_v && cap_ok_t);
wire         cap_en_b = nat_h || (nat_v && cap_ok_b);

logic        w_take;                           // the writer takes line_req this clock

always_ff @(posedge clk) begin
    wa_we <= 1'b0;
    ls_we <= 1'b0;
    if (lsb_pend) begin                        // the bottom pixel, one clock after the top pixel
        lsb_pend <= 1'b0; ls_we <= 1'b1; ls_wa <= {lsb_slot, ls_wa[7:0]}; ls_wd <= lsb_d;
    end
    if (wb_pend) begin                         // the bottom word of a pair, one clock after the top word
        wb_pend <= 1'b0; wa_we <= 1'b1; wa_a <= {wa_a[8], 1'b1, wa_a[6:0]}; wa_d <= wb_d;
    end
    if (w_take) line_req <= 1'b0;
    if (ce_pix) begin
        old_hb <= hblank_in;
        old_vb <= vblank_in;
        if (!hblank_in && !vblank_in) begin
            cx <= cx + 8'd1;
            if (cap_en_t) begin ls_we <= 1'b1; ls_wa <= {cap_st, cx}; ls_wd <= {top_rgb[23:20], top_rgb[15:12], top_rgb[7:4]}; end
            if (cap_en_b) begin
                lsb_d <= {bot_rgb[23:20], bot_rgb[15:12], bot_rgb[7:4]}; lsb_slot <= cap_sb; lsb_pend <= 1'b1;
                if (!cap_en_t) ls_wa <= {cap_st, cx};      // lsb_pend takes the pixel index from ls_wa[7:0]
            end
            if (!cx[0]) begin ev_top <= top_px; ev_bot <= bot_px; end
            else begin
                wa_we <= 1'b1; wa_a <= {cpp, 1'b0, cx[7:1]}; wa_d <= {top_px, ev_top};
                wb_d <= {bot_px, ev_bot}; wb_pend <= 1'b1;
            end
        end
        if (hblank_in && !old_hb && !vblank_in) begin      // line done
            line_req <= 1'b1; req_pp <= cpp; req_y <= cy;
            cpp <= ~cpp; cy <= cy + 9'd1; cx <= 8'd0;
        end
        if (!vblank_in && old_vb) begin cy <= 9'd0; cx <= 8'd0; end
    end
end

wire [63:0] lb_q;
logic [8:0] lb_ra;
dpram_dc #(.widthad_a(9), .width_a(64)) linebuf
(
    .clock_a(clk), .address_a(wa_a), .data_a(wa_d), .wren_a(wa_we), .q_a(),
    .clock_b(clk), .address_b(lb_ra), .data_b(64'd0), .wren_b(1'b0), .q_b(lb_q)
);

/////////////////////////////  Framebuffer writer  /////////////////////////////

localparam W_IDLE = 3'd0, W_ADDR = 3'd1, W_PRIME = 3'd2, W_DATA = 3'd3, W_NEXT = 3'd4;
logic  [2:0] wst = W_IDLE;
logic        wpp, wscr, wchunk;
logic  [8:0] wy;
logic  [5:0] ebeat = 6'd0;
logic [28:0] eaddr;
logic  [1:0] i_fb = 2'd0, o_fb = 2'd1, l_fb = 2'd2;
logic        fresh = 1'b0, vbl_pend = 1'b0, old_fbvbl = 1'b0;
logic  [1:0] fb_ready = 2'd0;                   // frames finished since the framebuffer layout last changed
logic  [2:0] last_layout = 3'd0;
// last write of a frame: line 223's last burst of its last screen (every layout captures 224 lines per screen)
wire         frame_done = wst == W_NEXT && wchunk && !(!wscr && en_bot) && wy == 9'd223;

wire         w_acc  = wst == W_DATA && !DDRAM_BUSY;
wire  [5:0]  wb_nxt = w_acc ? ebeat + 6'd1 : (wst == W_DATA ? ebeat : 6'd0);
assign lb_ra  = {wpp, wscr, wchunk, wb_nxt};
assign w_take = wst == W_IDLE && line_req && fb_on;

assign DDRAM_CLK      = clk;
assign DDRAM_BURSTCNT = 8'd64;
assign DDRAM_ADDR     = eaddr;
assign DDRAM_RD       = 1'b0;
assign DDRAM_DIN      = lb_q;
assign DDRAM_BE       = 8'hFF;
assign DDRAM_WE       = wst == W_DATA;

assign fb_base = {6'b001100, 2'b11, 24'd0} + {6'd0, o_fb, 24'd0};   // 33000000 + n * 01000000
assign fb_en   = fb_on && fb_ready == 2'd3;

always_ff @(posedge clk) begin
    case (wst)
        W_IDLE:
            if (w_take) begin
                wpp <= req_pp; wy <= req_y; wchunk <= 1'b0;
                wscr <= !en_top;                               // first screen this layout writes
                wst <= W_ADDR;
            end
        W_ADDR: begin
            eaddr <= FB0_W + {6'd0, i_fb, 21'd0} + {12'd0, 9'(wy + yoff[wscr]), 8'd0} + {21'd0, xoff_w[wscr]}
                   + {22'd0, wchunk, 6'd0};
            ebeat <= 6'd0; wst <= W_PRIME;
        end
        W_PRIME: wst <= W_DATA;
        W_DATA:
            if (!DDRAM_BUSY) begin
                ebeat <= ebeat + 6'd1;
                if (ebeat == 6'd63) wst <= W_NEXT;
            end
        W_NEXT:
            if (!wchunk) begin wchunk <= 1'b1; wst <= W_ADDR; end
            else if (!wscr && en_bot) begin wscr <= 1'b1; wchunk <= 1'b0; wst <= W_ADDR; end
            else wst <= W_IDLE;
        default: wst <= W_IDLE;
    endcase

    // triple buffering (artwork.sv): o_fb takes the newest finished buffer at the scaler's vblank
    old_fbvbl <= fb_vbl;
    if (fb_vbl && !old_fbvbl) vbl_pend <= 1'b1;
    if (frame_done) begin
        l_fb <= i_fb; i_fb <= 2'd3 - i_fb - o_fb; fresh <= 1'b1;
        if (fb_ready != 2'd3) fb_ready <= fb_ready + 2'd1;
    end else if (vbl_pend) begin
        vbl_pend <= 1'b0;
        if (fresh) begin o_fb <= l_fb; fresh <= 1'b0; end
    end

    last_layout <= layout;
    if (layout != last_layout || !fb_on) fb_ready <= 2'd0;
end

endmodule
