# DE1-SoC Quartus Integration

The canonical Quartus project is intentionally empty until the RTL protocol
and G2 regression gates pass.

When the project is assembled, its Platform Designer system must follow the
DE1-SoC reference integration pattern:

1. Connect the accelerator's F2SDRAM read master directly to
   `hps_0.f2h_sdram0_data`.
2. Drive `hps_0.f2h_sdram0_clock` from the generated system/compute PLL clock,
   not an unrelated raw clock.
3. Keep the lightweight command window on its own HPS bridge clock domain.
4. Wire HPS cold/debug/warm reset request paths into the top-level reset
   synchronizer.
5. Validate the generated address and clock domains before Quartus fit.

This is the useful portion of `norxander/DE1-SoC-HPSFPGA`; its Caffe IP is not
part of this project.
