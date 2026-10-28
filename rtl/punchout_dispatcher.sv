//============================================================================
//
//  PunchOut — board top (dispatcher)
//  Copyright (C) 2026 Rodimus
//
//  Pools (CPU / sound chip, ROM, RAM) live here; the board (rtl/boards/chp1/: CPU board + VIDEO / BAK boards)
//  drives them through bus ports, selected by variant (Projects/Arcade-Konami82_MiSTer/Claude/chip_pool_convention.md).
//  Boards never instantiate their own CPU / sound chip / ROM / RAM.
//
//  Variants (index 1 byte 0; numbering = tools/gen_mra.py SUPPORTED), MAME nintendo/punchout.cpp:
//    0  Punch-Out!!        (punchout, punchouta, punchoutah, punchoutj, punchita)  CHP1 CPU + VIDEO + BAK
//    1  Super Punch-Out!!  (spnchout, spnchouta, spnchoutj)    as 0 + CHS1-01-EXP (RP5C01 + RP5H01 protection)
//    2  Arm Wrestling      (armwrest)                          as 0, different VIDEO / BAK maps (+ fg tilemap)
//  Every variant: Z80 4 MHz (8 MHz / 2), RP2A03 (21.47727 MHz, CPU / 12), VLM5030 (21.47727 MHz / 6),
//  TWO monitors driven at once from ONE timing chain (20.16 MHz xtal, 5.04 MHz dot clock; schematic facts note).
//  The two screens are placed by rtl/punchout_layout.sv (Game Options Screen Layout).
//
//  Clock: CLK_SYS = 40.32 MHz (2 x 20.16 MHz): 8 CLK_SYS per pixel, exact Z80 / RP2A03 enables.
//
//============================================================================

module punchout_dispatcher
(
    input  logic        clk,            // CLK_SYS
    input  logic        reset,
    input  logic        pause,
    input  logic  [7:0] variant,
    input  logic  [7:0] game_flags2,
    input  logic [47:0][7:0] rom_rgn,   // index 1 bytes 64-111: ROM region table (kept for the record; the page map decodes)
    input  logic  [7:0] rom_inv,        // index 1 byte 112: ROMREGION_INVERT slot mask
    input  logic [255:0][7:0] rom_page, // index 1 bytes 128-383: slot n page k at 32n + k = store page (8K), FF = empty
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

    // top monitor (schematic "S": BAK PROMs 6E / 6F / 7F) and bottom monitor ("M": 7E / 8E / 8F); one timing chain
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

    // battery RAM save / load (MRA <nvram index="4" size="1024">), port B of the nvram pool
    input  logic  [9:0] nvs_addr,
    input  logic  [7:0] nvs_din,
    input  logic        nvs_we,
    output logic  [7:0] nvs_dout
);

/////////////////////////////  Shared CPU / sound chip pool  /////////////////////////////

// Main Z80 (T80pa): z80pa_0: every board's main CPU (CHP1 CPU board 6H). BUSRQ_n tied inactive as in the master
// type (schematic: VB -> LS74A 1D -> Z80 /BUSRQ; MAME does not model it).
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

// RP2A03 6502 core (T65, Mode 00, BCD_en 0; Nintendo core's T65 lineage with the BCD_en input):
// t65_0: every board's sound CPU (CPU board 4H; the 4F second 2A03 footprint is unpopulated). The RP2A03 glue + APU
// (rtl/sound/rp2a03.sv, rp2a03_apu.sv, Nintendo core) sit on the board, as in the Nintendo core.
chip_pool_pkg::t65_i_t t65_0_i;
chip_pool_pkg::t65_o_t t65_0_o;

wire [23:0] t65_0_a24;
/* verilator lint_off PINCONNECTEMPTY */
T65 t65_0
(
    .Mode(2'b00), .BCD_en(1'b0), .Res_n(t65_0_i.res_n), .Enable(t65_0_i.enable), .Clk(clk), .Rdy(t65_0_i.rdy),
    .Abort_n(1'b1), .IRQ_n(t65_0_i.irq_n), .NMI_n(t65_0_i.nmi_n), .SO_n(1'b1), .R_W_n(t65_0_o.rw), .Sync(), .EF(),
    .MF(), .XF(), .ML_n(), .VP_n(), .VDA(), .VPA(), .A(t65_0_a24), .DI(t65_0_i.di), .DO(t65_0_o.dout), .Regs(),
    .NMI_ack()
);
/* verilator lint_on PINCONNECTEMPTY */
assign t65_0_o.a = t65_0_a24[15:0];

// VLM5030: vlm5030_0: every board's speech chip (CPU board 6M, ROM 6P). Our model, rtl/sound/vlm5030_lpc.sv (MAME
// vlm5030.cpp port).
chip_pool_pkg::vlm5030_i_t vlm5030_0_i;
chip_pool_pkg::vlm5030_o_t vlm5030_0_o;
vlm5030_lpc vlm5030_0
(
    .clk(clk), .reset(reset), .i_oscen(vlm5030_0_i.oscen), .i_rst(vlm5030_0_i.rst), .i_start(vlm5030_0_i.start),
    .i_vcu(vlm5030_0_i.vcu), .i_d(vlm5030_0_i.d), .o_a(vlm5030_0_o.a), .o_me_l(vlm5030_0_o.me_l),
    .o_mte(vlm5030_0_o.mte), .o_bsy(vlm5030_0_o.bsy), .o_dao(vlm5030_0_o.dao), .o_audio(vlm5030_0_o.audio)
);

/////////////////////////////  Shared ROM blocks  /////////////////////////////

// One packed store (tools/gen_mra.py place()), sized to the LARGEST single set, never the sum of region maxima:
// Super Punch-Out = 0x4A000 bytes of CPU / sound / graphics / speech ROM, in three physical banks (256K + 32K + 8K)
// behind one linear address: rom0_bk0 0x00000-0x3FFFF, rom0_bk1 0x40000-0x47FFF, rom0_bk2 0x48000-0x49FFF. rom1 = 8K at
// index-0 address 0x50000: the colour PROM region bytes below 0x2000 (decoded on read; timing PROM 2D not stored).
// Readers address a region slot + region offset; the 8K page map (index 1 bytes 128-383) gives the store page, so
// empty ROM sockets cost nothing and read FF (ROMREGION_ERASEFF). ROMREGION_INVERT slots (byte 112) are inverted on
// read, never at load. Load decode never depends on the variant (index 1 arrives after the ROMs).
// Slots: 0 maincpu, 1 audiocpu, 2 gfx1, 3 gfx2, 4 gfx3, 5 gfx4, 6 vlm. Board ports (convention rule 5): rom0_* =
// port B (video), rom0b_* = port A (CPU side + big sprite 2, the second reader), each driving that port of all
// three banks rom0_bk0-2; rom1_* / rom1b_* = colour PROMs, bottom / top monitor.
// Page map entries kept: only the pages each slot can address (maincpu 0-5, audiocpu 7, gfx1 0-3, gfx2 0-5,
// gfx3 0-23, gfx4 0-7, vlm 0-1); the rest of the 256 bytes has no reader and is dropped by synthesis.
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
wire [18:0] sta = {pga[5:0], rom0b_a[12:0]};          // store address
wire [18:0] stb = {pgb[5:0], rom0_a[12:0]};

logic [17:0] rom0_bk0_aa, rom0_bk0_ab;
logic [14:0] rom0_bk1_aa, rom0_bk1_ab;
logic [12:0] rom0_bk2_aa, rom0_bk2_ab;
logic [12:0] rom1_aa, rom1_ab;
logic  [7:0] rom0_bk0_qa, rom0_bk0_qb, rom0_bk1_qa, rom0_bk1_qb, rom0_bk2_qa, rom0_bk2_qb, rom1_qa, rom1_qb;
assign rom0_bk0_aa = sta[17:0]; assign rom0_bk1_aa = sta[14:0]; assign rom0_bk2_aa = sta[12:0];
assign rom0_bk0_ab = stb[17:0]; assign rom0_bk1_ab = stb[14:0]; assign rom0_bk2_ab = stb[12:0];

// read data: bank select, empty socket and invert flag registered with the address (q is one clock later)
logic [1:0] bka = 2'd0, bkb = 2'd0;                    // 0 rom0_bk0, 1 rom0_bk1, 2 rom0_bk2, 3 empty
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

wire ld_rom0_bk0 = ioctl_wr0 && ioctl_addr[24:18] == 7'd0;                       // 0x00000-0x3FFFF
wire ld_rom0_bk1 = ioctl_wr0 && ioctl_addr[24:15] == 10'h008;                    // 0x40000-0x47FFF
wire ld_rom0_bk2 = ioctl_wr0 && ioctl_addr[24:13] == 12'h024;                    // 0x48000-0x49FFF
wire ld_rom1  = ioctl_wr0 && ioctl_addr[24:13] == 12'h028;                    // 0x50000-0x51FFF

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

// rom1: colour PROMs; port A = top monitor's palette reads, port B = bottom monitor's (both screens run at once)
dpram_dc #(.widthad_a(13)) rom1
(
    .clock_a(clk), .address_a(ld_rom1 ? ioctl_addr[12:0] : rom1_aa), .data_a(ioctl_dout), .wren_a(ld_rom1), .q_a(rom1_qa),
    .clock_b(clk), .address_b(rom1_ab), .data_b(8'd0), .wren_b(1'b0), .q_b(rom1_qb)
);

/////////////////////////////  Shared RAM pool  /////////////////////////////

// ram_pool_pkg buses (Universal's RAMPOOL convention): block n = pool_i[n] / pool_o[n], two read / write ports, one
// clock to q as dpram_dc; the owner board is picked by variant. Each block is sized to the largest user over the
// three variants (MAME memory maps), not to the bus width. Port A = CPU, port B = video engine (block 1: MRA save /
// load). Both screens' maps are separate blocks: the two pipelines run concurrently.
//   block 0  2K  Z80 work RAM            (every variant D000-D7FF)
//   block 1  1K  battery RAM             (C000-C3FF; HW = TC5514 1K x 4, MAME 1K x 8 DEFAULT_ALL_0 = BRAM power-up)
//   block 2  2K  top-screen bg tilemap   (Punch-Out D800-DFEF; Arm Wrestling F800-FFFF)
//   block 3  4K  bottom-screen maps      (Punch-Out F000-FFFF bg 64x32 + row scroll; Arm Wrestling F000-F7FF bg +
//                                         D800-DFEF fg)
//   block 4  2K  big sprite 1 map        (E000-E7FF; one engine feeds BOTH screens' colour muxes, schematic F)
//   block 5  2K  big sprite 2 map        (E800-EFFF; bottom screen only)
//   block 6  2K  RP2A03 RAM              (0000-07FF; CPU board 4L HM6116)
// DFF0-DFFD control registers (zoom, position, flip, monitor select, palette bank) are registers on the board.
localparam int RAM_BLOCKS = 7;
function automatic int ram_aw(input int n);           // block address width
    case (n)
        1:       ram_aw = 10;
        3:       ram_aw = 12;
        default: ram_aw = 11;
    endcase
endfunction

ram_pool_pkg::pram_i_t [RAM_BLOCKS-1:0] chp1_pr_i, pool_i;
ram_pool_pkg::pram_o_t [RAM_BLOCKS-1:0] pool_o;
assign pool_i = chp1_pr_i;                             // one board family so far
genvar n;                                              // Quartus 17: no genvar declared in the for header
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

// Pooled multipliers: none. The big-sprite zoom is incremental (HW: F283 / LS283 adders on the VIDEO board); the
// per-line y * zoom product is one small multiply in the board.

/////////////////////////////  Boards  /////////////////////////////

// CHP1 family (every variant; variant gates inside). Pool inputs from the board: <board>_<chip>_<n>_i, selected by
// variant (one board family so far, so the mux is the CHP1 board alone); pool outputs fan out unmuxed.
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
