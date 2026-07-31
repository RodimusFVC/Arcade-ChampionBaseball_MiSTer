//============================================================================
//
//  champbas_rom — ROM/BRAM regions for the Champion Baseball core
//  MAME driver: champbas.cpp (Champion Base Ball, Champion Base Ball Part-2,
//  Talbot, Exciting Soccer / Exciting Soccer II)
//
//  Pure download target + read ports. No game logic, no per-set
//  special-casing — deliberately set-agnostic. Region sizes are the max
//  across the whole 15-set driver, rounded up to the nearest power of 2
//  (dpram_dc / altsyncram require power-of-2 depths).
//
//  ioctl_addr restarts at 0 for every ioctl_index (MiSTer HPS convention).
//  Index map (see releases/Champion Base Ball.mra, releases/Exciting Soccer.mra):
//    0 maincpu   1 audiocpu   2 gfx_p01   3 hiscore cfg (elsewhere)
//    4 nvram (elsewhere)      5 set-id byte (below)      6 mcu
//    7 prom      8 gfx_p3     9 gfx3
//
//============================================================================

module champbas_rom
(
    input               clk,          // core/CPU clock, read side
    input               clk_dl,       // download clock (clk_sys), write side

    // ioctl download
    input               ioctl_download,
    input        [7:0]  ioctl_index,
    input        [24:0] ioctl_addr,
    input        [7:0]  ioctl_data,
    input               ioctl_wr,

    output logic [7:0]  set_id,       // from index 5

    // read ports (one per region)
    input        [14:0] maincpu_addr,   output [7:0] maincpu_data,
    input        [15:0] audiocpu_addr,  output [7:0] audiocpu_data,
    input        [13:0] gfx_p01_addr,   output [7:0] gfx_p01_data,
    input        [12:0] mcu_addr,       output [7:0] mcu_data,
    input         [9:0] prom_addr,      output [7:0] prom_data,
    input        [12:0] gfx_p3_addr,    output [7:0] gfx_p3_data,
    input        [12:0] gfx3_addr,      output [7:0] gfx3_data
);

    ////////////////////////////////////////////////////////////////////////
    // Per-region download write strobes
    ////////////////////////////////////////////////////////////////////////

    wire wr_maincpu  = ioctl_wr && ioctl_download && (ioctl_index == 8'd0);
    wire wr_audiocpu = ioctl_wr && ioctl_download && (ioctl_index == 8'd1);
    wire wr_gfx_p01  = ioctl_wr && ioctl_download && (ioctl_index == 8'd2);
    wire wr_mcu      = ioctl_wr && ioctl_download && (ioctl_index == 8'd6);
    wire wr_prom     = ioctl_wr && ioctl_download && (ioctl_index == 8'd7);
    wire wr_gfx_p3   = ioctl_wr && ioctl_download && (ioctl_index == 8'd8);
    wire wr_gfx3     = ioctl_wr && ioctl_download && (ioctl_index == 8'd9);

    // Index 3 (hiscore cfg) and index 4 (nvram) are handled elsewhere —
    // intentionally no write-enable / region here.

    ////////////////////////////////////////////////////////////////////////
    // Index 5 — set-id byte (NOT a BRAM region). Single byte, address 0.
    // Enumeration copied from releases/Champion Base Ball.mra's index-5 comment:
    //   0x00 champbas    0x01 champbasj   0x02 champbasja  0x03 champbasjb
    //   0x04 champbb2    0x05 champbb2j   0x06 tbasebal    0x07 talbot
    //   0x08 exctsccr    0x09 exctscc2    0x0A exctsccrb
    //
    // GAMESEL-FIX precedent (Arcade-ChampionBaseball.sv:350-361, dated
    // 2026-06-21): a "reset to 0 on every ioctl_download rising edge" was
    // tried for this exact index-5-byte-capture shape and reverted — the
    // index-4 NVRAM load fires its OWN separate ioctl_download transaction
    // AFTER the ROM/set-id download finishes, re-raising ioctl_download and
    // clobbering the already-captured byte back to 0. Fix was simple
    // capture-on-write with no active reset, relying on the register's
    // power-up initial value for the "no index-5 byte in this MRA" case.
    // Mirrored here for the same reason: initial value covers "reset to 0"
    // for MRAs without an index-5 part; no per-download-start reset.
    ////////////////////////////////////////////////////////////////////////

    wire wr_set_id = ioctl_wr && ioctl_download && (ioctl_index == 8'd5) && (ioctl_addr == 25'd0);

    initial set_id = 8'd0;
    always @(posedge clk_dl) begin
        if (wr_set_id) set_id <= ioctl_data;
    end

    ////////////////////////////////////////////////////////////////////////
    // Index 0 — maincpu: MAME ROM_REGION "maincpu", main Z80 program.
    // Max real use 0x8000 (champbb2, non-contiguous — padded in its MRA).
    ////////////////////////////////////////////////////////////////////////

    dpram_dc #(.widthad_a(15), .width_a(8)) maincpu_rom
    (
        .clock_a(clk),
        .address_a(maincpu_addr),
        .q_a(maincpu_data),

        .clock_b(clk_dl),
        .address_b(ioctl_addr[14:0]),
        .data_b(ioctl_data),
        .wren_b(wr_maincpu)
    );

    ////////////////////////////////////////////////////////////////////////
    // Index 1 — audiocpu: MAME ROM_REGION "audiocpu", audio Z80 program.
    // Max real use 0x9000 (exctsccr, 5-part region). Rounded up to a 64K
    // (widthad_a=16) BRAM because dpram_dc / altsyncram only support
    // power-of-2 depths (numwords_a => 2**widthad_a) — ~28K of this BRAM
    // is unused padding. Known optimisation target if BRAM gets tight.
    ////////////////////////////////////////////////////////////////////////

    dpram_dc #(.widthad_a(16), .width_a(8)) audiocpu_rom
    (
        .clock_a(clk),
        .address_a(audiocpu_addr),
        .q_a(audiocpu_data),

        .clock_b(clk_dl),
        .address_b(ioctl_addr[15:0]),
        .data_b(ioctl_data),
        .wren_b(wr_audiocpu)
    );

    ////////////////////////////////////////////////////////////////////////
    // Index 2 — gfx_p01: MAME ROM_REGION "gfx1"/"gfx2", planes 0/1 of
    // chars+sprites. De-interleaved by the MRA (<part offset/length>,
    // reproducing init_champbas()/the planes-0/1 half of init_exctsccr());
    // stored VERBATIM here, no rearrangement in RTL. Chars/sprites split on
    // an address bit downstream (0x2000 for champbas family, 0x1000 for
    // Talbot per the set-id) — not this module's concern.
    ////////////////////////////////////////////////////////////////////////

    dpram_dc #(.widthad_a(14), .width_a(8)) gfx_p01_rom
    (
        .clock_a(clk),
        .address_a(gfx_p01_addr),
        .q_a(gfx_p01_data),

        .clock_b(clk_dl),
        .address_b(ioctl_addr[13:0]),
        .data_b(ioctl_data),
        .wren_b(wr_gfx_p01)
    );

    ////////////////////////////////////////////////////////////////////////
    // Index 6 — mcu: MAME ROM_REGION "alpha_8201:mcu", ALPHA-8201/8302/8303
    // (HMCS40) program ROM for Talbot / Exciting Soccer family. Absent for
    // champbas/champbb2 (no MCU on that hardware) — region simply stays at
    // its power-up/uninitialized content when unused.
    ////////////////////////////////////////////////////////////////////////

    dpram_dc #(.widthad_a(13), .width_a(8)) mcu_rom
    (
        .clock_a(clk),
        .address_a(mcu_addr),
        .q_a(mcu_data),

        .clock_b(clk_dl),
        .address_b(ioctl_addr[12:0]),
        .data_b(ioctl_data),
        .wren_b(wr_mcu)
    );

    ////////////////////////////////////////////////////////////////////////
    // Index 7 — prom: MAME ROM_REGION "proms", colour PROMs (palette +
    // pen->color LUT, one or two PROMs depending on set). Max real use
    // 0x220 (exctsccr: 3 PROMs).
    ////////////////////////////////////////////////////////////////////////

    dpram_dc #(.widthad_a(10), .width_a(8)) prom_rom
    (
        .clock_a(clk),
        .address_a(prom_addr),
        .q_a(prom_data),

        .clock_b(clk_dl),
        .address_b(ioctl_addr[9:0]),
        .data_b(ioctl_data),
        .wren_b(wr_prom)
    );

    ////////////////////////////////////////////////////////////////////////
    // Index 8 — gfx_p3: gfx1's plane-3 source ROM (e.g. 6_c5.bin), stored
    // VERBATIM with no offset/length. init_exctsccr() (champbas.cpp) turns
    // this single byte source into two nibble-addressed destination bytes —
    // an MRA/loader can't express a nibble split, so this module just
    // stores the raw ROM image; the nibble select (addr>=0x1000 ? high :
    // low nibble of gfx_p3_rom[addr & 0xFFF]) happens downstream at fetch
    // time, not here.
    ////////////////////////////////////////////////////////////////////////

    dpram_dc #(.widthad_a(13), .width_a(8)) gfx_p3_rom
    (
        .clock_a(clk),
        .address_a(gfx_p3_addr),
        .q_a(gfx_p3_data),

        .clock_b(clk_dl),
        .address_b(ioctl_addr[12:0]),
        .data_b(ioctl_data),
        .wren_b(wr_gfx_p3)
    );

    ////////////////////////////////////////////////////////////////////////
    // Index 9 — gfx3: MAME ROM_REGION "gfx3", 4bpp sprites. Exciting
    // Soccer family only (verbatim, ROM_START order) — absent for
    // champbas/champbb2/Talbot.
    ////////////////////////////////////////////////////////////////////////

    dpram_dc #(.widthad_a(13), .width_a(8)) gfx3_rom
    (
        .clock_a(clk),
        .address_a(gfx3_addr),
        .q_a(gfx3_data),

        .clock_b(clk_dl),
        .address_b(ioctl_addr[12:0]),
        .data_b(ioctl_data),
        .wren_b(wr_gfx3)
    );

endmodule
