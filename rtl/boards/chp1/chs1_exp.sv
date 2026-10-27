//============================================================================
//
//  PunchOut: Super Punch-Out!! CHS1-01-EXP security board (in the Z80 socket): RP5C01 RTC + RP5H01 counter
//  Copyright (C) 2026 Rodimus
//
//  From MAME nintendo/punchout.cpp (spunchout_state: exp_r / exp_w / rp5h01_reset_w / rp5h01_clock_w) and the
//  devices machine/rp5c01.cpp (Curt Coder) and machine/rp5h01.cpp, as MAME configures them for spnchout:
//    RP5C01: clock 0 (OSCIN -> Vcc) and no battery, so it never keeps time and is never set: a 4-bit register file
//      (bank MODE00 / MODE01 with MAME's write masks, 13 bytes of RAM as nibbles in BLOCK10 / 11), all 0 at start
//      except the 12/24 select (1). Its timers never run, so _ALARM stays high (reads 0 in bit 5).
//    RP5H01: /CE grounded (always enabled), no PROM image in the set, so MAME's built-in s_initial_data is read.
//  I/O (global mask FF):  05 (mirror F0) write d0 = 74LS74 2D -> RP5H01 RESET (a 1 also clears the 1Q DATA CLOCK);
//    06 (mirror F0) write d0 = 74LS74 1D -> RP5H01 DATA CLOCK + TEST;  x7 read / write = RP5C01 register x (d0-d3),
//    read d5 = _ALARM, d6 = COUNTER OUT, d7 = DATA OUT (each inverted on the way in, as MAME), d4 = 1.
//
//============================================================================

module chs1_exp
(
    input  logic       clk,
    input  logic       reset,
    input  logic       io_wr,          // Z80 I/O write (level, any length: every effect below is idempotent)
    input  logic [7:0] a,              // Z80 address bits 7-0
    input  logic [7:0] d,
    output logic [7:0] q               // port x7 read value
);

/////////////////////////////  RP5C01  /////////////////////////////

localparam [3:0] R_MODE = 4'd13, R_TEST = 4'd14, R_RESET = 4'd15;

// MAME register_write_mask[mode][register] (registers 0-12)
function automatic logic [3:0] wmask(input logic m, input logic [3:0] r);
    case (r)
        4'd0:  wmask = m ? 4'h0 : 4'hF;     4'd1:  wmask = m ? 4'h0 : 4'h7;
        4'd2:  wmask = 4'hF;                4'd3:  wmask = 4'h7;
        4'd4:  wmask = 4'hF;                4'd5:  wmask = 4'h3;
        4'd6:  wmask = 4'h7;                4'd7:  wmask = 4'hF;
        4'd8:  wmask = 4'h3;                4'd9:  wmask = m ? 4'h0 : 4'hF;
        4'd10: wmask = 4'h1;                4'd11: wmask = m ? 4'h3 : 4'hF;
        default: wmask = m ? 4'h0 : 4'hF;   // 12
    endcase
endfunction

logic [3:0] reg0 [13];                 // MODE00: time counters
logic [3:0] reg1 [13];                 // MODE01: alarm / 12-24 select / leap year
logic [7:0] ram  [13];                 // BLOCK10 = low nibbles, BLOCK11 = high nibbles
logic [3:0] mode = 4'd0;

wire  [3:0] ro = a[7:4];
logic [3:0] rtc_q;
always_comb begin
    if (ro == R_MODE) rtc_q = mode;
    else if (ro == R_TEST || ro == R_RESET) rtc_q = 4'd0;           // write only
    else case (mode[1:0])
        2'd0:    rtc_q = reg0[ro];
        2'd1:    rtc_q = reg1[ro];
        2'd2:    rtc_q = ram[ro][3:0];
        default: rtc_q = ram[ro][7:4];
    endcase
end

wire wr_rtc = io_wr && a[3:0] == 4'd7;

always_ff @(posedge clk) begin
    if (reset) begin
        mode <= 4'd0;
        for (int i = 0; i < 13; i++) begin reg0[i] <= 4'd0; reg1[i] <= (i == 10) ? 4'd1 : 4'd0; ram[i] <= 8'd0; end
    end else if (wr_rtc) begin
        if (ro == R_MODE) mode <= d[3:0];
        else if (ro == R_RESET) begin
            if (d[0]) for (int i = 2; i < 9; i++) reg1[i] <= 4'd0;     // alarm reset: MODE01 minute .. day
        end
        else if (ro != R_TEST) case (mode[1:0])
            2'd0:    reg0[ro] <= d[3:0] & wmask(1'b0, ro);
            2'd1:    reg1[ro] <= d[3:0] & wmask(1'b1, ro);
            2'd2:    ram[ro][3:0] <= d[3:0];
            default: ram[ro][7:4] <= d[3:0];
        endcase
    end
end

/////////////////////////////  RP5H01  /////////////////////////////

// MAME rp5h01_device::s_initial_data (16 bytes, read MSB first)
function automatic logic pdata(input logic [6:0] c);
    case (c[6:3])
        4'd10, 4'd11, 4'd14, 4'd15: pdata = 1'b0;
        default:                    pdata = 1'b1;
    endcase
endfunction

logic [6:0] cnt = 7'd0;                // MAME m_counter: bit 5 = COUNTER OUT, (cnt & mode mask) >> 3 = data byte
logic       mode7 = 1'b0;              // TEST = 1: 7-bit counter, else 6-bit
logic       old_rst = 1'b0, old_clk = 1'b0;

wire wr_rst = io_wr && a[3:0] == 4'd5;
wire wr_clk = io_wr && a[3:0] == 4'd6;

always_ff @(posedge clk) begin
    if (reset) begin
        cnt <= 7'd0; mode7 <= 1'b0; old_rst <= 1'b0; old_clk <= 1'b0;
    end else if (wr_rst) begin
        // reset_w(d0) (0 -> 1 clears the counter); then a 1 also takes DATA CLOCK + TEST low (clock_w(0), test_w(0))
        old_rst <= d[0];
        if (d[0]) begin
            cnt <= (old_rst ? cnt : 7'd0) + (old_clk ? 7'd1 : 7'd0);
            old_clk <= 1'b0; mode7 <= 1'b0;
        end
    end else if (wr_clk) begin
        // clock_w(d0): 1 -> 0 counts; test_w(d0): counter mode
        if (old_clk && !d[0]) cnt <= cnt + 7'd1;
        old_clk <= d[0]; mode7 <= d[0];
    end
end

// DATA OUT = bit (7 - cidx[2:0]) of byte cidx[6:3]: every s_initial_data byte is 00 or FF, so the byte decides
wire [6:0] cidx = cnt & {mode7, 6'h3F};
assign q = {~pdata(cidx), ~cnt[5], 1'b0, 1'b1, rtc_q};    // d5: _ALARM never goes low (no timers at clock 0)

endmodule
