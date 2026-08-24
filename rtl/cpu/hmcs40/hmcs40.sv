//============================================================================
//
//  hmcs40 — Hitachi HMCS40-family MCU core, fixed to the HD44801 (HMCS44
//  family) configuration used by the ALPHA-8201/8302/8303 protection MCU.
//
//  Ported from MAME's cpu/hmcs40/{hmcs40.cpp,hmcs40op.cpp,hmcs40.h} (license
//  BSD-3-Clause, copyright hap), staged at:
//    Useful Information/mame/cpu/hmcs40/{hmcs40.cpp,hmcs40op.cpp,hmcs40.h,hmcs40d.cpp}
//  Every behavioural claim in this file's comments cites a line in that
//  staged source; nothing here is invented. See README.md in this directory
//  for the full opcode-coverage proof and open questions.
//
//  HD44801 = HMCS44 family (hmcs40.cpp:46, hmcs40.cpp:113-128):
//    stack_levels = 4, pcwidth = 11, prgwidth = 12 (program_2k, 4096 words),
//    datawidth = 8 (data_160x4, 160 x 4-bit RAM), polarity = CMOS.
//  NOTE: the task brief's "HD44801 -> HMCS43" is WRONG per hmcs40.cpp:46/123
//  — hd44801_device inherits hmcs44_cpu_device, not hmcs43_cpu_device. HMCS43
//  has only 3 stack levels, 80x4 RAM and no R4/R5 ports; HMCS44 has 4 levels,
//  160x4 RAM and R4/R5 as extra (unbound, dead) ports. This file implements
//  HMCS44 parameters throughout — verified by reading the constructor chain
//  directly (hmcs40.cpp:46 DEFINE_DEVICE_TYPE(HD44801,...) plus :113-128
//  hmcs44_cpu_device's ctor args), not assumed from the task brief.
//
//  Clocking model
//  --------------
//  `clk` : free-running system clock (fast; used for internal sequencing and
//          for the ROM request/ack handshake).
//  `cen` : one-clk-wide pulse, once per emulated machine cycle (4 OSC clocks
//          on real silicon; for champbas/exctsccr/talbot that's
//          XTAL(18.432MHz)/6/8/4 -> the wrapper generates this pulse train,
//          NOT this module). Every register commit that corresponds to one
//          MAME cycle() call (hmcs40.cpp:647-651, called once per
//          instruction fetch, once more inside op_p(), once more inside
//          take_interrupt()) consumes exactly one `cen` pulse here, so the
//          prescaler/timer rate matches hmcs40.cpp's icount accounting.
//  ROM is a request/ack handshake (rom_req/rom_addr/rom_data/rom_ack), not a
//  fixed-latency bus: the wrapper's BRAM (2 sequential byte reads through
//  champbas_rom's 13-bit mcu_addr/mcu_data port — see alpha8201.sv) needs
//  more than one `clk` to answer. Requests are issued as soon as the target
//  address is known, well before the qualifying `cen`, so ROM latency need
//  only stay under one `cen` period, not be zero.
//
//  KNOWN APPROXIMATION (documented, not silently swept under the rug): when
//  an INT1-edge counter-mode tc bump (hmcs40.cpp:598-599) lands on the exact
//  same clk edge as an FSM commit, the FSM commit wins and the INT1 bump for
//  that cycle is dropped. This is moot for ALPHA-8201: alpha8201.cpp's pin
//  table lists "31 INT1 n.c." (not connected), so int1_in is tied 0 by the
//  wrapper and this path never executes in the actual application. Kept
//  here only because this module is written as a general HD44801 core.
//
//============================================================================

module hmcs40 (
    input  wire        clk,
    input  wire         reset,       // sync, active-high
    input  wire         cen,         // 1 clk-wide, one pulse per machine cycle
    input  wire         hlt_in,      // HMCS40_INPUT_LINE_HLT (hmcs40.cpp:578) — active high halts the core

    // ROM interface — word space, 12-bit word address (4096 x 10-bit,
    // packed into 16-bit words per hmcs40.cpp's ENDIANNESS_LITTLE/16-wide
    // program space), request/ack handshake.
    output reg          rom_req,
    output reg  [11:0]  rom_addr,
    input  wire [15:0]  rom_data,
    input  wire          rom_ack,

    // R0-R7 ports, 4 bit each. HD44801/HMCS44: R0-R3 i/o, R4/R5 exist as
    // internal-only registers (no pins on this device; hmcs40.cpp:474-482
    // still routes them through the same read/write callback array, so a
    // wrapper that leaves r4_in/r5_in tied to 0 gets bit-exact "reads as 0"
    // behaviour for free), R6/R7 do not exist on HMCS44 either (writes
    // logged as ineffective, reads log "unknown" — hmcs40.cpp:474-482 — the
    // core still permits the access since MAME does too, it just never
    // reaches a real pin on this device).
    input  wire [3:0]  r0_in, r1_in, r2_in, r3_in, r4_in, r5_in, r6_in, r7_in,
    output wire [3:0]  r0_out, r1_out, r2_out, r3_out, r4_out, r5_out, r6_out, r7_out,

    // D0-D15 discrete i/o (hmcs40.cpp:406-424). HMCS44 has no read_d/
    // write_d override (hmcs40.h:344-352 declares none) so all 16 bits are
    // plain i/o at the base-class level.
    input  wire [15:0] d_in,
    output wire [15:0] d_out,

    // D-WRITE-STROBE-2026-08-01: one-cycle pulse whenever an instruction WRITES
    // the D port (SED/RED/SEDD/REDD), asserted even if the value is unchanged.
    // This is MAME's `m_write_d(...)` callback -> alpha_8201_device::mcu_d_w(),
    // which is the ONLY thing that latches the MCU's shared-RAM address and
    // commits its write. Without a real strobe the wrapper had to infer the
    // event from a value CHANGE, which misses same-value rewrites — and the
    // wrapper's actual behaviour was worse still: a LEVEL-triggered write that
    // fired every clock while the enable held, scribbling {R0,R1} across every
    // address the ports transiently passed through.
    output wire         d_we,

    // R-WRITE-STROBE-2026-08-01: one-cycle pulse when an instruction writes
    // R0-R3. MAME binds write_r<0..3> to alpha_8201_device::mcu_data_w(), which
    // calls mcu_update_address() -> mcu_writeram(). So an R0-R3 write is ALSO a
    // shared-RAM commit trigger, not just a D write. r_we_idx says which port.
    output wire         r_we,
    output wire  [2:0]  r_we_idx,

    // INT0/INT1 pins (HMCS40_INPUT_LINE_INT0/1, hmcs40.cpp:573-603)
    input  wire         int0_in,
    input  wire         int1_in,

    // debug/observability (not part of the MAME model — added for the
    // sim harness and for LED/audio-hijack style bring-up on HW)
    output wire [10:0] dbg_pc,
    output wire [9:0]  dbg_op,
    output wire         dbg_illegal,     // combinational, high the cycle an ILL opcode is dispatched
    output wire [3:0]  dbg_a, dbg_b, dbg_x, dbg_y
);

    // ------------------------------------------------------------------
    // Fixed HD44801 (HMCS44) parameters (hmcs40.cpp:113-114)
    // ------------------------------------------------------------------
    localparam [10:0] PC_MASK = 11'h7FF;   // pcwidth=11 -> pc 0-2047

    // ------------------------------------------------------------------
    // Instruction IDs — bijective with the 84 op_xxx handlers in
    // hmcs40.h, in the exact order they're declared there. ID 0 = illegal
    // (op_illegal, hmcs40op.cpp:41-44). Cross-validated against BOTH MAME's
    // disassembler table (hmcs40d.cpp:111-200) and its interpreter switch
    // (hmcs40.cpp:686-793) for all 1024 opcodes — see README.md "Opcode
    // coverage proof": mechanical, 0 mismatches, 84/84 handlers bijective
    // with 84 distinct table mnemonics, 480 legal + 544 illegal = 1024.
    // ------------------------------------------------------------------
    localparam [6:0]
        I_ILL   = 7'd0,
        I_LAB   = 7'd1,  I_LBA   = 7'd2,  I_LAY   = 7'd3,  I_LASPX = 7'd4,  I_LASPY = 7'd5,  I_XAMR  = 7'd6,
        I_LXA   = 7'd7,  I_LYA   = 7'd8,  I_LXI   = 7'd9,  I_LYI   = 7'd10, I_IY    = 7'd11, I_DY    = 7'd12,
        I_AYY   = 7'd13, I_SYY   = 7'd14, I_XSP   = 7'd15,
        I_LAM   = 7'd16, I_LBM   = 7'd17, I_XMA   = 7'd18, I_XMB   = 7'd19, I_LMAIY = 7'd20, I_LMADY = 7'd21,
        I_LMIIY = 7'd22, I_LAI   = 7'd23, I_LBI   = 7'd24,
        I_AI    = 7'd25, I_IB    = 7'd26, I_DB    = 7'd27, I_AMC   = 7'd28, I_SMC   = 7'd29, I_AM    = 7'd30,
        I_DAA   = 7'd31, I_DAS   = 7'd32, I_NEGA  = 7'd33, I_COMB  = 7'd34, I_SEC   = 7'd35, I_REC   = 7'd36,
        I_TC    = 7'd37, I_ROTL  = 7'd38, I_ROTR  = 7'd39, I_OR    = 7'd40,
        I_MNEI  = 7'd41, I_YNEI  = 7'd42, I_ANEM  = 7'd43, I_BNEM  = 7'd44, I_ALEI  = 7'd45, I_ALEM  = 7'd46, I_BLEM = 7'd47,
        I_SEM   = 7'd48, I_REM   = 7'd49, I_TM    = 7'd50,
        I_BR    = 7'd51, I_CAL   = 7'd52, I_LPU   = 7'd53, I_TBR   = 7'd54, I_RTN   = 7'd55,
        I_SEIE  = 7'd56, I_SEIF0 = 7'd57, I_SEIF1 = 7'd58, I_SETF  = 7'd59, I_SECF  = 7'd60,
        I_REIE  = 7'd61, I_REIF0 = 7'd62, I_REIF1 = 7'd63, I_RETF  = 7'd64, I_RECF  = 7'd65,
        I_TI0   = 7'd66, I_TI1   = 7'd67, I_TIF0  = 7'd68, I_TIF1  = 7'd69, I_TTF   = 7'd70,
        I_LTI   = 7'd71, I_LTA   = 7'd72, I_LAT   = 7'd73, I_RTNI  = 7'd74,
        I_SED   = 7'd75, I_RED   = 7'd76, I_TD    = 7'd77, I_SEDD  = 7'd78, I_REDD  = 7'd79,
        I_LAR   = 7'd80, I_LBR   = 7'd81, I_LRA   = 7'd82, I_LRB   = 7'd83, I_P     = 7'd84;

    // ------------------------------------------------------------------
    // Decoder — a standalone module (hmcs40_decoder.sv, same directory)
    // so the Verilator harness can instantiate exactly this hardware and
    // mechanically sweep all 1024 opcodes against the golden table
    // exported by hmcs40_coverage.py (see that module's header and
    // README.md "Opcode coverage proof"). Wired continuously to the raw
    // ROM data bus — cheap (a handful of comparators), and every use
    // site below reads op_id_from_rom instead of calling a function.
    // ------------------------------------------------------------------
    wire [6:0] op_id_from_rom;
    hmcs40_decoder u_decoder (.op(rom_data[9:0]), .id(op_id_from_rom));

    // ------------------------------------------------------------------
    // Register file (hmcs40.h:160-182)
    // ------------------------------------------------------------------
    reg [10:0] pc;                 // program counter (pc[10:6]=page, pc[5:0]=LFSR)
    reg [4:0]  pc_upper;           // LPU-latched upper bits (hmcs40op.cpp:462-476)
    reg [3:0]  a, b, x, spx, y, spy;
    reg        s, c;               // status, carry flip-flops
    reg [10:0] stack0, stack1, stack2, stack3; // hardware call stack (hmcs40op.cpp:24-36)

    reg [3:0]  tc;                 // timer/counter (hmcs40.h:173)
    reg        cf;                 // 0=timer mode, 1=counter mode (hmcs40.h:174)
    reg        ie;                 // interrupt enable (hmcs40.h:175)
    reg        iri, irt;           // pending external/timer interrupt (hmcs40.h:176-177)
    reg        if0, if1;           // external interrupt masks (hmcs40.h:178)
    reg        tf;                 // timer interrupt mask (hmcs40.h:179)
    reg [5:0]  prescaler;          // hmcs40.h:158

    reg [3:0]  r_lat0, r_lat1, r_lat2, r_lat3, r_lat4, r_lat5, r_lat6, r_lat7; // hmcs40.h:181, m_r[]
    reg [15:0] d_lat;              // D-port output latch (hmcs40.h:182, m_d)
    reg        d_we_r;             // D-WRITE-STROBE-2026-08-01 (1-cycle pulse)
    reg        r_we_r;             // R-WRITE-STROBE-2026-08-01 (1-cycle pulse)
    reg [2:0]  r_we_idx_r;

    reg        int0_q, int1_q;     // edge-detect regs for INT0/INT1 pins
    reg        eint_line;          // which pin caused the pending external IRQ (0/1)

    reg [1:0]  lpu_pend;           // 2-deep shift: LPU-taken delay slot (see file header)
    reg        block_int;          // 1-instruction "just did taken CAL/LPU" interrupt block

    reg        halted;

    wire int0_edge = int0_in & ~int0_q;
    wire int1_edge = int1_in & ~int1_q;

    // ------------------------------------------------------------------
    // R-port / D-port combinational read (CMOS wired-AND polarity,
    // hmcs40.cpp:392-395/411-414 with m_polarity = IS_CMOS = all-ones)
    // ------------------------------------------------------------------
    assign r0_out = r_lat0; assign r1_out = r_lat1; assign r2_out = r_lat2; assign r3_out = r_lat3;
    assign r4_out = r_lat4; assign r5_out = r_lat5; assign r6_out = r_lat6; assign r7_out = r_lat7;
    assign d_out  = d_lat;
    assign d_we    = d_we_r;   // D-WRITE-STROBE-2026-08-01
    assign r_we    = r_we_r;   // R-WRITE-STROBE-2026-08-01
    assign r_we_idx = r_we_idx_r;

    function automatic [3:0] read_r(input [2:0] idx);
        case (idx)
            3'd0: read_r = r0_in & r_lat0;
            3'd1: read_r = r1_in & r_lat1;
            3'd2: read_r = r2_in & r_lat2;
            3'd3: read_r = r3_in & r_lat3;
            3'd4: read_r = r4_in & r_lat4;
            3'd5: read_r = r5_in & r_lat5;
            3'd6: read_r = r6_in & r_lat6;
            default: read_r = r7_in & r_lat7;
        endcase
    endfunction

    function automatic read_d(input [3:0] idx);
        // hmcs40.cpp:406-414, CMOS: BIT(inp & m_d, index); inp = external read_d handler
        read_d = (d_in[idx] & d_lat[idx]);
    endfunction

    // ------------------------------------------------------------------
    // Data RAM — 160 x 4-bit (hmcs40.cpp:353-358 data_160x4), addressed
    // over an 8-bit space with two mirrored 16-entry windows. Implemented
    // as a flat 256-entry array (only 160 unique locations ever addressed)
    // — trivially small (1Kbit), no BRAM needed.
    // ------------------------------------------------------------------
    reg [3:0] dram [0:255];

    function automatic [7:0] ram_phys(input [7:0] addr);
        if (addr < 8'h80)      ram_phys = addr;                    // 0x00-0x7F direct (128)
        else if (addr < 8'hC0) ram_phys = {4'h8, addr[3:0]};       // 0x80-0xBF -> 0x80-0x8F (16)
        else                   ram_phys = {4'hC, addr[3:0]};       // 0xC0-0xFF -> 0xC0-0xCF (16)
    endfunction

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    localparam [2:0]
        S_RESET     = 3'd0,
        S_TOP       = 3'd1,   // Step1(LPU fixup)+Step2(shift regs)+Step3(int check) — hmcs40.cpp:663-676
        S_INT_ENTRY = 3'd2,   // wait for cen: push_stack + redirect to vector (take_interrupt, hmcs40.cpp:551-571)
        S_FETCH_REQ = 3'd3,   // issue rom_req for the (possibly redirected) pc
        S_FETCH_WAIT= 3'd4,   // wait for rom_ack & cen: commit fetch + decode + execute
        S_P_WAIT    = 3'd6;   // P only: wait for rom_ack & cen: commit pattern write-back
    reg [2:0] state;

    reg [9:0] op_cur;          // opcode currently being executed (post-fetch, pre-decode-registration)
    reg [3:0] i_rev;           // reversed 4-bit immediate (hmcs40.cpp:681, m_i)
    reg [10:0] fetch_pc;       // pc value used for THIS fetch (captured before increment) / interrupt return addr
    reg [10:0] pc_next_lfsr;   // LFSR-advanced pc, computed at fetch-issue time
    reg [10:0] pc_after_p;     // pc to restore once P's deferred write-back completes
    reg        rom_data_ready; // rom_ack arrived but a qualifying `cen` hasn't yet — see
                                // commit_fetch/commit_p below: rom_ack is a short pulse
                                // from the bridge and can arrive well before the `cen`
                                // that's actually allowed to consume it (this is what
                                // keeps the machine-cycle rate pinned to `cen`, not to
                                // however fast the ROM bridge happens to answer — a real
                                // bug in an earlier version of this file: the FSM was
                                // committing on rom_ack alone, so the whole core free-ran
                                // at ROM-bridge speed instead of the intended ~cen rate;
                                // caught by the Verilator harness, not by inspection).

    wire [10:0] pc_fixedup = lpu_pend[1] ? {pc_upper, pc[5:0]} : pc;

    // LFSR PC increment — bit-exact transcription of hmcs40.cpp:632-645
    // ("PC lower bits is a LFSR identical to TI TMS1000", two hardcoded
    // special-case wrap conditions).
    function automatic [10:0] increment_pc(input [10:0] pc_in);
        reg [5:0] low, mask;
        reg       fb;
        begin
            mask = 6'h3F;
            low  = pc_in[5:0];
            fb   = ((low << 1) & 6'h20) == (low & 6'h20);
            if (low == (mask >> 1))       fb = 1'b1;   // low == 0x1F
            else if (low == mask)         fb = 1'b0;   // low == 0x3F
            increment_pc = {pc_in[10:6], ((low << 1) | fb) & mask};
        end
    endfunction

    // ==================================================================
    // Combinational execute stage — given a freshly-fetched op (op_w) and
    // the "post-increment" pc that will follow it (next_pc_w), compute
    // every register's next value. Mirrors hmcs40op.cpp op_xxx() bodies.
    // For I_ILL, every n_* defaults to "hold current value" except n_pc
    // (still advances) — matches op_illegal() (hmcs40op.cpp:41-44, logs
    // only, no state change) plus the fact that Step4's fetch/increment_pc
    // already happened before dispatch regardless of legality.
    // P defers its own write-back to S_P_WAIT (op_p() does an extra ROM
    // read; hmcs40op.cpp:668-690) — this task only computes the pattern
    // address for that second request.
    // ==================================================================
    reg [3:0] n_a, n_b, n_x, n_spx, n_y, n_spy;
    reg       n_s, n_c;
    reg [10:0] n_pc;
    reg [4:0]  n_pc_upper;
    reg [3:0]  n_r_any; reg [2:0] n_r_any_idx; reg n_r_any_we;
    reg [15:0] n_d;
    reg        n_d_we;             // D-WRITE-STROBE-2026-08-01
    reg        push_req;           // request a stack push this cycle (return addr = next_pc_w)
    reg        pop_req;            // request a stack pop this cycle
    reg        ram_we;
    reg [7:0]  ram_we_addr;
    reg [3:0]  ram_we_data;
    reg        lpu_taken_now, cal_taken_now;
    reg        want_p_fetch;
    reg [11:0] p_addr_w;
    reg [6:0]  id_w;
    reg        tc_explicit_we;      // LTI/LTA: this instruction sets tc directly (also resets prescaler)
    reg [3:0]  tc_explicit_val;
    reg        tf_set_now, tf_clr_now; // SETF / RETF

    task automatic exec_instr(input [9:0] op_w, input [3:0] irev_w, input [10:0] next_pc_w);
        reg [11:0] addr12;
        reg [4:0]  t5;
        reg [3:0]  ram_val;   // dram[ram_phys({x,y})], read once per instruction — also
                               // sidesteps chaining a variable bit-select directly off an
                               // array-read expression (TM), which is the exact pattern
                               // CLAUDE.md flags as a Quartus 17.0 .v elaboration trap;
                               // named intermediate here even though this is a .sv file.
        begin
            // op_w is always called with rom_data[9:0] (see the
            // exec_instr() call site in S_FETCH_WAIT below), so the
            // continuously-decoded op_id_from_rom is exactly this
            // instruction's id — no need to decode op_w again.
            id_w = op_id_from_rom;
            ram_val = dram[ram_phys({x, y})];

            // defaults: hold state
            n_a = a; n_b = b; n_x = x; n_spx = spx; n_y = y; n_spy = spy;
            n_s = s; n_c = c;
            n_pc = next_pc_w;
            n_pc_upper = pc_upper;
            n_r_any_we = 1'b0; n_r_any_idx = 3'd0; n_r_any = 4'h0;
            n_d = d_lat;
            n_d_we = 1'b0;    // D-WRITE-STROBE-2026-08-01
            push_req = 1'b0; pop_req = 1'b0;
            ram_we = 1'b0; ram_we_addr = 8'h0; ram_we_data = 4'h0;
            lpu_taken_now = 1'b0; cal_taken_now = 1'b0;
            want_p_fetch = 1'b0; p_addr_w = 12'h0;
            tc_explicit_we = 1'b0; tc_explicit_val = 4'h0;
            tf_set_now = 1'b0; tf_clr_now = 1'b0;

            case (id_w)
                // -- register-to-register (hmcs40op.cpp:49-99) ----------
                I_LAB:   n_a = b;
                I_LBA:   n_b = a;
                I_LAY:   n_a = y;
                I_LASPX: n_a = spx;
                I_LASPY: n_a = spy;
                I_XAMR: begin
                    n_a = dram[ram_phys({4'hF, op_w[3:0]})];
                    ram_we = 1'b1; ram_we_addr = {4'hF, op_w[3:0]}; ram_we_data = a;
                end

                // -- RAM address instructions (hmcs40op.cpp:104-173) ----
                I_LXA: n_x = a;
                I_LYA: n_y = a;
                I_LXI: n_x = irev_w;
                I_LYI: n_y = irev_w;
                I_IY:  begin n_y = y + 4'd1; n_s = (n_y != 4'd0); end
                I_DY:  begin n_y = y - 4'd1; n_s = (n_y != 4'hF); end
                I_AYY: {n_s, n_y} = {1'b0, y} + {1'b0, a};
                I_SYY: begin {n_s, n_y} = {1'b0, y} - {1'b0, a}; n_s = ~n_s; end
                I_XSP: begin
                    if (op_w[0]) begin n_x = spx; n_spx = x; end
                    if (op_w[1]) begin n_y = spy; n_spy = y; end
                end

                // -- RAM register instructions (hmcs40op.cpp:178-224),
                // all followed by the same XSP(op&3) swap as XSP above --
                I_LAM: begin
                    n_a = ram_val;
                    if (op_w[0]) begin n_x = spx; n_spx = x; end
                    if (op_w[1]) begin n_y = spy; n_spy = y; end
                end
                I_LBM: begin
                    n_b = ram_val;
                    if (op_w[0]) begin n_x = spx; n_spx = x; end
                    if (op_w[1]) begin n_y = spy; n_spy = y; end
                end
                I_XMA: begin
                    n_a = ram_val;
                    ram_we = 1'b1; ram_we_addr = {x, y}; ram_we_data = a;
                    if (op_w[0]) begin n_x = spx; n_spx = x; end
                    if (op_w[1]) begin n_y = spy; n_spy = y; end
                end
                I_XMB: begin
                    n_b = ram_val;
                    ram_we = 1'b1; ram_we_addr = {x, y}; ram_we_data = b;
                    if (op_w[0]) begin n_x = spx; n_spx = x; end
                    if (op_w[1]) begin n_y = spy; n_spy = y; end
                end
                I_LMAIY: begin
                    ram_we = 1'b1; ram_we_addr = {x, y}; ram_we_data = a;
                    n_y = y + 4'd1; n_s = (n_y != 4'd0);
                    if (op_w[0]) begin n_x = spx; n_spx = x; end
                end
                I_LMADY: begin
                    ram_we = 1'b1; ram_we_addr = {x, y}; ram_we_data = a;
                    n_y = y - 4'd1; n_s = (n_y != 4'hF);
                    if (op_w[0]) begin n_x = spx; n_spx = x; end
                end

                // -- immediate instructions (hmcs40op.cpp:229-246) ------
                I_LMIIY: begin
                    ram_we = 1'b1; ram_we_addr = {x, y}; ram_we_data = irev_w;
                    n_y = y + 4'd1; n_s = (n_y != 4'd0);
                end
                I_LAI: n_a = irev_w;
                I_LBI: n_b = irev_w;

                // -- arithmetic (hmcs40op.cpp:251-369) -------------------
                I_AI:  {n_s, n_a} = {1'b0, a} + {1'b0, irev_w};
                I_IB:  begin n_b = b + 4'd1; n_s = (n_b != 4'd0); end
                I_DB:  begin n_b = b - 4'd1; n_s = (n_b != 4'hF); end
                I_AMC: begin
                    {n_c, n_a} = {1'b0, a} + {1'b0, ram_val} + {4'b0, c};
                    n_s = n_c;
                end
                I_SMC: begin
                    t5 = {1'b0, ram_val} - {1'b0, a} - {4'b0, (c ^ 1'b1)};
                    n_c = ~t5[4];
                    n_a = t5[3:0];
                    n_s = n_c;
                end
                I_AM:  {n_s, n_a} = {1'b0, a} + {1'b0, ram_val};
                I_DAA: if (c || (a > 4'd9)) begin n_a = a + 4'd6; n_c = 1'b1; end
                I_DAS: if (!c || (a > 4'd9)) begin n_a = a + 4'd10; n_c = 1'b0; end
                I_NEGA: n_a = (4'd0 - a);
                I_COMB: n_b = ~b;
                I_SEC: n_c = 1'b1;
                I_REC: n_c = 1'b0;
                I_TC:  n_s = c;
                I_ROTL: {n_c, n_a} = {a, c};
                I_ROTR: begin n_c = a[0]; n_a = {c, a[3:1]}; end
                I_OR:  n_a = a | b;

                // -- compare (hmcs40op.cpp:374-414), all set S only ------
                I_MNEI: n_s = (irev_w != ram_val);
                I_YNEI: n_s = (y != irev_w);
                I_ANEM: n_s = (a != ram_val);
                I_BNEM: n_s = (b != ram_val);
                I_ALEI: n_s = (a <= irev_w);
                I_ALEM: n_s = (a <= ram_val);
                I_BLEM: n_s = (b <= ram_val);

                // -- RAM bit manipulation (hmcs40op.cpp:419-435) ---------
                I_SEM: begin ram_we=1'b1; ram_we_addr={x,y}; ram_we_data = ram_val | (4'b0001 << op_w[1:0]); end
                I_REM: begin ram_we=1'b1; ram_we_addr={x,y}; ram_we_data = ram_val & ~(4'b0001 << op_w[1:0]); end
                I_TM:  n_s = ram_val[op_w[1:0]];

                // -- ROM address instructions (hmcs40op.cpp:440-489) -----
                I_BR: begin
                    if (s) n_pc = {next_pc_w[10:6], op_w[5:0]};
                    else   n_s = 1'b1;
                end
                I_CAL: begin
                    if (s) begin
                        cal_taken_now = 1'b1;
                        push_req = 1'b1;
                        n_pc = {5'b0, op_w[5:0]}; // "short calls default to page 0"
                    end else
                        n_s = 1'b1;
                end
                I_LPU: begin
                    if (s) begin
                        lpu_taken_now = 1'b1;
                        n_pc_upper = op_w[4:0];
                    end
                    // family==HMCS46/47 R70-bank merge N/A for HMCS44
                end
                I_TBR: begin
                    addr12 = ({8'b0, a} | ({8'b0, b} << 4) | ({11'b0, c} << 8) |
                              ({9'b0, op_w[2:0]} << 9) | ({1'b0, next_pc_w} & 12'hFC0));
                    n_pc = addr12[10:0] & PC_MASK;
                end
                I_RTN: pop_req = 1'b1;

                // -- interrupt instructions (hmcs40op.cpp:494-609) -------
                I_SEIE:  ; // handled via ie commit below (n_pc default already holds)
                I_SEIF0: ;
                I_SEIF1: ;
                I_SETF:  tf_set_now = 1'b1;
                I_SECF:  ;
                I_REIE:  ;
                I_REIF0: ;
                I_REIF1: ;
                I_RETF:  tf_clr_now = 1'b1;
                I_RECF:  ;
                I_TI0:   n_s = int0_q;
                I_TI1:   n_s = int1_q;
                I_TIF0:  n_s = if0;
                I_TIF1:  n_s = if1;
                I_TTF:   n_s = tf;
                I_LTI:   begin tc_explicit_we = 1'b1; tc_explicit_val = irev_w; end
                I_LTA:   begin tc_explicit_we = 1'b1; tc_explicit_val = a; end
                I_LAT:   n_a = tc;
                I_RTNI:  pop_req = 1'b1; // ie<=1 handled via id_w==I_RTNI check in ie commit below

                // -- input/output (hmcs40op.cpp:614-690) -----------------
                // D-WRITE-STROBE-2026-08-01: these four are exactly MAME's
                // write_d call sites for this device.
                I_SED:  begin n_d[y] = 1'b1;         n_d_we = 1'b1; end
                I_RED:  begin n_d[y] = 1'b0;         n_d_we = 1'b1; end
                I_TD:   n_s = read_d(y);
                I_SEDD: begin n_d[op_w[1:0]] = 1'b1; n_d_we = 1'b1; end
                I_REDD: begin n_d[op_w[1:0]] = 1'b0; n_d_we = 1'b1; end
                I_LAR:  n_a = read_r(op_w[2:0]);
                I_LBR:  n_b = read_r(op_w[2:0]);
                I_LRA:  begin n_r_any_we = 1'b1; n_r_any_idx = op_w[2:0]; n_r_any = a; end
                I_LRB:  begin n_r_any_we = 1'b1; n_r_any_idx = op_w[2:0]; n_r_any = b; end
                I_P: begin
                    want_p_fetch = 1'b1;
                    p_addr_w = ({8'b0, a} | ({8'b0, b} << 4) | ({11'b0, c} << 8) |
                                ({9'b0, op_w[2:0]} << 9) | ({1'b0, next_pc_w} & 12'hFC0)) & 12'hFFF;
                end

                default: ; // I_ILL — hmcs40op.cpp:41-44, no state change beyond pc advance
            endcase
        end
    endtask

    // ie next-value: SEIE=1, REIE=0, RTNI=1 (op_rtni calls op_seie() then
    // op_rtn(); hmcs40op.cpp:604-609), else unchanged.
    function automatic n_ie_f(input [6:0] id);
        case (id)
            I_SEIE, I_RTNI: n_ie_f = 1'b1;
            I_REIE:         n_ie_f = 1'b0;
            default:        n_ie_f = ie;
        endcase
    endfunction
    function automatic n_if0_f(input [6:0] id);
        case (id)
            I_SEIF0: n_if0_f = 1'b1;
            I_REIF0: n_if0_f = 1'b0;
            default: n_if0_f = if0;
        endcase
    endfunction
    function automatic n_if1_f(input [6:0] id);
        case (id)
            I_SEIF1: n_if1_f = 1'b1;
            I_REIF1: n_if1_f = 1'b0;
            default: n_if1_f = if1;
        endcase
    endfunction
    function automatic n_cf_f(input [6:0] id);
        case (id)
            I_SECF: n_cf_f = 1'b1;
            I_RECF: n_cf_f = 1'b0;
            default: n_cf_f = cf;
        endcase
    endfunction

    // P write-back (hmcs40op.cpp:673-689), applied once the pattern word
    // arrives. Only touches A/B and/or R2/R3, per the two destination bits.
    reg [3:0] pa, pb, pr2, pr3;
    always @* begin
        pa = a; pb = b; pr2 = r_lat2; pr3 = r_lat3;
        if (rom_data[8]) begin
            pa = {rom_data[0], rom_data[1], rom_data[2], rom_data[3]}; // bitswap<4>(data,0,1,2,3)
            pb = rom_data[7:4];
        end
        if (rom_data[9]) begin
            pr2 = {rom_data[4], rom_data[5], rom_data[6], rom_data[7]};
            pr3 = {rom_data[0], rom_data[1], rom_data[2], rom_data[3]};
        end
    end

    // ------------------------------------------------------------------
    // Main sequencer — single always block owns every register (no
    // cross-block races, no multiple-driver conflicts). Internally
    // organised as independent if/else-if priority chains per register
    // group so each signal has exactly one resolved value per edge.
    // ------------------------------------------------------------------
    wire commit_fetch = (state == S_FETCH_WAIT) && (rom_ack || rom_data_ready) && cen;
    wire commit_p      = (state == S_P_WAIT) && (rom_ack || rom_data_ready) && cen;
    wire commit_int    = (state == S_INT_ENTRY) && cen;
    wire commit_any_cycle = commit_fetch || commit_p || commit_int; // one prescaler tick each

    always @(posedge clk) begin
        if (reset) begin
            state <= S_RESET;
            pc <= PC_MASK;
            pc_upper <= 5'h0;
            a <= 4'h0; b <= 4'h0; x <= 4'h0; spx <= 4'h0; y <= 4'h0; spy <= 4'h0;
            s <= 1'b1; c <= 1'b0;
            stack0 <= 11'h0; stack1 <= 11'h0; stack2 <= 11'h0; stack3 <= 11'h0;
            // hmcs40.cpp:273-290 device_reset(): cf/ie/iri/irt=0, if0/if1/tf=1
            // (masked), tc/prescaler are not explicitly touched by
            // device_reset() but start zerofilled at device_start()
            // (hmcs40.cpp:210-215) and there is no path back to that state
            // once running, so zero here is the correct power-up value.
            cf <= 1'b0; ie <= 1'b0; iri <= 1'b0; irt <= 1'b0;
            if0 <= 1'b1; if1 <= 1'b1; tf <= 1'b1;
            tc <= 4'h0; prescaler <= 6'h0;
            r_lat0<=4'hF; r_lat1<=4'hF; r_lat2<=4'hF; r_lat3<=4'hF;
            r_lat4<=4'hF; r_lat5<=4'hF; r_lat6<=4'hF; r_lat7<=4'hF; // reset_io: m_polarity (CMOS=all 1s)
            d_lat <= 16'hFFFF;
            d_we_r <= 1'b0;        // D-WRITE-STROBE-2026-08-01
            r_we_r <= 1'b0; r_we_idx_r <= 3'd0;   // R-WRITE-STROBE-2026-08-01
            eint_line <= 1'b0;
            lpu_pend <= 2'b00;
            block_int <= 1'b0;
            halted <= 1'b0;
            rom_req <= 1'b0;
            rom_addr <= 12'h0;
            op_cur <= 10'h0;
            i_rev <= 4'h0;
            int0_q <= 1'b0; int1_q <= 1'b0;
            rom_data_ready <= 1'b0;
        end else if (hlt_in) begin
            // hmcs40.cpp:656-661: internal clock stopped, nothing advances
            halted <= 1'b1;
            int0_q <= int0_in; int1_q <= int1_in; // pin edges still observed
        end else begin
            halted <= 1'b0;
            int0_q <= int0_in;
            int1_q <= int1_in;
            // D-WRITE-STROBE-2026-08-01: default-clear so the strobe is exactly
            // one clk wide; the S_EXEC commit below re-asserts it when the
            // retiring instruction actually wrote D.
            d_we_r <= 1'b0;
            r_we_r <= 1'b0;   // R-WRITE-STROBE-2026-08-01

            case (state)
                S_RESET: state <= S_TOP;

                // Step1 (LPU delay-slot fixup) + Step2 (shift regs) +
                // Step3 (interrupt pending check) — hmcs40.cpp:663-676.
                // Purely combinational routing; consumes no `cen`.
                S_TOP: begin
                    pc <= pc_fixedup;
                    fetch_pc <= pc_fixedup;
                    if (ie && (iri || irt) && !block_int)
                        state <= S_INT_ENTRY;
                    else
                        state <= S_FETCH_REQ;
                    block_int <= 1'b0; // consumed unconditionally, hmcs40.cpp:676
                end

                // take_interrupt() (hmcs40.cpp:551-571): push return addr,
                // clear IE, redirect to vector. ONE cen tick.
                S_INT_ENTRY: if (cen) begin
                    stack3 <= stack2; stack2 <= stack1; stack1 <= stack0; stack0 <= fetch_pc;
                    ie <= 1'b0;
                    pc <= 11'h03F | (iri ? 11'h040 : 11'h000);
                    state <= S_FETCH_REQ;
                end

                S_FETCH_REQ: begin
                    // QUARTUS-FIX-2026-08-01: `pc[11:0]` selected bit 11 of an
                    // 11-bit vector (pc is [10:0]) — Quartus error 10232. The
                    // intent is a zero-extend into the 12-bit rom_addr, which is
                    // 12 bits only to carry p_addr_w at S_P_WRITE below.
                    rom_addr <= {1'b0, pc};
                    rom_req  <= 1'b1;
                    pc_next_lfsr <= increment_pc(pc);
                    state <= S_FETCH_WAIT;
                end

                // rom_ack (from the ROM bridge) can arrive many `clk`
                // cycles before the next `cen` — latch it (rom_data_ready)
                // and only actually commit once a qualifying `cen` shows
                // up, so the machine-cycle rate is set by `cen`, not by
                // however fast the ROM bridge happens to answer.
                S_FETCH_WAIT: begin
                    if (rom_ack) rom_data_ready <= 1'b1;
                    if ((rom_ack || rom_data_ready) && cen) begin
                    rom_data_ready <= 1'b0;
                    op_cur <= rom_data[9:0];
                    i_rev  <= {rom_data[0], rom_data[1], rom_data[2], rom_data[3]};
                    rom_req <= 1'b0;

                    exec_instr(rom_data[9:0], {rom_data[0], rom_data[1], rom_data[2], rom_data[3]}, pc_next_lfsr);

                    lpu_pend <= {lpu_pend[0], lpu_taken_now};
                    block_int <= lpu_taken_now | cal_taken_now;

                    a <= n_a; b <= n_b; x <= n_x; spx <= n_spx; y <= n_y; spy <= n_spy;
                    s <= n_s; c <= n_c;
                    pc_upper <= n_pc_upper;
                    d_lat  <= n_d;
                    d_we_r <= n_d_we;   // D-WRITE-STROBE-2026-08-01
                    // R-WRITE-STROBE-2026-08-01
                    r_we_r     <= n_r_any_we;
                    r_we_idx_r <= n_r_any_idx;
                    if (n_r_any_we) begin
                        case (n_r_any_idx)
                            3'd0: r_lat0 <= n_r_any; 3'd1: r_lat1 <= n_r_any;
                            3'd2: r_lat2 <= n_r_any; 3'd3: r_lat3 <= n_r_any;
                            3'd4: r_lat4 <= n_r_any; 3'd5: r_lat5 <= n_r_any;
                            // HMCS44 (HD44801) has R0-R5 only; writes to R6/R7 are
                            // ineffective and leave the latch at its reset 4'hF
                            // (hmcs44_cpu_device::write_r, hmcs40.cpp:474-482).
                            default: ;
                        endcase
                    end
                    if (ram_we) dram[ram_phys(ram_we_addr)] <= ram_we_data;

                    if (push_req) begin
                        stack3 <= stack2; stack2 <= stack1; stack1 <= stack0; stack0 <= pc_next_lfsr;
                    end
                    if (pop_req) begin
                        pc <= stack0 & PC_MASK;
                        stack0 <= stack1; stack1 <= stack2; stack2 <= stack3;
                    end else if (!want_p_fetch) begin
                        pc <= n_pc;
                    end
                    pc_after_p <= n_pc;

                    if (want_p_fetch) begin
                        rom_addr <= p_addr_w;
                        rom_req  <= 1'b1;
                        state <= S_P_WAIT;
                    end else begin
                        state <= S_TOP;
                    end
                    end // (rom_ack || rom_data_ready) && cen
                end

                // Same rom_ack-vs-cen decoupling as S_FETCH_WAIT above.
                S_P_WAIT: begin
                    if (rom_ack) rom_data_ready <= 1'b1;
                    if ((rom_ack || rom_data_ready) && cen) begin
                    rom_data_ready <= 1'b0;
                    rom_req <= 1'b0;
                    a <= pa; b <= pb; r_lat2 <= pr2; r_lat3 <= pr3;
                    pc <= pc_after_p;
                    state <= S_TOP;
                    end
                end

                default: state <= S_TOP;
            endcase

            // ---------------------------------------------------------
            // ie / if0 / if1 / cf — pure instruction-driven flip-flops,
            // single owner, only meaningful during S_FETCH_WAIT&rom_ack.
            // (Reading id_w/n_pc etc outside that window is harmless:
            // id_w retains its last-decoded value, and the *_f() functions
            // above only change ie/if0/if1/cf for specific id_w values
            // that can only have just been set during a real commit.)
            // ---------------------------------------------------------
            if (commit_fetch) begin
                ie  <= n_ie_f(id_w);
                if0 <= n_if0_f(id_w);
                if1 <= n_if1_f(id_w);
                cf  <= n_cf_f(id_w);
            end

            // ---------------------------------------------------------
            // tc / tf / prescaler / irt — single priority chain owning
            // all four. commit_any_cycle covers every point MAME calls
            // cycle()->clock_prescaler() (hmcs40.cpp:618-625): normal
            // fetch, P's extra fetch, and interrupt-entry's push.
            // hmcs40op.cpp:584-596 (LTI/LTA) resets the prescaler too.
            // int1_edge&&cf models hmcs40.cpp:598-599 (counter mode) —
            // dead path for ALPHA-8201 (INT1 is n.c., see file header).
            // ---------------------------------------------------------
            if (commit_fetch && tc_explicit_we) begin
                tc <= tc_explicit_val;
                prescaler <= 6'h0;
            end else if (commit_any_cycle) begin
                prescaler <= prescaler + 6'd1;
                if (prescaler == 6'h3F && !cf) begin
                    tc <= tc + 4'd1;
                    if (tc == 4'hF && !tf) irt <= 1'b1;
                end
            end else if (int1_edge && cf) begin
                tc <= tc + 4'd1;
                if (tc == 4'hF && !tf) irt <= 1'b1;
            end

            if (commit_int && !iri) irt <= 1'b0; // take_interrupt consumed the timer IRQ

            if (commit_fetch && tf_set_now) tf <= 1'b1;
            else if (commit_fetch && tf_clr_now) tf <= 1'b0;
            else if (commit_any_cycle && prescaler == 6'h3F && !cf && tc == 4'hF && !tf) tf <= 1'b1;
            else if (int1_edge && cf && tc == 4'hF && !tf) tf <= 1'b1;

            // ---------------------------------------------------------
            // iri / eint_line — external interrupt pending flip-flop.
            // Single owner: consumed by take_interrupt (S_INT_ENTRY),
            // set on a rising INT0/INT1 edge when unmasked
            // (hmcs40.cpp:588-600).
            // ---------------------------------------------------------
            if (commit_int && iri) iri <= 1'b0;
            else if (int0_edge && !if0) begin iri <= 1'b1; eint_line <= 1'b0; end
            else if (int1_edge && !if1) begin iri <= 1'b1; eint_line <= 1'b1; end
        end
    end

    // ------------------------------------------------------------------
    // Debug/observability
    // ------------------------------------------------------------------
    assign dbg_pc = pc;
    assign dbg_op = op_cur;
    assign dbg_illegal = commit_fetch && (op_id_from_rom == I_ILL);
    assign dbg_a = a; assign dbg_b = b; assign dbg_x = x; assign dbg_y = y;

endmodule
