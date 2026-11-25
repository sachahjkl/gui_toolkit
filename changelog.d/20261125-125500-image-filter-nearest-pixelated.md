type: Added

**Nearest-neighbour and pixelated image filtering (`draw.set_image_filter`, `render.FLAG_IMAGE_PIXELATED`, `render.FLAG_IMAGE_NEAREST`)**: `draw.set_image_filter(dc, .Smooth | .Pixelated | .Nearest)` sets per-instance image sampling for `image`, `image_corners`, `image_cover`, `image_tiled`, and retained `draw.Picture` recordings without adding extra GPU samplers or splitting GL batches. `.Pixelated` fetches nearest texels when magnifying and falls back to trilinear filtering with mips when minifying; `.Nearest` fetches nearest texels at every scale.
