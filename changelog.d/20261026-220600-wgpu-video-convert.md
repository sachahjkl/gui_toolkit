type: Fixed

**WebGPU: `render.video_convert`** converts pictures in memory (I420, NV12; P010 and 10-bit I420 when the adapter has `TextureFormat16bitNorm`) with `video.wgsl`, crop, rotation, matrix and range included, as on Direct3D 11: it returned `false` for every picture (`render/wgpu_video.odin`). A decoder's Direct3D 11 texture (`gpu_texture`) is still refused on WebGPU (wgpu-native cannot import it); `tests/video` checks that refusal there instead of calling a Direct3D 11 device the backend does not have (it crashed).
