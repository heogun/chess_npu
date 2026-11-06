// Engine adapter for the SF19 NNUE core (M7). The only call site is Eval::evaluate()
// (sw/host/patches/0002-fpga-eval.patch); everything else in the engine is official sf_19.
//
// SF_NNUE_MODE selects the evaluation path, once per process:
//   cpu      (default) official Network::evaluate(); the adapter does nothing.
//   plan     official result, and the hardware path's ARM work (features, request planning,
//            descriptor encoding) done and discarded: its cost without a device.
//   hw       the FPGA's (psqt, positional) pair. Any device error stops the process; there is no
//            silent CPU fallback.
//   compare  both, every evaluation; a differing pair stops the process.
// SF_NNUE_WEIGHTS (default /root/weights.bin) is the packed weight image, SF_NNUE_LOAD=0 keeps the
// image already in DDR (it is still read back and compared). SF_NNUE_TIMING=1 times each part per
// evaluation (adds clock reads to the measured path). A summary goes to stderr at exit.
// The hardware path supports one search thread: a second calling thread stops the process.
#pragma once

#include "network.h"

namespace Stockfish {
class Position;
}

namespace Stockfish::Eval::NNUE::Fpga {

// True unless SF_NNUE_MODE is cpu (or unset).
bool enabled();

NetworkOutput evaluate(const Network& network, const Position& pos, AccumulatorStack& accumulators,
                       AccumulatorCaches& caches);

}  // namespace Stockfish::Eval::NNUE::Fpga
