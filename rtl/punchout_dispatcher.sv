//  Based on MAME punchout.cpp (Nicola Salmoria, BSD-3-Clause)
//  Copyright (C) 2026 Rodimus

module punchout_dispatcher
(
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,
    input  logic  [7:0] variant,
    input  logic  [7:0] game_flags2,
    input  logic [47:0][7:0] rom_rgn,
    input  logic  [7:0] rom_inv,
    input  logic [255:0][7:0] rom_page,
    output logic        ce_pix,

    input  logic  [7:0] in0,
    input  logic  [7:0] in1,
    input  logic  [7:0] dsw1,
    input  logic  [7:0] dsw2,

    input  logic [24:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,

    input  logic        crt_flip,
    input  logic  [3:0] h_adj,
    input  logic  [3:0] v_adj,

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
    input  logic  [3:0] vol_speech,     // Game Options volumes: gain in eighths (8 = Default, 0 = Off)
    input  logic  [3:0] vol_music,

    input  logic  [9:0] nvs_addr,
    input  logic  [7:0] nvs_din,
    input  logic        nvs_we,
    output logic  [7:0] nvs_dout
);

/////////////////////////////  Shared CPU / sound chip pool  /////////////////////////////

// Main Z80 (T80pa): z80pa_0: every board's main CPU (CHP1 CPU board 6H). BUSRQ_n tied inactive as in the master
chip_pool_pkg::z80pa_i_t z80pa_0_i;
chip_pool_pkg::z80pa_o_t z80pa_0_o;

wire [15:0] z80pa_0_a;
wire  [7:0] z80pa_0_do;
wire        z80pa_0_m1_n, z80pa_0_mreq_n, z80pa_0_iorq_n, z80pa_0_rd_n, z80pa_0_wr_n, z80pa_0_rfsh_n;

/* verilator lint_off PINCONNECTEMPTY */
T80pa #(.Mode(0)) z80pa_0
(
    .RESET_n (~reset & z80pa_0_i.reset_n), .CLK(clk), .CEN_p(z80pa_0_i.cen_p), .CEN_n(z80pa_0_i.cen_n),
    .WAIT_n  (z80pa_0_i.wait_n), .INT_n(z80pa_0_i.int_n), .NMI_n(z80pa_0_i.nmi_n), .BUSRQ_n(1'b1),
    .M1_n(z80pa_0_m1_n), .MREQ_n(z80pa_0_mreq_n), .IORQ_n(z80pa_0_iorq_n), .RD_n(z80pa_0_rd_n), .WR_n(z80pa_0_wr_n),
    .RFSH_n(z80pa_0_rfsh_n), .HALT_n(), .BUSAK_n(), .OUT0(1'b0), .A(z80pa_0_a), .DI(z80pa_0_i.di), .DO(z80pa_0_do),
    .R800_mode(1'b0), .REG(), .DIRSet(1'b0), .DIR(212'd0)
);
/* verilator lint_on PINCONNECTEMPTY */

assign z80pa_0_o.a = z80pa_0_a;           assign z80pa_0_o.dout = z80pa_0_do;
assign z80pa_0_o.m1_n = z80pa_0_m1_n;     assign z80pa_0_o.mreq_n = z80pa_0_mreq_n; assign z80pa_0_o.iorq_n = z80pa_0_iorq_n;
assign z80pa_0_o.rd_n = z80pa_0_rd_n;     assign z80pa_0_o.wr_n = z80pa_0_wr_n;     assign z80pa_0_o.rfsh_n = z80pa_0_rfsh_n;

// t65_0: every board's sound CPU (CPU board 4H; the 4F second 2A03 footprint is unpopulated). The RP2A03 glue + APU
chip_pool_pkg::t65_i_t t65_0_i;
chip_pool_pkg::t65_o_t t65_0_o;

wire [23:0] t65_0_a24;
/* verilator lint_off PINCONNECTEMPTY */
T65 t65_0
(
    .Mode(2'b00), .Res_n(t65_0_i.res_n), .Enable(t65_0_i.enable), .Clk(clk), .Rdy(t65_0_i.rdy),
    .Abort_n(1'b1), .IRQ_n(t65_0_i.irq_n), .NMI_n(t65_0_i.nmi_n), .SO_n(1'b1), .R_W_n(t65_0_o.rw), .Sync(), .EF(),
    .MF(), .XF(), .ML_n(), .VP_n(), .VDA(), .VPA(), .A(t65_0_a24), .DI(t65_0_i.di), .DO(t65_0_o.dout), .Regs(),
    .NMI_ack()
);
/* verilator lint_on PINCONNECTEMPTY */
assign t65_0_o.a = t65_0_a24[15:0];

chip_pool_pkg::vlm5030_i_t vlm5030_0_i;
chip_pool_pkg::vlm5030_o_t vlm5030_0_o;
vlm5030_lpc vlm5030_0
(
    .clk(clk), .reset(reset), .i_oscen(vlm5030_0_i.oscen), .i_rst(vlm5030_0_i.rst), .i_start(vlm5030_0_i.start),
    .i_vcu(vlm5030_0_i.vcu), .i_d(vlm5030_0_i.d), .o_a(vlm5030_0_o.a), .o_me_l(vlm5030_0_o.me_l),
    .o_mte(vlm5030_0_o.mte), .o_bsy(vlm5030_0_o.bsy), .o_dao(vlm5030_0_o.dao), .o_audio(vlm5030_0_o.audio)
);

/////////////////////////////  Shared ROM blocks  /////////////////////////////

function automatic logic [7:0] page_of(input logic [2:0] slot, input logic [4:0] pg);
    case (slot)
        3'd0:    page_of = (pg < 5'd6)  ? rom_page[{3'd0, pg}] : 8'hFF;
        3'd1:    page_of = (pg == 5'd7) ? rom_page[{3'd1, pg}] : 8'hFF;
        3'd2:    page_of = (pg < 5'd4)  ? rom_page[{3'd2, pg}] : 8'hFF;
        3'd3:    page_of = (pg < 5'd6)  ? rom_page[{3'd3, pg}] : 8'hFF;
        3'd4:    page_of = (pg < 5'd24) ? rom_page[{3'd4, pg}] : 8'hFF;
        3'd5:    page_of = (pg < 5'd8)  ? rom_page[{3'd5, pg}] : 8'hFF;
        3'd6:    page_of = (pg < 5'd2)  ? rom_page[{3'd6, pg}] : 8'hFF;
        default: page_of = 8'hFF;
    endcase
endfunction

logic  [2:0] rom0b_slot, rom0_slot;
logic [17:0] rom0b_a, rom0_a;
logic  [7:0] rom0b_d, rom0_d;

wire [7:0]  pga = page_of(rom0b_slot, rom0b_a[17:13]);
wire [7:0]  pgb = page_of(rom0_slot, rom0_a[17:13]);
wire [18:0] sta = {pga[5:0], rom0b_a[12:0]};
wire [18:0] stb = {pgb[5:0], rom0_a[12:0]};

logic [17:0] rom0_bk0_aa, rom0_bk0_ab;
logic [14:0] rom0_bk1_aa, rom0_bk1_ab;
logic [12:0] rom0_bk2_aa, rom0_bk2_ab;
logic [12:0] rom1_aa, rom1_ab;
logic  [7:0] rom0_bk0_qa, rom0_bk0_qb, rom0_bk1_qa, rom0_bk1_qb, rom0_bk2_qa, rom0_bk2_qb, rom1_qa, rom1_qb;
assign rom0_bk0_aa = sta[17:0]; assign rom0_bk1_aa = sta[14:0]; assign rom0_bk2_aa = sta[12:0];
assign rom0_bk0_ab = stb[17:0]; assign rom0_bk1_ab = stb[14:0]; assign rom0_bk2_ab = stb[12:0];

logic [1:0] bka = 2'd0, bkb = 2'd0;
logic       inva = 1'b0, invb = 1'b0;
always_ff @(posedge clk) begin
    bka  <= pga[7] ? 2'd3 : ~sta[18] ? 2'd0 : ~sta[15] ? 2'd1 : 2'd2;
    bkb  <= pgb[7] ? 2'd3 : ~stb[18] ? 2'd0 : ~stb[15] ? 2'd1 : 2'd2;
    inva <= rom_inv[rom0b_slot];
    invb <= rom_inv[rom0_slot];
end
always_comb begin
    case (bka) 2'd0: rom0b_d = rom0_bk0_qa; 2'd1: rom0b_d = rom0_bk1_qa; 2'd2: rom0b_d = rom0_bk2_qa; default: rom0b_d = 8'hFF; endcase
    case (bkb) 2'd0: rom0_d = rom0_bk0_qb; 2'd1: rom0_d = rom0_bk1_qb; 2'd2: rom0_d = rom0_bk2_qb; default: rom0_d = 8'hFF; endcase
    if (inva) rom0b_d = ~rom0b_d;
    if (invb) rom0_d = ~rom0_d;
end

wire ld_rom0_bk0 = ioctl_wr0 && ioctl_addr[24:18] == 7'd0;
wire ld_rom0_bk1 = ioctl_wr0 && ioctl_addr[24:15] == 10'h008;
wire ld_rom0_bk2 = ioctl_wr0 && ioctl_addr[24:13] == 12'h024;
wire ld_rom1  = ioctl_wr0 && ioctl_addr[24:13] == 12'h028;

dpram_dc #(.widthad_a(18)) rom0_bk0
(
    .clock_a(clk), .address_a(ld_rom0_bk0 ? ioctl_addr[17:0] : rom0_bk0_aa), .data_a(ioctl_dout), .wren_a(ld_rom0_bk0), .q_a(rom0_bk0_qa),
    .clock_b(clk), .address_b(rom0_bk0_ab), .data_b(8'd0), .wren_b(1'b0), .q_b(rom0_bk0_qb)
);

dpram_dc #(.widthad_a(15)) rom0_bk1
(
    .clock_a(clk), .address_a(ld_rom0_bk1 ? ioctl_addr[14:0] : rom0_bk1_aa), .data_a(ioctl_dout), .wren_a(ld_rom0_bk1), .q_a(rom0_bk1_qa),
    .clock_b(clk), .address_b(rom0_bk1_ab), .data_b(8'd0), .wren_b(1'b0), .q_b(rom0_bk1_qb)
);

dpram_dc #(.widthad_a(13)) rom0_bk2
(
    .clock_a(clk), .address_a(ld_rom0_bk2 ? ioctl_addr[12:0] : rom0_bk2_aa), .data_a(ioctl_dout), .wren_a(ld_rom0_bk2), .q_a(rom0_bk2_qa),
    .clock_b(clk), .address_b(rom0_bk2_ab), .data_b(8'd0), .wren_b(1'b0), .q_b(rom0_bk2_qb)
);

dpram_dc #(.widthad_a(13)) rom1
(
    .clock_a(clk), .address_a(ld_rom1 ? ioctl_addr[12:0] : rom1_aa), .data_a(ioctl_dout), .wren_a(ld_rom1), .q_a(rom1_qa),
    .clock_b(clk), .address_b(rom1_ab), .data_b(8'd0), .wren_b(1'b0), .q_b(rom1_qb)
);

/////////////////////////////  Shared RAM pool  /////////////////////////////

//   block 0  2K  Z80 work RAM            (every variant D000-D7FF)
//   block 2  2K  top-screen bg tilemap   (Punch-Out D800-DFEF; Arm Wrestling F800-FFFF)
//   block 3  4K  bottom-screen maps      (Punch-Out F000-FFFF bg 64x32 + row scroll; Arm Wrestling F000-F7FF bg +
//                                         D800-DFEF fg)
//   block 4  2K  big sprite 1 map        (E000-E7FF; one engine feeds BOTH screens' colour muxes, schematic F)
//   block 5  2K  big sprite 2 map        (E800-EFFF; bottom screen only)
//   block 6  2K  RP2A03 RAM              (0000-07FF; CPU board 4L HM6116)
localparam int RAM_BLOCKS = 7;
function automatic int ram_aw(input int n);
    case (n)
        1:       ram_aw = 10;
        3:       ram_aw = 12;
        default: ram_aw = 11;
    endcase
endfunction

ram_pool_pkg::pram_i_t [RAM_BLOCKS-1:0] chp1_pr_i, pool_i;
ram_pool_pkg::pram_o_t [RAM_BLOCKS-1:0] pool_o;
assign pool_i = chp1_pr_i;
genvar n;
// genvar outside the for header: Quartus 17
generate
    for (n = 0; n < RAM_BLOCKS; n++) begin : rpool
        dpram_dc #(.widthad_a(ram_aw(n))) ram
        (
            .clock_a(clk), .address_a(pool_i[n].a_addr[ram_aw(n)-1:0]), .data_a(pool_i[n].a_d), .wren_a(pool_i[n].a_we),
            .q_a(pool_o[n].a_q),
            .clock_b(clk), .address_b(pool_i[n].b_addr[ram_aw(n)-1:0]), .data_b(pool_i[n].b_d), .wren_b(pool_i[n].b_we),
            .q_b(pool_o[n].b_q)
        );
    end
endgenerate

/////////////////////////////  Boards  /////////////////////////////

chip_pool_pkg::z80pa_i_t   chp1_z80pa_0_i;
chip_pool_pkg::t65_i_t     chp1_t65_0_i;
chip_pool_pkg::vlm5030_i_t chp1_vlm5030_0_i;
assign z80pa_0_i   = chp1_z80pa_0_i;
assign t65_0_i     = chp1_t65_0_i;
assign vlm5030_0_i = chp1_vlm5030_0_i;

chp1_board chp1
(
    .clk(clk), .reset(reset), .pause(pause), .variant(variant),
    .in0(in0), .in1(in1), .dsw1(dsw1), .dsw2(dsw2),
    .crt_flip(crt_flip), .h_adj(h_adj), .v_adj(v_adj),
    .z80pa_0_i(chp1_z80pa_0_i), .z80pa_0_o(z80pa_0_o), .t65_0_i(chp1_t65_0_i), .t65_0_o(t65_0_o),
    .vlm5030_0_i(chp1_vlm5030_0_i), .vlm5030_0_o(vlm5030_0_o),
    .rom0_slot(rom0_slot), .rom0_a(rom0_a), .rom0_d(rom0_d), .rom0b_slot(rom0b_slot), .rom0b_a(rom0b_a), .rom0b_d(rom0b_d),
    .rom1_a(rom1_ab), .rom1_d(rom1_qb), .rom1b_a(rom1_aa), .rom1b_d(rom1_qa),
    .pr_i(chp1_pr_i), .pr_o(pool_o),
    .nvs_addr(nvs_addr), .nvs_din(nvs_din), .nvs_we(nvs_we), .nvs_dout(nvs_dout),
    .ce_pix(ce_pix), .top_r(top_r), .top_g(top_g), .top_b(top_b), .bot_r(bot_r), .bot_g(bot_g), .bot_b(bot_b),
    .video_hs(video_hs), .video_vs(video_vs), .video_hblank(video_hblank), .video_vblank(video_vblank),
    .audio(audio),
    .vol_speech(vol_speech),
    .vol_music(vol_music)
);

/* verilator lint_off UNUSED */
wire unused_ok = &{1'b0, game_flags2, rom_rgn, t65_0_a24[23:16], ioctl_addr[24:18], rom_page};
/* verilator lint_on UNUSED */

endmodule
