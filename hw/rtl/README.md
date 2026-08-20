# DE1-SoC RTL

This directory contains only the canonical replacement accelerator RTL. It must remain
independent of `hw/legacy/` and of generated Quartus sources.

Required module groups:

- `protocol/`: command, response, timeout, and ownership contracts
- `memory/`: F2SDRAM request/response adapter and line buffers
- `nnue/`: persistent accumulator, quantizer, and FC engine
- `top/`: SoC wrapper and clock/reset domains
- `tb/`: protocol, arithmetic, and G2 tests

Every module must document address units, reset behavior, latency, backpressure,
and signed arithmetic at its interface.
