# Implemented ISA

Instructions are 16-bit words with opcode in bits 15:12. Unless noted,
function is bits 11:9. All execution and waits are counted in context grants
(four enabled core clocks per grant). `tools/assembler.py` validates encodings.

| Opcode | Encoding and behavior |
|---|---|
| 0 | MOV imm8 into X; bit 8 selects Y instead. Zero extends. |
| 1 | Function 0: masked push-pull OUT, value=X[7:0], enable=Y[7:0]. Function 1: masked open-drain OUT, X bit 0 drives low and X bit 1 releases. Functions 2/3 apply the corresponding push-pull/open-drain behavior using imm8 instead of X; X is unchanged. |
| 2 | X := X op Y for functions 0 ADD, 1 SUB, 2 OR, 3 AND, 4 XOR. Functions 5/6 shift X left/right by one; 7 rotates X left by one. All results wrap to 16 bits. |
| 3 | Branch conditions: 0 always, 1 X==Y, 2 X!=Y, 3 X<Y unsigned, 4 X>Y unsigned, 6 X!=0. Signed 8-bit offset in bits 8:1 is relative to the next instruction. Function 7 HALT. Function 5 is unsupported and raises error. |
| 4 | Function 0 WAIT imm8: skip the next imm8 grants of this context. Function 1 WAIT_PIN: pin in bits 2:0, target level in bit 3; hold PC until the synchronized pin matches. |
| 7 | Function 0 IN: X := synchronized GPIO byte. Function 4 SAMPLE: shift receive register left and insert selected pin (bits 2:0) into bit 0. Function 5 SAMPLE_LSB: shift low receive byte right and insert pin into bit 7, clearing upper byte. Function 6 RECEIVE: copy receive register into X. |
| 9 | LDI: arm a literal load into X (bit 8=0) or Y (bit 8=1). The following word is fetched on the next grant of this context. Each grant advances PC by one; the operation consumes two grants. |

Other opcodes and unsupported functions set the issuing context's sticky error
and otherwise advance as a no-op. PC arithmetic wraps modulo 256, including
literal fetch at PC 255 and signed branches. Errors are exposed through host
status and can be cleared with a write-one-to-clear bitmap.

HALT leaves pin state intact. STOP is a host operation that halts selected
contexts and releases their owned pins. RESTART clears selected contexts'
X/Y, receive, wait, and error state, sets their PCs to the configured entry,
and marks them running; it retains ownership and pin state. To release pins
before restarting, issue STOP first.

The wait delay includes the WAIT instruction itself: after WAIT(N), the next
instruction executes N+1 grants later. The protocol generators account for
OUT/SAMPLE instruction overhead when constructing their bit periods.
There is no implicit event FIFO, timeout, carry flag, stack, or CSR instruction.
