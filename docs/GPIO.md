# GPIO

`uio_in` is sampled synchronously by opcode 7. Opcode 1 updates the shared output value from the selected thread's X low byte and output enables from Y low byte. The output bus is driven only when the corresponding enable bit is set. Open-drain arbitration and input synchronizers are not part of the current top-level integration.
