type: Fixed

**WebGPU: frames of an offscreen renderer wait for the device**: with no present to pace them they piled up on a slow device, and a read-back waited behind them for up to minutes.
