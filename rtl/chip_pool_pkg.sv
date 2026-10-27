//============================================================================
//
//  chip_pool_pkg — bus types for a multi-board core's shared CPU / sound chip pool (canonical; same file in every core)
//  Copyright (C) 2026 Rodimus
//
//  Only one board runs at a time, so the CPUs and sound chips are instanced once in rtl/konami82_board.sv
//  and the active board drives them through these buses (selected by variant). *_i = board to chip,
//  *_o = chip to every board. Reset is the core reset.
//
//============================================================================

package chip_pool_pkg;

// Z80 (T80s, Mode 0, T2Write 1, IOWait 1; WAIT_n / BUSRQ_n inactive)
typedef struct packed {
    logic        ce;
    logic        int_n;
    logic        nmi_n;
    logic  [7:0] di;
} z80_i_t;

typedef struct packed {
    logic [15:0] a;
    logic  [7:0] dout;
    logic        m1_n;
    logic        mreq_n;
    logic        iorq_n;
    logic        rd_n;
    logic        wr_n;
    logic        rfsh_n;
} z80_o_t;

// MC6809E (mc6809is; HALT / DMABREQ inactive)
typedef struct packed {
    logic        fall_e;
    logic        fall_q;
    logic        irq_n;
    logic        firq_n;
    logic        nmi_n;
    logic  [7:0] d;
} m6809_i_t;

typedef struct packed {
    logic [15:0] a;
    logic  [7:0] dout;
    logic        rw;
    logic        lic;
} m6809_o_t;

// Z80 (T80s, as z80_i_t) with RESET_n on the bus: Konami82's board watchdogs reset the main and sound CPUs
typedef struct packed {
    logic        reset_n;
    logic        ce;
    logic        int_n;
    logic        nmi_n;
    logic  [7:0] di;
} z80r_i_t;

typedef struct packed {
    logic [15:0] a;
    logic  [7:0] dout;
    logic        m1_n;
    logic        mreq_n;
    logic        iorq_n;
    logic        rd_n;
    logic        wr_n;
    logic        rfsh_n;
} z80r_o_t;

// MC6809E (mc6809is, as m6809_i_t) with RESET on the bus: Konami82's board watchdogs
typedef struct packed {
    logic        reset_n;
    logic        fall_e;
    logic        fall_q;
    logic        irq_n;
    logic        firq_n;
    logic        nmi_n;
    logic  [7:0] d;
} m6809r_i_t;

typedef struct packed {
    logic [15:0] a;
    logic  [7:0] dout;
    logic        rw;
    logic        lic;
} m6809r_o_t;

// AY-3-8910 (jt49_bus, sel = 1)
typedef struct packed {
    logic        ce;
    logic        bdir;
    logic        bc1;
    logic  [7:0] din;
    logic  [7:0] ioa_in;
    logic  [7:0] iob_in;
} ay_i_t;

typedef struct packed {
    logic  [7:0] dout;
    logic  [7:0] a;
    logic  [7:0] b;
    logic  [7:0] c;
    logic  [7:0] iob_out;
    logic  [9:0] sound;                 // jt49 internal A+B+C mix (registered per accumulator cycle)
} ay_o_t;

// 8039 (T48 t8039_notri_extrom, EA low, program on pmem; T0 / T1 low, P1 / P2 inputs high)
typedef struct packed {
    logic        xtal_en;
    logic        int_n;
    logic  [7:0] db;
    logic  [7:0] pmem_d;
} mcs48_i_t;

typedef struct packed {
    logic  [7:0] p1;
    logic  [7:0] p2;
    logic [11:0] pmem_a;
    logic        rd_n;
} mcs48_o_t;

// Z80 (T80pa, Mode 0; BUSRQ_n inactive). RESET_n is on the bus: Lady Bug / 8203 hold their CPUs in reset ~48 ms past the core reset
typedef struct packed {
    logic        reset_n;
    logic        cen_p;
    logic        cen_n;
    logic        wait_n;
    logic        int_n;
    logic        nmi_n;
    logic  [7:0] di;
} z80pa_i_t;

typedef struct packed {
    logic [15:0] a;
    logic  [7:0] dout;
    logic        m1_n;
    logic        mreq_n;
    logic        iorq_n;
    logic        rd_n;
    logic        wr_n;
    logic        rfsh_n;
} z80pa_o_t;

// SN76489 (jt89, INTERPOL16 0, MODE 0). rst is on the bus: Lady Bug resets its pair on power-on only
typedef struct packed {
    logic        rst;
    logic        ce;
    logic        wr_n;
    logic        cs_n;
    logic  [7:0] din;
} sn76489_i_t;

typedef struct packed {
    logic [10:0] sound;                 // signed
    logic        ready;
} sn76489_o_t;

// MB88 (mb88 / mb88_core; STBY / SC inputs inactive, RAM clear = core reset)
typedef struct packed {
    logic        ena;
    logic        reset_n;
    logic  [3:0] k;
    logic [15:0] r_in;          // {R3, R2, R1, R0}
    logic        irq_n;
    logic        tc_n;
    logic        si_n;
    logic  [7:0] rom_d;
} mb88_i_t;

typedef struct packed {
    logic [15:0] r_out;         // {R3, R2, R1, R0}
    logic  [7:0] o;             // {OH, OL}
    logic        o_wr;
    logic  [3:0] p;
    logic [10:0] rom_a;
} mb88_o_t;

// NEW-PunchOut-2026-10-26: types not in the master yet (merge into Konami82's master; never rename the ones above)
// 6502 (T65, Mode 00, BCD_en 0 = the RP2A03's core). Enable = one CPU cycle. res_n on the bus: Punch-Out's main
// latch Q3 resets the RP2A03. Verbatim copy of Arcade-Nintendo's t65_i_t / t65_o_t (its NEW types, not merged yet).
typedef struct packed {
    logic        res_n;
    logic        enable;
    logic        rdy;
    logic        irq_n;
    logic        nmi_n;
    logic  [7:0] di;
} t65_i_t;

typedef struct packed {
    logic [15:0] a;
    logic  [7:0] dout;
    logic        rw;                    // 1 = read
} t65_o_t;

// VLM5030 (jotego jtcores modules/vlm5030: vlm5030_gl, Arnim Laeuger's gate-level VHDL; i_tst1 0, i_vref / i_tst3
// default). rst is the chip's RST pin (Punch-Out main latch Q4), not the core reset. oscen = 3.579545 MHz enable
// (the model needs clk >= 2x OSC).
typedef struct packed {
    logic        rst;
    logic        oscen;
    logic        start;
    logic        vcu;
    logic  [7:0] d;
} vlm5030_i_t;

typedef struct packed {
    logic [15:0] a;
    logic        me_l;
    logic        mte;
    logic        bsy;
    logic  [5:0] dao;                   // unsigned DAC + PWM (the pin)
    logic  [9:0] audio;                 // signed PCM (~8136 Hz)
} vlm5030_o_t;

endpackage
