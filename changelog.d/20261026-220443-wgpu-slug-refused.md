type: Fixed

**WebGPU: Slug text when the device refuses its shaders** draws nothing instead of passing a missing shader module to the pipeline: `r.slug.failed` is honoured by both backends (it was Direct3D 11 only), a refused `slug.wgsl` sets it, a recreated device asks again.
