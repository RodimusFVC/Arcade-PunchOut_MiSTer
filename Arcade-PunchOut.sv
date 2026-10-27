//============================================================================
//
//  PunchOut: Nintendo Punch-Out!! / Super Punch-Out!! / Arm Wrestling hardware (CHP1 boards) for MiSTer
//  Copyright (C) 2026 Rodimus
//
//  Top level carried over from the Rodimus Nintendo / Irem1 cores (Pac-Man core lineage, MikeJ / Sorgelig).
//  Board: rtl/punchout_board.sv (pools) + rtl/boards/chp1/ (CPU board, VIDEO / BAK boards). Bring-up 2026-10-27:
//  Punch-Out!! (variant 0); battery RAM saved on index 4 (no hiscore module: the game keeps its own table).
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//
//============================================================================

module emu
(
    `include "sys/emu_ports.vh"
);

wire        CLK_SYS;
wire        locked;
wire [127:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire [10:0] ps2_key;
wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_din;
wire        ioctl_wr;
wire  [7:0] ioctl_index;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] joystick_0, joystick_1;
wire [15:0] joystick_r_analog_0, joystick_r_analog_1;   // right analog sticks: [15:8] Y, [7:0] X, signed
wire [21:0] gamma_bus;
wire        direct_video;
wire        video_rotated;
wire        pause_cpu;
wire        hblank, vblank;

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign FB_FORCE_BLANK = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire signed [15:0] audio;
assign AUDIO_L = pause_cpu ? 16'd0 : audio;
assign AUDIO_R = pause_cpu ? 16'd0 : audio;
assign AUDIO_S = 1;   // signed
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS = 0;

///////////////////////////////////////////////////

// MRA index 1 (tools/gen_mra.py):
//   byte 0       board variant (see rtl/punchout_board.sv)
//   byte 1       flags: [0] 4-way joystick, [2] coins are 2-frame pulses, [4] vertical, [7] vertical is ROT90
//   byte 2       CPU ROM decode (none in punchout.cpp, always 0)
//   byte 3       board flags (none yet)
//   bytes 4-9    idle level of every bit of the 6 ports (IN0, IN1, DSW2, DSW1, 2 spare)
//   bytes 10-15  per port: DIP switch byte that supplies it (bit 7 set = none, use the idle byte)
//   bytes 16-63  input map, one byte per port bit (bit 0 first): control id, 0 = none; a pressed control inverts its bit
//   bytes 64-111 ROM region table, 8 slots x {base, start, len} (u16 LE, 256-byte units)
//   byte 112     ROMREGION_INVERT slot mask (the board inverts those regions on read; never at load)
//   bytes 128-383 ROM page map: slot n at 128 + 32n, store page (8K) of region page k, FF = empty socket
//               (rtl/punchout_board.sv, Shared ROM blocks)
// Only DIP ports go in the MRA switch bytes: Main_MiSTer builds the default as int shifts, so a byte >= 0x80 at
// position 3 sign-extends over bytes 4-7, and bytes 4+ are shifted by 32+ (mra_loader.cpp: binary[i] << (i * 8))
// ioctl: 0 ROMs, 1 config, 3 hiscore config (reserved fleet-wide, unused: NVRAM game), 4 battery RAM (MRA
// <nvram index="4" size="1024">), 254 DIPs; 5 = reserved for MAME artwork (not wired: dual-screen artwork is an open
// question), 2 / 6+ free.
reg [7:0] game_var    = 8'd0;
reg [7:0] game_flags  = 8'h00;
reg [7:0] game_flags2 = 8'd0;
reg [5:0] in_map[48];
reg [7:0] port_idle[6] = '{8'hFF,8'hFF,8'hFF,8'hFF,8'hFF,8'hFF};
reg [7:0] port_dip[6]  = '{8'h80,8'h80,8'h80,8'h80,8'h80,8'h80};
reg [47:0][7:0] rom_rgn = '0;
reg [7:0] rom_inv = 8'd0;
reg [255:0][7:0] rom_page = '1;
wire [5:0] map_idx  = ioctl_addr[5:0] - 6'd16;
wire [2:0] idle_idx = ioctl_addr[2:0] - 3'd4;      // bytes 4-9  -> 0-5
wire [3:0] dip_idx4 = ioctl_addr[3:0] - 4'd10;     // bytes 10-15 -> 0-5
wire [2:0] dip_idx  = dip_idx4[2:0];
wire [5:0] rgn_idx  = ioctl_addr[5:0];             // bytes 64-111 -> 0-47

always @(posedge CLK_SYS) begin
    if (ioctl_wr && ioctl_index == 8'd1) begin
        if (ioctl_addr == 25'd0) game_var   <= ioctl_dout;
        if (ioctl_addr == 25'd1) game_flags  <= ioctl_dout;
        if (ioctl_addr == 25'd3) game_flags2 <= ioctl_dout;
        if (ioctl_addr >= 25'd4  && ioctl_addr < 25'd10) port_idle[idle_idx] <= ioctl_dout;
        if (ioctl_addr >= 25'd10 && ioctl_addr < 25'd16) port_dip[dip_idx]   <= ioctl_dout;
        if (ioctl_addr >= 25'd16 && ioctl_addr < 25'd64) in_map[map_idx] <= ioctl_dout[5:0];
        if (ioctl_addr >= 25'd64 && ioctl_addr < 25'd112) rom_rgn[rgn_idx] <= ioctl_dout;
        if (ioctl_addr == 25'd112) rom_inv <= ioctl_dout;
        if (ioctl_addr >= 25'd128 && ioctl_addr < 25'd384) rom_page[ioctl_addr[7:0] - 8'd128] <= ioctl_dout;
    end
end

wire game_vert = game_flags[4];
wire vert_view = game_vert & ~status[12];

wire [1:0] ar = status[9:8];

// LAYOUT-STEP2-2026-10-27: Original = the layout's picture aspect while its framebuffer is shown; original:
// assign VIDEO_ARX = (!ar) ? (vert_view ? 12'd3 : 12'd4) : (ar - 1'd1);
// assign VIDEO_ARY = (!ar) ? (vert_view ? 12'd4 : 12'd3) : 12'd0;
wire        lay_fb_en;
wire [11:0] lay_ar_x, lay_ar_y;
assign VIDEO_ARX = (!ar) ? (lay_fb_en ? lay_ar_x : vert_view ? 12'd3 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (lay_fb_en ? lay_ar_y : vert_view ? 12'd4 : 12'd3) : 12'd0;

// MAME artwork: not wired (both MAME layouts, punchout.zip / armwrest.zip, are two-screen views; artwork.sv
// composites one screen). When it is: artwork #(.IDX(8'd5)), art_avail -> H1, ioctl_wait(art_wait), 27-bit
// ioctl address, FB / DDRAM muxed with screen_rotate (Irem1's Arcade-Irem1.sv is the wiring reference).
wire art_avail = 1'b0;

// Status bits: as the Nintendo / Irem1 cores, except ONE Flip Screen (fleet convention 2026-10-25) at the CRT Flip
// bit 22: it drives the board's own 180-degree mirror (both outputs); the old HDMI Flip bit 11 is left unused.
`include "build_id.v"
localparam CONF_STR = {
	"PUNCHOUT;;",
	"P1,Video Options;",
	"P1O89,Aspect Ratio,Original,Full screen,[ARC1],[ARC2];",
	"P1OC,Orientation,Vert,Horz;",
	"P1OM,Flip Screen,Off,On;",
	"P1O[40:37],H Position (CRT),0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P1O[44:41],V Position (CRT),0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P1OGI,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	// DISPLAY-TEMP-2026-10-27: bring-up only, until the two-screen presentation is designed
	// LAYOUT-STEP1-2026-10-27: replaced by Game Options "Screen Layout" (rtl/punchout_layout.sv); original:
	// "P1OS,Screen (bring-up),Bottom,Top;",
	"-;",
	// LAYOUT-STEP1-2026-10-27: Game Options shown (was "H1P2,Game Options;" / "H1-;", hidden until artwork)
	"P2,Game Options;",
	"P2O[47:45],Screen Layout,Vert. Top/Bottom,Horz. Top|Bottom,Horz. Bottom|Top,Vert. Bottom/Top,Single Top,Single Bottom,Split Top>HDMI,Split Top>CRT;",
	"P2O[62:59],Speech Volume,Default,+1,+2,+3,+4,+5,+6,+7,Off,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[66:63],Music Volume,Default,+1,+2,+3,+4,+5,+6,+7,Off,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"P3,Pause Options;",
	"P3OJ,Pause when OSD is open,On,Off;",
	"P3OK,Dim video after 10s,On,Off;",
	"-;",
	// NVRAM-2026-10-27: battery RAM game, no hiscore module (Gottlieb's item); originals below
	// "P4,High Score Options;",
	// "P4OL,Autosave Hiscores,Off,On;",
	"OR,Autosave NVRAM,On,Off;",
	"-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Btn 1,Btn 2,Btn 3,Btn 4,Coin,Start 1P,Start 2P,Pause,Btn 5,Btn 6,Rack Test;",
	"jn,A,B,X,Y,Select,Start,R,L;",
	"V,v",`BUILD_DATE
};

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(CLK_SYS),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	// H1 = Game Options page (header + trailing "-;"): NOR of every item's show condition; today only the artwork
	// items would live there, so the page is hidden until art_avail exists
	.status_menumask({~art_avail, direct_video}),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),
	.ioctl_wait(1'b0),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_r_analog_0(joystick_r_analog_0),
	.joystick_r_analog_1(joystick_r_analog_1),
	.ps2_key(ps2_key)
);

////////////////////   CLOCKS   ///////////////////

// pll: CLK_SYS = 40.32 MHz = 2 x the 20.16 MHz video xtal (CLK-2026-10-27, rtl/pll/pll_0002.v): 8 clocks per
// 5.04 MHz pixel; Z80 4 MHz and RP2A03 1.789773 MHz enables are exact fractions (rtl/boards/chp1/chp1_board.sv).
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(CLK_SYS),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(locked)
);

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;
wire        cfg_waitrequest;

pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(0),
	.mgmt_address(0),
	.mgmt_writedata(0),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

// Hold the board in reset until the PLL is locked and the ROM download has finished
wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~locked;

///////////////////         Controls           //////////////////

// kb: [0] up [1] down [2] left [3] right [4] Btn 1 (Ctrl) [5] Btn 2 (Alt) [6] Start 1 [7] Start 2 [8] Coin 1 [9] Coin 2 [10] Service [11] Tilt [12] Pause
wire [12:0] kb;
/* verilator lint_off PINCONNECTEMPTY */
ctl_keyboard keyboard(.clk(CLK_SYS), .ps2_key(ps2_key), .pause(pause_cpu), .kb(kb), .kbx());
/* verilator lint_on PINCONNECTEMPTY */

// Joystick bits: 0 R, 1 L, 2 D, 3 U, 4-7 Btn 1-4, 8 Coin, 9 Start 1P, 10 Start 2P, 11 Pause, 12-13 Btn 5-6, 14 Rack Test (unmapped)
wire [3:0] dir1_raw = {joystick_0[3] | kb[0], joystick_0[2] | kb[1], joystick_0[1] | kb[2], joystick_0[0] | kb[3]};
wire [3:0] dir2_raw = joystick_1[3:0];
wire [3:0] dir1, dir2;   // {U, D, L, R}
ctl_joy4way joy4way_1(.clk(CLK_SYS), .en(game_flags[0]), .in(dir1_raw), .out(dir1));
ctl_joy4way joy4way_2(.clk(CLK_SYS), .en(game_flags[0]), .in(dir2_raw), .out(dir2));

wire m_pause = joystick_0[11] | kb[12];

wire coin1, coin2;
ctl_coin_impulse #(.PAUSE_MODE(1)) coin_imp1(.clk(CLK_SYS), .pause(pause_cpu), .vblank(vblank), .en(game_flags[2]),
                           .coin_raw(joystick_0[8] | kb[8]), .coin(coin1));
ctl_coin_impulse #(.PAUSE_MODE(1)) coin_imp2(.clk(CLK_SYS), .pause(pause_cpu), .vblank(vblank), .en(game_flags[2]),
                           .coin_raw(joystick_1[8] | kb[9]), .coin(coin2));

wire rack_btn = joystick_0[14] | joystick_1[14];
wire rack_tog;
ctl_toggle rack_toggle(.clk(CLK_SYS), .clear(ioctl_download), .btn(rack_btn), .pause(pause_cpu), .q(rack_tog));

wire [3:0] rstick0, rstick1;   // {U, D, L, R}
ctl_stick_dirs #(.MODE(0), .THRESH(7'd48)) rstick_0(.stick(joystick_r_analog_0), .dir(rstick0));
ctl_stick_dirs #(.MODE(0), .THRESH(7'd48)) rstick_1(.stick(joystick_r_analog_1), .dir(rstick1));

// control ids 0-35 = ctl_ids (pad 2's Start = Start 2P only; pads never linked), 36-45 core-local (Irem1 numbering),
// 46 core-local: P1 Btn 1 or Start 1P (Punch-Out reads only IN0 bits 0-3, so "PRESS START" = a punch; user
// 2026-10-27: Start also throws L Blow, so pads don't look broken). Same pad only.
wire [35:0] ctl36;
// BTNSWAP-2026-10-27: pad A / B swapped (bits 4 / 5) so B, the left face button, throws the Left Blow and A the
// Right Blow (user, on HW); MRA / CONF_STR mapping unchanged. Original:
// ctl_ids ids(.joy0(joystick_0), .joy1(joystick_1), .kb(kb), .dir1(dir1), .dir2(dir2),
//             .coin1(coin1), .coin2(coin2), .coin3(1'b0), .ctl(ctl36));
wire [15:0] joy0_ab = {joystick_0[15:6], joystick_0[4], joystick_0[5], joystick_0[3:0]};
wire [15:0] joy1_ab = {joystick_1[15:6], joystick_1[4], joystick_1[5], joystick_1[3:0]};
ctl_ids ids(.joy0(joy0_ab), .joy1(joy1_ab), .kb(kb), .dir1(dir1), .dir2(dir2),
            .coin1(coin1), .coin2(coin2), .coin3(1'b0), .ctl(ctl36));
wire [63:0] ctl =
{
	17'd0,
	ctl36[5] | ctl36[19],                           // 46 P1 Btn 1 or Start 1P
	joystick_1[13] | rstick1[3],                    // 45 P2 R Up    (Btn 6)
	joystick_1[12] | rstick1[2],                    // 44 P2 R Down  (Btn 5)
	joystick_1[7]  | rstick1[1],                    // 43 P2 R Left  (Btn 4)
	joystick_1[6]  | rstick1[0],                    // 42 P2 R Right (Btn 3)
	joystick_0[13] | rstick0[3],                    // 41 P1 R Up    (Btn 6)
	joystick_0[12] | rstick0[2],                    // 40 P1 R Down  (Btn 5)
	joystick_0[7]  | rstick0[1],                    // 39 P1 R Left  (Btn 4)
	joystick_0[6]  | rstick0[0],                    // 38 P1 R Right (Btn 3)
	rack_tog,                                       // 37 rack test (toggle)
	rack_btn,                                       // 36 rack test (held)
	ctl36                                           // 35-0 shared ids
};

// DIP switches arrive from the OSD via ioctl index 254
reg [7:0] dip_sw[8] = '{8'hFF,8'hFF,8'hFF,8'hFF,8'h00,8'h00,8'h00,8'h00};
always @(posedge CLK_SYS) begin
	if (ioctl_wr && (ioctl_index == 8'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end

wire [7:0]   in_port[6];
wire [47:0]  port_idle_flat, port_sel_flat, in_ports;
wire [63:0]  dip_bytes_flat;
wire [383:0] in_map_flat;
genvar gi;
generate
	for (gi = 0; gi < 6; gi = gi + 1) begin : g_port
		assign port_idle_flat[gi*8 +: 8] = port_idle[gi];
		assign port_sel_flat[gi*8 +: 8]  = port_dip[gi];   // [7] = 1: idle byte, else DIP byte [2:0]
		assign in_port[gi] = in_ports[gi*8 +: 8];
	end
	for (gi = 0; gi < 8; gi = gi + 1) begin : g_dip
		assign dip_bytes_flat[gi*8 +: 8] = dip_sw[gi];
	end
	for (gi = 0; gi < 48; gi = gi + 1) begin : g_map
		assign in_map_flat[gi*8 +: 8] = {2'b00, in_map[gi]};
	end
endgenerate
ctl_port_map #(.NP(6), .IDW(6), .BASE_MODE(1)) port_map
(
	.clk(CLK_SYS), .idle(port_idle_flat), .in_map(in_map_flat), .dips(32'd0), .port_sel(port_sel_flat),
	.dip_bytes(dip_bytes_flat), .dip_bit(144'd0), .ctl(ctl), .ovr_mask(48'd0), .ovr_val(48'd0), .ports(in_ports)
);

// PAUSE SYSTEM (CLKSPD = the real CLK_SYS in MHz, for the 10 s dim timer)
wire [23:0] rgb_out;
// pause #(8,8,8,49) pause      // CLK-2026-10-27: original (49.152 MHz)
pause #(8,8,8,40) pause
(
	.*,
	.clk_sys(CLK_SYS),
	.user_button(m_pause),
	// .pause_request(hs_pause),   // NVRAM-2026-10-27: original (hiscore module)
	.pause_request(1'b0),
	.options(~status[20:19])
);

///////////////                 Video                  ////////////////

wire hs, vs;
wire [7:0] r, g, b;
wire ce_pix;
wire [7:0] top_r, top_g, top_b, bot_r, bot_g, bot_b;

// TWO screens, one timing chain (schematic facts). Which screen(s) reach HDMI / analog and how is an OPEN question
// (user decision after bring-up).
// DISPLAY-TEMP-2026-10-27: OSD "Screen (bring-up)" picks one monitor; original placeholder below
// assign {r, g, b} = {bot_r, bot_g, bot_b};
// LAYOUT-STEP1-2026-10-27: Game Options "Screen Layout" (rtl/punchout_layout.sv); original:
// assign {r, g, b} = status[28] ? {top_r, top_g, top_b} : {bot_r, bot_g, bot_b};
// Native stream = the CRT's picture (pause dims it); the framebuffer = HDMI's, dimmed by the layout module.
// LAYOUT-STEP3-2026-10-27: the dim moved into rtl/punchout_layout.sv (dim_video now driven: qsf PAUSE_OUTPUT_DIM);
// step 1 (dimmed copies here, never passed on) was:
// wire [23:0] top_d = dim_video ? {1'b0, top_r[7:1], 1'b0, top_g[7:1], 1'b0, top_b[7:1]} : {top_r, top_g, top_b};
// wire [23:0] bot_d = dim_video ? {1'b0, bot_r[7:1], 1'b0, bot_g[7:1], 1'b0, bot_b[7:1]} : {bot_r, bot_g, bot_b};
wire        dim_video;                 // pause: video dimmed after 10 s of pause
wire [23:0] nat_rgb;
wire        nat_ce, nat_hs, nat_vs, nat_hb, nat_vb, nat31;
wire [11:0] lay_fb_w, lay_fb_h;
wire [31:0] lay_fb_base;
wire  [7:0] lay_burstcnt, lay_be;
wire [28:0] lay_addr;
wire [63:0] lay_din;
wire        lay_clk, lay_rd, lay_we;
/* verilator lint_off PINCONNECTEMPTY */
punchout_layout layout
(
	.clk(CLK_SYS), .layout(status[47:45]), .direct_video(direct_video), .dim(dim_video),
	.ce_pix(ce_pix), .hs_in(hs), .vs_in(vs), .hblank_in(hblank), .vblank_in(vblank),
	.top_rgb({top_r, top_g, top_b}), .bot_rgb({bot_r, bot_g, bot_b}),
	// LAYOUT-STEP3-2026-10-27: native timing from the layout (Horz. 2x pixel rate, Vert. 31 kHz); step 1 was:
	// .ce_out(), .hs_out(), .vs_out(), .hblank_out(), .vblank_out(), .rgb_out(nat_rgb),   // step 1: timing unchanged
	.ce_out(nat_ce), .hs_out(nat_hs), .vs_out(nat_vs), .hblank_out(nat_hb), .vblank_out(nat_vb), .rgb_out(nat_rgb),
	.nat31(nat31),
	.fb_en(lay_fb_en), .fb_w(lay_fb_w), .fb_h(lay_fb_h), .ar_x(lay_ar_x), .ar_y(lay_ar_y), .fb_base(lay_fb_base), .fb_vbl(FB_VBL),
	.DDRAM_CLK(lay_clk), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(lay_burstcnt), .DDRAM_ADDR(lay_addr),
	.DDRAM_RD(lay_rd), .DDRAM_DIN(lay_din), .DDRAM_BE(lay_be), .DDRAM_WE(lay_we)
);
/* verilator lint_on PINCONNECTEMPTY */
assign {r, g, b} = nat_rgb;

wire rotate_ccw = ~game_flags[7];  // ROT270 sets rotate CCW, ROT90 sets CW
wire no_rotate  = ~game_vert | status[12] | direct_video;
wire flip       = 1'b0;            // Flip Screen = the board's CRT Flip mechanism (status[22]), not screen_rotate
// LAYOUT-STEP1-2026-10-27: screen_rotate's FB / DDRAM shared with the layout framebuffer (Irem1's wiring); original:
// screen_rotate screen_rotate(.*);
wire        sr_fb_en, sr_clk, sr_rd, sr_we;
wire  [4:0] sr_fb_format;
wire [11:0] sr_fb_w, sr_fb_h;
wire [31:0] sr_fb_base;
wire [13:0] sr_fb_stride;
wire  [7:0] sr_burstcnt, sr_be;
wire [28:0] sr_addr;
wire [63:0] sr_din;
screen_rotate screen_rotate
(
	.*,
	.FB_EN(sr_fb_en), .FB_FORMAT(sr_fb_format), .FB_WIDTH(sr_fb_w), .FB_HEIGHT(sr_fb_h),
	.FB_BASE(sr_fb_base), .FB_STRIDE(sr_fb_stride),
	.DDRAM_CLK(sr_clk), .DDRAM_BURSTCNT(sr_burstcnt), .DDRAM_ADDR(sr_addr), .DDRAM_DIN(sr_din),
	.DDRAM_BE(sr_be), .DDRAM_WE(sr_we), .DDRAM_RD(sr_rd)
);
// PunchOut is ROT0, so screen_rotate never takes the framebuffer: the layout owns it (and DDR3) whenever it is on
assign FB_EN     = lay_fb_en | sr_fb_en;
assign FB_FORMAT = lay_fb_en ? 5'b00110 : sr_fb_format;
assign FB_WIDTH  = lay_fb_en ? lay_fb_w : sr_fb_w;
assign FB_HEIGHT = lay_fb_en ? lay_fb_h : sr_fb_h;
assign FB_BASE   = lay_fb_en ? lay_fb_base : sr_fb_base;
assign FB_STRIDE = lay_fb_en ? 14'd2048 : sr_fb_stride;
assign DDRAM_CLK      = CLK_SYS;
assign DDRAM_BURSTCNT = sr_fb_en ? sr_burstcnt : lay_burstcnt;
assign DDRAM_ADDR     = sr_fb_en ? sr_addr : lay_addr;
assign DDRAM_DIN      = sr_fb_en ? sr_din : lay_din;
assign DDRAM_BE       = sr_fb_en ? sr_be : lay_be;
assign DDRAM_WE       = sr_fb_en ? sr_we : lay_we;
assign DDRAM_RD       = sr_fb_en ? sr_rd : lay_rd;

// LAYOUT-STEP3-2026-10-27: the layout's native stream (512-pixel Horz. lines: WIDTH 512; Vert. is already 31 kHz, so
// no scandoubler / fx there); original:
// arcade_video #(256,24) arcade_video
// (
// 	.*,
//
// 	.clk_video(CLK_SYS),
//
// 	.RGB_in(rgb_out),
// 	.HBlank(hblank),
// 	.VBlank(vblank),
// 	.HSync(hs),
// 	.VSync(vs),
//
// 	.fx(status[18:16])
// );
arcade_video #(512,24) arcade_video
(
	.*,

	.clk_video(CLK_SYS),
	.ce_pix(nat_ce),

	.RGB_in(rgb_out),
	.HBlank(nat_hb),
	.VBlank(nat_vb),
	.HSync(nat_hs),
	.VSync(nat_vs),

	.fx(nat31 ? 3'd0 : status[18:16]),
	.forced_scandoubler(forced_scandoubler & ~nat31)
);

///////////////                 Board                  ////////////////

punchout_board board
(
	.clk(CLK_SYS),
	.reset(reset),
	.pause(pause_cpu),
	.variant(game_var),
	.game_flags2(game_flags2),
	.rom_rgn(rom_rgn),
	.rom_inv(rom_inv),
	.rom_page(rom_page),
	.ce_pix(ce_pix),

	.in0(in_port[0]),
	.in1(in_port[1]),
	.dsw2(in_port[2]),
	.dsw1(in_port[3]),

	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr0(ioctl_wr & (ioctl_index == 8'd0)),

	.crt_flip(status[22]),
	.h_adj(status[40:37]),
	.v_adj(status[44:41]),

	.top_r(top_r),
	.top_g(top_g),
	.top_b(top_b),
	.bot_r(bot_r),
	.bot_g(bot_g),
	.bot_b(bot_b),
	.video_hs(hs),
	.video_vs(vs),
	.video_hblank(hblank),
	.video_vblank(vblank),

	.audio(audio),
	// LAYOUT-STEP1-2026-10-27: Game Options volumes (Exidy form: OSD value ^ 8 = gain in eighths, Default = 8)
	.vol_speech(status[62:59] ^ 4'd8),
	.vol_music(status[66:63] ^ 4'd8),

	// NVRAM (MRA <nvram index="4" size="1024">): loaded with the MRA, saved when the OSD opens / closes (Gottlieb)
	.nvs_addr(ioctl_addr[9:0]),
	.nvs_din(ioctl_dout),
	.nvs_we(ioctl_download & ioctl_wr & (ioctl_index == 8'd4)),
	.nvs_dout(ioctl_din)
);

assign ioctl_upload_req = ~status[27] & ~ioctl_download;

// NVRAM-2026-10-27: hiscore module commented out below. Punch-Out keeps its own score table in the battery RAM
// (C000-C3FF), saved whole on index 4 (user, 2026-10-27: NVRAM only, no hiscore).
// // Hiscore: config = MRA index 3, dump = index 4 (hiscore.dat: punchout D660, spnchout D5C0 = work RAM).
// wire [15:0] hs_address;
// wire  [7:0] hs_data_in;
// wire  [7:0] hs_data_out;
// wire        hs_write_enable;
// wire        hs_access_read;
// wire        hs_access_write;
// wire        hs_pause;
// wire        hs_configured;
//
// hiscore #(
// 	.HS_ADDRESSWIDTH(16),
// 	.CFG_ADDRESSWIDTH(4),
// 	.CFG_LENGTHWIDTH(2)
// ) hi (
// 	.*,
// 	.clk(CLK_SYS),
// 	.paused(pause_cpu),
// 	.autosave(status[21]),
// 	.ram_address(hs_address),
// 	.data_from_ram(hs_data_out),
// 	.data_to_ram(hs_data_in),
// 	.data_from_hps(ioctl_dout),
// 	.data_to_hps(ioctl_din),
// 	.ram_write(hs_write_enable),
// 	.ram_intent_read(hs_access_read),
// 	.ram_intent_write(hs_access_write),
// 	.pause_cpu(hs_pause),
// 	.configured(hs_configured)
// );

endmodule
