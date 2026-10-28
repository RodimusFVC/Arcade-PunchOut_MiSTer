//============================================================================
//
//  Ricoh RP2A03 glue: a pooled 6502 core (T65 bus, chip_pool_pkg) + rp2a03_apu + the chip's external bus
//  Copyright (C) 2026 Rodimus
//
//  One CPU cycle per ce (CLK / 12). Bus cycle = the time between two ce; the board answers ext_a / ext_rw with
//  ext_din by the next ce and performs writes at ce. As on the die, APU register writes ($4000-$4017) also go out
//  on the external bus (DK3 relies on the RAM seeing them). $4015 reads come from the APU.
//  DMC fetch: the next CPU read cycle is held with RDY (two idle cycles + the fetch cycle on the DMC address).
//  The 2A03 has decimal mode cut on the die (the D flag still exists); the pooled core is the stock T65 (decimal on).
//
//============================================================================

module rp2a03
(
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,             // CPU cycle (21.477 MHz / 12)
    input  logic        nmi_n,

    output chip_pool_pkg::t65_i_t t65_i,
    input  chip_pool_pkg::t65_o_t t65_o,

    output logic [15:0] ext_a,
    output logic        ext_rw,         // 1 = read
    output logic  [7:0] ext_dout,
    input  logic  [7:0] ext_din,

    output logic [15:0] aux_a,
    output logic [15:0] aux_b
);

logic        dmc_req, dmc_ack;
logic [15:0] dmc_addr;
logic  [7:0] apu_dout;
logic        apu_sel, apu_irq_n;
logic  [1:0] dma_st = 2'd0;              // 0 idle, 1-2 held, 3 fetch
wire         dma_fetch = dma_st == 2'd3;

assign ext_a    = dma_fetch ? dmc_addr : t65_o.a;
assign ext_rw   = dma_fetch ? 1'b1 : t65_o.rw;
assign ext_dout = t65_o.dout;

rp2a03_apu apu
(
    .clk(clk), .reset(reset), .ce(ce),                            // held / fetch cycles show a CPU read
    .addr(t65_o.a), .rw(t65_o.rw), .din(t65_o.dout), .dout(apu_dout), .sel_4015(apu_sel), .irq_n(apu_irq_n),
    .dmc_req(dmc_req), .dmc_addr(dmc_addr), .dmc_ack(dmc_ack), .dmc_data(ext_din),
    .aux_a(aux_a), .aux_b(aux_b)
);

always_ff @(posedge clk) begin
    if (reset) dma_st <= 2'd0;
    else if (ce) case (dma_st)
        2'd0: if (dmc_req && t65_o.rw) dma_st <= 2'd1;
        default: dma_st <= dma_st + 2'd1;                               // 3 -> 0 after the fetch
    endcase
end
assign dmc_ack = ce && dma_fetch;

assign t65_i.res_n  = ~reset;
assign t65_i.enable = ce;
assign t65_i.rdy    = dma_st == 2'd0 && !(dmc_req && t65_o.rw);
assign t65_i.irq_n  = apu_irq_n;
assign t65_i.nmi_n  = nmi_n;
assign t65_i.di     = apu_sel ? apu_dout : ext_din;

endmodule
