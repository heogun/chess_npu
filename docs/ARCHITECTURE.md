# DE1-SoC Accelerator Architecture

## Scope

This is the canonical replacement architecture for the M4 implementation. The
old implementation is preserved under `hw/legacy/` and is not a source
dependency.

The primary correctness gate remains G2:

```text
FPGA output == Stockfish reference output, byte for byte
```

The target device is the DE1-SoC Cyclone V 5CSEMA5F31C6.

Stockfish 18 network selection is part of the contract. The accelerator must
support both network shapes selected by `evaluate.cpp`:

| Network | HD | TFF | FT storage | FC storage |
|---|---:|---:|---|---|
| small | 128 | 0 | HPS DDR3 | DE1-SoC M10K |
| big | 1024 | 79856 | HPS DDR3 | DE1-SoC M10K |

The ARM side retains Stockfish's small-net threshold and big-net fallback. The
FPGA must never silently evaluate a different network shape.

The DE1-SoC resource budget is a hard constraint: 87 DSP blocks, 397 M10K
blocks, Cyclone V 5CSEMA5F31C6 routing/timing, and a 100 MHz HPS/FPGA command
clock. Higher-frequency compute domains are optional only after the 100 MHz
baseline closes timing and passes G2.

## Source Layout

- `hw/rtl/`: canonical RTL and protocol testbenches
- `hw/arm/`: canonical HPS client and reference utilities
- `hw/quartus/`: canonical Platform Designer and Quartus project
- `hw/legacy/`: frozen M4/DDR implementation and its software

Generated Quartus, Verilator, SD, and cross-compiled artifacts are not source
inputs for the canonical build.

## Dataflow

1. HPS produces a request descriptor and feature delta list.
2. A command bridge accepts descriptors with explicit backpressure.
3. A dedicated F2SDRAM read master fetches FT/PSQT data from HPS DDR3.
4. A persistent accumulator applies `REFRESH` or `ACCUMULATE` updates.
5. A banked FC engine evaluates quantized activations with parallel MAC lanes.
6. A result ring returns `{seq, psqt, positional, status}`.

Every transport has an explicit timeout and error result. No request may leave
the accelerator permanently busy.

## Optimization Mapping

- OPT-001/002/011: parallel FC lanes, M10K banking, pipelined adder tree
- OPT-004: CPU affinity and isolated search worker
- OPT-006: command/feature/result multi-slot buffering
- OPT-007: packed DMA and cache-line-aligned buffers where measurable
- OPT-009: persistent delta accumulator
- OPT-010: retain index-list sparsity; only add measured FC zero-skip paths
- OPT-013: dedicated F2SDRAM command/data master
- OPT-014/021: CDC and high-frequency compute domain after baseline closure
- OPT-017: optional FT compression only after DDR bandwidth measurement
- OPT-018: bounded asynchronous batching, never speculative score use
- OPT-023: local weight broadcast and neighbor-local accumulation

OPT-003, OPT-012, OPT-015, OPT-016, OPT-019, OPT-020, OPT-022, OPT-024, and
OPT-025 remain excluded because they violate G2, add unnecessary coupling, or
do not address the measured bottleneck.

## Protocol Rules

- Address units are named in every interface and never inferred.
- Byte order is little-endian and tested at the boundary.
- Read requests hold address/control until acceptance.
- Read responses are counted and matched to requests.
- `waitrequest` and response timeout become explicit hardware errors.
- Reset clears all in-flight transactions and ring ownership.
- Descriptor ownership changes only through producer/consumer indices.

## DE1-SoC HPS Integration Reference

The reference `norxander/DE1-SoC-HPSFPGA` project uses the same board-level
pattern required here:

- connect the FPGA read master directly to `hps.f2h_sdram0_data`;
- connect `hps.f2h_sdram0_clock` from the generated compute/system PLL clock;
- keep the lightweight HPS control interface on its own bridge clock;
- expose reset request paths from the HPS and do not infer reset release from
  the application clock alone.

The reference `norxander/DE1-SoC-Yocto` repository contains a Caffe interrupt
stub, not a reusable contiguous-DDR allocator. Its driver is therefore not
imported. The canonical build will use an explicit reserved-memory/DMA allocation contract when
the HPS software path is implemented, rather than copying an unrelated IRQ
driver.

## Verification Gates

1. Pure RTL unit tests for each protocol and arithmetic block.
2. Memory-model test for F2SDRAM reads, including stalls and delayed responses.
3. G2 golden vectors for REFRESH and ACCUMULATE.
4. Verilator regression.
5. Quartus elaboration, lint, fit, and timing checks.
6. Board smoke test before performance benchmarking.

Performance claims are accepted only with same-board measurements against the
Stockfish software evaluator.
