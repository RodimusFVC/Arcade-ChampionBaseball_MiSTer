//============================================================================
//
//  ExcitingSoccer_SND.sv
//
//  Sound board for Exciting Soccer / Exciting Soccer II (champbas.cpp).
//
//  This is a SEPARATE BOARD from ChampionBaseball_SND.sv, not a variant of it.
//  Nothing is shared:
//
//                        champbas board          exciting soccer board
//    audio Z80 clock     18.432/6 = 3.072 MHz    14.318181/4 = 3.579545 MHz
//    AY location         on the MAIN board       on THIS board
//    AY access           memory-mapped $7000/1   Z80 I/O space
//    AY count            1                       4  (2 on Soccer II)
//    DAC count           1  ($C000)              2  ($C008/$C009)
//    interrupts          none, CPU polls         4 kHz NMI + 75 Hz timer IRQ
//    ROM / RAM           0000-5FFF / E000-E3FF   0000-8FFF / A000-A7FF
//
//  MAME reference: champbas.cpp
//    exctsccr_sound_map      :670    exctsccr_sound_io_map  :681
//    exctscc2_sound_io_map   :690    machine cfg exctsccr   :1072
//    machine cfg exctscc2    :1132
//  Verified against Useful Information/disassembly/exctsccr_audiocpu.dasm:
//    $0000 `ld sp,$A7FF`  -> top of the A000-A7FF RAM
//    $0100 `ld hl,$A000 / ld bc,$0800` -> clears exactly 2 KB
//    $0038 `jp $082B` (IM1 timer IRQ) · $0066 `jp $03A3` (NMI)
//  Both vectors are populated, confirming BOTH interrupt sources are real.
//
//============================================================================

module ExcitingSoccer_SND
(
    input                clk,            // 49.152 MHz
    input                reset,
    input                pause,

    // Soccer II drops ay3/ay4 and moves ay1/ay2 in I/O space (:690, :1141).
    // It also runs ay1 at the standard divider instead of the VR (:1138).
    input                is_exctscc2,

    // ---- from the main board ($A080 write, champbasj_map)
    input         [7:0]  sound_latch,
    input                sound_latch_wr,

    // ---- audio CPU ROM (MRA index 1, 0x0000-0x8FFF)
    output       [15:0]  rom_addr,
    input         [7:0]  rom_data,

    output signed [15:0] sound_out
);

    ////////////////////////////////////////////////////////////////////////
    // Clock enables.
    //
    // This board runs off its OWN 14.318181 MHz crystal, which is unrelated
    // to the 18.432 MHz main board and therefore has no integer ratio to the
    // 49.152 MHz system clock. Fractional accumulators, not dividers:
    //
    //   Z80  14.318181/4 = 3.579545 MHz -> 3579545.25/49152000 * 2^24 = 1221797
    //   AY   14.318181/8 = 1.789773 MHz -> derived as cen_z80/2, which is
    //        EXACT and preserves the hardware's 2:1 relationship for free.
    //   ay1  1.94 MHz on exctsccr only — the melody AY's clock is set by a
    //        VR pot (0.9-3.9 MHz); 1.94 MHz is the factory mark MAME reads
    //        (:1119-1120). 8.4% off the others, ~1.4 semitones, so it is
    //        audible and worth its own accumulator.
    ////////////////////////////////////////////////////////////////////////

    localparam [24:0] INC_Z80 = 25'd1221797;   // -> 3579545.6 Hz  (err 0.4 Hz)
    localparam [24:0] INC_AY1 = 25'd662263;    // -> 1940003   Hz  (err 3   Hz)

    reg [24:0] acc_z80 = 25'd0;
    reg [24:0] acc_ay1 = 25'd0;
    always_ff @(posedge clk) begin
        acc_z80 <= {1'b0, acc_z80[23:0]} + INC_Z80;
        acc_ay1 <= {1'b0, acc_ay1[23:0]} + INC_AY1;
    end

    wire cen_z80 = acc_z80[24];

    reg ay_tog = 1'b0;
    always_ff @(posedge clk) if (cen_z80) ay_tog <= ~ay_tog;

    wire cen_ay  = cen_z80 & ay_tog;                    // 1.789773 MHz
    wire cen_ay1 = is_exctscc2 ? cen_ay : acc_ay1[24];  // VR pot on exctsccr

    ////////////////////////////////////////////////////////////////////////
    // Interrupts (:1091-1095).
    //
    //   NMI  4 kHz  — "updates the dac". nmi_line_pulse, so edge-triggered.
    //   IRQ  75 Hz  — "irq source unknown, determines music tempo".
    //                 set_input_line_and_vector(0, HOLD_LINE, 0xff): the line
    //                 is HELD until the CPU acknowledges, so it is cleared on
    //                 the interrupt-acknowledge cycle, not after a fixed time.
    //                 Vector 0xFF is irrelevant — $0038 is populated, so the
    //                 firmware runs IM1 and the vector is never fetched.
    //
    // Both divide the 49.152 MHz clock EXACTLY, no fractional term needed:
    //   49152000/4000 = 12288      49152000/75 = 655360
    ////////////////////////////////////////////////////////////////////////

    localparam [13:0] NMI_DIV = 14'd12287;    // 12288 counts, 0-based
    localparam [19:0] IRQ_DIV = 20'd655359;   // 655360 counts, 0-based

    reg [13:0] nmi_div_cnt = 14'd0;
    reg [19:0] irq_div_cnt = 20'd0;
    wire nmi_tick = (nmi_div_cnt == 14'd0);
    wire irq_tick = (irq_div_cnt == 20'd0);

    always_ff @(posedge clk) begin
        if (reset) begin
            nmi_div_cnt <= NMI_DIV;
            irq_div_cnt <= IRQ_DIV;
        end else begin
            nmi_div_cnt <= nmi_tick ? NMI_DIV : (nmi_div_cnt - 14'd1);
            irq_div_cnt <= irq_tick ? IRQ_DIV : (irq_div_cnt - 20'd1);
        end
    end

    wire [15:0] A;
    wire  [7:0] cpu_dout;
    wire        mreq_n, iorq_n, rd_n, wr_n, m1_n;

    // Interrupt acknowledge: IORQ with M1 low (never a real I/O cycle).
    wire int_ack = cen_z80 & ~iorq_n & ~m1_n;

    reg int_n_r = 1'b1;
    always_ff @(posedge clk) begin
        if (reset)         int_n_r <= 1'b1;
        else if (irq_tick) int_n_r <= 1'b0;   // HOLD_LINE
        else if (int_ack)  int_n_r <= 1'b1;
    end

    // NMI is edge-triggered; hold low long enough for the Z80 to latch it.
    // 15 cen_z80 ticks, released ~880 ticks before the next 4 kHz pulse.
    reg [3:0] nmi_cnt = 4'd0;
    always_ff @(posedge clk) begin
        if (reset)                          nmi_cnt <= 4'd0;
        else if (nmi_tick)                  nmi_cnt <= 4'hF;
        else if (cen_z80 && nmi_cnt != 4'd0) nmi_cnt <= nmi_cnt - 4'd1;
    end
    wire nmi_n_r = (nmi_cnt == 4'd0);

    ////////////////////////////////////////////////////////////////////////
    // Memory decode — exctsccr_sound_map (:670)
    //
    //   0000-8FFF  ROM   (36 KB: 4 x 0x2000 + 1 x 0x1000, ROM_START :1401)
    //   A000-A7FF  RAM   (2 KB)
    //   C008       W  DAC1
    //   C009       W  DAC2
    //   C00C       W  soundlatch clear
    //   C00D       R  soundlatch
    //
    // MAME declares NO mirrors on this map (unlike champbas, which mirrors
    // everything by 0x1FFF), so these are decoded exactly. The C00x accesses
    // are full-address compares for the same reason.
    ////////////////////////////////////////////////////////////////////////

    wire mem_wr = ~mreq_n & ~wr_n;

    wire cs_rom     = (A[15:12] <= 4'h8);              // 0000-8FFF
    wire cs_ram     = (A[15:11] == 5'b1010_0);         // A000-A7FF
    wire cs_dac1    = (A == 16'hC008);
    wire cs_dac2    = (A == 16'hC009);
    wire cs_latchcl = (A == 16'hC00C);
    wire cs_latchrd = (A == 16'hC00D);

    assign rom_addr = A;

    ////////////////////////////////////////////////////////////////////////
    // Sound latch. Written by the MAIN CPU at $A080, read here at $C00D,
    // cleared by this CPU writing $C00C.
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] latch_reg = 8'd0;

    always_ff @(posedge clk) begin
        if (reset)                               latch_reg <= 8'd0;
        else if (sound_latch_wr)                 latch_reg <= sound_latch;
        else if (cen_z80 & mem_wr & cs_latchcl)  latch_reg <= 8'd0;
    end

    ////////////////////////////////////////////////////////////////////////
    // Two 6-bit R2R DACs (:1128-1129). Same convention as the champbas DAC,
    // which is HW-confirmed: the low 6 bits are the payload, 0x20 is mid.
    ////////////////////////////////////////////////////////////////////////

    reg [5:0] dac1_reg = 6'd32;
    reg [5:0] dac2_reg = 6'd32;

    always_ff @(posedge clk) begin
        if (reset) begin
            dac1_reg <= 6'd32;
            dac2_reg <= 6'd32;
        end else if (cen_z80 & mem_wr) begin
            if (cs_dac1) dac1_reg <= cpu_dout[5:0];
            if (cs_dac2) dac2_reg <= cpu_dout[5:0];
        end
    end

    wire signed [16:0] dac1_signed = ($signed({10'd0, dac1_reg}) - 17'sd32) <<< 10;
    wire signed [16:0] dac2_signed = ($signed({10'd0, dac2_reg}) - 17'sd32) <<< 10;

    ////////////////////////////////////////////////////////////////////////
    // Work RAM — A000-A7FF (2 KB)
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] ram_dout;

    dpram_dc #(.widthad_a(11), .width_a(8)) sound_ram
    (
        .clock_a(clk),
        .address_a(A[10:0]),
        .data_a(cpu_dout),
        .wren_a(cen_z80 & mem_wr & cs_ram),
        .q_a(ram_dout),

        .clock_b(clk),
        .address_b(11'd0),
        .data_b(8'd0),
        .wren_b(1'b0),
        .q_b()
    );

    ////////////////////////////////////////////////////////////////////////
    // AY-3-8910 x4 on Z80 I/O SPACE (:681, :690) — not memory-mapped.
    //
    // map.global_mask(0x00ff) so only A[7:0] decodes, and every AY uses
    // ay8910_device::data_address_w => even = DATA, odd = ADDRESS latch,
    // i.e. bc1 = A[0], same convention as champbas's $7000/$7001.
    //
    //            exctsccr        exctscc2
    //     ay1    0x82/0x83       0x8a/0x8b
    //     ay2    0x86/0x87       0x8e/0x8f
    //     ay3    0x8a/0x8b       (removed)
    //     ay4    0x8e/0x8f       (removed)
    //
    // NOTE the overlap: Soccer II's ay1/ay2 sit on exctsccr's ay3/ay4
    // addresses. Decode must therefore be selected by set, not merged.
    ////////////////////////////////////////////////////////////////////////

    wire io_wr = cen_z80 & ~iorq_n & ~wr_n & m1_n;

    wire hit_82 = io_wr & (A[7:1] == 7'b1000_001);   // 0x82/0x83
    wire hit_86 = io_wr & (A[7:1] == 7'b1000_011);   // 0x86/0x87
    wire hit_8a = io_wr & (A[7:1] == 7'b1000_101);   // 0x8a/0x8b
    wire hit_8e = io_wr & (A[7:1] == 7'b1000_111);   // 0x8e/0x8f

    wire ay1_wr = is_exctscc2 ? hit_8a : hit_82;
    wire ay2_wr = is_exctscc2 ? hit_8e : hit_86;
    wire ay3_wr = is_exctscc2 ? 1'b0   : hit_8a;
    wire ay4_wr = is_exctscc2 ? 1'b0   : hit_8e;

    wire [7:0] ay1A, ay1B, ay1C, ay2A, ay2B, ay2C;
    wire [7:0] ay3A, ay3B, ay3C, ay4A, ay4B, ay4C;

    es_ay ay1 (.clk(clk), .rst_n(~reset), .cen(cen_ay1),
               .wr(ay1_wr), .a0(A[0]), .din(cpu_dout), .A(ay1A), .B(ay1B), .C(ay1C));
    es_ay ay2 (.clk(clk), .rst_n(~reset), .cen(cen_ay),
               .wr(ay2_wr), .a0(A[0]), .din(cpu_dout), .A(ay2A), .B(ay2B), .C(ay2C));
    es_ay ay3 (.clk(clk), .rst_n(~reset), .cen(cen_ay),
               .wr(ay3_wr), .a0(A[0]), .din(cpu_dout), .A(ay3A), .B(ay3B), .C(ay3C));
    es_ay ay4 (.clk(clk), .rst_n(~reset), .cen(cen_ay),
               .wr(ay4_wr), .a0(A[0]), .din(cpu_dout), .A(ay4A), .B(ay4B), .C(ay4C));

    ////////////////////////////////////////////////////////////////////////
    // DC removal — same shaping as the champbas board (raw byte into bit 5).
    ////////////////////////////////////////////////////////////////////////

    reg div = 1'b0;
    always_ff @(posedge clk) div <= ~div;
    wire cen_dcrm = ~div;

    wire signed [15:0] d1A, d1B, d1C, d2A, d2B, d2C;
    wire signed [15:0] d3A, d3B, d3C, d4A, d4B, d4C;

    jt49_dcrm2 #(16) r1A (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay1A, 5'd0}), .dout(d1A));
    jt49_dcrm2 #(16) r1B (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay1B, 5'd0}), .dout(d1B));
    jt49_dcrm2 #(16) r1C (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay1C, 5'd0}), .dout(d1C));
    jt49_dcrm2 #(16) r2A (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay2A, 5'd0}), .dout(d2A));
    jt49_dcrm2 #(16) r2B (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay2B, 5'd0}), .dout(d2B));
    jt49_dcrm2 #(16) r2C (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay2C, 5'd0}), .dout(d2C));
    jt49_dcrm2 #(16) r3A (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay3A, 5'd0}), .dout(d3A));
    jt49_dcrm2 #(16) r3B (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay3B, 5'd0}), .dout(d3B));
    jt49_dcrm2 #(16) r3C (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay3C, 5'd0}), .dout(d3C));
    jt49_dcrm2 #(16) r4A (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay4A, 5'd0}), .dout(d4A));
    jt49_dcrm2 #(16) r4B (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay4B, 5'd0}), .dout(d4B));
    jt49_dcrm2 #(16) r4C (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay4C, 5'd0}), .dout(d4C));

    ////////////////////////////////////////////////////////////////////////
    // Mix. MAME (:1120-1129): each AY 0.08, each DAC 0.3
    //   => DAC 0.6 total vs AY 0.32 total, i.e. ~65% / ~35%.
    //
    // Following the champbas board's GAIN-FIX lesson: scale ONCE, and size
    // the budget so the sum provably cannot clip.
    //     DAC : 2 x 32768 x 0.3125 = 20480   (63%)
    //     AY  : 12 x 4080 x 0.25   = 12240   (37%)
    //                        worst  = 32720  <  32767
    // Both factors are shift-adds, no multiplier. Ratio lands within 2% of
    // MAME's.
    //
    // Soccer II sums 6 AY channels instead of 12, so it is quieter here —
    // which is correct, it genuinely has half the chips.
    //
    // #unverified: the RATIO comes from the MAME machine config, not a board.
    // Tune by ear if the DACs swamp the melody or vice versa.
    ////////////////////////////////////////////////////////////////////////

    wire signed [19:0] ay_sum = {{4{d1A[15]}}, d1A} + {{4{d1B[15]}}, d1B} + {{4{d1C[15]}}, d1C}
                              + {{4{d2A[15]}}, d2A} + {{4{d2B[15]}}, d2B} + {{4{d2C[15]}}, d2C}
                              + {{4{d3A[15]}}, d3A} + {{4{d3B[15]}}, d3B} + {{4{d3C[15]}}, d3C}
                              + {{4{d4A[15]}}, d4A} + {{4{d4B[15]}}, d4B} + {{4{d4C[15]}}, d4C};

    wire signed [19:0] dac_sum = {{3{dac1_signed[16]}}, dac1_signed}
                               + {{3{dac2_signed[16]}}, dac2_signed};

    wire signed [19:0] mix = (dac_sum >>> 2) + (dac_sum >>> 4)   // DAC x 0.3125
                           + (ay_sum  >>> 2);                    // AY  x 0.25

    assign sound_out = pause ? 16'sd0 : mix[15:0];

    ////////////////////////////////////////////////////////////////////////
    // CPU read mux + Z80
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] cpu_din;

    always_comb begin
        if      (cs_rom)     cpu_din = rom_data;
        else if (cs_ram)     cpu_din = ram_dout;
        else if (cs_latchrd) cpu_din = latch_reg;
        else                 cpu_din = 8'hFF;
    end

    T80s cpu
    (
        .RESET_n(~reset),
        .CLK(clk),
        .CEN(cen_z80 & ~pause),
        .WAIT_n(1'b1),
        .INT_n(int_n_r),
        .NMI_n(nmi_n_r),
        .BUSRQ_n(1'b1),
        .M1_n(m1_n),
        .MREQ_n(mreq_n),
        .IORQ_n(iorq_n),
        .RD_n(rd_n),
        .WR_n(wr_n),
        .A(A),
        .DI(cpu_din),
        .DO(cpu_dout)
    );

endmodule


//============================================================================
//  One AY-3-8910 with a stretched write strobe.
//
//  The strobe MUST be stretched — this is the lesson the champbas board
//  already paid for (ChampionBaseball_SND.sv:137): the Z80 write pulse is a
//  handful of clk cycles while cen_ay is only 1-in-27 here, so driving bdir
//  straight off the decode can miss the chip entirely. Held until a cen tick
//  consumes it.
//============================================================================

module es_ay
(
    input        clk,
    input        rst_n,
    input        cen,
    input        wr,          // already gated by cen_z80
    input        a0,          // 0 = data write, 1 = address latch
    input  [7:0] din,
    output [7:0] A,
    output [7:0] B,
    output [7:0] C
);

    reg       pending = 1'b0;
    reg       bc1_lat = 1'b0;
    reg [7:0] din_lat = 8'd0;

    always_ff @(posedge clk) begin
        if (!rst_n) pending <= 1'b0;
        else if (wr) begin
            pending <= 1'b1;
            bc1_lat <= a0;      // address latch = bc1 high
            din_lat <= din;
        end else if (cen) pending <= 1'b0;
    end

    jt49_bus #(.COMP(3'b100)) u
    (
        .rst_n  (rst_n),
        .clk    (clk),
        .clk_en (cen),
        .bdir   (pending),
        .bc1    (bc1_lat),
        .din    (din_lat),
        .sel    (1'b1),
        .dout   (),
        .A      (A),
        .B      (B),
        .C      (C),
        .IOA_in (8'hFF),
        .IOB_in (8'hFF)
    );

endmodule
