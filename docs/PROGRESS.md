# DE1-SoC Optimization Progress

This log is updated after every completed implementation step. A step is not
complete until its code, focused test, and documentation are updated.

## Step 1: Freeze Legacy And Establish V2 Baseline

Status: **complete**

Completed:

- M4 BRAM RTL moved to `hw/legacy/rtl_m4_bram`.
- M4 ARM software moved to `hw/legacy/arm_m4`.
- Failed DDR Platform Designer source moved to `hw/legacy/fpga_top_soc_ddr`.
- Old Quartus project moved to `hw/legacy/quartus_m4`.
- Canonical DE1-SoC paths created at `hw/rtl`, `hw/arm`, and `hw/quartus`.
- Stockfish 18 big/small network requirements documented in `docs/ARCHITECTURE.md`.
- DE1-SoC resource constraints documented: 87 DSP, 397 M10K, 100 MHz baseline,
  HPS DDR3, and ARM Cortex-A9.

## Step 2: Verify New Arithmetic And Memory Primitives

Status: **complete**

Completed:

- Added `hw/rtl/memory/f2sdram_read_master.sv` with explicit address units,
  request holding, response backpressure, beat counting, and timeout/error.
- Added `hw/rtl/nnue/delta_accumulator.sv`.
- Added `hw/rtl/nnue/parallel_mac.sv`.
- Added focused tests under `hw/rtl/memory/` and `hw/rtl/tb/`.
- Icarus tests pass for F2SDRAM and compute primitives.
- Verilator lint runs through `tools/lint.sh`.

Known baseline warnings remain in copied legacy arithmetic modules. They are
tracked for cleanup before Quartus integration.

## Step 3: Stockfish 18 FT Delta Layout

Status: **complete**

Completed:

- Added `hw/rtl/nnue/ft_delta_engine.sv`.
- Locked the Stockfish 18 physical FT layout:
  - bias column: `[0 .. HD-1]`
  - main feature `f`: `HD + f * HD + lane`
- Connected refresh bias loading and signed add/remove column updates to the
  persistent accumulator.
- Verified the address and arithmetic contract with
  `hw/rtl/tb/tb_ft_delta_engine.sv` for a small `HD=4` memory model.
- Test result: `PASS Stockfish FT delta layout`.

## Next Steps

1. Add G2 golden-vector regression for REFRESH and ACCUMULATE.
2. Add the canonical Quartus project only after RTL simulation passes.

## Step 4: FC0 M10K Banking

Status: **complete**

Completed:

- Added `hw/rtl/nnue/fc0_weight_banks.sv`.
- Implemented 16 independent input-lane banks for DE1-SoC.
- Preserved Stockfish 18 output-major FC0 layout.
- Verified two chunks of a multi-output bank read with
  `hw/rtl/tb/tb_fc0_weight_banks.sv`.
- Test result: `PASS FC0 16-bank layout`.

## Step 5: FC0 Parallel Engine

Status: **complete**

Completed:

- Added `hw/rtl/nnue/fc0_parallel_engine.sv`.
- Consumes one 16-weight bank read per cycle.
- Accumulates `HD / 16` chunks per output row.
- Preserves signed bias and accumulation width for Stockfish 18 FC0.
- Verified all outputs with `hw/rtl/tb/tb_fc0_parallel_engine.sv`.
- Test result: `PASS FC0 parallel engine`.

## Step 6: G2 Golden Regression

Status: **in progress**

Completed:

- Added `tools/g2_check.py`.
- Loads the real Stockfish 18 small-net FT, FC, and PSQT binaries.
- Reconstructs FT bias/feature columns, quantization, FC0/FC1/FC2, forward
  correction, and PSQT bucket arithmetic.
- Compares all 8 cases and all 8 buckets against `ref.txt`.
- Current result: PSQT matches all 64 vectors, but FC positional does not.
- The mismatch is retained as a blocking regression; no G2 pass is claimed.

## Step 7: Full Network Integration

Status: **next**

The next step is to connect the G2-verified arithmetic path into one RTL
network pipeline, then add big-net parameters and threat-feature handling.

## Step 6: G2 Golden Regression

Status: **next**

The next step is to connect the new FT and FC primitives to Stockfish 18
golden vectors before adding activation stages or Quartus integration.
