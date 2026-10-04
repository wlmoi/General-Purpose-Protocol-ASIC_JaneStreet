# Architecture

The checked-in implementation currently contains a four-slot round-robin execution core in `src/jane_top.v`. Each enabled clock selects one slot, advances its program counter, and executes one instruction. Program storage is a 512 x 16-bit synthesizable array initialized to zero in simulation.

The Tiny Tapeout wrapper is `tt_um_jonestreet_protocol_engine`; `src/top.v` is a compatibility wrapper. The present integration exposes the execution output and GPIO input/output buses. The legacy peripheral modules remain separate and are not connected to the top-level core yet.
