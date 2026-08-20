# DE1-SoC HPS Software

The client owns descriptor production, cache-coherent DMA buffers, delta
feature extraction, result matching, and G2 comparison. It must not contain
FPGA physical addresses as untyped literals; those belong in one ABI header.

The legacy client remains under `hw/legacy/arm_m4/` for comparison only.
