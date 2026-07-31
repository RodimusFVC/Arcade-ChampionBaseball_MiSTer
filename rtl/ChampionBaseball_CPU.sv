//============================================================================
//
//  ChampionBaseball Main CPU Board (TVG-1-CPU-B)
//  Based on MAME kangaroo.cpp by Ville Laitinen, Aaron Giles
//
//============================================================================
//============================================================================
//  ChampionBaseball_CPU.sv
//
//  NOTE (2026-07-30): This file has been RENAMED from the Kangaroo core but its
//  CONTENTS ARE STILL KANGAROO'S. The Champion Baseball (champbas.cpp) memory map,
//  video and sound hardware have NOT been implemented yet. See
//  Claude/champbas_conversion_brief_2026-07-30.md for the target specification.
//============================================================================

module ChampionBaseball_CPU
(
    input         reset,
    input         clk_10m,           // 10 MHz master clock (matches real XTAL)

    // Video outputs
    output  [2:0] video_r, video_g,  // BGR 3-bit palette
    output  [1:0] video_b,
    output        video_hsync, video_vsync,
    output        video_hblank, video_vblank,
    output        ce_pix,

    // Inputs
    input   [7:0] dsw0,             // 8-bit DIP switch
    input   [4:0] in0,              // IN0: service, start1, start2, coin_l, coin_r
    // GAMESEL-2026-06-21: in1 widened 5->8 (bit5/0x20 = Funky Fish 2nd button). Original: input [4:0] in1,
    input   [7:0] in1,              // IN1: P1 right,left,up,down,punch + bit5 = FF 2nd btn (0x20)
    input   [7:0] in2,              // IN2: P2 right, left, up, down, punch

    // Sound interface
    output  [7:0] sound_latch,      // Data to sound CPU
    output        sound_latch_wr,   // Strobe: sound latch written

    // Blitter ROMs — directly memory-mapped, loaded via index 2
    input         blit0_cs_i, blit1_cs_i, blit2_cs_i, blit3_cs_i,
    // Main program ROMs — loaded via index 0
    input         rom0_cs_i, rom1_cs_i, rom2_cs_i,
    input         rom3_cs_i, rom4_cs_i, rom5_cs_i,
    input  [24:0] ioctl_addr,
    input   [7:0] ioctl_data,
    input         ioctl_wr,

    // MCU (MB8841) — index 6 ROM download + presence flag (original Kangaroo HW only)
    input         mcu_present,    // 1 = MB8841 fitted (kangaroo/kangarooa); 0 = bootleg / Funky Fish
    input         mcurom_wr,      // ioctl_wr for index 6 (prog 0x000-0x7FF + protrom 0x800-0xFFF)

    input         pause,

    // Hiscore interface (active high, stubbed for now)
    input  [15:0] hs_address,
    input   [7:0] hs_data_in,
    output  [7:0] hs_data_out,
    input         hs_write
);

//------------------------------------------------------- Clock Enables -------------------------------------------------------//

// Generate clock enables from 10 MHz master
// cen_5m  = 10/2 = 5 MHz (pixel clock)
// cen_2m5 = 10/4 = 2.5 MHz (Z80 clock)
reg [1:0] div = 2'd0;
always_ff @(posedge clk_10m) begin
    div <= div + 2'd1;
end
wire cen_5m  = (div[0] == 1'b0);     // Every 2nd clock
wire cen_2m5 = (div == 2'd0);         // Every 4th clock

assign ce_pix = cen_5m;

//------------------------------------------------------------ CPU -------------------------------------------------------------//

// Main CPU — Zilog Z80 (T80s soft core)
wire [15:0] cpu_A;
wire  [7:0] cpu_Dout;
wire n_m1, n_mreq, n_iorq, n_rd, n_wr, n_rfsh;

T80s #(.Mode(0), .T2Write(1), .IOWait(1)) main_cpu
(
    .RESET_n(reset),
    .CLK(clk_10m),
    .CEN(cen_2m5 & ~pause),
    .INT_n(n_irq),
    .NMI_n(n_nmi),
    .BUSRQ_n(1'b1),
    .M1_n(n_m1),
    .MREQ_n(n_mreq),
    .IORQ_n(n_iorq),
    .RD_n(n_rd),
    .WR_n(n_wr),
    .RFSH_n(n_rfsh),
    .A(cpu_A),
    .DI(cpu_Din),
    .DO(cpu_Dout)
);

//------------------------------------------------------ Address Decoding ------------------------------------------------------//

// Active-low signals for memory regions
wire mem_access = ~n_mreq & n_rfsh;

// ROM: 0x0000-0x5FFF (read only)
wire cs_rom = mem_access & (cpu_A[15:14] == 2'b00) & ~cpu_A[13]; // 0x0000-0x1FFF
wire cs_rom_hi = mem_access & (cpu_A[15:13] == 3'b001);           // 0x2000-0x3FFF
wire cs_rom_top = mem_access & (cpu_A[15:13] == 3'b010);          // 0x4000-0x5FFF
wire cs_any_rom = cs_rom | cs_rom_hi | cs_rom_top;

// Video RAM: 0x8000-0xBFFF (write only from CPU perspective)
wire cs_videoram = mem_access & (cpu_A[15:14] == 2'b10);          // 0x8000-0xBFFF

// Banked blitter ROM: 0xC000-0xDFFF (read only)
wire cs_blitbank = mem_access & (cpu_A[15:13] == 3'b110);         // 0xC000-0xDFFF

// Work RAM: 0xE000-0xE3FF
wire cs_workram = mem_access & (cpu_A[15:10] == 6'b111000);       // 0xE000-0xE3FF

// DSW: 0xE400 (read, mirrored across 0xE400-0xE7FF)
wire cs_dsw = mem_access & (cpu_A[15:10] == 6'b111001);           // 0xE400-0xE7FF

// Video control: 0xE800-0xE80A (write, mirrored with 0x03F0)
wire cs_vidctrl = mem_access & (cpu_A[15:10] == 6'b111010);       // 0xE800-0xEBFF

// IN0 read / soundlatch write: 0xEC00
wire cs_in0 = mem_access & (cpu_A[15:8] == 8'hEC);

// IN1 read / coin counter write: 0xED00
wire cs_in1 = mem_access & (cpu_A[15:8] == 8'hED);

// IN2 read: 0xEE00
wire cs_in2 = mem_access & (cpu_A[15:8] == 8'hEE);

// MCU: 0xEF00 (security chip; MB8841 on original HW, returns 0 on bootleg)
wire cs_mcu = mem_access & (cpu_A[15:8] == 8'hEF);

//--------------------------------------------------------- CPU Data Mux -------------------------------------------------------//

wire [7:0] rom_D;
wire [7:0] blitbank_D;
wire [7:0] workram_D;
wire [7:0] mcu_dout;            // 0xEF00 read data (MCU R0 latch, or 0 on bootleg)

wire [7:0] cpu_Din =
    cs_any_rom     ? rom_D :
    cs_blitbank    ? blitbank_D :
    (cs_workram & ~n_rd) ? workram_D :
    cs_dsw         ? dsw0 :
    cs_in0         ? {3'b000, in0} :
    // GAMESEL-2026-06-21: pass all 8 IN1 bits (was {3'b000, in1}, which forced bits 5-7 to 0 → 2nd button dead).
    cs_in1         ? in1 :
    cs_in2         ? in2 :
    cs_mcu         ? mcu_dout :    // MB8841 R0 (original HW) or 0x00 (bootleg)
    8'hFF;

//-------------------------------------------------------- Program ROMs --------------------------------------------------------//

wire [7:0] rom0_D, rom1_D, rom2_D, rom3_D, rom4_D, rom5_D;

assign rom_D = (cpu_A[15:12] == 4'h0) ? rom0_D :
               (cpu_A[15:12] == 4'h1) ? rom1_D :
               (cpu_A[15:12] == 4'h2) ? rom2_D :
               (cpu_A[15:12] == 4'h3) ? rom3_D :
               (cpu_A[15:12] == 4'h4) ? rom4_D :
               (cpu_A[15:12] == 4'h5) ? rom5_D :
               8'hFF;

eprom_4k rom0 (.ADDR(cpu_A[11:0]), .CLK(clk_10m), .DATA(rom0_D),
               .ADDR_DL(ioctl_addr), .CLK_DL(clk_10m), .DATA_IN(ioctl_data),
               .CS_DL(rom0_cs_i), .WR(ioctl_wr));
eprom_4k rom1 (.ADDR(cpu_A[11:0]), .CLK(clk_10m), .DATA(rom1_D),
               .ADDR_DL(ioctl_addr), .CLK_DL(clk_10m), .DATA_IN(ioctl_data),
               .CS_DL(rom1_cs_i), .WR(ioctl_wr));
eprom_4k rom2 (.ADDR(cpu_A[11:0]), .CLK(clk_10m), .DATA(rom2_D),
               .ADDR_DL(ioctl_addr), .CLK_DL(clk_10m), .DATA_IN(ioctl_data),
               .CS_DL(rom2_cs_i), .WR(ioctl_wr));
eprom_4k rom3 (.ADDR(cpu_A[11:0]), .CLK(clk_10m), .DATA(rom3_D),
               .ADDR_DL(ioctl_addr), .CLK_DL(clk_10m), .DATA_IN(ioctl_data),
               .CS_DL(rom3_cs_i), .WR(ioctl_wr));
eprom_4k rom4 (.ADDR(cpu_A[11:0]), .CLK(clk_10m), .DATA(rom4_D),
               .ADDR_DL(ioctl_addr), .CLK_DL(clk_10m), .DATA_IN(ioctl_data),
               .CS_DL(rom4_cs_i), .WR(ioctl_wr));
eprom_4k rom5 (.ADDR(cpu_A[11:0]), .CLK(clk_10m), .DATA(rom5_D),
               .ADDR_DL(ioctl_addr), .CLK_DL(clk_10m), .DATA_IN(ioctl_data),
               .CS_DL(rom5_cs_i), .WR(ioctl_wr));

//------------------------------------------------------- Blitter ROMs --------------------------------------------------------//

// Blitter has 4 x 4KB ROMs, banked into 0xC000-0xDFFF via bank select (video_control[8])
// Bank 0: blit0 + blit2 (when bit 0 or 2 of bank select is 0)
// Bank 1: blit1 + blit3 (when bit 0 or 2 of bank select is set)
// MAME: m_blitbank->set_entry((data & 0x05) ? 1 : 0)
// Bank 0 maps: C000-CFFF=blit0(v0), D000-DFFF=blit2(v1)
// Bank 1 maps: C000-CFFF=blit1(v2), D000-DFFF=blit3(v3)

wire [7:0] blit0_D, blit1_D, blit2_D, blit3_D;
wire blit_bank_sel = (video_control[8] & 8'h05) != 0;  // MAME: (data & 0x05) ? 1 : 0

assign blitbank_D = cpu_A[12] ?
    (blit_bank_sel ? blit3_D : blit2_D) :
    (blit_bank_sel ? blit1_D : blit0_D);

eprom_4k blit0 (.ADDR(cpu_A[11:0]), .CLK(clk_10m), .DATA(blit0_D),
                .ADDR_DL(ioctl_addr), .CLK_DL(clk_10m), .DATA_IN(ioctl_data),
                .CS_DL(blit0_cs_i), .WR(ioctl_wr));
eprom_4k blit1 (.ADDR(cpu_A[11:0]), .CLK(clk_10m), .DATA(blit1_D),
                .ADDR_DL(ioctl_addr), .CLK_DL(clk_10m), .DATA_IN(ioctl_data),
                .CS_DL(blit1_cs_i), .WR(ioctl_wr));
eprom_4k blit2 (.ADDR(cpu_A[11:0]), .CLK(clk_10m), .DATA(blit2_D),
                .ADDR_DL(ioctl_addr), .CLK_DL(clk_10m), .DATA_IN(ioctl_data),
                .CS_DL(blit2_cs_i), .WR(ioctl_wr));
eprom_4k blit3 (.ADDR(cpu_A[11:0]), .CLK(clk_10m), .DATA(blit3_D),
                .ADDR_DL(ioctl_addr), .CLK_DL(clk_10m), .DATA_IN(ioctl_data),
                .CS_DL(blit3_cs_i), .WR(ioctl_wr));

//------------------------------------------------------------ RAM ------------------------------------------------------------//

// Work RAM (0xE000-0xE3FF, 1KB)
dpram_dc #(.widthad_a(10)) workram
(
    .clock_a(clk_10m),
    .wren_a(cs_workram & ~n_wr),
    .address_a(cpu_A[9:0]),
    .data_a(cpu_Dout),
    .q_a(workram_D),

    .clock_b(clk_10m),
    .wren_b(hs_write),
    .address_b(hs_address[9:0]),
    .data_b(hs_data_in),
    .q_b(hs_data_out)
);

//--------------------------------------------------- Video Control Registers --------------------------------------------------//

// MAME: m_video_control[0..10], written at 0xE800-0xE80A
// Only bits [3:0] of the address select the register (mirrored with 0x03F0)
reg [7:0] video_control [0:10];
integer vc_i;
initial begin
    for (vc_i = 0; vc_i < 11; vc_i = vc_i + 1)
        video_control[vc_i] = 8'd0;
end

// Trigger for blitter execution (directly from Step 4)
reg blitter_start = 0;

always_ff @(posedge clk_10m) begin
    blitter_start <= 0;
    if(cs_vidctrl & ~n_wr) begin
        if(cpu_A[3:0] <= 4'd10)
            video_control[cpu_A[3:0]] <= cpu_Dout;
        if(cpu_A[3:0] == 4'd5)
            blitter_start <= 1;  // Writing to reg 5 triggers DMA blit
    end
end

//------------------------------------------------------- Sound Latch ---------------------------------------------------------//

reg [7:0] slatch = 8'd0;
reg       slatch_wr_pulse = 0;
always_ff @(posedge clk_10m) begin
    slatch_wr_pulse <= 0;
    if(cs_in0 & ~n_wr) begin
        slatch <= cpu_Dout;
        slatch_wr_pulse <= 1;
    end
end
assign sound_latch = slatch;
assign sound_latch_wr = slatch_wr_pulse;

//------------------------------------------------------- Bootleg NMI ---------------------------------------------------------//

// The bootleg has no MCU. It pulses NMI at reset to make the game boot.
// MAME: m_maincpu->pulse_input_line(INPUT_LINE_NMI, attotime::zero);
// On original HW (mcu_present) the MB8841 drives NMI instead (see MCU block below) — this pulse is unused.
reg [7:0] nmi_boot_cnt = 8'd0;
reg n_nmi_boot = 1'b1;
always_ff @(posedge clk_10m) begin
    if(!reset) begin
        nmi_boot_cnt <= 8'd255;
        n_nmi_boot <= 1'b1;
    end
    else if(nmi_boot_cnt > 0 && cen_2m5) begin
        nmi_boot_cnt <= nmi_boot_cnt - 8'd1;
        if(nmi_boot_cnt == 8'd32)
            n_nmi_boot <= 1'b0;
        else if(nmi_boot_cnt == 8'd16)
            n_nmi_boot <= 1'b1;
    end
end

// NMI source select: MB8841 (R3.3) on original HW, bootleg boot pulse otherwise. (mcu_nmi_n: MCU block below.)
wire n_nmi = mcu_present ? mcu_nmi_n : n_nmi_boot;

//-------------------------------------------------------- MB8841 MCU ---------------------------------------------------------//
// Original Kangaroo (TVG-1-CPU-B, IC29) fits an MB8841 microcomputer used for protection. Per MAME
// kangaroo.cpp:153 — besides the boot NMI it "acts like a timer to determine the intervals of the big ape
// enemy appearing." Wiring mirrors kangaroo_mcu_state (kangaroo.cpp:455-504):
//   CPU wr 0xEF00 -> main_data                                            (mcu_w)
//   CPU rd 0xEF00 <- R0 port latch                                        (mcu_r)
//   K port = 0xF & (R2.0 ? main_data : F) & (~R3.0 ? protrom[addr] : F)   (mcu_port_k_r)
//   O port (oh:ol) -> protrom addr A0-A7 ; R3.1 -> A8 (A9,A10=GND)        (mcu_port_o_w / mcu_port_r_w)
//   R3.3 -> main-CPU NMI                                                  (mcu_port_r_w)
// MCU clock = 10MHz/4 = 2.5MHz (MAME MB8841(.., 10_MHz_XTAL/4)). Held in reset when not fitted.
// darfpga mb88 has separate R in/out ports and no external drive on kangaroo's R pins, so tie in<-out
// (MAME's read_r returns the output latch). Nothing drives the MCU /IRQ or /TC externally on kangaroo.

// timer ÷32 prescaler (MAME TIMER_PRESCALE=32) now lives INSIDE the mb88.sv wrapper
// (generated from `ena`, no external ena_timer port anymore — see mb88.sv header).
wire mcu_ena       = cen_2m5 & ~pause;
wire mcu_reset_n   = reset & mcu_present;     // hold in reset unless MB8841 is fitted

wire [10:0] mcu_rom_addr;
wire  [7:0] mcu_rom_q;
wire  [3:0] mcu_ol, mcu_oh;
wire  [7:0] mcu_o = {mcu_oh, mcu_ol};         // combined O port = protrom A0-A7
wire  [3:0] r0_out, r1_out, r2_out, r3_out;

reg  [7:0] main_data = 8'd0;                  // CPU write to 0xEF00 (mcu_w)
always_ff @(posedge clk_10m)
    if (cs_mcu & ~n_wr) main_data <= cpu_Dout;

wire [10:0] protrom_addr = {2'b00, r3_out[1], mcu_o};   // A8 = R3.1, A0-A7 = O
wire  [7:0] protrom_q;

wire  [3:0] mcu_k = 4'hF
                  & ( r2_out[0] ? main_data[3:0] : 4'hF)   // gated by R2.0
                  & (~r3_out[0] ? protrom_q[3:0] : 4'hF);  // gated by ~R3.0

wire mcu_nmi_n = ~r3_out[3];                  // R3.3 asserts NMI (active high) -> n_nmi low
assign mcu_dout = mcu_present ? {4'h0, r0_out} : 8'h00;

mb88 mcu
(
    .clock      (clk_10m),
    .ena        (mcu_ena),
    .reset_n    (mcu_reset_n),

    .r0_port_in (r0_out), .r1_port_in (r1_out), .r2_port_in (r2_out), .r3_port_in (r3_out),
    .r0_port_out(r0_out), .r1_port_out(r1_out), .r2_port_out(r2_out), .r3_port_out(r3_out),
    .k_port_in  (mcu_k),
    .ol_port_out(mcu_ol), .oh_port_out(mcu_oh),
    .p_port_out (),

    .stby_n     (1'b1),
    .tc_n       (1'b1),
    .irq_n      (1'b1),
    .sc_in_n    (1'b1),
    .si_n       (1'b1),
    .sc_out_n   (),
    .so_n       (),
    .to_n       (),

    .rom_addr   (mcu_rom_addr),
    .rom_data   (mcu_rom_q)
);

// MCU internal program ROM (2KB) — index 6, ioctl_addr[11]==0
dpram_dc #(.widthad_a(11), .width_a(8)) mcu_prog
(
    .clock_a(clk_10m), .address_a(mcu_rom_addr), .data_a(8'd0), .wren_a(1'b0), .q_a(mcu_rom_q),
    .clock_b(clk_10m), .address_b(ioctl_addr[10:0]), .data_b(ioctl_data),
    .wren_b(mcurom_wr & ~ioctl_addr[11]), .q_b()
);

// MCU protection PROM (2KB) — index 6, ioctl_addr[11]==1
dpram_dc #(.widthad_a(11), .width_a(8)) mcu_prot
(
    .clock_a(clk_10m), .address_a(protrom_addr), .data_a(8'd0), .wren_a(1'b0), .q_a(protrom_q),
    .clock_b(clk_10m), .address_b(ioctl_addr[10:0]), .data_b(ioctl_data),
    .wren_b(mcurom_wr & ioctl_addr[11]), .q_b()
);

//-------------------------------------------------------- VBlank IRQ ----------------------------------------------------------//

// MAME: standard IM1 interrupt, RST 38h every vblank
// IRQ fires on vblank rising edge
reg n_irq = 1'b1;
reg vblank_last = 0;
always_ff @(posedge clk_10m) begin
    if(!reset) begin
        n_irq <= 1'b1;
        vblank_last <= 0;
    end
    else begin
        vblank_last <= video_vblank;
        // Assert IRQ on rising edge of vblank
        if(video_vblank & ~vblank_last)
            n_irq <= 1'b0;
        // Auto-clear: Z80 IM1 acknowledges via M1+IORQ
        if(~n_m1 & ~n_iorq)
            n_irq <= 1'b1;
    end
end

//-------------------------------------------------------- Video Timing --------------------------------------------------------//

// Kangaroo video timing from MAME:
// screen.set_raw(10_MHz_XTAL, 320*2, 0*2, 256*2, 260, 8, 248);
// Total: 640 pixel clocks horizontal (at 5 MHz that's 320 positions at 10 MHz)
// But the screen uses 10 MHz as raw pixel clock with 640 total, 512 visible
// Vertical: 260 lines total, visible 8-248 (240 lines)
//
// We run the pixel counter at 10 MHz (ce_pix = cen_5m for output,
// but the counters tick every clk_10m)

reg [9:0] h_cnt = 10'd0;  // 0-639
reg [8:0] v_cnt = 9'd0;   // 0-259

always_ff @(posedge clk_10m) begin
    if(!reset) begin
        h_cnt <= 0;
        v_cnt <= 0;
    end
    else begin
        if(h_cnt == 10'd639) begin
            h_cnt <= 0;
            if(v_cnt == 9'd259)
                v_cnt <= 0;
            else
                v_cnt <= v_cnt + 9'd1;
        end
        else
            h_cnt <= h_cnt + 10'd1;
    end
end

// Sync and blank generation
// MAME visible: x = 0*2 to 256*2-1 = 0 to 511, y = 8 to 247
// TOP-BOTTOM-FIX-2026-06-21: the scanout pixel pipeline is 2 clk_10m cycles deep (combinational addr ->
// DPRAM addr-reg -> scan_word latch), so the pixel for h_cnt=H is output at H+2. hblank/hsync were
// combinational off h_cnt, so the active window LED the data by 2 px -> 2 rows of pre-visible garbage at the
// display TOP and the last 2 real rows pushed off the BOTTOM (h_cnt = display-vertical, ROT90). Delay
// hblank/hsync by 2 cycles to align the window with the data. This is a latency match, NOT a directional
// window shift (which wraps junk). v-axis has no such latency -> vblank/vsync stay combinational, and the
// vblank IRQ keeps using the undelayed video_vblank (game timing untouched).
// Original combinational lines below:
// assign video_hblank = (h_cnt >= 10'd512);
// assign video_hsync  = (h_cnt >= 10'd560) & (h_cnt < 10'd624);  // ~64 clocks
wire video_hblank_raw = (h_cnt >= 10'd512);
wire video_hsync_raw  = (h_cnt >= 10'd560) & (h_cnt < 10'd624);  // ~64 clocks
reg [1:0] hblank_sr = 2'b11;
reg [1:0] hsync_sr  = 2'b00;
always_ff @(posedge clk_10m) begin
    hblank_sr <= {hblank_sr[0], video_hblank_raw};
    hsync_sr  <= {hsync_sr[0],  video_hsync_raw};
end
assign video_hblank = hblank_sr[1];
assign video_hsync  = hsync_sr[1];
assign video_vblank = (v_cnt < 9'd8) | (v_cnt >= 9'd248);
assign video_vsync  = (v_cnt >= 9'd252) & (v_cnt < 9'd256);     // ~4 lines

//--------------------------------------------------------- Video RAM ----------------------------------------------------------//

// Kangaroo VRAM: 16384 addresses × 32 bits (4 bytes per word, 2 planes × 4 pixels)
// Split into two 16-bit-wide dpram_dc instances (lo=bytes 0,1  hi=bytes 2,3)
// Port A = CPU/blitter read-modify-write
// Port B = video scanout (read-only)

wire [15:0] vram_lo_qa, vram_hi_qa;   // Port A read data (CPU/blitter side)
wire [15:0] vram_lo_qb, vram_hi_qb;   // Port B read data (scanout side)
reg  [13:0] vram_addr_a;
reg  [15:0] vram_lo_da, vram_hi_da;
reg         vram_we_a;
wire [13:0] vram_addr_b;               // Scanout address (active accent accent driven by compositing logic)

dpram_dc #(.widthad_a(14), .width_a(16)) vram_lo
(
    .clock_a(clk_10m),
    .address_a(vram_addr_a),
    .data_a(vram_lo_da),
    .wren_a(vram_we_a),
    .q_a(vram_lo_qa),

    .clock_b(clk_10m),
    .address_b(vram_addr_b),
    .data_b(16'd0),
    .wren_b(1'b0),
    .q_b(vram_lo_qb)
);

dpram_dc #(.widthad_a(14), .width_a(16)) vram_hi
(
    .clock_a(clk_10m),
    .address_a(vram_addr_a),
    .data_a(vram_hi_da),
    .wren_a(vram_we_a),
    .q_a(vram_hi_qa),

    .clock_b(clk_10m),
    .address_b(vram_addr_b),
    .data_b(16'd0),
    .wren_b(1'b0),
    .q_b(vram_hi_qb)
);

// DIAG-2026-06-18 PLANE-OFFSET FIX (the 2-month sprite-edge fringe). The scanout previously read plane A
// and plane B through ONE shared port B (muxed on h_cnt[0]); with the 1-cycle DPRAM latency that left
// plane A one COLUMN ahead of plane B at compositing → garbage at sprite EDGES (interiors fine). These two
// MIRROR instances (written identically on port A) give plane B its own same-latency read port, so plane A
// reads vram_lo/hi:B and plane B reads vram_lo2/hi2:B — aligned (recreates step4's combinational dual-read).
wire [15:0] vram2_lo_qb, vram2_hi_qb;   // plane-B mirror scanout read data
wire [13:0] vram_addr_b2;               // plane B scanout address (mirror port B)

dpram_dc #(.widthad_a(14), .width_a(16)) vram_lo2
(
    .clock_a(clk_10m), .address_a(vram_addr_a), .data_a(vram_lo_da), .wren_a(vram_we_a), .q_a(),
    .clock_b(clk_10m), .address_b(vram_addr_b2), .data_b(16'd0), .wren_b(1'b0), .q_b(vram2_lo_qb)
);
dpram_dc #(.widthad_a(14), .width_a(16)) vram_hi2
(
    .clock_a(clk_10m), .address_a(vram_addr_a), .data_a(vram_hi_da), .wren_a(vram_we_a), .q_a(),
    .clock_b(clk_10m), .address_b(vram_addr_b2), .data_b(16'd0), .wren_b(1'b0), .q_b(vram2_hi_qb)
);

//------------------------------------------------ VRAM Expand/Mask Functions --------------------------------------------------//

// MAME videoram_write expand logic — pure combinational functions
// Expand 8-bit CPU data to 32-bit (DCBADCBA → 4 bytes)
function [31:0] expand_data;
    input [7:0] data;
    reg [31:0] e;
    begin
        e = 32'd0;
        if (data[0]) e = e | 32'h00000055;
        if (data[4]) e = e | 32'h000000aa;
        if (data[1]) e = e | 32'h00005500;
        if (data[5]) e = e | 32'h0000aa00;
        if (data[2]) e = e | 32'h00550000;
        if (data[6]) e = e | 32'h00aa0000;
        if (data[3]) e = e | 32'h55000000;
        if (data[7]) e = e | 32'haa000000;
        expand_data = e;
    end
endfunction

// Build layer mask from 4-bit mask value
function [31:0] build_layermask;
    input [3:0] mask;
    reg [31:0] m;
    begin
        m = 32'd0;
        if (mask[3]) m = m | 32'h30303030;
        if (mask[2]) m = m | 32'hc0c0c0c0;
        if (mask[1]) m = m | 32'h03030303;
        if (mask[0]) m = m | 32'h0c0c0c0c;
        build_layermask = m;
    end
endfunction

//------------------------------------------------------ Blitter ROM -----------------------------------------------------------//

// 16KB blitter ROM — single dpram_dc, port A = blitter read, port B = ioctl download
wire [7:0] blitrom_qa;
reg  [13:0] blitrom_addr_a;

// Compute ioctl write address for blitter ROM download
// blit0 → 0x0000-0x0FFF, blit1 → 0x1000-0x1FFF, blit2 → 0x2000-0x2FFF, blit3 → 0x3000-0x3FFF
wire [13:0] blitrom_dl_addr = blit0_cs_i ? {2'b00, ioctl_addr[11:0]} :
                               blit1_cs_i ? {2'b01, ioctl_addr[11:0]} :
                               blit2_cs_i ? {2'b10, ioctl_addr[11:0]} :
                               blit3_cs_i ? {2'b11, ioctl_addr[11:0]} :
                               14'd0;
wire blitrom_dl_wr = ioctl_wr & (blit0_cs_i | blit1_cs_i | blit2_cs_i | blit3_cs_i);

dpram_dc #(.widthad_a(14), .width_a(8)) blitrom_mem
(
    .clock_a(clk_10m),
    .address_a(blitrom_addr_a),
    .data_a(8'd0),
    .wren_a(1'b0),
    .q_a(blitrom_qa),

    .clock_b(clk_10m),
    .address_b(blitrom_dl_addr),
    .data_b(ioctl_data),
    .wren_b(blitrom_dl_wr),
    .q_b()
);

//------------------------------------------------------ DMA Blitter -----------------------------------------------------------//

// Pipelined read-modify-write state machine:
//   IDLE     — wait for blitter_start or CPU VRAM write
//   RMW_READ — present address to VRAM port A, wait 1 cycle for read data
//   RMW_WRITE— compute new value, write back to VRAM port A
//   BLIT_SETUP — load blitter parameters
//   BLIT_READ  — present blitrom address, wait for ROM data
//   BLIT_RMW_RD — present VRAM dest address, wait for old data
//   BLIT_RMW_WR_LO — write low-half blit result to VRAM
//   BLIT_RMW_RD2 — re-read VRAM for high-half blit
//   BLIT_RMW_WR_HI — write high-half blit result, advance to next pixel

localparam ST_IDLE        = 4'd0;
localparam ST_CPU_RMW_RD  = 4'd1;
localparam ST_CPU_RMW_WR  = 4'd2;
localparam ST_BLIT_SETUP  = 4'd3;
localparam ST_BLIT_ROMRD  = 4'd4;
localparam ST_BLIT_RMW_RD = 4'd5;
localparam ST_BLIT_RMW_WR_LO = 4'd6;
localparam ST_BLIT_RMW_RD2   = 4'd7;
localparam ST_BLIT_RMW_WR_HI = 4'd8;
localparam ST_BLIT_NEXT   = 4'd9;
localparam ST_CPU_RMW_RD2 = 4'd10;
localparam ST_BLIT_ROWSTART = 4'd11;
// DPRAM-LATENCY-FIX-2026-06-21: blitrom_mem is dpram_dc (altsyncram) = 2 clks addr-reg+read (the CPU RMW in
// this file correctly waits 2). The blit ROM reads waited only 1 → LOW/HIGH captured a cycle early off the
// shared port → 1-source-pixel skew between planes = the green/blue 1px fringe. These settle states fix it.
localparam ST_BLIT_WAIT_LO  = 4'd12;
localparam ST_BLIT_WAIT_HI  = 4'd13;

reg [3:0]  vram_state = ST_IDLE;
reg [7:0]  blit_width;
reg [7:0]  blit_height;
reg [7:0]  blit_x_cnt;
reg [7:0]  blit_y_cnt;
reg [15:0] blit_cur_src;
reg [15:0] blit_cur_dst;
reg [7:0]  blit_adj_mask;
reg [7:0]  blit_rom_data_lo;
reg [7:0]  blit_rom_data_hi;

// Registered copies of CPU write params (captured in IDLE)
reg [13:0] cpu_wr_addr;
reg [7:0]  cpu_wr_data;
reg [3:0]  cpu_wr_mask;

// Read-modify-write intermediates
reg [31:0] rmw_old_word;
reg [31:0] rmw_new_word;
reg [31:0] rmw_expdata;
reg [31:0] rmw_layermask;

always_ff @(posedge clk_10m) begin
    if (!reset) begin
        vram_state <= ST_IDLE;
        vram_we_a <= 0;
    end
    else begin
        vram_we_a <= 0;  // Default: no write

        case (vram_state)
            ST_IDLE: begin
                if (blitter_start) begin
                    // Latch blitter params
                    blit_width   <= video_control[4];
                    blit_height  <= video_control[5];
                    blit_cur_src <= {video_control[1], video_control[0]};
                    blit_cur_dst <= {video_control[3], video_control[2]};
                    blit_x_cnt  <= 0;
                    blit_y_cnt  <= 0;
                    // Compute adjusted mask
                    blit_adj_mask <= video_control[8];
                    vram_state <= ST_BLIT_SETUP;
                end
                else if (cs_videoram & ~n_wr) begin
                    // CPU VRAM write — start RMW cycle
                    cpu_wr_addr <= cpu_A[13:0];
                    cpu_wr_data <= cpu_Dout;
                    cpu_wr_mask <= video_control[8][3:0];
                    vram_addr_a <= cpu_A[13:0];  // Present read address
                    vram_state <= ST_CPU_RMW_RD;
                end
            end

            //--- CPU VRAM write (3-cycle RMW: addr → wait → read+compute → write) ---
            ST_CPU_RMW_RD: begin
                // Address was presented last cycle. dpram output will be valid NEXT cycle.
                // Pre-compute expand/mask while waiting for RAM.
                rmw_expdata  <= expand_data(cpu_wr_data);
                rmw_layermask <= build_layermask(cpu_wr_mask);
                vram_state <= ST_CPU_RMW_RD2;
            end

            ST_CPU_RMW_RD2: begin
                // NOW the dpram output is valid — latch it
                rmw_old_word <= {vram_hi_qa, vram_lo_qa};
                vram_state <= ST_CPU_RMW_WR;
            end

            ST_CPU_RMW_WR: begin
                rmw_new_word = (rmw_old_word & ~rmw_layermask) | (rmw_expdata & rmw_layermask);
                vram_addr_a <= cpu_wr_addr;
                vram_lo_da <= rmw_new_word[15:0];
                vram_hi_da <= rmw_new_word[31:16];
                vram_we_a  <= 1;
                vram_state <= ST_IDLE;
            end

            //--- Blitter DMA ---
            ST_BLIT_SETUP: begin
                // Adjust mask per MAME: OR top/bottom 2-bit pairs during DMA
                if (blit_adj_mask[3:2] != 0) blit_adj_mask[3:2] <= 2'b11;
                if (blit_adj_mask[1:0] != 0) blit_adj_mask[1:0] <= 2'b11;
                // Start first pixel: present low-half ROM addr
                blitrom_addr_a <= {1'b0, blit_cur_src[12:0]};
                // DPRAM-LATENCY-FIX-2026-06-21: was "vram_state <= ST_BLIT_ROMRD;" (1-cycle settle — TOO EARLY).
                vram_state <= ST_BLIT_WAIT_LO;
            end

            // DPRAM-LATENCY-FIX-2026-06-21: NEW settle state — LOW-half ROM needs 2 clks (addr-reg + read), like
            // the CPU RMW. Without it blit_rom_data_lo was captured a cycle early off the shared blitrom port,
            // landing the LOW plane 1 source-pixel off from HIGH = the green/blue 1px fringe.
            ST_BLIT_WAIT_LO: begin
                vram_state <= ST_BLIT_ROMRD;
            end

            ST_BLIT_ROMRD: begin
                // DPRAM-LATENCY-FIX-2026-06-21: LOW-half ROM data now valid (2 clks after present). Capture it,
                // then present HIGH-half addr + the VRAM read addr (both captured 2 clks later in ST_BLIT_RMW_RD).
                blit_rom_data_lo <= blitrom_qa;
                blitrom_addr_a <= {1'b1, blit_cur_src[12:0]};
                vram_addr_a <= (blit_cur_dst[13:0] + {6'd0, blit_x_cnt}) & 14'h3FFF;
                // DPRAM-LATENCY-FIX-2026-06-21: was "vram_state <= ST_BLIT_RMW_RD;" (1-cycle — TOO EARLY).
                vram_state <= ST_BLIT_WAIT_HI;
            end

            // DPRAM-LATENCY-FIX-2026-06-21: NEW settle state — HIGH-half ROM + VRAM reads need 2 clks.
            ST_BLIT_WAIT_HI: begin
                vram_state <= ST_BLIT_RMW_RD;
            end

            ST_BLIT_RMW_RD: begin
                // DPRAM-LATENCY-FIX-2026-06-21: HIGH-half ROM AND VRAM read-back both valid now (2 clks after
                // presented in ST_BLIT_ROMRD). Both match the SAME source pixel as LOW → planes aligned.
                blit_rom_data_hi <= blitrom_qa;
                rmw_old_word     <= {vram_hi_qa, vram_lo_qa};
                vram_state <= ST_BLIT_RMW_WR_LO;
            end

            // DPRAM-LATENCY-FIX-2026-06-21: ST_BLIT_RMW_RD2 no longer reached (VRAM capture merged above). Kept.
            ST_BLIT_RMW_RD2: begin
                rmw_old_word <= {vram_hi_qa, vram_lo_qa};
                vram_state <= ST_BLIT_RMW_WR_LO;
            end

            ST_BLIT_RMW_WR_LO: begin
                // clear pixel first
                rmw_expdata   = 32'h00000000;
                rmw_layermask = build_layermask(blit_adj_mask[3:0]);
                // Apply low-half blit (mask & 0x0A)
                //
                // NOTE 2026-05-16: this pairing is INVERTED from MAME's
                // kangaroo.cpp:344-345 (MAME pairs LOW↔0x05, HIGH↔0x0a).
                // We swapped to match MAME and the test showed: colors went
                // way off across all graphics + sprite trails turned BLACK
                // instead of green (clear started working but background
                // restoration broke). Diagnosis: the mismatch here is being
                // consumed by a COMPENSATING WRONGNESS elsewhere in the
                // pipeline (compositing? palette LUT? plane extraction at
                // scanout?), and the two wrongs make a right visually.
                // Reverting until we can ground-truth against MAME and find
                // the second mismatch. See
                // Claude/sprite_artifacting_audit_2026-05-16.md.
                rmw_expdata   = expand_data(blit_rom_data_lo);
                // PAIRING-MAME-MATCH-2026-06-21: with the DPRAM timing skew fixed, match MAME kangaroo.cpp:344
                // (LOW-half ROM <-> mask & 0x05). The inverted pairing only looked right because the skew was
                // compensating; now it's exposed. Original (inverted) line below:
                // rmw_layermask = build_layermask(blit_adj_mask[3:0] & 4'b1010);
                rmw_layermask = build_layermask(blit_adj_mask[3:0] & 4'b0101);
                rmw_new_word  = (rmw_old_word & ~rmw_layermask) | (rmw_expdata & rmw_layermask);
                // Now apply high-half blit (mask & 0x05) on top of that
                rmw_expdata   = expand_data(blit_rom_data_hi);
                // PAIRING-MAME-MATCH-2026-06-21: HIGH-half ROM <-> mask & 0x0a per MAME kangaroo.cpp:345.
                // Original (inverted) line below:
                // rmw_layermask = build_layermask(blit_adj_mask[3:0] & 4'b0101);
                rmw_layermask = build_layermask(blit_adj_mask[3:0] & 4'b1010);
                rmw_new_word  = (rmw_new_word & ~rmw_layermask) | (rmw_expdata & rmw_layermask);
                // Write back
                vram_addr_a <= (blit_cur_dst[13:0] + {6'd0, blit_x_cnt}) & 14'h3FFF;
                vram_lo_da  <= rmw_new_word[15:0];
                vram_hi_da  <= rmw_new_word[31:16];
                vram_we_a   <= 1;
                vram_state  <= ST_BLIT_NEXT;
            end

            ST_BLIT_NEXT: begin
                // Advance to next pixel
                blit_cur_src <= blit_cur_src + 16'd1;
                if (blit_x_cnt == blit_width) begin
                    blit_x_cnt <= 0;
                    if (blit_y_cnt == blit_height) begin
                        vram_state <= ST_IDLE;  // Done
                    end
                    else begin
                        blit_y_cnt  <= blit_y_cnt + 8'd1;
                        blit_cur_dst <= blit_cur_dst + 16'd256;
                        // Start next row: read ROM for first pixel
                        blitrom_addr_a <= {1'b0, (blit_cur_src + 16'd1) & 16'h1FFF};
                        vram_state <= ST_BLIT_ROWSTART;
                    end
                end
                else begin
                    blit_x_cnt <= blit_x_cnt + 8'd1;
                    // Start next pixel: present LOW-half ROM addr
                    blitrom_addr_a <= {1'b0, (blit_cur_src + 16'd1) & 16'h1FFF};
                    // DPRAM-LATENCY-FIX-2026-06-21: was "vram_state <= ST_BLIT_ROMRD;" (1-cycle — TOO EARLY).
                    vram_state <= ST_BLIT_WAIT_LO;
                end
            end

            ST_BLIT_ROWSTART: begin
                // blit_cur_dst is now settled — proceed to ROM read
                vram_state <= ST_BLIT_ROMRD;
            end

            default: vram_state <= ST_IDLE;
        endcase
    end
end

//----------------------------------------------- Pixel Compositing (screen_update) --------------------------------------------//

// MAME screen_update variables derived from video_control registers
wire [7:0] scrolly = video_control[6];
wire [7:0] scrollx = video_control[7];
wire [2:0] maska = (video_control[10] & 8'h28) >> 3;   // MAME exact
wire [2:0] maskb =  video_control[10][2:0];
wire [7:0] xora = video_control[9][5] ? 8'hFF : 8'h00;
wire [7:0] xorb = video_control[9][4] ? 8'hFF : 8'h00;
wire       enaa = video_control[9][3];
wire       enab = video_control[9][2];
wire       pria = ~video_control[9][1];
wire       prib = ~video_control[9][0];

// Current scanout position (used for address)
wire [8:0] scan_x = h_cnt[9:1];
wire [7:0] scan_y = v_cnt[7:0];

// 2026-06-18: scanout left at NATIVE (full content + correct size). HW results that rule out the simple
// knobs: doubling (src_col=h_cnt[9:2]) => top-half magnified; doubling + halved extent (hblank 256) =>
// only 1/4 of screen. So the doubling<->display-extent relationship here is NOT understood — needs a full
// pixel-path trace (h_cnt/v_cnt -> ce_pix -> arcade_video -> screen_rotate -> FB) before any more scanout
// edits. is_odd=h_cnt[1] interleave + pixb_raw priority kept (interleave present, just not MAME-clean).
wire [7:0] effxa = scrollx + (scan_x[7:0] ^ xora);
wire [7:0] effya = scrolly + (scan_y ^ xora);
wire [7:0] effxb = scan_x[7:0] ^ xorb;
wire [7:0] effyb = scan_y ^ xorb;

// Scanout pipeline — DIAG-2026-06-18 PLANE-OFFSET FIX. Read BOTH planes EVERY cycle on their own
// same-latency ports (plane A = vram_lo/hi:B, plane B = vram_lo2/hi2:B) instead of alternating ONE
// shared port on h_cnt[0]. The old alternating read left plane A one COLUMN ahead of plane B at the
// compositing point → garbage-colored sprite EDGES (the 2-month fringe / "green poop"). Now both planes
// are ALIGNED to the same column. Slices are delayed one cycle to match the 1-cycle DPRAM read latency,
// identically for both planes. (Image may shift ~1px horizontally vs before — cosmetic; adjust hblank if so.)

reg [31:0] scan_word_a, scan_word_b;
reg [1:0]  scan_effxa_slice, scan_effxb_slice;

wire [13:0] scan_addr_a_w = {effxa[7:2], effya};
wire [13:0] scan_addr_b_w = {effxb[7:2], effyb};

assign vram_addr_b  = scan_addr_a_w;   // plane A read port (vram_lo/hi:B)
assign vram_addr_b2 = scan_addr_b_w;   // plane B read port (vram_lo2/hi2:B)

reg [1:0] effxa_slice_hold, effxb_slice_hold;

always_ff @(posedge clk_10m) begin
    // capture this cycle's slice indices (for the addresses presented this cycle)
    effxa_slice_hold <= effxa[1:0];
    effxb_slice_hold <= effxb[1:0];
    // latch both planes together: q_b holds data for the address presented LAST cycle (1-cycle DPRAM
    // latency), and the matching last-cycle slice → plane A and plane B aligned to the SAME column.
    scan_word_a      <= {vram_hi_qb,  vram_lo_qb};
    scan_word_b      <= {vram2_hi_qb, vram2_lo_qb};
    scan_effxa_slice <= effxa_slice_hold;
    scan_effxb_slice <= effxb_slice_hold;
end

// Extract pixel bytes from latched 32-bit words
wire [7:0] vram_slice_a = (scan_effxa_slice == 2'd0) ? scan_word_a[7:0] :
                          (scan_effxa_slice == 2'd1) ? scan_word_a[15:8] :
                          (scan_effxa_slice == 2'd2) ? scan_word_a[23:16] :
                                                       scan_word_a[31:24];

wire [7:0] vram_slice_b = (scan_effxb_slice == 2'd0) ? scan_word_b[7:0] :
                          (scan_effxb_slice == 2'd1) ? scan_word_b[15:8] :
                          (scan_effxb_slice == 2'd2) ? scan_word_b[23:16] :
                                                       scan_word_b[31:24];

wire [3:0] pixa_raw = vram_slice_a[3:0];   // Plane A = low nibble
wire [3:0] pixb_raw = vram_slice_b[7:4];   // Plane B = high nibble

// Priority compositing (MAME logic)
// Even pixels (first of pair): full brightness, no KOS1 masking
// Odd pixels (second of pair): apply KOS1 color mask for Z=0 pixels
// DIAG-2026-06-18: at the NEW 10MHz pixel sampling (arcade_video ce_pix_2x), arcade_video samples the
// core's RGB once per h_cnt, so consecutive display pixels share scan_x (= the doubling) and h_cnt[0]
// is the doubled-pixel parity → full / dimmed-copy alternation = MAME interleave. (Was h_cnt[1], the
// parity for the old 5MHz/256px path.) Source stays native scan_x = full 256-column content.
wire is_odd_pixel = h_cnt[0];

// (2026-06-18: plane-hold "bleed fix" REVERTED — had zero effect on HW, so the bleed is NOT plane-A/B
//  misalignment. Back to the straight KOS1 masking. Bleed cause now suspected = the scaler interpolating
//  the fine interleave pattern in the horizontally-stretched THIN framebuffer → fix is the WIDTH/aspect.)
wire [3:0] pixa_masked = (is_odd_pixel && !(pixa_raw[3])) ? (pixa_raw & {1'b0, maska}) : pixa_raw;
wire [3:0] pixb_masked = (is_odd_pixel && !(pixb_raw[3])) ? (pixb_raw & {1'b0, maskb}) : pixb_raw;

wire [3:0] pixa_final = is_odd_pixel ? pixa_masked : pixa_raw;
wire [3:0] pixb_final = is_odd_pixel ? pixb_masked : pixb_raw;

reg [2:0] final_color;
always_comb begin
    final_color = 3'd0;
    if (enaa && (pria || pixb_raw == 0))
        final_color = final_color | pixa_final[2:0];
    if (enab && (prib || pixa_final == 0))
        final_color = final_color | pixb_final[2:0];
end

// Output — BGR 3-bit palette (MAME: PALETTE(config, m_palette, palette_device::BGR_3BIT))
wire active_video = ~video_hblank & ~video_vblank;
assign video_r = active_video ? {final_color[2], final_color[2], final_color[2]} : 3'd0;
assign video_g = active_video ? {final_color[1], final_color[1], final_color[1]} : 3'd0;
assign video_b = active_video ? {final_color[0], final_color[0]} : 2'd0;

endmodule
