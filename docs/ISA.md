# ISA

The currently integrated subset uses 16-bit words and the opcode in bits 15:12.

| Opcode | Meaning |
|---|---|
| 0 | `MOV X, imm8` |
| 1 | `OUT`, drives X low byte and Y low byte as output enable |
| 2 | ALU; function bits 11:9: add, subtract, OR, AND, XOR |
| 3 | branch; function 7 halts, function 0 branches by signed offset |
| 4 | wait for the immediate low five bits of slot cycles |
| 7 | read GPIO input into X low byte |
| 9 | load X from the following program word |

All other opcodes are inert. The assembler and Python model in `tools/` implement this same subset.
