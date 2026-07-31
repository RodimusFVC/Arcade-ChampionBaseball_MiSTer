//============================================================================
//
//  ChampionBaseball_MAIN.sv
//
//  Main CPU board for the Alpha Denshi champbas.cpp hardware.
//  MAME reference: champbas.cpp — champbas_map :576, machine cfg :964
//
//  Z80 @ XTAL 18.432 / 6 = 3.072 MHz, LS259 control latch, 32x32 tilemap,
//  8 hardware sprites, watchdog on a vblank counter.
//
//  NOTE: the AY-3-8910 lives on THIS board and is written by the MAIN CPU at
//  0x7000-0x7001 (champbas.cpp:579) — it is NOT on the sound board. The sound
//  CPU drives only the DAC. Register writes are handed out via ay_* below.
//
//  CLOCKING: this module is deliberately clock-agnostic. It takes a free
//  running `clk` plus two clock enables. The intended source is a 49.152 MHz
//  PLL output, which divides EXACTLY:
//      49.152 / 16 = 3.072 MHz  -> cen_cpu
//      49.152 /  8 = 6.144 MHz  -> cen_pix   (18.432/3, see the VIDEO module)
//  The inherited Kangaroo PLL emits 40 MHz / 10 MHz and cannot produce either;
//  reconfiguring it is a separate step. No fractional divider is needed once
//  the PLL is right.
//
//============================================================================

module ChampionBaseball_MAIN
(
    input                clk,
    input                cen_cpu,        // 3.072 MHz enable
    input                cen_pix,        // 6.144 MHz enable
    input                reset,
    input                pause,

    // ---- controls (active LOW at the port, as MAME reads them)
    input         [7:0]  p1,
    input         [7:0]  p2,
    input         [7:0]  dsw,            // bit 7 is REPLACED internally, see below
    input         [7:0]  system,

    input         [7:0]  set_id,         // MRA index 5

    // ---- main CPU ROM (champbas_rom index 0)
    output       [14:0]  rom_addr,
    input         [7:0]  rom_data,

    // ---- gfx + prom ports, passed through to the video module
    output       [13:0]  gfx_addr,
    input         [7:0]  gfx_data,
    output        [9:0]  prom_addr,
    input         [7:0]  prom_data,

    // ---- AY-3-8910 (main board, main CPU writes it)
    output        [7:0]  ay_din,
    output               ay_addr_wr,
    output               ay_data_wr,

    // ---- sound board latch
    output        [7:0]  sound_latch,
    output               sound_latch_wr,

    // ---- palette PROM download snoop, passed to the video module
    input                clk_dl,
    input                ioctl_download,
    input         [7:0]  ioctl_index,
    input        [24:0]  ioctl_addr,
    input         [7:0]  ioctl_data,
    input                ioctl_wr,

    // ---- video out
    output        [7:0]  video_r, video_g, video_b,
    output               video_hsync, video_vsync,
    output               video_hblank, video_vblank
);

    ////////////////////////////////////////////////////////////////////////
    // Address decode — champbas_map (champbas.cpp:576)
    //
    //   0000-5FFF  ROM
    //   7000-7001  (mirror 0FFE)  W  AY-3-8910 data_address_w
    //   8000-87FF  RW VRAM   (tilemap_w)
    //   8800-8FFF  RW main RAM   (8FF0-8FFF = sprite attribute table)
    //   A000       R  P1     | A000-A007  W  LS259 write_d0
    //   A040       R  P2     | A060-A06F  W  spriteram (x/y only)
    //   A080       R  DSW (mirror 0020) | A080  W  soundlatch
    //   A0C0       R  SYSTEM | A0C0      W  watchdog reset
    ////////////////////////////////////////////////////////////////////////

    wire [15:0] A;
    wire  [7:0] cpu_dout;
    wire        m1_n, mreq_n, iorq_n, rd_n, wr_n;

    wire cs_rom   = (A <  16'h6000);
    // 0x7000-0x7001 mirrored across 0x7000-0x7FFF (mirror mask 0x0FFE leaves A0 significant)
    wire cs_ay    = (A[15:12] == 4'h7);
    wire cs_vram  = (A[15:11] == 5'b1000_0);          // 8000-87FF
    wire cs_ram   = (A[15:11] == 5'b1000_1);          // 8800-8FFF
    wire cs_io    = (A[15:8]  == 8'hA0);

    wire mem_rd = ~mreq_n & ~rd_n;
    wire mem_wr = ~mreq_n & ~wr_n;

    // I/O sub-decode. A[7:6] picks the quadrant, matching MAME's A000/A040/A080/A0C0.
    wire io_q0 = cs_io & (A[7:6] == 2'b00);           // A000-A03F
    wire io_q1 = cs_io & (A[7:6] == 2'b01);           // A040-A07F
    wire io_q2 = cs_io & (A[7:6] == 2'b10);           // A080-A0BF  (DSW mirror 0x20 lands here)
    wire io_q3 = cs_io & (A[7:6] == 2'b11);           // A0C0-A0FF

    wire ls259_wr   = mem_wr & io_q0 & (A[5:3] == 3'b000);   // A000-A007
    wire spram_wr   = mem_wr & io_q1 & (A[5:4] == 2'b10);    // A060-A06F
    assign sound_latch_wr = mem_wr & io_q2;
    wire wdog_wr    = mem_wr & io_q3;

    assign sound_latch = cpu_dout;

    ////////////////////////////////////////////////////////////////////////
    // AY-3-8910 register select
    //
    // champbas uses data_address_w: offset 0 = DATA, offset 1 = ADDRESS
    // (champbas.cpp:579). champbb2j inverts this to address_data_w (:628),
    // which is the ONLY difference in that set's map — hence the set_id test
    // rather than a separate code path.
    ////////////////////////////////////////////////////////////////////////

    localparam SET_CHAMPBB2J = 8'h05;                  // see any MRA's index-5 enumeration

    wire ay_sel_inverted = (set_id == SET_CHAMPBB2J);
    wire ay_wr           = mem_wr & cs_ay;
    wire ay_is_addr      = ay_sel_inverted ? ~A[0] : A[0];

    assign ay_din     = cpu_dout;
    assign ay_addr_wr = ay_wr &  ay_is_addr;
    assign ay_data_wr = ay_wr & ~ay_is_addr;

    ////////////////////////////////////////////////////////////////////////
    // LS259 mainlatch @ 9D (champbas.cpp:970-978), written with D0.
    //
    //   0 irq_enable   1 !WORK (nc)   2 gfxbank      3 flip (INVERTED)
    //   4 palettebank  5 nc           6 MCU start    7 MCU bus dir
    //
    // Talbot nops 2 and 4; exctsccr nops 4. Those are "this game never writes
    // them" facts, not decode differences, so the latch is wired uniformly and
    // the unused bits simply stay 0.
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] mainlatch = 8'd0;

    always_ff @(posedge clk) begin
        if (reset) mainlatch <= 8'd0;
        else if (cen_cpu && ls259_wr) mainlatch[A[2:0]] <= cpu_dout[0];
    end

    wire irq_mask     = mainlatch[0];
    wire gfx_bank     = mainlatch[2];
    wire flip_screen  = ~mainlatch[3];      // .invert() at :974 undone here
    wire palette_bank = mainlatch[4];

    ////////////////////////////////////////////////////////////////////////
    // Watchdog — set_vblank_count(0x10) at :983.
    //
    // Its counter is also READ BACK as DSW bit 7 via watchdog_bit2()
    // (:487, :745):  (0x10 - counter) >> 2 & 1
    // This is NOT a dip switch. The MRA deliberately omits bit 7 and the
    // value is substituted here.
    ////////////////////////////////////////////////////////////////////////

    reg [4:0] wdog_cnt = 5'd0;
    reg       vblank_d = 1'b0;
    wire      vblank_rise = video_vblank & ~vblank_d;

    // WDOG-FIX-2026-07-30 (found in Verilator sim, not on hardware):
    // vblank_d MUST track video_vblank continuously, including during reset.
    // Previously it was reset to 0 while video_vblank is already 1 at reset
    // (v_cnt=0, and vblank = v_cnt < 16), so releasing reset manufactured a
    // FALSE vblank rising edge and ticked wdog_cnt to 1. wdog_cnt==1 gives
    // 0x10-1 = 0b01111, whose bit[2] is 1 — so watchdog_bit2() read back as 1
    // through DSW bit 7, and the boot code at $00A3-$00A7
    //     ld a,($A080) / add a,a / jr c,$00A7
    // hung FOREVER (that jr targets itself and never re-reads the port).
    // Measured: first $A080 read returned 0xA6 with wdog_cnt=1.
    always_ff @(posedge clk) begin
        vblank_d <= video_vblank;
        if (reset)            wdog_cnt <= 5'd0;
        else if (wdog_wr)     wdog_cnt <= 5'd0;
        else if (vblank_rise) wdog_cnt <= wdog_cnt + 5'd1;
    end

    wire [4:0] wdog_diff = 5'h10 - wdog_cnt;
    wire       wdog_bit2 = wdog_diff[2];

    wire [7:0] dsw_read = {wdog_bit2, dsw[6:0]};

    ////////////////////////////////////////////////////////////////////////
    // Sprite position RAM — A060-A06F, 16 bytes, WRITE ONLY from the CPU
    // (champbas.cpp:590 is .writeonly()). Holds x/y only; code/colour/flip
    // live in main RAM at 8FF0-8FFF. Small enough to be registers.
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] spriteram [0:15];

    always_ff @(posedge clk) begin
        if (cen_cpu && spram_wr) spriteram[A[3:0]] <= cpu_dout;
    end

    ////////////////////////////////////////////////////////////////////////
    // Main RAM — 8800-8FFF (2KB). Port B is reserved for the sprite engine's
    // attribute reads at 8FF0-8FFF; unused while sprites are stubbed.
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] ram_dout;

    dpram_dc #(.widthad_a(11), .width_a(8)) main_ram
    (
        .clock_a(clk),
        .address_a(A[10:0]),
        .data_a(cpu_dout),
        .wren_a(cen_cpu & mem_wr & cs_ram),
        .q_a(ram_dout),

        .clock_b(clk),
        .address_b(11'd0),
        .data_b(8'd0),
        .wren_b(1'b0),
        .q_b()
    );

    ////////////////////////////////////////////////////////////////////////
    // Video
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] vram_dout;

    ChampionBaseball_VIDEO video
    (
        .clk(clk),
        .cen_pix(cen_pix),
        .reset(reset),

        .cpu_vram_addr(A[10:0]),
        .cpu_vram_din(cpu_dout),
        .cpu_vram_we(cen_cpu & mem_wr & cs_vram),
        .cpu_vram_dout(vram_dout),

        .flip_screen(flip_screen),
        .gfx_bank(gfx_bank),
        .palette_bank(palette_bank),

        .gfx_addr(gfx_addr),
        .gfx_data(gfx_data),
        .prom_addr(prom_addr),
        .prom_data(prom_data),

        .clk_dl(clk_dl),
        .ioctl_download(ioctl_download),
        .ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr),
        .ioctl_data(ioctl_data),
        .ioctl_wr(ioctl_wr),

        .VGA_R(video_r),
        .VGA_G(video_g),
        .VGA_B(video_b),
        .HSync(video_hsync),
        .VSync(video_vsync),
        .HBlank(video_hblank),
        .VBlank(video_vblank)
    );

    ////////////////////////////////////////////////////////////////////////
    // CPU read mux
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] cpu_din;

    always_comb begin
        if      (cs_rom)  cpu_din = rom_data;
        else if (cs_vram) cpu_din = vram_dout;
        else if (cs_ram)  cpu_din = ram_dout;
        else if (io_q0)   cpu_din = p1;
        else if (io_q1)   cpu_din = p2;
        else if (io_q2)   cpu_din = dsw_read;
        else if (io_q3)   cpu_din = system;
        else              cpu_din = 8'hFF;
    end

    assign rom_addr = A[14:0];

    ////////////////////////////////////////////////////////////////////////
    // IRQ — vblank asserts IRQ0 only while irq_mask; irq_enable_w(0) clears it
    // (champbas.cpp:492, :915). It is a HELD level, not a pulse: the game must
    // clear the mask to release it.
    ////////////////////////////////////////////////////////////////////////

    reg irq_pending = 1'b0;

    always_ff @(posedge clk) begin
        if (reset)            irq_pending <= 1'b0;
        else if (!irq_mask)   irq_pending <= 1'b0;
        else if (vblank_rise) irq_pending <= 1'b1;
    end

    wire int_n = ~(irq_pending & irq_mask);

    ////////////////////////////////////////////////////////////////////////
    // Z80
    //
    // T80s, matching Kyugo — Kyugo_CPU.sv:252 records that swapping the T80
    // wrapper here made a CPU lose a timing race, so this is not a free choice.
    ////////////////////////////////////////////////////////////////////////

    T80s cpu
    (
        .RESET_n(~reset),
        .CLK(clk),
        .CEN(cen_cpu & ~pause),
        .WAIT_n(1'b1),
        .INT_n(int_n),
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
