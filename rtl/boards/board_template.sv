//============================================================================
//  board_template.sv - start a new PunchOut-core board by copying this file (NOT in files.qip, never compiled).
//  Copyright (C) 2026 Rodimus
//
//  Boards never instantiate a CPU, sound chip, ROM store or board RAM. They live ONCE in the dispatcher
//  rtl/punchout_board.sv: Z80 z80pa_0, RP2A03's 6502 t65_0, VLM5030 vlm5030_0 (chip_pool_pkg buses), the shared ROM
//  blocks (rom0_bk0-2 packed store, ports rom0_* / rom0b_*; rom1 colour PROMs, ports rom1_* / rom1b_*) and the seven
//  board RAM pool blocks (ram_pool_pkg; map in the dispatcher's "Shared RAM pool" section: 0 Z80 work 2K, 1 battery 1K,
//  2 top bg 2K, 3 bottom maps 4K, 4 big sprite 1 2K, 5 big sprite 2 2K, 6 RP2A03 RAM 2K). The two screens run at
//  once, so RAMs of the two video pipelines never share a block.
//  To add the board: copy this file to rtl/boards/<board>/<board>_board.sv (the port list below is chp1_board's, the
//  only board so far), add it to files.qip + verilator/Makefile SRC + verilator/lint.sh, instance it in the
//  dispatcher, put its *_i buses on the variant muxes (pool_i, any chip bus; today a plain assign: one board family)
//  and tie the blocks it doesn't use to '0. A RAM bigger than its block = grow the block, never a private dpram_dc.
//  A RAM / chip that truly can't pool = "// POOL-EXCEPTION: <reason>" on its instance line + a Pool contract row
//  (Claude/punchout_core_2026-10-27.md). verilator/common/pool_check.sh (POOL_MODS in verilator/Makefile) enforces it.
//============================================================================

module board_template
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

endmodule
