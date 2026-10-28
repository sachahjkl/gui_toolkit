// Package render: a 2D GPU painter. One instanced-quad pipeline (rect.wgsl) draws everything, through one of two
// backends chosen at build time: Direct3D 11 (render_d3d.odin, frame.odin, Windows only) or WebGPU (wgpu_*.odin, every
// system). This file holds the shared types (Rect_Inst, the frame description, the Renderer and Texture_Data structs)
// and the backend-agnostic procedures (texture bookkeeping, pooled targets, the sRGB conversions, the GPU-timing and
// presentation accessors). The backend-specific work is dispatched from api.odin by `when USE_WGPU`.
//
// The Renderer and Texture_Data structs name Direct3D and DXGI types in some of their fields. Those types and the
// Win32 types alongside them still compile on every system (the vendor bindings check everywhere; only linking to
// d3d11.dll is Windows-only), so the structs are shared as they are; the code that calls into Direct3D lives behind
// `when !USE_WGPU` / in the Windows-only files and is never built elsewhere.
package render

import "core:math"
import "base:runtime"
import "core:time"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"
import "vendor:wgpu"
import "../platform"

// LOW_LATENCY (default on): at most one frame in flight + a waitable swap chain. The app waits for the GPU *before*
// reading input, so what is drawn is based on the freshest mouse position. With DXGI's default (3 frames queued) a
// hover or a drag shows up 2-3 refreshes late, which feels "floaty". Build with -define:LOW_LATENCY=false to compare.
LOW_LATENCY :: #config(LOW_LATENCY, true)
// RENDER_PROBE: print, once per second, frames presented / shown / missed, input -> screen latency, the measured rate.
RENDER_PROBE :: #config(RENDER_PROBE, false)
// D3D_DEBUG: the Direct3D debug layer (validation messages; slows drawing and presenting). On in debug builds; a profiling
// build that wants true GPU and present times turns it off with -define:D3D_DEBUG=false.
D3D_DEBUG :: #config(D3D_DEBUG, ODIN_DEBUG)
// GPU_TIMING: timestamp queries around frame_submit; `gpu_ms` returns the GPU time of a recent frame (read a few
// frames late so it never stalls). Without it, `set_gpu_timing` turns the same measurement on at run time.
GPU_TIMING :: #config(GPU_TIMING, false)
@(private) GPU_QUERY_FRAMES :: 4

// One primitive. 144 bytes, laid out exactly as the vertex shader's per-instance input.
// Without a transform (`xform` = 0) `dst` is in pixels. With one, `dst`, `radii`, `border` and `soft` are in the
// transform's local space: the vertex shader maps the corners to the screen and the pixel shader evaluates the shape
// in local space, so rotated / skewed rects keep exact rounded corners and a 1 px antialiased edge.
Rect_Inst :: struct #packed {
	dst:    [4]f32,       // x0 y0 x1 y1 (pixels, or local units with a transform)
	src:    [4]f32,       // u0 v0 u1 v1 (texels)
	colors: [4][4]f32,    // top-left, bottom-left, top-right, bottom-right (linear rgba)
	radii:  [4]f32,       // same corner order
	border: f32,          // > 0: draw only a ring of this thickness
	soft:   f32,          // <= 1: crisp antialiased edge; > 1: soft shape (shadows)
	use_tex: f32,         // KIND_*: shape, glyph (alpha x atlas coverage), image (color x RGBA texel), gradient, shadow
	tex_size: f32,        // atlas width/height in texels (square); 1 for images (the shader asks the texture)
	xform:  u32,          // index into the frame's transform table (`frame_submit`), 0 = none (dst in pixels);
	                      // in a picture: its transform slot, 0 = the picture's own space
	clip:   u32,          // index into the frame's clip-shape table, 0 = none (only the batch scissor clips);
	                      // in a picture: into the picture's clip table, 0 = only the clips around the replay
	flags:  u32,          // FLAG_*
	aux:    u32,          // KIND_GRADIENT: first entry of the gradient in the gradient table (frame or picture)
}
#assert(size_of(Rect_Inst) == 144)

KIND_SHAPE :: 0
KIND_GLYPH :: 1
KIND_IMAGE :: 2
// A rounded rect filled with a gradient evaluated per pixel (linear, radial, conic, repeating, tiled): `aux` is its
// entry in the gradient table (see Gradient_Header); colors[0].a multiplies it.
KIND_GRADIENT :: 3
// The gaussian blur of a rounded rect, computed analytically (box-shadow): `src` is the shape (x0 y0 x1 y1), `radii`
// its corners, colors[0] the color; colors[1] the second rect (x0 y0 x1 y1), colors[2] its corners, colors[3].x the
// standard deviation, colors[3].y SHADOW_* flags. All in the instance's units (local units under a transform).
KIND_SHADOW :: 4
// A glyph drawn from its outline by the Slug shaders (slug.wgsl, their own pipeline: the instance is drawn between
// the others in order, see Frame_Data.slug_runs). dst: the glyph's box (instance units, y down); src: the same box in
// em units (y up); colors[0]: the color; radii: band scale x y, offset x y; xform and clip as any instance;
// flags: band max x | band max y << 8; aux: glyph location in the band texture, x | y << 16.
KIND_SLUG :: 5
SHADOW_INSET :: 1   // inside the second rect, outside the blurred shape (CSS inset box-shadow)
SHADOW_HOLE :: 2    // outer shadow: not drawn inside the second rect (CSS: the shadow is clipped out of the border box)

FLAG_TILE :: 1   // image: repeat (wrap addressing) instead of clamping to `src`; `src` should be the whole texture
FLAG_LAYER :: 2  // image: a layer composited 1:1 in screen pixels (texels fetched, not filtered); no transform
FLAG_CIRCLE :: 4 // circular corners whatever set_corner_smoothing says (content with its own rules: CSS border-radius)
FLAG_SCREEN :: 8 // image: texels are screen pixels (texel 0 = screen pixel src.xy, src.zw = valid size): a backdrop
FLAG_BLEND :: 16 // layer composite through a blend mode (bits BLEND_SHIFT..): reads the batch's `backdrop` (t5),
                 // whose texel 0 is screen pixel radii.xy, and writes the result (the batch draws without blending)
FLAG_TEX_SRGB :: 32    // image: texels hold premultiplied sRGB-encoded color (else premultiplied linear color)
FLAG_LERP_SRGB :: 64   // corner colors interpolate across the primitive in sRGB (else in the target's Blend_Space)
FLAG_LERP_LINEAR :: 128 // corner colors interpolate in linear light
BLEND_SHIFT :: 8
// Layer composites (FLAG_LAYER) and backdrops (FLAG_SCREEN) of a filter chain's result:
FLAG_SCALED :: 0x10000 // the texture holds the image reduced (a large blur): sampled bilinearly. FLAG_LAYER: `src` is the
                       // rect in reduced texels (valid size src.zw), read transparent past it; FLAG_SCREEN: tex_size is
                       // the scale (texels per screen pixel), edges repeat
FLAG_MATRIX :: 0x20000 // color matrices applied to the texel (straight sRGB values, each result clamped), as a Color
                       // pass would: `aux` is their entry in the frame's gradient table (see Color_Matrix_Entry)
FLAG_PROJECT :: 0x40000 // image: a layer drawn through a homography (draw.draw_plane). `xform` is the first of two
                        // entries of the transform table that hold the 3x3 matrix mapping layer texels to homogeneous screen
                        // pixels, then ceil(cuts / 2) entries of cuts (half-planes a x + b y + c >= 0 of the layer's texel space,
                        // 3 floats each, kept per pixel: the pieces of a plane split by a BSP, MAX_CUTS in rect.wgsl).
                        // `dst` the quad (layer texel space), `src` the texels of the texture it covers; colors[1]: x the most
                        // taps of the anisotropic filter, y the number of cuts, z 1 when the texture has mip levels;
                        // colors[2] the frame rect (x0 y0 x1 y1: the antialiased edge, z <= x: `dst`); colors[3] the valid
                        // texels of the texture. Perspective-correct, antialiased at the frame's edge, clipped at W <= 0

// The space colors are combined in: alpha blending, antialiased edges, interpolation of corner colors, image
// filtering, layer composites. Colors given to the renderer are always linear (draw.srgb / draw.hex convert); the
// space is where the arithmetic happens.
Blend_Space :: enum u8 {
	Linear,   // linear light: physically correct mixing (50 % black over white is 188), what the UI is tuned for
	Srgb,     // gamma-encoded sRGB values, as web browsers composite (CSS Color 4, Compositing 1: 50 % black over white is 128)
}

// How a text color and the background guessed under it are blended by the text correction (Skia's "device gamma").
Text_Curve :: enum u8 {
	None,    // no correction: coverage blended as it is, in the target's space
	Srgb,    // as in linear light (the sRGB transfer curve): Skia's SK_GAMMA_SRGB, Chromium on Windows and macOS
	Power,   // in a space of exponent `gamma` over sRGB values: Skia's SK_GAMMA_EXPONENT (Chromium on Linux 1.2, Android 1.4)
}

// How glyph coverage becomes alpha (see set_text_rendering). Coverage is first raised to `coverage_exponent` (< 1
// thickens). Then, unless `curve` is None, it is corrected the way Skia does (SkMaskGamma, as used by Chromium): it is
// boosted by `contrast` (0..1, tapered by the luminance of the background, guessed as the opposite of the text's), text
// and guessed background are blended through `curve`, and the coverage that makes the target's own blend (sRGB values
// or linear light) produce that result is used. With the same settings text has the same weight in both blend spaces.
Text_Rendering :: struct {
	curve:             Text_Curve,
	gamma:             f32,   // curve = Power: the exponent
	contrast:          f32,   // 0..1 (Chromium on Windows: 1.0; Linux 0.2; macOS and Android 0)
	coverage_exponent: f32,   // 1: none
}

// The renderer's defaults: Linear keeps the toolkit's historical look (linear blending thickened by 0.8); Srgb is what
// Chromium does on Windows (Skia built with SK_GAMMA_SRGB and SK_GAMMA_CONTRAST=1.0, see chromium/src skia/BUILD.gn).
// (`gamma` 1.2, unused by these curves, is what a switch to Power starts from.)
TEXT_RENDERING_LINEAR :: Text_Rendering{curve = .None, gamma = 1.2, contrast = 0, coverage_exponent = 0.8}
TEXT_RENDERING_SRGB :: Text_Rendering{curve = .Srgb, gamma = 1.2, contrast = 1, coverage_exponent = 1}

text_rendering_default :: proc(space: Blend_Space) -> Text_Rendering {
	return space == .Srgb ? TEXT_RENDERING_SRGB : TEXT_RENDERING_LINEAR
}

// Blend modes of CSS Compositing 1 (mix-blend-mode), computed in sRGB on straight colors as browsers do.
Blend_Mode :: enum u8 {
	Normal, Multiply, Screen, Overlay, Darken, Lighten, Color_Dodge, Color_Burn, Hard_Light, Soft_Light, Difference,
	Exclusion, Hue, Saturation, Color, Luminosity, Plus_Darker, Plus_Lighter,
}

// A 2D affine transform for the vertex shader, x' = a*x + c*y + e, y' = b*x + d*y + f (`m` = a b c d e f).
Xform_Data :: struct {
	m: [6]f32,
	_: [2]f32,
}
#assert(size_of(Xform_Data) == 32)

// Clip shape kinds (Clip_Data.kind).
CLIP_RRECT :: 0     // rounded rect: center, half_size, per-corner radii
CLIP_ELLIPSE :: 1   // ellipse: center, half_size = radii
CLIP_POLYGON :: 2   // polygon: points[first ..< first + count] of the frame's point table, local space
// Clip_Data.flags
CLIP_CIRCLE :: 1    // rounded rect: circular corners whatever set_corner_smoothing says
CLIP_EVENODD :: 2   // polygon: even-odd fill rule (else nonzero)
CLIP_SCISSOR :: 4   // picture clip: a plain rect, also cut by the batch scissor; skipped per pixel when the picture is
                    // replayed under a uniform scale + translation (the scissor is exact then, as for push_clip)

// A clip shape evaluated per pixel: `inv` maps screen pixels to the clip's local space (same layout as Xform_Data.m),
// where the shape lies (see CLIP_*; rounded rect radii in the order top-left, bottom-left, top-right, bottom-right).
// `px` = screen pixels per local unit (antialiasing width). `parent` chains nested clips (0 = end); the shader follows
// at most MAX_CLIP_DEPTH links. In a picture, `inv` and `px` are unused: the shape lies in the space of transform slot
// `xform` (0 = the picture's space), mapped at replay; `parent` 0 continues with the clips around the replay.
Clip_Data :: struct {
	inv:       [6]f32,
	px:        f32,
	parent:    u32,
	center:    [2]f32,
	half_size: [2]f32,
	radii:     [4]f32,
	kind:      u32,
	first:     u32,
	count:     u32,
	flags:     u32,
	xform:     u32,
	_:         [3]u32,
}
#assert(size_of(Clip_Data) == 96)

MAX_CLIP_DEPTH :: 8

Texture :: distinct int

// One step of the frame, in recording order: a draw call (a range of instances under one scissor, with its
// textures, into one target) or, when `op` > 0, the operation ops[op - 1] (clear a layer, copy what a target holds,
// run a filter pass).
Batch :: struct {
	clip:  [4]f32,        // scissor x0 y0 x1 y1 (screen pixels, also inside a layer)
	tex:   Texture,       // coverage texture (glyph atlas, t0), 0 = none
	first: int,
	count: int,
	image: Texture,       // RGBA texture of the batch's KIND_IMAGE instances (t1), 0 = none
	target: int,          // 0 = the frame; k > 0 = layers[k - 1] (offscreen, see Layer)
	backdrop: Texture,    // FLAG_BLEND composites: what the target held under them (t5); the batch does not blend
	op:    int,           // > 0: not a draw call: Frame_Data.ops[op - 1]
	replay: int,          // > 0: draws retained instances (`first` indexes the retained instance heap) through
	                      // Frame_Data.replays[replay - 1]
	app:   int,           // > 0: one KIND_APP instance (`first`, count 1) drawn by Frame_Data.apps[app - 1]'s shader (app_shader.odin)
	shape: u32,           // while a picture is recorded: its innermost clip (the scissor is computed at replay)
}

// How a picture's instances are drawn this frame (draw.replay): its matrix (picture space -> screen pixels), the
// alpha it is faded by, the clip shape around it (frame table, 0 = none) and where its tables start in the retained
// heaps.
Replay :: struct {
	m, inv:  [6]f32,
	alpha:   f32,
	outer:   u32,
	slots, clips, points, grads: u32,
	slug_runs: [][2]int,   // the picture's Slug instances: [first, count) in its own numbering (from `insts`)
	insts:   u32,          // where the picture's instances start in the retained instance heap
}

// Gradient table entries (KIND_GRADIENT), [4]f32 each, from the instance's `aux`:
//   [0] bits: kind | GRAD_* flags, space, hue method, stop count
//   [1] geometry: Linear: start x y, end x y; Radial: center x y, radii x y; Conic: center x y, start angle (radians,
//       clockwise from up), 0
//   [2] tile: x y w h (w = 0: not tiled)
//   [3] gap between tiles x y, first and last stop position (the period of a repeating gradient)
//   [4 + 2k] stop k color, premultiplied in the interpolation space (the hue of polar spaces is not premultiplied)
//   [5 + 2k] stop k: position, transition hint (< 0: none) as a fraction of the interval to the next stop, 0, 0
GRAD_LINEAR :: 0
GRAD_RADIAL :: 1
GRAD_CONIC :: 2
GRAD_REPEATING :: 0x100
GRAD_DITHER :: 0x200
GRAD_REPEAT_X :: 0x400
GRAD_REPEAT_Y :: 0x800
GRAD_HEADER :: 4      // entries before the stops
MAX_GRADIENT_STOPS :: 256

// An offscreen layer: the batches whose `target` is its index + 1 draw into `tex` (a render target from
// acquire_target) instead of the frame, with screen pixel (x, y) landing on texel (x, y) - origin. Batches run in the
// order they were recorded, so a layer is cleared (an Op), drawn, then sampled by the instance that composites it.
// Content accumulates as premultiplied color in the layer's `space`: sampling it as a KIND_IMAGE (FLAG_TEX_SRGB for an
// sRGB layer) composites it exactly, into a target of either space.
Layer :: struct {
	tex:    Texture,      // 0: nothing to draw (empty or refused): its batches are skipped
	origin: [2]f32,
	size:   [2]int,
	space:  Blend_Space,  // what its draw calls blend in
}

// A region of a texture holding screen pixels: texel (0, 0) is screen pixel `origin`, one texel covers 1 / `scale`
// screen pixels (1, or 1/2^k for the reduced images of large blurs), `size` texels hold valid content, premultiplied in
// `space`.
Image_Ref :: struct {
	tex:    Texture,
	origin: [2]f32,
	scale:  f32,
	size:   [2]int,
	space:  Blend_Space,
}

MAX_COLOR_MATRICES :: 8
// Taps of one blur pass (bilinear pairs, center included): a standard deviation up to MAX_BLUR_SIGMA texels.
MAX_BLUR_TAPS :: 64
MAX_BLUR_SIGMA :: 40

Pass_Mode :: enum u32 {
	Color,       // the color matrices, in order, each result clamped (CSS filter functions other than blur)
	Blur,        // one direction of a separable gaussian (`dir`, `sigma` in src texels)
	Downsample,  // 1 / factor size: factor x factor average (bilinear taps between texel pairs)
	Shadow,      // drop shadow: src = blurred alpha, src2 = the input; out = src2 over (color x src.a moved by offset)
	Mask,        // masks (CSS Masking 1): src2 = a mask layer, its coverage its alpha or luminance (PASS_MASK_LUMINANCE).
	             // PASS_MASK_APPLY: out = src (the content, any space) x coverage. Else out = the coverage composited
	             // with src's alpha (the layers below, PASS_MASK_DEST) by the Mask_Op in flags >> MASK_OP_SHIFT,
	             // as premultiplied white
}
PASS_IN_LINEAR :: 1    // src holds linear premultiplied color (the frame, a layer); else sRGB-encoded premultiplied
PASS_OUT_LINEAR :: 2   // write linear premultiplied color (the end of a chain); else sRGB-encoded premultiplied
PASS_CLAMP :: 4        // reads past src's valid region repeat its edge (backdrops); else they are transparent
PASS_SRC2_LINEAR :: 8  // Shadow, Mask: src2 holds linear color
PASS_MASK_LUMINANCE :: 16
PASS_MASK_DEST :: 32
PASS_MASK_APPLY :: 64
MASK_OP_SHIFT :: 8

// How a mask layer combines with the layers below it (CSS mask-composite).
Mask_Op :: enum u32 { Add, Subtract, Intersect, Exclude }

// A filter pass (CSS Filter Effects 1). Colors are processed in sRGB as browsers do: a chain over a linear layer
// converts once from it (PASS_IN_LINEAR on its first pass) and back once (PASS_OUT_LINEAR on its last); over an sRGB
// layer it converts nothing.
Pass :: struct {
	mode:   Pass_Mode,
	flags:  u32,
	src, src2, dst: Image_Ref,   // dst.tex is written (cleared first); sources are sampled bilinearly
	dir:    [2]f32,
	sigma:  f32,
	offset: [2]f32,              // Shadow: screen pixels
	color:  [4]f32,              // Shadow: sRGB, straight alpha
	matrices: [MAX_COLOR_MATRICES][20]f32,   // Color: row-major 4 x 5 (r g b a 1) on straight sRGB values
	matrix_count: int,
	factor: int,                 // Downsample: 2, 4 or 8 (box average of factor x factor source texels); 0 = 2
}

// Mips: rebuild the mip levels of a render target (acquire_target_mips) from its level 0. Read: copy a box of a layer
// for readback_poll (readback.odin).
Op_Kind :: enum u8 { Clear, Copy, Pass, Mips, Read }

Op :: struct {
	kind:   Op_Kind,
	dst:    Texture,      // Clear: the layer's texture; Copy: a snapshot (acquire_snapshot); Pass: pass.dst.tex
	source: int,          // Copy, Read: the target read, as Batch.target
	box:    [4]i32,       // Copy, Read: x0 y0 x1 y1 in the source target's texels, copied to texel (0, 0) of dst
	readback: Readback_Id,   // Read
	pass:   Pass,
}

// Everything one frame draws (draw.end_frame builds it). Tables may be empty; entry 0 of xforms / clips is never read.
Frame_Data :: struct {
	insts:   []Rect_Inst,
	batches: []Batch,
	xforms:  []Xform_Data,
	clips:   []Clip_Data,
	points:  [][2]f32,    // polygon clip vertices
	layers:  []Layer,
	ops:     []Op,
	grads:   [][4]f32,    // gradient table (KIND_GRADIENT of immediate instances)
	replays: []Replay,    // pictures drawn this frame (Batch.replay)
	// Slug text (slug.wgsl): the instances of KIND_SLUG are drawn by their own pipeline. `slug_runs` lists them as
	// [first, count) of `insts`, ascending and not adjacent; a batch is drawn in pieces alternating between the two
	// pipelines, in order. `slug_curves` / `slug_bands` are the glyph data textures (create_slug_textures).
	slug_runs:   [][2]int,
	slug_curves: Texture,
	slug_bands:  Texture,
	// Application shaders (app_shader.odin): the draws (Batch.app) and the vec4 parameters they read (an instance's `aux` is the
	// first one of its draw)
	apps:       []App_Draw,
	app_params: [][4]f32,
}

Texture_Kind :: enum u8 { None, R8, RGBA, Target, Snapshot, Slug_Curves, Slug_Bands, Data }

// The texels of a data texture (create_texture_data): raw 8-bit values, never color-converted.
Data_Format :: enum u8 {
	RGBA8,   // four channels (a normal map, a mask pack); sampled as 0..1 floats, no sRGB decoding, not premultiplied
	R8,      // one channel (a height map, a mask)
}

Texture_Data :: struct {
	tex:  ^d3d11.ITexture2D,
	view: ^d3d11.IShaderResourceView,
	rtv:  ^d3d11.IRenderTargetView,   // Target only
	size: int,            // R8: width = height
	w, h: int,
	kind: Texture_Kind,
	mips: bool,           // has a full mip chain (generated after updates, before the next draw)
	mips_dirty: bool,
	data_format: Data_Format,   // Data only
	unfilled: bool,       // RGBA: nothing was ever written (D3D leaves DEFAULT textures undefined): zeroed before the first draw, unless an update covering the whole texture comes first
	space: Blend_Space,   // RGBA: how texels are stored (see create_texture_rgba)
	unorm: bool,          // Target: 8 bits per channel (else fp16)
	wtex:  wgpu.Texture,       // TOOLKIT_RENDER=wgpu: the texture,
	wview: wgpu.TextureView,   // its view for sampling (every mip level; a snapshot: in the frame's blend space),
	wrtv:  wgpu.TextureView,   // and for rendering into (Target only)
	wformat: wgpu.TextureFormat,
	mip_count: int,
	canvas: u8,           // RGBA, canvas.odin: 1 a source of canvas pixels, 2 a canvas (render target, kept), 3 a R8 clip mask / layer (see canvas_texture_objects)
}

Renderer :: struct {
	id:          u64,                     // renderer_id
	device:      ^d3d11.IDevice,
	ctx:         ^d3d11.IDeviceContext,
	swapchain:   ^dxgi.ISwapChain1,
	rtv:         ^d3d11.IRenderTargetView,
	vs:          ^d3d11.IVertexShader,
	ps:          ^d3d11.IPixelShader,
	layout:      ^d3d11.IInputLayout,
	slug:        Slug_Pipeline,           // slug.odin
	inst_buf:    ^d3d11.IBuffer,
	inst_cap:    int,
	globals:     ^d3d11.IBuffer,
	blend:       ^d3d11.IBlendState,
	raster:      ^d3d11.IRasterizerState,
	sampler:     ^d3d11.ISamplerState,    // glyph atlas: bilinear, clamp, level 0 only
	sampler_img: ^d3d11.ISamplerState,    // images: trilinear, clamp
	sampler_wrap: ^d3d11.ISamplerState,   // tiled images: trilinear, wrap
	xform_buf:   ^d3d11.IBuffer,          // StructuredBuffer<Xform_Data> (t2, vertex shader)
	xform_view:  ^d3d11.IShaderResourceView,
	xform_cap:   int,
	clip_buf:    ^d3d11.IBuffer,          // StructuredBuffer<Clip_Data> (t3, pixel shader)
	clip_view:   ^d3d11.IShaderResourceView,
	clip_cap:    int,
	points_buf:  ^d3d11.IBuffer,          // StructuredBuffer<float2> (t4, pixel shader): polygon clip vertices
	points_view: ^d3d11.IShaderResourceView,
	points_cap:  int,
	grads_buf:   ^d3d11.IBuffer,          // StructuredBuffer<float4> (t6): gradient table of the frame
	grads_view:  ^d3d11.IShaderResourceView,
	grads_cap:   int,
	replay_cb:   ^d3d11.IBuffer,          // constant buffer b2: the Replay of the batch being drawn
	apps:        [dynamic]App_Shader_Data,   // application shaders (app_shader.odin); index 0 is a dummy
	app_blend:   [App_Blend]^d3d11.IBlendState,
	app_params_buf:  ^d3d11.IBuffer,      // the parameters of the frame's app draws (t13)
	app_params_view: ^d3d11.IShaderResourceView,
	app_params_cap:  int,
	app_empty_tex:   ^d3d11.ITexture2D,   // 1 x 1 transparent: the textures a draw leaves empty
	app_empty_view:  ^d3d11.IShaderResourceView,
	heaps:       [Heap_Kind]Heap,         // retained data of pictures (retained.odin)
	heap_generation: u64,                 // bumps when the heaps are emptied (device lost): pictures upload again
	device_generation: u64,               // bumps when the device was recreated (recover): texture contents were lost
	lost:        bool,                    // the device was removed or reset: recover() before drawing again
	blend_replace: ^d3d11.IBlendState,    // FLAG_BLEND composites write their result
	fx_vs:       ^d3d11.IVertexShader,    // filter passes (filter.wgsl)
	fx_ps:       ^d3d11.IPixelShader,
	fx_constants: ^d3d11.IBuffer,
	sampler_border: ^d3d11.ISamplerState, // filter passes: bilinear, clamp (the shader adds the transparent border)
	frame_tex:   ^d3d11.ITexture2D,       // what `rtv` draws into (back buffer or offscreen image): snapshots copy it
	frame_format: dxgi.FORMAT,            // its storage format
	frame_view:  dxgi.FORMAT,             // how a copy of it is read: values in `space`, like the frame's render target view
	space:       Blend_Space,             // of the frame (init, set_blend_space); new RGBA textures are stored in it
	text:        Text_Rendering,          // set_text_rendering
	blur_sigma_limit: f32,                // set_blur_sigma_limit
	textures:    [dynamic]Texture_Data,   // index 0 is a dummy so Texture(0) means "none"
	free_textures: [dynamic]Texture,      // destroyed slots, reused by the next create
	targets:     [dynamic]Pooled_Target,  // layer render targets and snapshots, reused from frame to frame
	scratch:     [dynamic]u8,             // RGBA upload conversion
	zeros:       [dynamic]u8,             // zero_unfilled: a band of zero bytes
	gpu_queries: [GPU_QUERY_FRAMES][3]^d3d11.IQuery,   // GPU_TIMING: disjoint, begin, end per frame slot
	gpu_frame:   int,
	gpu_last_ms: f32,
	gpu_last_frame: int,                  // 1 + the timed submit `gpu_last_ms` belongs to (0: none yet)
	gpu_timing:  bool,                    // set_gpu_timing: measure without -define:GPU_TIMING
	prof:        Gpu_Profiler,            // set_gpu_profile: GPU time of each step (gpu_profile.odin)
	video:       Video_Pipeline,          // video.odin: decoded pictures to RGBA textures
	canvas:      Canvas_Pipeline,         // canvas.odin: 2D canvas drawing
	targets_gen: u64,                     // targets_generation
	filter_format: Target_Format,         // set_filter_precision
	latency_handle: win.HANDLE,           // signaled when the swap chain can accept a new frame (LOW_LATENCY)
	swap_flags:  dxgi.SWAP_CHAIN,
	present:     Present_State,           // present.odin: mode, frame statistics
	swap_buffers: int,                    // set before init: back buffers of the swap chain (0 = 2). 3 lets frames be
	                                      // presented faster than the compositor takes them (tearing on a fixed-rate display)
	                                      // without Present blocking; latency stays bounded by the latency object.
	size:        [2]int,                  // what is drawn and shown (the window's client area)
	buffer_size: [2]int,                  // the swap chain's buffers: `size` or larger (resize, set_resize_slack)
	source_size: [2]int,                  // the region of the buffers presented (SetSourceSize)
	resize_slack: int,                    // set_resize_slack: 0 = DEFAULT_RESIZE_SLACK, < 0 = buffers of the exact size
	fixed_surface: bool,                  // set_fixed_surface: the buffers keep one size while the window resizes
	surface_max: [2]int,                  // that size
	hwnd:        win.HWND,
	surface_handles: platform.Surface_Handles,   // the neutral native handles init was given (wgpu backend; the surface is made from them)
	corner_smoothing: f32,                // 0 = circular corners, 1 = full squircle (see set_corner_smoothing)
	transparent: bool,                    // presented through DirectComposition with premultiplied alpha
	dcomp:        ^IDCompositionDevice,
	dcomp_target: ^IDCompositionTarget,
	dcomp_visual: ^IDCompositionVisual,
	offscreen:   ^d3d11.ITexture2D,      // init_offscreen: the frame target instead of a swap chain
	warp:        bool,                   // the device is WARP (software)
	wg:          Wgpu_State,             // the wgpu backend (wgpu_*.odin); zero on the Direct3D backend
	first_present_noted: bool,
	capture:     Capture_State,          // capture.odin: reading a frame back
	damage:      Damage_State,           // damage.odin: partial redraw (dirty rectangles)
	damage_clear_vb: ^d3d11.IBuffer,     // solid quads that clear the damaged region (D3D11 has no scissored clear)
	damage_clear_cap: int,
	damage_verify_ref: ^d3d11.ITexture2D, // render.damage.verify: the full frame rendered for comparison
	damage_verify_rtv: ^d3d11.IRenderTargetView,
	teardown_wait_ms: int,               // set_teardown_wait
	swap_gen:    u64,                    // the device_generation the window's objects (swap chain, views, capture copy) were made on (exchanged with a Surface)
	swap_space:  u64,                    // the space_epoch they were made in (idem)
	space_epoch: u64,                    // bumps at each set_blend_space
}

blend_space :: proc(r: ^Renderer) -> Blend_Space { return r.space }

// True when the window shows through pixels with alpha < 1 (init asked for it and the system supports it).
is_transparent :: proc(r: ^Renderer) -> bool { return r.transparent }

// Glyph coverage to alpha (see Text_Rendering). Applies to the whole frame, from the next frame_submit.
set_text_rendering :: proc(r: ^Renderer, t: Text_Rendering) {
	r.text = Text_Rendering{
		curve = t.curve,
		gamma = clamp(t.gamma, 0.25, 4),
		contrast = clamp(t.contrast, 0, 1),
		coverage_exponent = clamp(t.coverage_exponent, 0.1, 4),
	}
}

text_rendering :: proc(r: ^Renderer) -> Text_Rendering { return r.text }

// Corner shape for every rounded rect: 0 = circular arcs, 1 = squircle (superellipse corners, continuous curvature).
set_corner_smoothing :: proc(r: ^Renderer, smoothing: f32) { r.corner_smoothing = clamp(smoothing, 0, 1) }

// Call right after reading input: the next present is credited with this time (Displayed_Frame.input), unless
// set_frame_input gave an earlier one (the time the input arrived).
mark_input :: proc(r: ^Renderer) {
	if r.present.input._nsec == 0 { r.present.input = time.tick_now() }
}

// The sRGB transfer functions (IEC 61966-2-1), on one channel in 0..1.
linear_to_srgb :: proc(l: f32) -> f32 {
	x := clamp(l, 0, 1)
	return x <= 0.0031308 ? x * 12.92 : 1.055 * math.pow(x, 1 / 2.4) - 0.055
}

srgb_to_linear :: proc(s: f32) -> f32 {
	x := clamp(s, 0, 1)
	return x <= 0.04045 ? x / 12.92 : math.pow((x + 0.055) / 1.055, 2.4)
}

////////////////////////////////
// Resize bookkeeping (shared). The swap-chain / surface work itself is per backend (d3d_resize, wgpu_resize).

DEFAULT_RESIZE_SLACK :: 256

// Room the swap chain's buffers keep to grow during a resize, in pixels per axis (see resize; 0 = buffers of the exact
// size). Default DEFAULT_RESIZE_SLACK. Takes effect at the next resize.
set_resize_slack :: proc(r: ^Renderer, px: int) { r.resize_slack = px > 0 ? px : -1 }

@(private)
resize_slack :: proc(r: ^Renderer) -> int { return r.resize_slack == 0 ? DEFAULT_RESIZE_SLACK : max(r.resize_slack, 0) }

// The size of the swap chain's buffers (at least the presented size; see resize).
buffer_size :: proc(r: ^Renderer) -> [2]int { return r.buffer_size }

// `destroy` waits at most `ms` milliseconds for the swap chain to be released (0: as long as it takes). A program that ends right
// after `destroy` sets it, so that a compositor with no time to spare does not hold it up.
set_teardown_wait :: proc(r: ^Renderer, ms: int) { r.teardown_wait_ms = max(ms, 0) }

////////////////////////////////
// Textures (bookkeeping shared by both backends; the GPU objects are per backend)

@(private)
add_texture :: proc(r: ^Renderer, td: Texture_Data) -> Texture {
	if n := len(r.free_textures); n > 0 {
		t := pop(&r.free_textures)
		r.textures[int(t)] = td
		return t
	}
	append(&r.textures, td)
	return Texture(len(r.textures) - 1)
}

// Size in texels (0, 0 for an invalid or destroyed texture).
texture_size :: proc(r: ^Renderer, t: Texture) -> [2]int {
	if int(t) <= 0 || int(t) >= len(r.textures) { return {} }
	td := r.textures[int(t)]
	return {td.w, td.h}
}

// How an RGBA texture stores its texels (the renderer's blend space when it was created).
texture_space :: proc(r: ^Renderer, t: Texture) -> Blend_Space {
	if int(t) <= 0 || int(t) >= len(r.textures) { return .Linear }
	return r.textures[int(t)].space
}

// Bytes per texel of a texture (render targets and images; 0 for none).
texture_bpp :: proc(r: ^Renderer, t: Texture) -> int {
	if int(t) <= 0 || int(t) >= len(r.textures) { return 0 }
	switch r.textures[int(t)].kind {
	case .None: return 0
	case .R8: return 1
	case .Data: return r.textures[int(t)].data_format == .R8 ? 1 : 4
	case .RGBA, .Snapshot, .Slug_Bands: return 4
	case .Target: return r.textures[int(t)].unorm ? 4 : 8
	case .Slug_Curves: return 8
	}
	return 0
}

// True when every pixel of the block has alpha 255 (RGBA8 rows `pitch` bytes apart): an opaque image needs no conversion.
// A reduction of the words' AND, which the compiler vectorizes: memory speed, and a transparent image stops at its first
// row with a translucent pixel.
@(private)
block_is_opaque :: proc(pixels: []u8, w, h, pitch: int) -> bool {
	for row in 0 ..< h {
		words := ([^]u32)(raw_data(pixels[row * pitch:]))[:w]
		acc: u32 = 0xFFFF_FFFF
		for v in words { acc &= v }
		if acc >> 24 != 0xFF { return false }
	}
	return true
}

// One RGBA8 pixel (R in the low byte) premultiplied: each color channel c becomes round(c * a / 255) = (c * a + 127) / 255
// (the division as the exact multiply-and-shift ((t + 128) * 257) >> 16 of t = c * a, two channels per multiply).
@(private)
premultiply_word :: #force_inline proc "contextless" (px: u32) -> u32 {
	a := px >> 24
	rb := (px & 0x00FF_00FF) * a + 0x0080_0080
	rb = ((rb + ((rb >> 8) & 0x00FF_00FF)) >> 8) & 0x00FF_00FF
	g := ((px >> 8) & 0xFF) * a + 128
	g = (g + (g >> 8)) >> 8
	return rb | (g & 0xFF) << 8 | a << 24
}

// Converts a w x h block of straight sRGB RGBA8 to the texture's storage (see create_texture_rgba) into r.scratch, and
// returns what to upload: the converted copy, or the caller's own pixels when they are opaque (premultiplying changes
// nothing: no pass over them, no copy; `row` = bytes between rows, `n` = bytes the upload reads).
@(private)
premultiply_upload :: proc(r: ^Renderer, td: ^Texture_Data, w, h: int, pixels: []u8, pitch: int) -> (data: rawptr, row, n: int) {
	if block_is_opaque(pixels, w, h, pitch) { return raw_data(pixels), pitch, pitch * (h - 1) + w * 4 }
	runtime.resize(&r.scratch, w * h * 4)
	if td.space == .Srgb {
		// premultiplied on the sRGB values themselves: no tables and no branches, a word at a time (what the compiler
		// vectorizes); alpha 255 and 0 come out right by themselves
		for y in 0 ..< h {
			src := ([^]u32)(raw_data(pixels[y * pitch:]))[:w]
			dst := ([^]u32)(raw_data(r.scratch[y * w * 4:]))[:w]
			for i in 0 ..< w { dst[i] = premultiply_word(src[i]) }
		}
		return raw_data(r.scratch), w * 4, w * h * 4
	}
	srgb_tables_init()
	for y in 0 ..< h {
		src := pixels[y * pitch:][:w * 4]
		dst := r.scratch[y * w * 4:][:w * 4]
		for i := 0; i < w * 4; i += 4 {
			a := src[i + 3]
			switch a {
			case 255: dst[i], dst[i + 1], dst[i + 2], dst[i + 3] = src[i], src[i + 1], src[i + 2], 255
			case 0:   dst[i], dst[i + 1], dst[i + 2], dst[i + 3] = 0, 0, 0, 0
			case:
				if td.space == .Srgb {
					for k in 0 ..< 3 { dst[i + k] = u8((u32(src[i + k]) * u32(a) + 127) / 255) }
				} else {
					af := f32(a) / 255
					for k in 0 ..< 3 {
						lin := srgb_to_linear_table[src[i + k]] * af
						dst[i + k] = linear_to_srgb_table[int(lin * (LINEAR_STEPS - 1) + 0.5)]
					}
				}
				dst[i + 3] = a
			}
		}
	}
	return raw_data(r.scratch), w * 4, w * h * 4
}

@(private) LINEAR_STEPS :: 4096
@(private) srgb_to_linear_table: [256]f32
@(private) linear_to_srgb_table: [LINEAR_STEPS]u8
@(private) srgb_tables_ready: bool

@(private)
srgb_tables_init :: proc() {
	if srgb_tables_ready { return }
	for i in 0 ..< 256 {
		c := f32(i) / 255
		srgb_to_linear_table[i] = c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4)
	}
	for i in 0 ..< LINEAR_STEPS {
		l := f32(i) / (LINEAR_STEPS - 1)
		s := l <= 0.0031308 ? l * 12.92 : 1.055 * math.pow(l, 1 / 2.4) - 0.055
		linear_to_srgb_table[i] = u8(clamp(s * 255 + 0.5, 0, 255))
	}
	srgb_tables_ready = true
}

// GPU memory of the textures the renderer made, by kind, in bytes (mip chains included).
Texture_Memory :: struct { glyphs, images, targets, count: int, slug: int }

texture_memory :: proc(r: ^Renderer) -> (m: Texture_Memory) {
	for td, i in r.textures {
		if i == 0 || (td.tex == nil && td.wtex == nil) { continue }
		m.count += 1
		switch td.kind {
		case .None:
		case .R8: m.glyphs += td.size * td.size
		case .RGBA:
			n := td.w * td.h * 4
			m.images += td.mips ? n * 4 / 3 : n
		case .Data:
			n := td.w * td.h * (td.data_format == .R8 ? 1 : 4)
			m.images += td.mips ? n * 4 / 3 : n
		case .Target, .Snapshot: m.targets += td.w * td.h * (td.kind == .Snapshot || td.unorm ? 4 : 8)
		case .Slug_Curves: m.slug += td.w * td.h * 8
		case .Slug_Bands: m.slug += td.w * td.h * 4
		}
	}
	return
}

////////////////////////////////
// Layer targets (pool shared by both backends; the GPU objects are made per backend)

@(private)
Pooled_Target :: struct {
	tex:   Texture,
	w, h:  int,
	snapshot: bool,       // a copy of the frame (its format, no render target view); else a render target
	unorm: bool,          // render target in 8 bits per channel (filter results, sRGB-encoded); else fp16
	mips:  bool,          // with a full mip chain (a plane's layer: Op_Kind.Mips fills it)
	used:  bool,          // handed out for the frame being built
	kept:  bool,          // keep_target: held across frames by its owner (a cached filter result), never handed out
	idle:  int,           // frames since it was last used
}

// Formats of pooled render targets (acquire_target_format).
Target_Format :: enum u8 {
	Half,    // fp16 RGBA: layers (content blended in linear light needs it), linear results
	Unorm8,  // 8-bit RGBA: sRGB-encoded premultiplied filter results (half the memory and bandwidth)
}

// Pooled targets are allocated in steps of this many pixels, so a layer that grows or shrinks a little (an animation)
// keeps its texture.
@(private) TARGET_STEP :: 128
// A pooled target nobody used for this many frames is released.
@(private) TARGET_IDLE_FRAMES :: 120

// A render target of at least w x h pixels for the frame being built (fp16, premultiplied, in whatever space its
// writer uses): a layer, a filter pass. It belongs to the renderer and is handed back by frame_submit, or earlier by release_target. 0 when the size
// is out of range or the device refuses (draw then falls back to per-primitive alpha).
acquire_target :: proc(r: ^Renderer, w, h: int) -> Texture { return acquire_pooled(r, w, h, false) }

// acquire_target with a full mip chain (fp16): drawn into at level 0, then filled by an Op_Kind.Mips recorded after the last
// draw into it. 0 also when the device cannot generate mips for the format: the caller falls back to acquire_target.
acquire_target_mips :: proc(r: ^Renderer, w, h: int) -> Texture { return acquire_pooled(r, w, h, false, false, true) }

// Can the device build the mip levels of fp16 render targets (acquire_target_mips)?
target_mips_supported :: proc(r: ^Renderer) -> bool {
	when USE_WGPU { return true } else {
		support: u32
		r.device->CheckFormatSupport(.R16G16B16A16_FLOAT, &support)
		return support & u32(d3d11.FORMAT_SUPPORT.MIP_AUTOGEN) != 0
	}
}

// acquire_target in a chosen format.
acquire_target_format :: proc(r: ^Renderer, w, h: int, format: Target_Format) -> Texture {
	return acquire_pooled(r, w, h, false, format == .Unorm8)
}

// A texture that can receive a copy of `target` (0: the frame, k: a layer, as Batch.target): the frame's own format
// (8-bit, read in the frame's blend space, or fp16 for a linear translucent window), fp16 for a layer. For backdrops
// and blend modes.
acquire_snapshot :: proc(r: ^Renderer, w, h: int, target: int) -> Texture {
	return acquire_pooled(r, w, h, target == 0 && r.frame_format != .R16G16B16A16_FLOAT)
}

// Hands a pooled texture back before the end of the frame: a texture acquired later in the frame may reuse it. Safe
// because steps run in the order they are recorded: release it once the last step reading it is recorded. A kept
// texture is not affected (unkeep_target hands it back).
release_target :: proc(r: ^Renderer, t: Texture) {
	if t == 0 { return }
	for &p in r.targets { if p.tex == t { if !p.kept { p.used = false }; return } }
}

// Keeps a pooled texture acquired this frame beyond the frame (a filter result reused by later frames): the pool never
// hands it out again until unkeep_target. Its contents survive until then, except when the pool is emptied
// (release_targets, a lost device: `targets_generation` changes) . false: not a pooled texture.
keep_target :: proc(r: ^Renderer, t: Texture) -> bool {
	if t == 0 { return false }
	for &p in r.targets {
		if p.tex == t { p.kept, p.used, p.idle = true, true, 0; return true }
	}
	return false
}

// Gives a kept texture back to the pool (reusable from the next acquire on).
unkeep_target :: proc(r: ^Renderer, t: Texture) {
	if t == 0 { return }
	for &p in r.targets { if p.tex == t { p.kept, p.used, p.idle = false, false, 0; return } }
}

// Changes whenever pooled textures were destroyed wholesale (release_targets, device recovery): kept textures of an
// older generation are gone.
targets_generation :: proc(r: ^Renderer) -> u64 { return r.targets_gen }

@(private)
acquire_pooled :: proc(r: ^Renderer, w, h: int, snapshot: bool, unorm := false, mips := false) -> Texture {
	if w <= 0 || h <= 0 || w > max_texture_size(r) || h > max_texture_size(r) { return 0 }
	if mips && (snapshot || unorm || (w <= 1 && h <= 1)) { return 0 }
	when !USE_WGPU {
		if mips {
			support: u32
			r.device->CheckFormatSupport(.R16G16B16A16_FLOAT, &support)
			if support & u32(d3d11.FORMAT_SUPPORT.MIP_AUTOGEN) == 0 { return 0 }
		}
	}
	best := -1
	for &p, i in r.targets {
		if p.used || p.kept || p.snapshot != snapshot || p.unorm != unorm || p.mips != mips || p.w < w || p.h < h { continue }
		if best < 0 || p.w * p.h < r.targets[best].w * r.targets[best].h { best = i }
	}
	if best >= 0 {
		r.targets[best].used, r.targets[best].idle = true, 0
		return r.targets[best].tex
	}
	limit := max_texture_size(r)
	aw := min((w + TARGET_STEP - 1) / TARGET_STEP * TARGET_STEP, limit)
	ah := min((h + TARGET_STEP - 1) / TARGET_STEP * TARGET_STEP, limit)
	td := Texture_Data{w = aw, h = ah, size = max(aw, ah), kind = snapshot ? .Snapshot : .Target, unorm = unorm && !snapshot, mips = mips}
	when USE_WGPU {
		if !wgpu_target_objects(r, &td) { return 0 }
		t := add_texture(r, td)
		append(&r.targets, Pooled_Target{tex = t, w = aw, h = ah, snapshot = snapshot, unorm = td.unorm, mips = mips, used = true})
		return t
	} else {
	desc := d3d11.TEXTURE2D_DESC{
		Width = u32(aw), Height = u32(ah), MipLevels = 1, ArraySize = 1, Format = unorm ? .R8G8B8A8_UNORM : .R16G16B16A16_FLOAT,
		SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.SHADER_RESOURCE, .RENDER_TARGET},
	}
	if mips { desc.MipLevels, desc.MiscFlags = 0, {.GENERATE_MIPS} }
	if snapshot {
		// the frame's typeless storage, read through the view of its blend space: texels hold the values the frame
		// blends with (linear decoded from sRGB, or sRGB as stored)
		desc.Format, desc.BindFlags = .B8G8R8A8_TYPELESS, {.SHADER_RESOURCE}
	}
	if win.FAILED(r.device->CreateTexture2D(&desc, nil, &td.tex)) { return 0 }
	if snapshot {
		sd := d3d11.SHADER_RESOURCE_VIEW_DESC{Format = r.frame_view, ViewDimension = .TEXTURE2D}
		sd.Texture2D.MipLevels = 1
		if win.FAILED(r.device->CreateShaderResourceView(td.tex, &sd, &td.view)) { td.tex->Release(); return 0 }
	} else {
		if win.FAILED(r.device->CreateShaderResourceView(td.tex, nil, &td.view)) { td.tex->Release(); return 0 }
		if win.FAILED(r.device->CreateRenderTargetView(td.tex, nil, &td.rtv)) { td.view->Release(); td.tex->Release(); return 0 }
	}
	t := add_texture(r, td)
	append(&r.targets, Pooled_Target{tex = t, w = aw, h = ah, snapshot = snapshot, unorm = td.unorm, mips = mips, used = true})
	return t
	}
}

// Ends the frame's use of the layer targets; releases the ones idle for long.
@(private)
recycle_targets :: proc(r: ^Renderer) {
	for i := len(r.targets) - 1; i >= 0; i -= 1 {
		p := &r.targets[i]
		if p.kept { continue }
		if p.used { p.used, p.idle = false, 0; continue }
		p.idle += 1
		if p.idle > TARGET_IDLE_FRAMES {
			destroy_texture(r, p.tex)
			unordered_remove(&r.targets, i)
		}
	}
}

// Releases every pooled layer target (memory pressure, device teardown), kept ones included (targets_generation).
release_targets :: proc(r: ^Renderer) {
	for p in r.targets { destroy_texture(r, p.tex) }
	clear(&r.targets)
	r.targets_gen += 1
}

// GPU memory held by the pooled layer targets, in bytes (kept ones included).
targets_bytes :: proc(r: ^Renderer) -> int {
	n := 0
	for p in r.targets {
		b := p.w * p.h * (p.snapshot || p.unorm ? 4 : 8)
		n += p.mips ? b * 4 / 3 : b
	}
	return n
}

// GPU memory of the kept targets (keep_target), in bytes.
kept_targets_bytes :: proc(r: ^Renderer) -> int {
	n := 0
	for p in r.targets { if p.kept { n += p.w * p.h * (p.unorm ? 4 : 8) } }
	return n
}

////////////////////////////////
// GPU timing accessors (shared; the measurement itself is per backend)

// GPU time of frame_submit (milliseconds) for a frame a few frames back; 0 when nothing is measured (neither
// -define:GPU_TIMING=true nor set_gpu_timing).
gpu_ms :: proc(r: ^Renderer) -> f32 { return r.gpu_last_ms }

// Measures the GPU time of each frame_submit from now on (timestamp queries in a ring, read GPU_QUERY_FRAMES submits
// later: the CPU never waits for them). Costs a few queries per frame; off, nothing.
set_gpu_timing :: proc(r: ^Renderer, on: bool) { r.gpu_timing = on }
gpu_timing_enabled :: proc(r: ^Renderer) -> bool { return GPU_TIMING || r.gpu_timing }

// The index the next timed frame_submit will have: remember it with a frame to match `gpu_result` to it later.
gpu_next_frame :: proc(r: ^Renderer) -> int { return r.gpu_frame }

// The latest GPU time read back, and the index of the submit it measured (ok false: none yet).
gpu_result :: proc(r: ^Renderer) -> (ms: f32, frame: int, ok: bool) {
	if r.gpu_last_frame == 0 { return 0, -1, false }
	return r.gpu_last_ms, r.gpu_last_frame - 1, true
}

// The constant buffer of rect.wgsl (register b0), per target. Shared: both backends fill it (frame.odin, wgpu_frame.odin).
@(private)
Globals :: struct #packed {
	viewport_size: [2]f32,
	corner_n, corner_boost: f32,
	target_origin: [2]f32,
	target_space: u32,       // Blend_Space of the target being drawn
	text_gamma: f32,         // 0: no correction; < 0: the sRGB curve; > 0: a power curve
	text_contrast, text_exponent: f32,
	_: [2]f32,
}
#assert(size_of(Globals) == 48)
