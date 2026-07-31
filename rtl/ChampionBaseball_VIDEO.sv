//============================================================================
//
//  ChampionBaseball_VIDEO.sv
//
//  Video for the Alpha Denshi champbas.cpp hardware.
//  MAME reference: champbas.cpp  (video code :240-521, screen cfg :986-995)
//
//  Hardware: 32x32 tilemap of 8x8 tiles + 8 hardware sprites.
//  NO SCROLL of any kind — `grep scroll champbas.cpp` returns nothing.
//  Screen: 256x224 visible (MAME visarea 0..255 x 16..239), ROT0 for champbas.
//
//  Structure adapted from Arcade-Kyugo's FG tilemap pipeline (Kyugo_CPU.sv:757-860),
//  which is the closest match in the fleet: unscrolled 8x8 tiles, per-tile colour
//  from a separate attribute plane, colour through a LUT PROM, 2bpp pens packed as
//  high/low nibble of one byte. Kyugo's BG pipeline is deliberately NOT used — all
//  of its scroll lookahead machinery solves a problem this hardware does not have.
//
//  THIS FILE IS INCOMPLETE BY DESIGN: the tilemap path is implemented, the sprite
//  layer is a stub (see SPRITE STUB below). Sprites are the next step.
//
//============================================================================

module ChampionBaseball_VIDEO
(
    input               clk,             // video clock
    input               cen_pix,         // pixel clock enable (target 6.144 MHz)
    input               reset,

    // ---- CPU port into tile RAM (0x8000-0x87FF, 2KB: 0x000-0x3FF codes, 0x400-0x7FF attrs)
    input       [10:0]  cpu_vram_addr,
    input        [7:0]  cpu_vram_din,
    input               cpu_vram_we,
    output       [7:0]  cpu_vram_dout,

    // ---- control bits from the LS259 mainlatch (champbas.cpp:970-978)
    input               flip_screen,     // latch bit 3, ALREADY de-inverted by the caller
    input               gfx_bank,        // latch bit 2
    input               palette_bank,    // latch bit 4

    // ---- gfx ROM port (champbas_rom index 2 region, 16KB)
    output      [13:0]  gfx_addr,
    input        [7:0]  gfx_data,

    // ---- colour LUT PROM port (champbas_rom index 7 region; LUT lives at 0x020-0x11F)
    output       [9:0]  prom_addr,
    input        [7:0]  prom_data,

    // ---- palette PROM snoop (see PALETTE PROM note below)
    input               clk_dl,
    input               ioctl_download,
    input        [7:0]  ioctl_index,
    input       [24:0]  ioctl_addr,
    input        [7:0]  ioctl_data,
    input               ioctl_wr,

    // ---- video out
    output       [7:0]  VGA_R,
    output       [7:0]  VGA_G,
    output       [7:0]  VGA_B,
    output              HSync,
    output              VSync,
    output              HBlank,
    output              VBlank
);

    ////////////////////////////////////////////////////////////////////////
    // Video timing
    //
    // MAME gives only set_size(256,256) + visarea 0..255 x 16..239 + 60 Hz
    // (champbas.cpp:987-989). This driver does NOT use set_raw(), so MAME
    // carries no real dot clock / blanking numbers for this board.
    //
    // #unverified: totals below are chosen to land on the standard 15 kHz
    // arcade line rate from the board's own 18.432 MHz XTAL, and to mirror
    // Kyugo's vertical structure (visible lines 16..239), which is identical:
    //   pixel clock 18.432/3 = 6.144 MHz
    //   384 x 264   ->  6.144e6/384 = 16.0 kHz H,  16000/264 = 60.6 Hz V
    // Confirm against real hardware; adjust H_TOTAL/V_TOTAL here only.
    ////////////////////////////////////////////////////////////////////////

    localparam H_TOTAL   = 9'd384;
    localparam H_VIS     = 9'd256;
    localparam HS_START  = 9'd272;
    localparam HS_END    = 9'd304;

    localparam V_TOTAL   = 9'd264;
    localparam V_VIS_LO  = 9'd16;    // first visible line  (MAME visarea min_y)
    localparam V_VIS_HI  = 9'd240;   // one past last        (MAME visarea max_y = 239)
    localparam VS_START  = 9'd244;
    localparam VS_END    = 9'd248;

    reg [8:0] h_cnt = 9'd0;
    reg [8:0] v_cnt = 9'd0;

    always_ff @(posedge clk) begin
        if (reset) begin
            h_cnt <= 9'd0;
            v_cnt <= 9'd0;
        end else if (cen_pix) begin
            if (h_cnt == H_TOTAL - 9'd1) begin
                h_cnt <= 9'd0;
                v_cnt <= (v_cnt == V_TOTAL - 9'd1) ? 9'd0 : v_cnt + 9'd1;
            end else begin
                h_cnt <= h_cnt + 9'd1;
            end
        end
    end

    wire hblk = (h_cnt >= H_VIS);
    wire vblk = (v_cnt < V_VIS_LO) || (v_cnt >= V_VIS_HI);

    assign HBlank = hblk;
    assign VBlank = vblk;
    assign HSync  = (h_cnt >= HS_START) && (h_cnt < HS_END);
    assign VSync  = (v_cnt >= VS_START) && (v_cnt < VS_END);

    ////////////////////////////////////////////////////////////////////////
    // Screen -> world coordinates
    //
    // champbas has no scroll, so world coords ARE screen coords; flip is a
    // straight mirror of both axes. LS259 bit 3 drives flip_screen_set with
    // .invert() (champbas.cpp:974) — the CALLER is responsible for undoing
    // that inversion, so `flip_screen` arriving here is already active-high.
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] h_raw = h_cnt[7:0];
    wire [7:0] v_raw = v_cnt[7:0];

    wire [7:0] sx = h_raw ^ {8{flip_screen}};
    wire [7:0] sy = v_raw ^ {8{flip_screen}};

    wire [4:0] tile_col = sx[7:3];
    wire [4:0] tile_row = sy[7:3];
    wire [2:0] fx       = sx[2:0];
    wire [2:0] fy       = sy[2:0];

    ////////////////////////////////////////////////////////////////////////
    // Tile RAM  (0x8000-0x87FF)
    //
    // 2KB dual-port: port A = CPU (read/write), port B = video fetch (read).
    // 0x000-0x3FF = tile codes, 0x400-0x7FF = per-tile colour attributes
    // (champbas.cpp:345-351, tilemap_w :505).
    ////////////////////////////////////////////////////////////////////////

    reg  [10:0] vram_raddr;
    wire  [7:0] vram_rdata;

    dpram_dc #(.widthad_a(11), .width_a(8)) tile_ram
    (
        .clock_a(clk),
        .address_a(cpu_vram_addr),
        .data_a(cpu_vram_din),
        .wren_a(cpu_vram_we),
        .q_a(cpu_vram_dout),

        .clock_b(clk),
        .address_b(vram_raddr),
        .data_b(8'd0),
        .wren_b(1'b0),
        .q_b(vram_rdata)
    );

    ////////////////////////////////////////////////////////////////////////
    // Tilemap fetch pipeline
    //
    // Adapted from Kyugo_CPU.sv:793-846. Kyugo's version carries a
    // `bg_row_lookahead` branch to cover the row-wrap discontinuity its
    // SCROLLING bg introduces; champbas has no scroll, so fx tracks h_cnt
    // directly every line and that entire branch is unnecessary.
    //
    // Per 8-pixel tile, on cen_pix:
    //   fx=0: address tile RAM for the NEXT tile (code)
    //   fx=1: latch code; address tile RAM for its attribute (+0x400)
    //   fx=2: latch attribute -> colour; address gfx ROM, byte at (y+8)
    //   fx=3: latch byte_hi; address gfx ROM, byte at (y)
    //   fx=4: latch byte_lo
    //   fx=7: promote _nxt -> _lat, becomes the tile displayed from next fx=0
    ////////////////////////////////////////////////////////////////////////

    // COL0-FIX-2026-07-30: column 0 of every line was showing the WRONG tile —
    // visible in sim as "CREDIT 00" rendering as "REDIT 00".
    //
    // The pipeline fetches one tile ahead, so the tile displayed at h_cnt=0 must
    // have been fetched during the PREVIOUS line's blanking. Left to run freely,
    // sx keeps counting through hblank (h_cnt 256..383 -> sx wraps 0..127), so the
    // tile latched at the h_cnt=383 promote was column 16's, not column 0's.
    //
    // This is Kyugo's `bg_row_lookahead` (Kyugo_CPU.sv:798), which I originally
    // dropped on the reasoning that it only serves scrolling. It does not — it also
    // PRIMES column 0, which every unscrolled tilemap needs just as much.
    //
    // v_cnt increments when h_cnt wraps, so the prime must use the NEXT line's row.
    wire [7:0] sy_next       = (v_raw + 8'd1) ^ {8{flip_screen}};
    wire [4:0] tile_row_next = sy_next[7:3];
    wire [2:0] fy_next       = sy_next[2:0];

    wire       prime         = (h_cnt >= 9'd376);

    wire [4:0] fetch_col = tile_col + 5'd1;   // always one tile ahead

    reg  [7:0] code_nxt;
    reg  [4:0] color_nxt;
    reg  [7:0] byte_lo_nxt, byte_hi_nxt;

    reg  [4:0] color_lat;
    reg  [7:0] byte_lo_lat, byte_hi_lat;

    reg [13:0] gfx_addr_r;
    assign gfx_addr = gfx_addr_r;

    // Char tiles occupy the low half of the index-2 region (0x0000-0x1FFF);
    // sprites occupy 0x2000-0x3FFF. Hence the leading 1'b0.
    // Tile is 16 bytes: {code[8:0], byte_select, fy[2:0]}.
    wire [8:0] code_full = {gfx_bank, code_nxt};

    always_ff @(posedge clk) begin
        if (cen_pix) begin
            if (prime) begin
                // Prime column 0 of the NEXT line. Sequenced directly by h_cnt (fixed
                // ticks every line) rather than by fx, and promoted at the last possible
                // tick for maximum freshness — same shape as Kyugo's lookahead window.
                case (h_cnt)
                    9'd376: vram_raddr <= {1'b0, tile_row_next, 5'd0};
                    9'd377: begin
                        code_nxt   <= vram_rdata;
                        vram_raddr <= {1'b1, tile_row_next, 5'd0};
                    end
                    9'd378: begin
                        color_nxt  <= vram_rdata[4:0];
                        gfx_addr_r <= {1'b0, code_full, 1'b1, fy_next};
                    end
                    9'd379: begin
                        byte_hi_nxt <= gfx_data;
                        gfx_addr_r  <= {1'b0, code_full, 1'b0, fy_next};
                    end
                    9'd380: byte_lo_nxt <= gfx_data;
                    9'd383: begin
                        color_lat   <= color_nxt;
                        byte_lo_lat <= byte_lo_nxt;
                        byte_hi_lat <= byte_hi_nxt;
                    end
                    default: ;
                endcase
            end else
            case (fx)
                3'd0: vram_raddr <= {1'b0, tile_row, fetch_col};
                3'd1: begin
                    code_nxt   <= vram_rdata;
                    vram_raddr <= {1'b1, tile_row, fetch_col};   // +0x400 attribute plane
                end
                3'd2: begin
                    // colour = (attr & 0x1f) | 0x20  (champbas.cpp:348). The |0x20 is a
                    // constant, so only the low 5 bits are stored; bit5 is reinserted
                    // at palette-index assembly below.
                    color_nxt  <= vram_rdata[4:0];
                    gfx_addr_r <= {1'b0, code_full, 1'b1, fy};   // byte at y+8
                end
                3'd3: begin
                    byte_hi_nxt <= gfx_data;
                    gfx_addr_r  <= {1'b0, code_full, 1'b0, fy};  // byte at y
                end
                3'd4: byte_lo_nxt <= gfx_data;
                3'd7: begin
                    color_lat   <= color_nxt;
                    byte_lo_lat <= byte_lo_nxt;
                    byte_hi_lat <= byte_hi_nxt;
                end
                default: ;
            endcase
        end
    end

    ////////////////////////////////////////////////////////////////////////
    // Pixel decode
    //
    // charlayout (champbas.cpp:830): 8x8, 2bpp, planes { 0, 4 },
    // xoffset { STEP4(8*8,1), STEP4(0,1) }, yoffset { STEP8(0,8) }, 16 bytes.
    //
    // Working that through: plane 0 is the HIGH nibble, plane 1 the LOW
    // nibble of the same byte, and within a nibble the MSB is the leftmost
    // pixel of that 4-pixel chunk.
    //
    // !! DIFFERS FROM KYUGO !! Because STEP4(8*8,1) comes FIRST in the
    // xoffset list, x=0..3 read the byte at offset y+8 and x=4..7 read the
    // byte at offset y. Kyugo's FG is the other way round (its comment at
    // Kyugo_CPU.sv:850 says x[2]=0 selects the byte at y). Copying Kyugo's
    // `fg_byte_sel` unchanged would swap each 4-pixel half of every tile.
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] byte_sel = fx[2] ? byte_lo_lat : byte_hi_lat;
    wire [1:0] xic      = ~fx[1:0];

    wire p0_bit = byte_sel[{1'b1, xic}];   // high nibble -> plane 0
    wire p1_bit = byte_sel[{1'b0, xic}];   // low  nibble -> plane 1

    wire [1:0] tile_pix = {p0_bit, p1_bit};

    // Pen index within the 512-entry space: {colour[5:0], pen[1:0]}.
    // colour[5] is the constant 1 from the |0x20 above.
    wire [7:0] tile_pen = {1'b1, color_lat[4:0], tile_pix};

    ////////////////////////////////////////////////////////////////////////
    // SPRITE STUB — not yet implemented.
    //
    // champbas.cpp:387-418. 8 sprites, iterated offs=0x0E down to 0 step -2.
    //   x/y   from spriteram 0xA060-0xA06F
    //   code/colour/flip from MAIN RAM 0x8FF0-0x8FFF  (not spriteram!)
    //   sx = spriteram[offs+1] - 16 ; sy = 255 - spriteram[offs]
    //   flipx = ~attr & 1, flipy = ~attr & 2   (both ACTIVE LOW)
    //   drawn twice: at sx and at sx+256 (horizontal wraparound)
    // Priority is sprites OVER the tilemap (screen_update_champbas :465
    // draws the tilemap first, then sprites).
    //
    // Until implemented, the sprite layer is permanently transparent so the
    // tilemap can be brought up and verified on its own.
    ////////////////////////////////////////////////////////////////////////

    wire       spr_opaque = 1'b0;
    wire [7:0] spr_pen    = 8'd0;

    ////////////////////////////////////////////////////////////////////////
    // Colour lookup
    //
    // Two-stage indirect palette (champbas.cpp:240-285):
    //   stage 1: pen[7:0] -> LUT PROM -> 4-bit colour index low nibble
    //   stage 2: {palette_bank, lut[3:0]} -> 32-entry palette PROM -> RGB
    //
    // The bit-4 term: MAME computes
    //   ctabentry = (lut[i & 0xff] & 0x0f) | ((i & 0x100) >> 4)
    // i.e. colour_index[4] = pen[8]. Working both the tilemap path
    // (palette offset palette_bank<<8) and the sprite path (colour |=
    // palette_bank<<6, x4 pens) through to a pen index shows pen[8] ==
    // palette_bank in BOTH cases, so bit 4 is simply palette_bank and the
    // 512-pen space never needs to be materialised.
    //
    // LUT PROM sits at 0x020 in the index-7 region (palette PROM is 0x000-0x01F).
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] active_pen = spr_opaque ? spr_pen : tile_pen;

    assign prom_addr = 10'h020 + {2'd0, active_pen};

    wire [4:0] color_index = {palette_bank, prom_data[3:0]};

    ////////////////////////////////////////////////////////////////////////
    // Palette PROM (32 x 8)
    //
    // Held as registers rather than sharing the index-7 BRAM: that BRAM has a
    // single core-side read port, and the LUT lookup above needs it every
    // pixel. 32 bytes is cheap in FFs and removes the contention entirely.
    // Snooped straight off the download stream (index 7, addr 0x000-0x01F).
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] pal_prom [0:31];

    always_ff @(posedge clk_dl) begin
        if (ioctl_wr && ioctl_download && (ioctl_index == 8'd7) && (ioctl_addr < 25'h20))
            pal_prom[ioctl_addr[4:0]] <= ioctl_data;
    end

    wire [7:0] pal_byte = pal_prom[color_index];

    ////////////////////////////////////////////////////////////////////////
    // Resistor-network DAC (champbas.cpp:243-251)
    //
    //   R: bits 0-2 through 1k / 470 / 220
    //   G: bits 3-5 through 1k / 470 / 220
    //   B: bits 6-7 through       470 / 220
    //
    // MAME calls compute_resistor_weights(0,255,...) which normalises each
    // channel to full scale. For 1k/470/220 that yields the familiar
    // 0x21 / 0x47 / 0x97 triple (the same constants exctsccr_palette :301
    // hardcodes). For the 2-resistor blue leg, 470/220 normalises to
    // 0x51 / 0xAE. Each channel's weights sum to 0xFF.
    ////////////////////////////////////////////////////////////////////////

    function automatic [7:0] rgb3;
        input b0, b1, b2;
        begin
            rgb3 = (b0 ? 8'h21 : 8'h00) + (b1 ? 8'h47 : 8'h00) + (b2 ? 8'h97 : 8'h00);
        end
    endfunction

    function automatic [7:0] rgb2;
        input b0, b1;
        begin
            rgb2 = (b0 ? 8'h51 : 8'h00) + (b1 ? 8'hAE : 8'h00);
        end
    endfunction

    wire [7:0] r_lvl = rgb3(pal_byte[0], pal_byte[1], pal_byte[2]);
    wire [7:0] g_lvl = rgb3(pal_byte[3], pal_byte[4], pal_byte[5]);
    wire [7:0] b_lvl = rgb2(pal_byte[6], pal_byte[7]);

    wire blanking = hblk || vblk;

    assign VGA_R = blanking ? 8'd0 : r_lvl;
    assign VGA_G = blanking ? 8'd0 : g_lvl;
    assign VGA_B = blanking ? 8'd0 : b_lvl;

endmodule
