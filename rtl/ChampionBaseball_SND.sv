//============================================================================
//
//  ChampionBaseball_SND.sv
//
//  Sound for the Alpha Denshi champbas.cpp hardware.
//  MAME reference: champbas_sound_map :659, machine cfg :980-1004
//  Verified against Useful Information/disassembly/champbas_audiocpu.dasm
//
//  Z80 @ XTAL 18.432/6 = 3.072 MHz driving a 6-bit R2R DAC, plus an
//  AY-3-8910 @ 18.432/12 = 1.536 MHz.
//
//  !! The AY is NOT on this board on real hardware — it sits on the MAIN board
//  and is written by the MAIN CPU at $7000/$7001 (champbas.cpp:579). It is
//  instantiated here only so all audio lives in one place; its register writes
//  arrive via ay_* from ChampionBaseball_MAIN. The sound CPU drives ONLY the DAC.
//
//  champbas has NO sound interrupt — the audio CPU polls the latch (`di` at
//  $0000 in the dasm, and champbas() configures no timer). exctsccr differs:
//  it adds a 4 kHz NMI and a 75 Hz timer IRQ (:1091-1095).
//
//============================================================================

module ChampionBaseball_SND
(
    input                clk,
    input                cen_cpu,        // 3.072 MHz
    input                cen_ay,         // 1.536 MHz
    input                reset,
    input                pause,

    // ---- from the main board
    input         [7:0]  sound_latch,
    input                sound_latch_wr,
    input         [7:0]  ay_din,
    input                ay_addr_wr,
    input                ay_data_wr,

    // ---- audio CPU ROM (champbas_rom index 1)
    output       [15:0]  rom_addr,
    input         [7:0]  rom_data,

    output signed [15:0] sound_out
);

    ////////////////////////////////////////////////////////////////////////
    // Address decode — champbas_sound_map (champbas.cpp:659)
    //
    //   0000-5FFF  ROM
    //   6000       R  soundlatch        (mirror 1FFF)
    //   8000       W  4-bit return code to main CPU — UNUSED (mirror 1FFF)
    //   A000       W  soundlatch clear  (mirror 1FFF)
    //   C000       W  DAC               (mirror 1FFF)
    //   E000-E3FF  RAM                  (mirror 1C00)
    //
    // Every region is 8KB-aligned once mirroring is applied, so A[15:13] alone
    // decodes it. Corroborated by the dasm: `ld sp,$E3FF` at $0001 puts the
    // stack at the top of RAM, and $0005/$0008/$0011 hit A000/8000/C000.
    ////////////////////////////////////////////////////////////////////////

    wire [15:0] A;
    wire  [7:0] cpu_dout;
    wire        mreq_n, iorq_n, rd_n, wr_n, m1_n;

    wire mem_wr = ~mreq_n & ~wr_n;

    wire cs_rom   = (A[15:13] <  3'b011);   // 0000-5FFF
    wire cs_latch = (A[15:13] == 3'b011);   // 6000-7FFF
    wire cs_ret   = (A[15:13] == 3'b100);   // 8000-9FFF (write-only, ignored)
    wire cs_clr   = (A[15:13] == 3'b101);   // A000-BFFF
    wire cs_dac   = (A[15:13] == 3'b110);   // C000-DFFF
    wire cs_ram   = (A[15:13] == 3'b111);   // E000-FFFF

    assign rom_addr = A;

    ////////////////////////////////////////////////////////////////////////
    // Sound latch (MAME GENERIC_LATCH_8).
    // Written by the MAIN CPU at $A080, read here at $6000, cleared by this
    // CPU writing $A000. The audio CPU clears it at boot ($0005).
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] latch_reg = 8'd0;

    always_ff @(posedge clk) begin
        if (reset)                          latch_reg <= 8'd0;
        else if (sound_latch_wr)            latch_reg <= sound_latch;
        else if (cen_cpu & mem_wr & cs_clr) latch_reg <= 8'd0;
    end

    ////////////////////////////////////////////////////////////////////////
    // 6-bit R2R DAC at $C000. The dasm initialises it to $20 at $000F-$0011,
    // exactly mid-scale for a 6-bit range (0..63) — which confirms the low 6
    // bits are the payload rather than the high 6.
    ////////////////////////////////////////////////////////////////////////

    reg [5:0] dac_reg = 6'd32;

    always_ff @(posedge clk) begin
        if (reset)                          dac_reg <= 6'd32;
        else if (cen_cpu & mem_wr & cs_dac) dac_reg <= cpu_dout[5:0];
    end

    // Centre on mid-scale, then scale to FULL 16-bit range: (-32..+31) << 10
    // gives -32768..+31744. Attenuation happens once, in the mix below.
    wire signed [16:0] dac_signed = ($signed({10'd0, dac_reg}) - 17'sd32) <<< 10;

    ////////////////////////////////////////////////////////////////////////
    // Work RAM — E000-E3FF (1KB)
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] ram_dout;

    dpram_dc #(.widthad_a(10), .width_a(8)) sound_ram
    (
        .clock_a(clk),
        .address_a(A[9:0]),
        .data_a(cpu_dout),
        .wren_a(cen_cpu & mem_wr & cs_ram),
        .q_a(ram_dout),

        .clock_b(clk),
        .address_b(10'd0),
        .data_b(8'd0),
        .wren_b(1'b0),
        .q_b()
    );

    ////////////////////////////////////////////////////////////////////////
    // AY-3-8910 (jt49 by Jotego). Pattern taken from the hardware-verified
    // TimePilot core (TimePilot_SND.sv:226): jt49_bus, sel=1, per-channel
    // outputs through jt49_dcrm2. TimePilot also runs on a 49 MHz clock.
    //
    // champbas uses ay8910_device::data_address_w, so $7000 = DATA and
    // $7001 = ADDRESS. In AY bus terms: address latch = {bdir,bc1} = 11,
    // data write = 10. champbb2j inverts the two, but MAIN already resolves
    // that from set_id, so the strobes arrive here already correct.
    //
    // The strobes MUST be stretched: the Z80 write pulse is ~24 clk wide while
    // cen_ay is 1-in-32, so driving bdir straight off the decode can miss the
    // AY entirely. Held until a cen_ay tick consumes it.
    ////////////////////////////////////////////////////////////////////////

    reg        ay_pending = 1'b0;
    reg        ay_bc1_lat = 1'b0;
    reg  [7:0] ay_din_lat = 8'd0;

    always_ff @(posedge clk) begin
        if (reset) ay_pending <= 1'b0;
        else if (ay_addr_wr | ay_data_wr) begin
            ay_pending <= 1'b1;
            ay_bc1_lat <= ay_addr_wr;      // address latch = bc1 high
            ay_din_lat <= ay_din;
        end else if (cen_ay) ay_pending <= 1'b0;
    end

    wire [7:0] ayA_raw, ayB_raw, ayC_raw;

    jt49_bus #(.COMP(3'b100)) ay
    (
        .rst_n  (~reset),
        .clk    (clk),
        .clk_en (cen_ay),
        .bdir   (ay_pending),
        .bc1    (ay_bc1_lat),
        .din    (ay_din_lat),
        .sel    (1'b1),
        .dout   (),
        .A      (ayA_raw),
        .B      (ayB_raw),
        .C      (ayC_raw),
        .IOA_in (8'hFF),
        .IOB_in (8'hFF)
    );

    // DC removal, same shaping as TimePilot: raw byte shifted up into 16 bits
    reg div = 1'b0;
    always_ff @(posedge clk) div <= ~div;
    wire cen_dcrm = ~div;

    wire signed [15:0] ayA_dc, ayB_dc, ayC_dc;

    jt49_dcrm2 #(16) dcrm_A
    ( .clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ayA_raw, 5'd0}), .dout(ayA_dc) );
    jt49_dcrm2 #(16) dcrm_B
    ( .clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ayB_raw, 5'd0}), .dout(ayB_dc) );
    jt49_dcrm2 #(16) dcrm_C
    ( .clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ayC_raw, 5'd0}), .dout(ayC_dc) );

    ////////////////////////////////////////////////////////////////////////
    // Mix. MAME routes the AY at 0.3 and the DAC at 0.7 (:1002, :1004), so the
    // DAC is the dominant voice — most of champbas's audio is sampled speech
    // and effects through the DAC, not AY tones.
    //
    // GAIN-FIX-2026-07-30: HW-confirmed "correct sounds but volume kinda low".
    // The first version attenuated TWICE — each AY channel ended at 1/8 and the
    // DAC at 1/4 of full scale. Now each source is scaled ONCE, with the budget
    // worked out so the sum cannot exceed 16 bits:
    //     DAC : +/-32768 x 0.75 = +/-24576   (~76% of the mix)
    //     AY  : 3 x +/-4080 = +/-12240 x 0.625 = +/-7650  (~24%)
    //     worst case 24576 + 7650 = 32226  <  32767, so it cannot clip
    // That split lands close to MAME's 0.7/0.3 without needing a multiplier.
    // Net change: DAC ~3x louder, AY ~5x louder.
    //
    // #unverified: the RATIO is from the MAME machine config, not a real board.
    // Tune by ear if the AY drowns out the DAC or vice versa.
    ////////////////////////////////////////////////////////////////////////

    wire signed [17:0] ay_sum = {{2{ayA_dc[15]}}, ayA_dc}
                              + {{2{ayB_dc[15]}}, ayB_dc}
                              + {{2{ayC_dc[15]}}, ayC_dc};

    wire signed [17:0] dac_x  = {dac_signed[16], dac_signed};

    wire signed [17:0] mix = (dac_x  >>> 1) + (dac_x  >>> 2)     // DAC x 0.75
                           + (ay_sum >>> 1) + (ay_sum >>> 3);    // AY  x 0.625

    assign sound_out = pause ? 16'sd0 : mix[15:0];

    ////////////////////////////////////////////////////////////////////////
    // CPU read mux + Z80
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] cpu_din;

    always_comb begin
        if      (cs_rom)   cpu_din = rom_data;
        else if (cs_latch) cpu_din = latch_reg;
        else if (cs_ram)   cpu_din = ram_dout;
        else               cpu_din = 8'hFF;
    end

    T80s cpu
    (
        .RESET_n(~reset),
        .CLK(clk),
        .CEN(cen_cpu & ~pause),
        .WAIT_n(1'b1),
        .INT_n(1'b1),          // champbas has no sound IRQ — the CPU polls
        .NMI_n(1'b1),
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
