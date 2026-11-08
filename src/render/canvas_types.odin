package render

// The 2D canvas renderer's data (see canvas.odin, canvas.wgsl): what a canvas context records and the renderer replays in
// one go. A list is built by the owner of the canvas (a context recording its calls); nothing in it points into the
// renderer except texture handles.

// One primitive: a quad of device pixels, its geometry, its paint, its operator. 96 bytes, the vertex shader's per-instance
// input (locations 0 to 5).
Canvas_Inst :: struct #packed {
	box:   [4]f32,   // x0 y0 x1 y1: the device pixels the quad covers (the pixel shader gives each one its coverage)
	geom:  [4]f32,   // CG_RECT, CG_RRECT, CG_ELLIPSE: center x y, half size x y (local units). CG_SHAPE: the bounds x0 y0 x1 y1
	geom2: [4]f32,   // CG_RRECT: radii top-left, top-right, bottom-right, bottom-left (local units)
	inv:   [4]f32,   // device pixel -> local space (a b c d: x' = a x + c y + e, y' = b x + d y + f)
	misc:  [4]f32,   // inv e, inv f, the global alpha, device pixels per local unit
	ids:   [4]u32,   // flags (below), paint index, CG_SHAPE: offset of its data in the heap, bands | (unused) << 16
}
#assert(size_of(Canvas_Inst) == 96)

// Canvas_Inst.ids[0]: the geometry kind (bits 0..3), then
CG_RECT :: 1
CG_RRECT :: 2
CG_ELLIPSE :: 3
CG_SHAPE :: 4
CF_EVENODD :: 16     // CG_SHAPE: even-odd fill rule (else nonzero)
CF_UNBOUNDED :: 32   // the operator changes pixels the shape does not cover (source-in...): the quad's pixels are all written
CF_CLIP :: 64        // the clip mask of the draw (Canvas_Cmd.clip) multiplies the coverage
CF_MASK_OUT :: 128   // writes the coverage (times the clip) to a clip mask instead of painting
CF_OP_SHIFT :: 8     // bits 8..12: the Composite_Op of the canvas2d package (Source_Over = 0 ... Luminosity = 25)

// A fill: what each covered pixel takes. 96 bytes (a table, Canvas_List.paints).
Canvas_Paint :: struct #packed {
	color: [4]f32,   // CP_SOLID: premultiplied; CPF_TINT: the tint
	m:     [4]f32,   // device pixel -> paint space a b c d (linear gradient: x y of t = x px + y py + t.z)
	t:     [4]f32,   // e f, linear gradient: (_, _, t0)
	p:     [4]f32,   // radial: x0 y0 r0 x1; conic: center x y, start angle; image: source rectangle x0 y0 x1 y1 (texels)
	q:     [4]f32,   // radial: y1 r1; image: texture width, height
	kind:  u32,
	nstops: u32,
	stops: u32,      // first stop in Canvas_List.stops (two [4]f32 each: the straight color, then the offset in x)
	flags: u32,
}
#assert(size_of(Canvas_Paint) == 96)

CP_SOLID :: 0
CP_LINEAR :: 1
CP_RADIAL :: 2
CP_CONIC :: 3
CP_IMAGE :: 4

// Canvas_Paint.flags for an image: wrap x (bits 0..1), wrap y (2..3): WRAP_NONE (transparent outside the source rectangle),
// WRAP_CLAMP, WRAP_REPEAT; the filter (bits 4..6); CPF_LINEAR_SRC: the texture holds linear light (a video converted for a
// linear renderer); CPF_TINT: the texel's alpha scales `color` (the shadow of a blurred layer).
CP_WRAP_NONE :: 0
CP_WRAP_CLAMP :: 1
CP_WRAP_REPEAT :: 2
CP_FILTER_SHIFT :: 4
CP_FILTER_NEAREST :: 0
CP_FILTER_BILINEAR :: 1   // no mip levels (imageSmoothingQuality "low")
CP_FILTER_MIPS :: 2       // trilinear ("medium")
CP_FILTER_ANISO :: 3      // anisotropic ("high")
CPF_LINEAR_SRC :: 256
CPF_TINT :: 512

Canvas_Cmd_Kind :: enum u8 {
	Draw,         // the instances [first, first + count) with `op`, `source`, `clip`, inside `box` (the scissor)
	Clip_Make,    // a new clip mask `id`: the instances [first, first + count) (CF_MASK_OUT) multiplied by the mask `clip` (0: none), inside `box`
	Clip_Free,    // the clip mask `id` is not used any more
	Put,          // putImageData: the premultiplied pixels at `pix` (a `box` w x h block, rows packed) replace the block at box.xy
	Snapshot,     // a copy of `box` of the canvas, the source CANVAS_SRC_SNAPSHOT of the draws that follow (drawImage of itself)
	Layer_Begin,  // a transparent layer `id` of the size of `box` (canvas pixels): draws go into it until Layer_End
	Layer_End,
	Layer_Fx,     // layer `id2` through the pass `fx` into layer `id` (may be the same one)
	Layer_Free,
	Clear,        // the whole canvas to `color` (premultiplied)
}

Canvas_Fx :: enum u8 { Matrix, Blur, Copy }

// Values of Canvas_Cmd.source: an index into Canvas_List.sources, or
CANVAS_SRC_NONE :: -1
CANVAS_SRC_SNAPSHOT :: -2
// <= CANVAS_SRC_LAYER0: the texture of layer (CANVAS_SRC_LAYER0 - source)
CANVAS_SRC_LAYER0 :: -3

Canvas_Cmd :: struct {
	kind:   Canvas_Cmd_Kind,
	op:     u8,            // Draw: the Composite_Op
	fx:     Canvas_Fx,
	source: i32,
	clip:   i32,           // the mask drawn through (0: none)
	id:     i32,
	id2:    i32,
	box:    [4]i32,        // x0 y0 x1 y1 in canvas pixels (Put: x y w h)
	first, count: int,
	pix:    int,
	sigma:  f32,           // Layer_Fx Blur: standard deviation in pixels
	color_matrix: [20]f32,// Layer_Fx Matrix: rows r g b a of the 4x5 matrix on straight colors (r g b a 1), row-major
	color:  [4]f32,
}

// What one flush draws, in order.
Canvas_List :: struct {
	insts:   []Canvas_Inst,
	heap:    [][4]u32,       // polygon data (see canvas.wgsl: shape_coverage)
	paints:  []Canvas_Paint,
	stops:   [][4]f32,
	cmds:    []Canvas_Cmd,
	pixels:  []u8,
	sources: []Texture,      // textures draws sample (canvas textures made by canvas_texture_create, or any RGBA texture)
}

// A texture of a canvas (a drawing target or a source of pixels): premultiplied sRGB-encoded values in R8G8B8A8, whatever the
// renderer's blend space. It draws with draw.image like any RGBA texture (texture_space says Srgb).
Canvas_Texture_Info :: struct {
	size:    [2]int,
	mips:    bool,
	target:  bool,
}

// Statistics of the canvas renderer (reset by canvas_stats_reset).
Canvas_Stats :: struct {
	submits:   int,
	draws:     int,    // draw calls
	insts:     int,
	copies:    int,    // backdrop, snapshot copies
	layers:    int,
	clip_masks: int,
	reads:     int,    // read-backs
	read_bytes: int,
	uploads:   int,
	upload_bytes: int,
}
