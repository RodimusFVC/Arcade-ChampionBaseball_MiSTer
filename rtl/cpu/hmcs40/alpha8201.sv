//============================================================================
//
//  alpha8201 — ALPHA-8201 protection MCU wrapper (Champion Base Ball /
//  Exciting Soccer / Talbot family).
//
//  Ported from MAME's alpha8201.cpp (license BSD-3-Clause, copyright hap),
//  staged at Useful Information/mame/alpha8201.{cpp,h}. Every behavioural
//  claim in this file's comments cites a line in that staged source.
//
//  The ALPHA-8201 "isn't a real CPU. It is a Hitachi HD44801 4-bit MCU,
//  programmed to interpret an external program using a custom instruction
//  set" (alpha8201.cpp:9-10). This module is the GLUE around the generic
//  hmcs40 core in this directory: 1KB RAM shared between the Z80 and the
//  MCU, bus-direction arbitration, and R0-R3/D-port address+data-bus
//  emulation exactly as alpha8201.cpp models it (alpha8201.cpp:344-428).
//
//  STANDALONE / NOT WIRED IN: per the task brief, this file does not touch
//  champbas_map, files.qip or the qsf. Integration point (for whoever wires
//  this in later):
//    - mcu_addr/mcu_data  -> rtl/ram_rom/champbas_rom.sv's existing
//      mcu_addr[12:0]/mcu_data[7:0] port (index 6, already staged there,
//      NOT modified by this task — see that file's header comment).
//    - ext_addr/ext_din/ext_dout/ext_we -> champbas_map 0x6000-0x63FF
//      (champbas.cpp:599, ext_ram_r/ext_ram_w).
//    - mcu_start/bus_dir -> LS259 mainlatch Q6/Q7 (champbas.cpp:935-936).
//    - cen: this module needs a ~96kHz-equivalent machine-cycle enable
//      (XTAL(18.432MHz)/6/8/4, champbas.cpp:938 ALPHA_8201 clock, /4 for
//      hmcs40's "4 clocks per machine cycle", hmcs40.h:113). Generated
//      internally from `clk` via CEN_DIV; default 511 assumes clk=CLK_49M
//      (49.152MHz, Arcade-ChampionBaseball.sv:110/275) -> 49.152e6/512 =
//      96000 Hz. BELIEVED correct arithmetic, not measured on hardware.
//
//============================================================================

module alpha8201 #(
    parameter [15:0] CEN_DIV = 16'd511   // clk cycles per machine-cycle tick, minus 1
) (
    input  wire        clk,
    input  wire        reset,

    // Z80-side control (LS259 mainlatch, champbas.cpp:935-936)
    input  wire        mcu_start,     // Q6 -> alpha_8201_device::mcu_start_w (INT0 pin)
    input  wire        bus_dir,       // Q7 -> alpha_8201_device::bus_dir_w (1=MCU owns shared RAM)

    // Z80-side shared RAM window (champbas_map 0x6000-0x63FF, 1KB,
    // alpha8201.cpp:418-428 ext_ram_r/ext_ram_w — "going by exctsccr,
    // m_bus has no effect here": Z80 access is unconditional regardless
    // of bus_dir, ported as-is even though it looks like it should be
    // gated — MAME's own comment says this was determined empirically).
    input  wire [9:0]  ext_addr,
    input  wire [7:0]  ext_din,
    output wire [7:0]  ext_dout,
    input  wire        ext_we,

    // MCU program ROM — byte-addressed, 1-cycle registered read latency,
    // pin-compatible with rtl/ram_rom/champbas_rom.sv's mcu_addr/mcu_data
    // (dpram_dc-backed, see that file and verilator/dpram_dc.v for the
    // exact timing model this bridges to).
    output wire [12:0] mcu_addr,
    input  wire [7:0]  mcu_data,

    // debug/observability
    output wire [10:0] dbg_pc,
    output wire [9:0]  dbg_op,
    output wire        dbg_illegal,
    output wire [9:0]  dbg_mcu_ram_addr,
    output wire        dbg_mcu_rd_en,
    output wire        dbg_mcu_wr_en
);

    // ------------------------------------------------------------------
    // Machine-cycle enable generator
    // ------------------------------------------------------------------
    reg [15:0] cen_cnt;
    reg        cen;
    always @(posedge clk) begin
        if (reset) begin
            cen_cnt <= 16'd0;
            cen <= 1'b0;
        end else begin
            cen <= 1'b0;
            if (cen_cnt == CEN_DIV) begin
                cen_cnt <= 16'd0;
                cen <= 1'b1;
            end else begin
                cen_cnt <= cen_cnt + 16'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // ROM bridge — hmcs40's word-space request/ack handshake to
    // champbas_rom's byte-addressed, 1-cycle-latency mcu_addr/mcu_data.
    // Two sequential byte reads (low byte @ word*2, high byte @ word*2+1,
    // little-endian per hmcs40.cpp's ENDIANNESS_LITTLE program space).
    // Always issued as soon as the core requests it — nothing here waits
    // on `cen`, so total turnaround is a handful of `clk` cycles, far
    // under one `cen` period (see hmcs40.sv's file header for why that
    // matters for prescaler/timer accuracy).
    // ------------------------------------------------------------------
    wire         core_rom_req;
    wire [11:0]  core_rom_addr;
    reg  [15:0]  core_rom_data;
    reg          core_rom_ack;

    localparam [1:0] RB_IDLE = 2'd0, RB_LO = 2'd1, RB_HI = 2'd2, RB_ACK = 2'd3;
    reg [1:0]  rb_state;
    reg [11:0] rb_word_addr;
    reg [7:0]  rb_lo;

    // NOTE: in RB_IDLE this must combinationally track core_rom_addr (not
    // the registered rb_word_addr, which is only latched ON the edge that
    // leaves RB_IDLE) — champbas_rom's dpram_dc samples address_a AT the
    // clock edge, so the low-byte address has to be valid *during* the
    // RB_IDLE cycle for the RB_LO cycle's mcu_data to come back correct.
    assign mcu_addr = (rb_state == RB_IDLE) ? {core_rom_addr, 1'b0} :
                                               {rb_word_addr, 1'b1};

    always @(posedge clk) begin
        if (reset) begin
            rb_state <= RB_IDLE;
            core_rom_ack <= 1'b0;
            rb_word_addr <= 12'h0;
        end else begin
            core_rom_ack <= 1'b0;
            case (rb_state)
                RB_IDLE: if (core_rom_req) begin
                    rb_word_addr <= core_rom_addr; // mcu_addr already reflects {addr,0} combinationally above
                    rb_state <= RB_LO;
                end
                RB_LO: begin
                    // mcu_data now valid for the LOW byte (address was
                    // presented last cycle); mcu_addr switches to the HIGH
                    // byte address this same cycle (see assign above).
                    rb_lo <= mcu_data;
                    rb_state <= RB_HI;
                end
                RB_HI: begin
                    // mcu_data now valid for the HIGH byte.
                    core_rom_data <= {mcu_data, rb_lo};
                    core_rom_ack  <= 1'b1;
                    rb_state <= RB_ACK;
                end
                RB_ACK: begin
                    rb_state <= RB_IDLE; // one idle cycle so a re-request sees a fresh IDLE sample
                end
                default: rb_state <= RB_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // R0-R7 / D0-D15 glue (alpha8201.cpp:320-330 device_add_mconfig +
    // 350-393 the actual handlers)
    // ------------------------------------------------------------------
    wire [3:0] r0_out, r1_out, r2_out, r3_out;
    wire [15:0] d_out;
    wire        mcu_d_we;   // WR-EVENT-FIX-2026-08-01: true D-write strobe
    wire        mcu_r_we;   // WR-EVENT-FIX rev2: true R-write strobe
    wire [2:0]  mcu_r_we_idx;

    // mcu_update_address() (alpha8201.cpp:357-361):
    //   m_mcu_address = (m_mcu_d<<8 & 0x300) | m_mcu_r[2]<<4 | m_mcu_r[3];
    wire [9:0] mcu_ram_addr = {d_out[1:0], r2_out, r3_out};

    // D2 = /RD (active low), D3 = WR (active high) — pinout table,
    // alpha8201.cpp:42-62 ("42: D2 /RD", "1: D3 WR").
    wire mcu_rd_en = bus_dir && ~d_out[2];                  // mcu_data_r gate, alpha8201.cpp:368
    wire mcu_wr_en = bus_dir && (d_out[3:2] == 2'b11);      // mcu_writeram gate, alpha8201.cpp:353

    assign dbg_mcu_ram_addr = mcu_ram_addr;
    assign dbg_mcu_rd_en    = mcu_rd_en;
    assign dbg_mcu_wr_en    = mcu_wr_en;

    reg [7:0] shared_ram [0:1023];

    // Z80 side — unconditional (alpha8201.cpp:418-428 comment: "going by
    // exctsccr, m_bus has no effect here").
    assign ext_dout = shared_ram[ext_addr];

    // MCU side — read (mcu_data_r, alpha8201.cpp:364-376): R0 gets the
    // high nibble, R1 the low nibble ("if(offset==0) ret>>=4").
    wire [7:0] mcu_ram_rd = shared_ram[mcu_ram_addr];
    // R-PORT-READBACK-FIX-2026-08-07 (part 2): MAME read_r() (hmcs40.cpp:387-396)
    // returns (callback_result & output_latch) for CMOS parts. HD44801 is
    // IS_CMOS (hmcs40.cpp:123), so m_polarity is truthy -> the AND branch.
    // GATE-CLOSED-FIX-2026-08-08: the 08-07 fix correctly ADDED `& rN_out`, but it
    // also changed the GATE-CLOSED fallback from 4'h0 to 4'hF, and that second
    // change is wrong.
    //
    // In MAME the read_r callback IS mcu_data_r (alpha8201.cpp:364-376), and that
    // function returns **0** when the gate is closed (`u8 ret = 0;`, only assigned
    // inside `if (m_bus && ~m_mcu_d & 4)`). read_r then ANDs the callback result
    // with the output latch (hmcs40.cpp:392-393), so MAME yields 0 & latch = 0.
    // Ours yielded 4'hF & rN_out = rN_out — the MCU read its own output latch back
    // instead of zero.
    //
    // ⚠️ Why this survived until now: it is INVISIBLE on exctsccr, which sets
    // bus_dir=1 at $01B7 and leaves it, so the gate is open for the whole run.
    // Talbot holds **bus_dir=0 from frame 50 to frame 300** (mainlatch 0x42/0x43),
    // so every R0/R1 port read across that window took the wrong branch. Same
    // silicon, same MCU image — a different usage path.
    //
    // ORIGINAL (pre-2026-08-07, missing the latch AND):
    // wire [3:0] r0_in = mcu_rd_en ? mcu_ram_rd[7:4] : 4'h0;
    // wire [3:0] r1_in = mcu_rd_en ? mcu_ram_rd[3:0] : 4'h0;
    // ORIGINAL (2026-08-07, latch AND correct but fallback wrong):
    // wire [3:0] r0_in = (mcu_rd_en ? mcu_ram_rd[7:4] : 4'hF) & r0_out;
    // wire [3:0] r1_in = (mcu_rd_en ? mcu_ram_rd[3:0] : 4'hF) & r1_out;
    wire [3:0] r0_in = (mcu_rd_en ? mcu_ram_rd[7:4] : 4'h0) & r0_out;
    wire [3:0] r1_in = (mcu_rd_en ? mcu_ram_rd[3:0] : 4'h0) & r1_out;

    // MCU side — write (mcu_writeram, alpha8201.cpp:350-355).
    //
    // WR-EVENT-FIX-2026-08-01 — this was LEVEL-triggered and that is wrong.
    // MAME calls mcu_writeram() from exactly TWO places:
    //     :360  mcu_d_w()    — after mcu_update_address() relatches the address
    //     :409  bus_dir_w()  — when the Z80 hands the bus over
    // so a write happens ONCE per event, with a settled address. Level-
    // triggering fired every clk while `bus_dir && d[3:2]==11` held, and
    // because mcu_ram_addr is built from d_out/r2/r3 — which change as the MCU
    // executes — it sprayed {R0,R1} across every address the ports transiently
    // passed through, corrupting shared RAM. Symptom: Talbot boots, coins up,
    // plays its tune, then locks the moment the protection routine starts
    // driving the ports (HW, 2026-08-01).
    //
    // d_we is a true write strobe from the core (SED/RED/SEDD/REDD), not a
    // value-change guess, so a same-value D rewrite still commits — matching
    // MAME, where write_d fires on every write.
    wire       bus_dir_edge = bus_dir & ~bus_dir_q;
    reg        bus_dir_q;
    always @(posedge clk) bus_dir_q <= bus_dir;

    // WR-EVENT-FIX-2026-08-01 rev2 — mcu_writeram() has THREE trigger paths in
    // MAME, not two. Both port writers funnel through mcu_update_address():
    //     mcu_data_w()  (write_r<0..3>, alpha8201.cpp:378-384) -> update_address -> writeram
    //     mcu_d_w()     (write_d,       :386-393)              -> update_address -> writeram
    //     bus_dir_w()   (:403-409)                             -> writeram directly
    // The MCU's natural sequence is R2/R3 (address) -> D (WR) -> R0/R1 (data),
    // so the commit that actually lands the byte is usually the R WRITE. rev1 of
    // this fix triggered on d_we|bus_dir only, dropped that trigger, and changed
    // nothing on hardware (Talbot still locked).
    // Only R0-R3 count: device_add_mconfig binds write_r<0..3> and nothing else.
    wire mcu_r03_we    = mcu_r_we & (mcu_r_we_idx <= 3'd3);
    wire mcu_wr_commit = mcu_wr_en & (mcu_d_we | mcu_r03_we | bus_dir_edge);

    // ------------------------------------------------------------------
    // SHARED-RAM-SINGLE-DRIVER-FIX-2026-08-01
    //
    // The Z80-side and MCU-side writes used to live in TWO SEPARATE always
    // blocks both driving `shared_ram`. That is multiple drivers on one array:
    // -- Verilator stays quiet only because this project's Makefile passes
    // -Wno-MULTIDRIVEN, and Quartus compiled it without inferring a single
    // shared memory — so the Z80 and the MCU were effectively writing into
    // different storage and could never see each other's data.
    //
    // That made the whole handshake dead regardless of WHEN the MCU committed,
    // which is why three successive write-trigger fixes (level -> d_we/bus_dir
    // -> +r_we) produced ZERO behavioural change on both talbot and exctsccr.
    //
    // Both writers now live in ONE block. Z80 has priority, matching MAME where
    // ext_ram_w is unconditional and the MCU's write is gated on m_bus.
    // (This is the same defect class the vault records for Kangaroo's mb88xx.v:
    // registers driven from more than one always block.)
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (ext_we)
            shared_ram[ext_addr]     <= ext_din;
        else if (mcu_wr_commit)
            shared_ram[mcu_ram_addr] <= {r0_out, r1_out};
    end

    // R2/R3 reads and R4-R7/D reads are all unbound in
    // device_add_mconfig (alpha8201.cpp:320-330 only binds read_r<0>,
    // read_r<1>, write_r<0..3>, write_d) -> external input side reads as
    // 0 for everything else, which the core's CMOS wired-AND polarity
    // (hmcs40.cpp:392-395) then ANDs down to a hard 0 regardless of the
    // port's own latch — bit-exact "unbound port reads 0" per MAME.
    hmcs40 u_mcu (
        .clk        (clk),
        .reset      (reset),
        .cen        (cen),
        .hlt_in     (1'b0),           // pin 19 !HLT tied to Vcc — never halted (alpha8201.cpp:52)

        .rom_req    (core_rom_req),
        .rom_addr   (core_rom_addr),
        .rom_data   (core_rom_data),
        .rom_ack    (core_rom_ack),

        // UNBOUND-PORT-READBACK-FIX-2026-08-01 --------------------------------
        // R2-R7 have NO read_r<> bind in device_add_mconfig, so they take MAME's
        // UNBOUND devcb_read default. These were tied to 4'h0, and with the CMOS
        // wired-AND in read_r (hmcs40.cpp: `return (inp & m_r[index]) & 0xf`)
        // that forces every read of R2-R7 to 0 no matter what the latch holds —
        // i.e. `LRA 4` followed by `LAR 4` cannot round-trip.
        //
        // That is invisible on the ALPHA-8201 (talbot / exctsccrb), which never
        // touches R2-R7 — which is exactly why talbot passes its self-test. The
        // ALPHA-8302 (exctsccr) DOES use R4/R5 as scratch: an opcode-word
        // set-diff of the two firmwares shows 00C4/00C5 (LAR 4/5) and 02C4/02C5
        // (LRA 4/5) present only in the 8302. With the reads stuck at 0 its
        // routine computes garbage and never writes the >=8 answer the Z80 spins
        // on at $0ECF -> "TESTING 6" hangs forever.
        //
        // 4'hF makes the wired-AND return the output latch, which is also what
        // an unconnected CMOS pin driven by its own latch does on real silicon.
        // Inferred from behaviour (MAME runs exctsccr correctly AND the 8302
        // does LRA/LAR round-trips, so its unbound read cannot be returning 0);
        // devcb.h is not staged here to confirm directly. #unverified
        //
        // R0/R1 are NOT changed: MAME binds read_r<0>/read_r<1> to mcu_data_r,
        // which genuinely returns 0 when not reading (alpha8201.cpp:364-376), so
        // r0_in/r1_in already match the reference exactly.
        // ---------------------------------------------------------------------
        // REVERTED 2026-08-02 — the 4'hF experiment above is DISPROVEN ON HW:
        // it entirely broke Talbot (which previously booted and played) and did
        // nothing for exctsccr. Talbot's 8201 therefore DOES read R2-R7 and
        // REQUIRES them to read 0 — which means MAME's unbound devcb_read
        // really does return 0, and the agent's original comment was right.
        // My behavioural inference ("MAME must return all-ones or LRA/LAR
        // round-trips would break") was WRONG: the 8302 evidently tolerates
        // LAR 4/5 reading 0, so R4/R5 are not scratch registers after all.
        // DO NOT retry this. Back to the correct 4'h0.
        // R-PORT-READBACK-FIX-2026-08-07: R2/R3 were tied to 0. MAME read_r()
        // (hmcs40.cpp:387-396) always combines the callback result with the
        // OUTPUT LATCH m_r[index], and alpha8201.cpp:323-328 binds only
        // read_r<0>/<1> — so R2/R3 read back their own output latch. R3 is the
        // shared-RAM address low nibble AND the firmware's counter storage
        // (LAR 3 -> AI 1 -> LRA 3); returning 0 froze it and hung TESTING 6.
        // R2/R3 readback is NOT the Talbot discriminator — tested both ways on HW:
        // 4'h0 gave a RANDOM crash, the latch readback gives a DETERMINISTIC one.
        // Neither works, and exctsccr/champbb2 need the readback. Do not revisit.
        // ORIGINAL: .r0_in(r0_in), .r1_in(r1_in), .r2_in(4'h0), .r3_in(4'h0),
        .r0_in(r0_in), .r1_in(r1_in), .r2_in(r2_out), .r3_in(r3_out),
        .r4_in(4'h0),  .r5_in(4'h0),  .r6_in(4'h0),  .r7_in(4'h0),
        .r0_out(r0_out), .r1_out(r1_out), .r2_out(r2_out), .r3_out(r3_out),
        .r4_out(), .r5_out(), .r6_out(), .r7_out(),

        // D-PORT-READBACK-FIX-2026-08-07: same bug as R2/R3. read_d IS unbound
        // (alpha8201.cpp:329 binds write_d only), and the core already applies
        // the CMOS wired-AND with the output latch (hmcs40.cpp:411-414,
        // m_polarity=IS_CMOS). Feeding 0 forced every D read to 0; all-ones
        // makes the AND return the latch, which is what MAME does.
        // ORIGINAL: .d_in       (16'h0),
        .d_in       (16'hFFFF),
        .d_out      (d_out),
        .d_we       (mcu_d_we),       // WR-EVENT-FIX-2026-08-01
        .r_we       (mcu_r_we),       // WR-EVENT-FIX rev2
        .r_we_idx   (mcu_r_we_idx),

        .int0_in    (mcu_start),      // pin 30 INT0 = GO (alpha8201.cpp:57)
        .int1_in    (1'b0),           // pin 31 INT1 = n.c. (alpha8201.cpp:58)

        .dbg_pc(dbg_pc), .dbg_op(dbg_op), .dbg_illegal(dbg_illegal),
        .dbg_a(), .dbg_b(), .dbg_x(), .dbg_y()
    );

endmodule
