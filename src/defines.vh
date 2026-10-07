// SPDX-FileCopyrightText: © 2026 General-Purpose Protocol ASIC contributors
// SPDX-License-Identifier: Apache-2.0
// `default_nettype none  (left as default for compatibility with tb files)

`ifndef JANE_DEFINES_VH
`define JANE_DEFINES_VH

// ---------------------------------------------------------------------------
// Global architectural constants — single source of truth.
// ---------------------------------------------------------------------------

// Number of hardware execution contexts (threads). Deterministic round-robin.
`define JP_NUM_THREADS   4
`define JP_THREAD_W      2

// Instruction width / program memory depth (512 x 16). Area and macro
// feasibility are not yet measured; see docs/AREA_TIMING.md.
`define JP_INST_W        16
`define JP_PROG_DEPTH    512
`define JP_PROG_AW       9

// Data memory (X/Y windows): 4 threads x 32 registers each, plus a shared
// window at 192..223 for host<->thread and thread<thread messaging.
`define JP_XREGS         32
`define JP_DM_TOTAL      256

// Free-running absolute time base, wraps every 2^24 cycles (~335 ms @50MHz).
`define JP_TIME_W        24

// GPIO fabric width (uio pins; the protocol pins). ui_in is an additional
// 8-bit sideband readable via IN.GI, outputs mirrored on uo_out.
`define JP_GPIO_W        8

// Trace FIFO depth (power-of-two), entry = {timestamp[23:0], gpio[7:0], evt[3:0]}
`define JP_TRACE_DEPTH   32
`define JP_TRACE_AW      5
`define JP_TRACE_EW      36

// Mailbox FIFOs (host <-> engine), 8 x 8-bit each.
`define JP_MB_DEPTH      8
`define JP_MB_AW         3

// ---------------------------------------------------------------------------
// Instruction opcodes (bits [15:12]) — see docs/ISA.md for full reference.
// ---------------------------------------------------------------------------
`define OP_MOV    4'h0   // X := imm8                       (class G)
`define OP_OUT    4'h1   // class A: OUT/OUTD/CLR/SET/OEN/OUTM
`define OP_ALU    4'h2   // X := X op Y | X := X op imm6    (class B)
`define OP_BR     4'h3   // conditional branch + HALT       (class C)
`define OP_WAIT   4'h4   // WAIT CYCLE/EDGE/DLINE/TMO/EV    (class D)
`define OP_PUSH   4'h5   // push byte                       (class E)
`define OP_POP    4'h6   // pop byte                        (class E)
`define OP_IN     4'h7   // IN GPIO / IN GI / IN SYN        (class F)
`define OP_CSR    4'h8   // CSR read/write                  (class H)
`define OP_LDI    4'h9   // LDI r,imm8 / LDS r,imm8         (class I)
`define OP_JMPR   4'ha   // register-indirect jump          (class J)
`define OP_TRC    4'hb   // trace + SW events               (class K)
`define OP_EXT    4'hc   // extended ops                    (class L)
`define OP_EDG    4'hd   // scheduled edge units            (class M)
// opcodes 4'he, 4'hf are ILLEGAL (reserved): deterministic NOP+ERR behavior.

// ALU operations (r field in OP_ALU)
`define ALU_ADD  3'd0
`define ALU_SUB  3'd1
`define ALU_OR   3'd2
`define ALU_AND  3'd3
`define ALU_XOR  3'd4
`define ALU_SHL  3'd5
`define ALU_SHR  3'd6
`define ALU_ROL  3'd7

// Branch conditions (r field in OP_BR)
`define BR_ALWAYS 3'd0
`define BR_EQ     3'd1
`define BR_NE     3'd2
`define BR_LT     3'd3   // unsigned
`define BR_GT     3'd4   // unsigned
`define BR_CARRY  3'd5
`define BR_NZ     3'd6   // zero flag clear
`define BR_HALT   3'd7

// Wait forms (r field in OP_WAIT)
`define W_CYC     3'd0   // D := T + imm5 ; wait until T >= D (exact delta from issue)
`define W_EDGE    3'd1   // wait pin change on mask OR timeout(imm5 cycles); imm5==0 -> infinite
`define W_DSYNC   3'd2   // if T>=D then D+=delta ; wait until T>=D  (drift-free cadence)
`define W_TMO     3'd3   // pure timeout wait, imm5 cycles (imm5==0 -> 32 cycles? no: 0 means 1)
`define W_EV      3'd4   // wait event-mask bit set OR timeout; mask = last WAIT.EV arm
`define W_RDY     3'd5   // wait synchronized pin level == imm5[0] on mask, or timeout imm5
`define W_RQ      3'd6   // reschedule: yield, resume after one full RR pass
`define W_DADJ    3'd7   // D := D + imm5 ; wait until T >= D (deadline advance)

// OUT sub-ops (r field in OP_OUT)
`define O_OUT   3'd0     // drive pins: value=X[7:0], oe=Y[7:0] immediate
`define O_OUTD  3'd1     // open-drain: X[i]=0 -> drive low, X[i]=1 -> release
`define O_SET   3'd2     // global out reg set bits (X[7:0]); persists
`define O_CLR   3'd3     // global out reg clear bits
`define O_OEN   3'd4     // global oe write: X[7:0] -> global output enable
`define O_OUTM  3'd5     // masked drive: value=X[7:0], oe=imm5 expanded mask? -> uses m field
`define O_RES   3'd6     // reserved
`define O_NOP   3'd7     // nop

// IN sources (r field in OP_IN)
`define I_GPIO  3'd0     // X := {8'h0, uio synced}
`define I_RAW   3'd1     // X := {8'h0, uio raw}
`define I_GI    3'd2     // X := {8'h0, ui_in}
`define I_SYN   3'd3     // X := {8'h0, synced & ~oe} (input-only view)

// PUSH/POP variants (r field in OP_PUSH / OP_POP)
`define PS_XLO  3'd0     // push X[7:0]
`define PS_XHI  3'd1     // push X[15:8]
`define PS_STK  3'd2     // push to thread stack (dm window)
`define PS_MBX  3'd3     // push to host mailbox fifo
`define PP_XLO  3'd0     // pop byte -> X[7:0]
`define PP_XHI  3'd1     // pop byte -> X[15:8]
`define PP_STK  3'd2     // pop from thread stack
`define PP_MBX  3'd3     // pop from host mailbox (engine<-host fifo)

// CSR addresses (a field in OP_CSR / EXT2 rs) — 6 bits
`define CSR_OSRL   6'h00  // R  output state low  {oe[7:0]} packed views below
`define CSR_OSRH   6'h01  // R  output state high (uio_out)
`define CSR_TMR    6'h02  // R  time[15:0]
`define CSR_TMRH   6'h03  // R  {8'h0,time[23:16]}
`define CSR_ISR    6'h04  // RW ISR[15:0] (w1c semantics on store)
`define CSR_ISRH   6'h05  // RW ISR[23:16]
`define CSR_IOM    6'h06  // W  input ownership mask (set via store value)
`define CSR_OWM    6'h07  // W  output ownership mask
`define CSR_FSTAT  6'h08  // R  {trfull,trempty,rxfull,rxempty,wfull,wempty, 10'b0}
`define CSR_FDATA  6'h09  // R  RX fifo head byte (pop)
`define CSR_EDV    6'h0A  // R  edge unit valid bitmap [3:0]
`define CSR_TSUB   6'h0B  // R  (D > T) ? D - T : 0  [15:0]
`define CSR_DEADL  6'h0C  // R  deadline[15:0]
`define CSR_DEADH  6'h0D  // R  {8'h0, deadline[23:16]}
`define CSR_FLAGS  6'h0E  // R  flags {ovf,zero,cy,tmo,evmatch,pinedge,rdylvl,4'b0}
`define CSR_STACK  6'h0F  // R  stack pointer (per granted thread via mux)
`define CSR_TMASK  6'h10  // W  event trigger mask [15:0]
`define CSR_CRCPL  6'h11  // W  CRC poly low
`define CSR_CRCPH  6'h12  // W  CRC poly high
`define CSR_CRCOX  6'h13  // W  CRC xorout low
`define CSR_CRCOXH 6'h14  // W  CRC xorout high
`define CSR_CRCLS  6'h15  // W  CRC length (0..16)
`define CSR_CRCSEEDL 6'h16// W  seed load low (and triggers load)
`define CSR_CRCSEEDH 6'h17// W  seed load high
`define CSR_GPOUT  6'h18  // W  global out reg direct write
`define CSR_GPOEN  6'h19  // W  global oe direct write
`define CSR_BITCFG 6'h1A  // W  bit engine cfg (mode/dir/pin/width/refl)
`define CSR_BITDIV 6'h1B  // W  bit engine clkdiv low/high (two writes)
`define CSR_BITGO  6'h1C  // W  start engines: X[0]=tx X[1]=rx X[2]=stop_tx X[3]=stop_rx
`define CSR_EDCTL  6'h1D  // W  edge unit select+arm handled by OP_EDG instead
`define CSR_THCTRL 6'h1E  // W  thread ctrl: {clr_deadline, halt, start} of sel
`define CSR_TSSEL  6'h1F  // W  target-thread select for THCTRL/TS reads
`define CSR_TRCHI  6'h20  // R  trace entry [35:24]
`define CSR_TRCLO  6'h21  // R  trace entry [23:0]
`define CSR_TRCTRL 6'h22  // W  trace control: X[0]=en, X[1]=clear, X[2]=pop
`define CSR_STAT   6'h23  // R  {8'h0, err_bitmap, run_bitmap}
`define CSR_PC0    6'h24  // R  PC of selected debug thread
`define CSR_DMADR  6'h25  // RW data-memory inspection address
`define CSR_DMDAT  6'h26  // RW data-memory inspection data
`define CSR_PMADR  6'h27  // RW program-memory inspection address
`define CSR_PMDAT  6'h28  // RW program-memory inspection data (write => port wr)
`define CSR_ERRCNT 6'h29  // R  illegal-instruction count (sticky, w1c)
`define CSR_HOSTTX 6'h2A  // W  engine->host mailbox push (also POP.MBX mirror)
`define CSR_HOSTRX 6'h2B  // R  host->engine mailbox pop
`define CSR_TIMOD  6'h2C  // W  {imm...} timing mode word (reserved, ties off)
`define CSR_N      6'h2D

// EXT function codes (fn field, 6 bits inst[11:6] with opcode class L)
`define EXT_NOP      6'h00
`define EXT_SLEEP    6'h01   // deassert ena-style core idle until interrupt-ish (uses X cycles)
`define EXT_CLRDEAD  6'h02   // D := 0 (always ready)
`define EXT_CLOAD    6'h03   // crc_reg := X
`define EXT_CA       6'h04   // crc_a: crc_reg ^= X (pre-positioned)
`define EXT_CR       6'h05   // crc_r: process 8 bits of X[7:0] through poly (multi-cycle, stalls thread)
`define EXT_CGET16   6'h06   // X := crc_result
`define EXT_CGET8    6'h07   // X := {8'h0, crc_result[15:8]}
`define EXT_SHIFT    6'h08   // X := shifter_op(X) using BITCFG width/dir
`define EXT_GETTCNT  6'h09   // X := tx_count
`define EXT_SETTCNT  6'h0A   // tx_count := X[4:0]
`define EXT_GETRCNT  6'h0B   // X := rx_count
`define EXT_SETRCNT  6'h0C   // rx_count := X[4:0]
`define EXT_GETSHREG 6'h0D   // X := shift register
`define EXT_SETSHREG 6'h0E   // shift register := X
`define EXT_TADD     6'h0F   // D := D + X[15:0] (mod 2^24)
`define EXT_TSUB     6'h10   // X := (D>T) ? D-T : 0
`define EXT_READT    6'h11   // X := time[15:0]
`define EXT_READTH   6'h12   // X := {8'h0,time[23:16]}
`define EXT_WRBIT    6'h13   // push X[7:0] into bit-engine TX byte pipeline
`define EXT_RDSTSW   6'h14   // X := shared-window dm[X[7:0] & 63 | 192]
`define EXT_WRSTSW   6'h15   // shared-window dm[...] := Y
`define EXT_GETOWM   6'h16   // X := {8'h0, own_oe}
`define EXT_GETIOM   6'h17   // X := {8'h0, own_in}
`define EXT_TRG      6'h18   // software trigger: sets ISR bit X[3:0], optional trace
`define EXT_ERR      6'h19   // raise ERR flag (thread error bitmap), continue
`define EXT_DBGWR    6'h1A   // uo_out := X[7:0] (debug mirror)
`define EXT_DBGRD    6'h1B   // X := {8'h0, ui_in}
`define EXT_GETSP    6'h1C   // X := stack pointer
`define EXT_SETSP    6'h1D   // stack pointer := X[5:0]
`define EXT_WWAIT    6'h1E   // wait while event-mask bit CLEAR (complement of WAIT EV)
`define EXT_IDLE     6'h1F   // park thread until any ISR&mask event (no timeout)

// Edge-unit fields (OP_EDG)
// EDG.ARM  : schedule atomic future edge on pin p: at absolute time t, drive
//            (value,oe) masked by m. 2 units per thread, total 8.
// EDG.CLR  : cancel unit(s) selected by X[3:0] bitmap
// EDG.STAT : X := valid bitmap

// Trace event codes (evt[3:0])
`define TEVT_EDGE    4'h1
`define TEVT_TRIG    4'h2
`define TEVT_TMO     4'h3
`define TEVT_FIFO    4'h4
`define TEVT_SW1     4'h5
`define TEVT_SW2     4'h6
`define TEVT_START   4'h7

// Thread context offsets inside DM window (per-thread base = t*32)
// X is at base+0, Y at base+1 (both via dedicated fast regs, aliased in DM).
`define DM_SHARED_BASE 8'd192

// Pin indices for well-known protocol roles (firmware convention, not HW)
// T0:UART-RX uio0, T1:UART-TX uio1, T2:I2C-SDA uio2, T2:I2C-SCL uio3,
// T3:SPI-SCK uio4, T3:SPI-MOSI uio5, T3:SPI-MISO uio6, free uio7.

`endif
