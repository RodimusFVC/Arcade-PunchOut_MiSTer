//============================================================================
//
//  PunchOut: Nintendo Punch-Out!! / Super Punch-Out!! / Arm Wrestling hardware (CHP1 boards) for MiSTer
//  Copyright (C) 2026 Rodimus
//
//  Top level carried over from the Rodimus Nintendo / Irem1 cores (Pac-Man core lineage, MikeJ / Sorgelig).
//  Board: rtl/punchout_dispatcher.sv (pools) + rtl/boards/chp1/ (CPU board, VIDEO / BAK boards). Battery RAM saved on
//  index 4 (no hiscore module: the game keeps its own table).
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
wire [15:0] joystick_r_analog_0, joystick_r_analog_1;
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
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS = 0;

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
wire [2:0] idle_idx = ioctl_addr[2:0] - 3'd4;
wire [3:0] dip_idx4 = ioctl_addr[3:0] - 4'd10;
wire [2:0] dip_idx  = dip_idx4[2:0];
wire [5:0] rgn_idx  = ioctl_addr[5:0];

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

wire        lay_fb_en;
wire [11:0] lay_ar_x, lay_ar_y;
assign VIDEO_ARX = (!ar) ? (lay_fb_en ? lay_ar_x : vert_view ? 12'd3 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (lay_fb_en ? lay_ar_y : vert_view ? 12'd4 : 12'd3) : 12'd0;

wire art_avail = 1'b0;

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
	"-;",
	"P2,Game Options;",
	"P2O[47:45],Screen Layout,Vert. Top/Bottom,Horz. Top|Bottom,Horz. Bottom|Top,Vert. Bottom/Top,Single Top,Single Bottom,Split Top>HDMI,Split Top>CRT;",
	"P2O[62:59],Speech Volume,Default,+1,+2,+3,+4,+5,+6,+7,Off,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[66:63],Music Volume,Default,+1,+2,+3,+4,+5,+6,+7,Off,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"P3,Pause Options;",
	"P3OJ,Pause when OSD is open,On,Off;",
	"P3OK,Dim video after 10s,On,Off;",
	"-;",
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

wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~locked;

wire [12:0] kb;
/* verilator lint_off PINCONNECTEMPTY */
ctl_keyboard keyboard(.clk(CLK_SYS), .ps2_key(ps2_key), .pause(pause_cpu), .kb(kb), .kbx());
/* verilator lint_on PINCONNECTEMPTY */

wire [3:0] dir1_raw = {joystick_0[3] | kb[0], joystick_0[2] | kb[1], joystick_0[1] | kb[2], joystick_0[0] | kb[3]};
wire [3:0] dir2_raw = joystick_1[3:0];
wire [3:0] dir1, dir2;
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

wire [3:0] rstick0, rstick1;
ctl_stick_dirs #(.MODE(0), .THRESH(7'd48)) rstick_0(.stick(joystick_r_analog_0), .dir(rstick0));
ctl_stick_dirs #(.MODE(0), .THRESH(7'd48)) rstick_1(.stick(joystick_r_analog_1), .dir(rstick1));

wire [35:0] ctl36;
wire [15:0] joy0_ab = {joystick_0[15:6], joystick_0[4], joystick_0[5], joystick_0[3:0]};
wire [15:0] joy1_ab = {joystick_1[15:6], joystick_1[4], joystick_1[5], joystick_1[3:0]};
ctl_ids ids(.joy0(joy0_ab), .joy1(joy1_ab), .kb(kb), .dir1(dir1), .dir2(dir2),
            .coin1(coin1), .coin2(coin2), .coin3(1'b0), .ctl(ctl36));
wire [63:0] ctl =
{
	17'd0,
	ctl36[5] | ctl36[19],
	joystick_1[13] | rstick1[3],
	joystick_1[12] | rstick1[2],
	joystick_1[7]  | rstick1[1],
	joystick_1[6]  | rstick1[0],
	joystick_0[13] | rstick0[3],
	joystick_0[12] | rstick0[2],
	joystick_0[7]  | rstick0[1],
	joystick_0[6]  | rstick0[0],
	rack_tog,
	rack_btn,
	ctl36
};

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
		assign port_sel_flat[gi*8 +: 8]  = port_dip[gi];
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

wire [23:0] rgb_out;
pause #(8,8,8,40) pause
(
	.*,
	.clk_sys(CLK_SYS),
	.user_button(m_pause),
	.pause_request(1'b0),
	.options(~status[20:19])
);

wire hs, vs;
wire [7:0] r, g, b;
wire ce_pix;
wire [7:0] top_r, top_g, top_b, bot_r, bot_g, bot_b;

wire        dim_video;
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
	.ce_out(nat_ce), .hs_out(nat_hs), .vs_out(nat_vs), .hblank_out(nat_hb), .vblank_out(nat_vb), .rgb_out(nat_rgb),
	.nat31(nat31),
	.fb_en(lay_fb_en), .fb_w(lay_fb_w), .fb_h(lay_fb_h), .ar_x(lay_ar_x), .ar_y(lay_ar_y), .fb_base(lay_fb_base), .fb_vbl(FB_VBL),
	.DDRAM_CLK(lay_clk), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(lay_burstcnt), .DDRAM_ADDR(lay_addr),
	.DDRAM_RD(lay_rd), .DDRAM_DIN(lay_din), .DDRAM_BE(lay_be), .DDRAM_WE(lay_we)
);
/* verilator lint_on PINCONNECTEMPTY */
assign {r, g, b} = nat_rgb;

wire rotate_ccw = ~game_flags[7];
wire no_rotate  = ~game_vert | status[12] | direct_video;
wire flip       = 1'b0;
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

punchout_dispatcher board
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
	.vol_speech(status[62:59] ^ 4'd8),
	.vol_music(status[66:63] ^ 4'd8),

	.nvs_addr(ioctl_addr[9:0]),
	.nvs_din(ioctl_dout),
	.nvs_we(ioctl_download & ioctl_wr & (ioctl_index == 8'd4)),
	.nvs_dout(ioctl_din)
);

assign ioctl_upload_req = ~status[27] & ~ioctl_download;

endmodule
