# Project instructions

## Authoritative baseline

- Read `README.md`, `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`, and `docs/BENCHMARK.md` before implementation.
- Target only Stockfish `sf_19`, commit recorded in `config/stockfish.lock.json`, on Terasic DE1-SoC. Do not follow upstream master or silently upgrade the network.
- `third_party/stockfish/` is the official reference checkout. Verify it with `tools/fetch-stockfish.ps1`. Keep tracked upstream files unchanged; maintain integration patches separately.
- Current SF19 implementation and board verification are not complete. Directory README files describe planned responsibilities, not working implementations.

## Historical material

- `archive/` is recovery material only. Do not search, extract, compile, or import it as part of normal work unless the task explicitly requires recovery or reuse review.
- SF18 big/small architecture, old register maps, old PASS logs, old boot images and macOS/lima instructions are not current specifications.
- A recovered module must pass the current SF19 tests before reuse. Never carry forward historical completion claims.
- Git history is historical evidence, not an alternative project specification.

## Acceptance

- Require bit-exact NNUE output against official Stockfish 19. Compare both output integers and intermediate tensors; no tolerance, retraining, or reduced precision.
- Primary evaluation compares ARM-only and ARM+FPGA on the same physical DE1-SoC, same network and identical input/state trace.
- Correctness is a mandatory pass/fail gate; speed is measured only after passing it. Record mismatches, errors and fallback counts explicitly.
- Measure host-observed evaluation latency including communication, synchronization and result retrieval. Report FPGA compute-only timing separately.
- Report unverified work honestly. Simulation, compilation and CPU fallback do not establish board correctness or successful boot.
