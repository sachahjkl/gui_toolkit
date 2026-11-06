type: Fixed

**A window that cannot be remade** (Direct3D 11, WebGPU) counts as a device lost: the next `frame_begin` tries again, where it drew into nothing and the next clear crashed. A swap chain that `ResizeBuffers` finds gone is a loss too, and a size asked while there is no swap chain is kept.
