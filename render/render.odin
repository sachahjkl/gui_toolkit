// Package render: Direct3D 11 backend. One instanced-quad pipeline draws everything (see rect.wgsl).
package render

import "core:fmt"
import "core:math"
import "core:mem"
import "base:runtime"
import "core:time"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"
import "vendor:directx/dxgi"
import "vendor:wgpu"

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

Op_Kind :: enum u8 { Clear, Copy, Pass, Mips }   // Mips: rebuild the mip levels of a render target (acquire_target_mips) from its level 0

Op :: struct {
	kind:   Op_Kind,
	dst:    Texture,      // Clear: the layer's texture; Copy: a snapshot (acquire_snapshot); Pass: pass.dst.tex
	source: int,          // Copy: the target read, as Batch.target
	box:    [4]i32,       // Copy: x0 y0 x1 y1 in the source target's texels, copied to texel (0, 0) of dst
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
}

Texture_Kind :: enum u8 { None, R8, RGBA, Target, Snapshot, Slug_Curves, Slug_Bands }

Texture_Data :: struct {
	tex:  ^d3d11.ITexture2D,
	view: ^d3d11.IShaderResourceView,
	rtv:  ^d3d11.IRenderTargetView,   // Target only
	size: int,            // R8: width = height
	w, h: int,
	kind: Texture_Kind,
	mips: bool,           // has a full mip chain (generated after updates, before the next draw)
	mips_dirty: bool,
	space: Blend_Space,   // RGBA: how texels are stored (see create_texture_rgba)
	unorm: bool,          // Target: 8 bits per channel (else fp16)
	wtex:  wgpu.Texture,       // TOOLKIT_RENDER=wgpu: the texture,
	wview: wgpu.TextureView,   // its view for sampling (every mip level; a snapshot: in the frame's blend space),
	wrtv:  wgpu.TextureView,   // and for rendering into (Target only)
	wformat: wgpu.TextureFormat,
	mip_count: int,
}

Renderer :: struct {
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
	gpu_queries: [GPU_QUERY_FRAMES][3]^d3d11.IQuery,   // GPU_TIMING: disjoint, begin, end per frame slot
	gpu_frame:   int,
	gpu_last_ms: f32,
	gpu_last_frame: int,                  // 1 + the timed submit `gpu_last_ms` belongs to (0: none yet)
	gpu_timing:  bool,                    // set_gpu_timing: measure without -define:GPU_TIMING
	prof:        Gpu_Profiler,            // set_gpu_profile: GPU time of each step (gpu_profile.odin)
	video:       Video_Pipeline,          // video.odin: decoded pictures to RGBA textures
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
	hwnd:        win.HWND,
	corner_smoothing: f32,                // 0 = circular corners, 1 = full squircle (see set_corner_smoothing)
	transparent: bool,                    // presented through DirectComposition with premultiplied alpha
	dcomp:        ^IDCompositionDevice,
	dcomp_target: ^IDCompositionTarget,
	dcomp_visual: ^IDCompositionVisual,
	offscreen:   ^d3d11.ITexture2D,      // init_offscreen: the frame target instead of a swap chain
	warp:        bool,                   // the device is WARP (software)
	wg:          Wgpu_State,             // TOOLKIT_RENDER=wgpu (wgpu_*.odin); zero otherwise
	first_present_noted: bool,
}

// `transparent`: the window shows through wherever the frame has alpha < 1 (open the window with `transparent` too).
// Clear to {0, 0, 0, 0} and draw translucent colours; the output is premultiplied, which is what blending onto a
// transparent clear produces anyway. `space`: what the frame blends in (set_blend_space changes it later).
d3d_init :: proc(r: ^Renderer, hwnd: win.HWND, size: [2]int, transparent := false, space := Blend_Space.Linear) -> bool {
	r.hwnd = hwnd
	r.size = size
	r.transparent = transparent
	r.space = space
	create_device(r, .HARDWARE) or_return
	create_swapchain(r) or_return
	return init_pipeline(r)
}

// The swap chain of the window (a composition one when translucent), its waitable object and the frame's view.
@(private)
create_swapchain :: proc(r: ^Renderer) -> bool {
	hwnd, size, transparent := r.hwnd, r.size, r.transparent
	dxgi_device: ^dxgi.IDevice
	r.device->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dxgi_device))
	adapter: ^dxgi.IAdapter
	dxgi_device->GetAdapter(&adapter)
	factory: ^dxgi.IFactory2
	adapter->GetParent(dxgi.IFactory2_UUID, (^rawptr)(&factory))
	defer { factory->Release(); adapter->Release(); dxgi_device->Release() }

	desc := dxgi.SWAP_CHAIN_DESC1{
		Width       = 0, Height = 0,
		Format      = .B8G8R8A8_UNORM,
		SampleDesc  = {Count = 1},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		BufferCount = u32(clamp(r.swap_buffers, 2, 16) if r.swap_buffers > 0 else 2),
		// STRETCH: the presented region (SetSourceSize, see resize) maps onto the client area 1:1 when it has the
		// window's size. (With NONE, DWM drew a source region smaller than the buffers magnified.) A frame that
		// comes after the window changed size is stretched for the refresh it is shown in.
		Scaling     = .STRETCH,
		SwapEffect  = .FLIP_DISCARD,
		AlphaMode   = .UNSPECIFIED,
	}
	when LOW_LATENCY { desc.Flags = {.FRAME_LATENCY_WAITABLE_OBJECT} }
	// tearing presents (variable refresh) need the flag from creation on; a composition swap chain cannot tear
	r.present.tearing_ok = !transparent && check_tearing(factory)
	if r.present.tearing_ok { desc.Flags += {.ALLOW_TEARING} }
	r.swap_flags = desc.Flags
	present_reset(r)
	// translucent: through DirectComposition; where that is missing (Wine, old systems) fall back to an opaque window
	if transparent && !init_composition(r, factory, dxgi_device, hwnd, desc, size) {
		fmt.eprintln("render: DirectComposition unavailable, the window is opaque")
		r.transparent = false
	}
	if !r.transparent {
		if hr := factory->CreateSwapChainForHwnd(r.device, hwnd, &desc, nil, nil, &r.swapchain); win.FAILED(hr) {
			fmt.eprintln("render: CreateSwapChainForHwnd failed", hr)
			return false
		}
	}
	factory->MakeWindowAssociation(hwnd, {.NO_ALT_ENTER})
	when LOW_LATENCY {
		sc2: ^dxgi.ISwapChain2
		if win.SUCCEEDED(r.swapchain->QueryInterface(dxgi.ISwapChain2_UUID, (^rawptr)(&sc2))) {
			sc2->SetMaximumFrameLatency(1)
			r.latency_handle = sc2->GetFrameLatencyWaitableObject()
			sc2->Release()
		}
	}
	create_target(r)
	r.source_size = r.buffer_size
	return true
}

// Releases every GPU object and the renderer's memory (textures still alive included). The renderer can be
// initialized again afterwards.
d3d_destroy :: proc(r: ^Renderer) {
	rel :: proc(p: ^$T) { if p^ != nil { p^->Release(); p^ = nil } }
	for i in 1 ..< len(r.textures) { destroy_texture(r, Texture(i)) }
	delete(r.textures); delete(r.free_textures); delete(r.targets); delete(r.scratch)
	for &q in r.gpu_queries { for &x in q { rel(&x) } }
	profile_destroy(r)
	video_pipeline_destroy(r)
	rel(&r.xform_view); rel(&r.xform_buf); rel(&r.clip_view); rel(&r.clip_buf); rel(&r.inst_buf); rel(&r.globals)
	rel(&r.points_view); rel(&r.points_buf); rel(&r.blend_replace); rel(&r.fx_vs); rel(&r.fx_ps); rel(&r.fx_constants)
	rel(&r.sampler_border); rel(&r.frame_tex); rel(&r.grads_view); rel(&r.grads_buf); rel(&r.replay_cb)
	heaps_destroy(r)
	rel(&r.sampler); rel(&r.sampler_img); rel(&r.sampler_wrap); rel(&r.raster); rel(&r.blend)
	rel(&r.layout); rel(&r.ps); rel(&r.vs); rel(&r.rtv); rel(&r.offscreen)
	slug_destroy(r)
	rel(&r.dcomp_visual); rel(&r.dcomp_target); rel(&r.dcomp); rel(&r.swapchain)
	if r.latency_handle != nil { win.CloseHandle(r.latency_handle) }
	present_destroy(r)
	if r.ctx != nil { r.ctx->ClearState() }
	rel(&r.ctx); rel(&r.device)
	r^ = {}
}

// A renderer without a window: frames are drawn into an offscreen B8G8R8A8 (sRGB) image of `size` that
// `read_pixels` returns. For tests and image export. `warp`: the software rasterizer (deterministic, no GPU needed).
d3d_init_offscreen :: proc(r: ^Renderer, size: [2]int, warp := false, space := Blend_Space.Linear) -> bool {
	r.size = size
	r.space = space
	r.warp = warp
	if !create_device(r, warp ? .WARP : .HARDWARE) {
		if warp || !create_device(r, .WARP) { return false }
		r.warp = true
	}
	create_offscreen_target(r) or_return
	return init_pipeline(r)
}

@(private)
create_offscreen_target :: proc(r: ^Renderer) -> bool {
	r.device->CreateTexture2D(&{
		Width = u32(r.size.x), Height = u32(r.size.y), MipLevels = 1, ArraySize = 1, Format = .B8G8R8A8_TYPELESS,
		SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.RENDER_TARGET},
	}, nil, &r.offscreen)
	if r.offscreen == nil { return false }
	r.frame_tex = r.offscreen
	r.frame_tex->AddRef()
	// typeless storage: the view is chosen by the blend space (like the swap chain's), the readback copies raw bytes
	return create_offscreen_view(r)
}

@(private)
create_offscreen_view :: proc(r: ^Renderer) -> bool {
	r.frame_format = .B8G8R8A8_TYPELESS
	r.frame_view = r.space == .Srgb ? .B8G8R8A8_UNORM : .B8G8R8A8_UNORM_SRGB
	r.device->CreateRenderTargetView(r.offscreen, &{Format = r.frame_view, ViewDimension = .TEXTURE2D}, &r.rtv)
	return r.rtv != nil
}

// Changes what the frame blends in (see Blend_Space) and resets the text rendering to that space's default
// (text_rendering_default; call set_text_rendering afterwards to keep your own). Pooled targets are released (snapshots
// of the frame are read in its space). Existing RGBA textures keep the space they were stored in and are converted
// when drawn; layers keep their own. Call it between frames.
d3d_set_blend_space :: proc(r: ^Renderer, space: Blend_Space) {
	if space == r.space { return }
	previous := r.space
	r.space = space
	r.text = text_rendering_default(space)
	release_targets(r)
	r.ctx->OMSetRenderTargets(0, nil, nil)
	if r.rtv != nil { r.rtv->Release(); r.rtv = nil }
	if r.offscreen != nil {
		create_offscreen_view(r)
		return
	}
	if r.swapchain == nil { return }
	if r.frame_tex != nil { r.frame_tex->Release(); r.frame_tex = nil }
	if r.transparent {
		// a translucent window's buffers change format: linear fp16 (scRGB) or 8-bit premultiplied sRGB
		b := r.buffer_size
		if b.x <= 0 || b.y <= 0 { b = r.size }
		if hr := r.swapchain->ResizeBuffers(0, u32(max(b.x, 1)), u32(max(b.y, 1)), composition_format(space), r.swap_flags); win.FAILED(hr) {
			fmt.eprintln("render: ResizeBuffers to the format of the blend space failed", hr, "- staying in", previous)
			r.space = previous
			r.text = text_rendering_default(previous)
		}
		set_composition_color_space(r)
	}
	create_target(r)
	if r.transparent {
		r.source_size = r.buffer_size   // ResizeBuffers presents the whole buffers again
		if r.size != r.buffer_size && !set_source_size(r, r.size) { resize_buffers(r, r.size) }
	}
}

blend_space :: proc(r: ^Renderer) -> Blend_Space { return r.space }

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

// The offscreen image (init_offscreen) after the last frame: RGBA8, sRGB, `size.x * size.y * 4` bytes (whatever the
// blend space: in Linear the view encodes, in Srgb the values are stored as they are).
d3d_read_pixels :: proc(r: ^Renderer, allocator := context.allocator) -> []u8 {
	if r.offscreen == nil { return nil }
	staging: ^d3d11.ITexture2D
	r.device->CreateTexture2D(&{
		Width = u32(r.size.x), Height = u32(r.size.y), MipLevels = 1, ArraySize = 1, Format = .B8G8R8A8_TYPELESS,
		SampleDesc = {Count = 1}, Usage = .STAGING, CPUAccessFlags = {.READ},
	}, nil, &staging)
	if staging == nil { return nil }
	defer staging->Release()
	r.ctx->CopyResource(staging, r.offscreen)
	mapped: d3d11.MAPPED_SUBRESOURCE
	if win.FAILED(r.ctx->Map(staging, 0, .READ, {}, &mapped)) { return nil }
	defer r.ctx->Unmap(staging, 0)
	out := make([]u8, r.size.x * r.size.y * 4, allocator)
	for y in 0 ..< r.size.y {
		row := mem.slice_ptr((^u8)(uintptr(mapped.pData) + uintptr(y * int(mapped.RowPitch))), r.size.x * 4)
		for x in 0 ..< r.size.x {
			o := (y * r.size.x + x) * 4
			out[o], out[o + 1], out[o + 2], out[o + 3] = row[x * 4 + 2], row[x * 4 + 1], row[x * 4], row[x * 4 + 3]
		}
	}
	return out
}

@(private)
create_device :: proc(r: ^Renderer, driver: d3d11.DRIVER_TYPE) -> bool {
	feature_levels := [?]d3d11.FEATURE_LEVEL{._11_0}
	base_device: ^d3d11.IDevice
	base_ctx: ^d3d11.IDeviceContext
	// VIDEO_SUPPORT: hardware decoders (Media Foundation / DXVA) work on this device and hand their pictures to it as textures
	flags := d3d11.CREATE_DEVICE_FLAGS{.BGRA_SUPPORT, .VIDEO_SUPPORT}
	when D3D_DEBUG { flags += {.DEBUG} }
	hr := d3d11.CreateDevice(nil, driver, nil, flags, &feature_levels[0], len(feature_levels), d3d11.SDK_VERSION, &base_device, nil, &base_ctx)
	if win.FAILED(hr) && .VIDEO_SUPPORT in flags {
		// (the software rasterizer has no video support: no hardware decoding there anyway)
		flags -= {.VIDEO_SUPPORT}
		hr = d3d11.CreateDevice(nil, driver, nil, flags, &feature_levels[0], len(feature_levels), d3d11.SDK_VERSION, &base_device, nil, &base_ctx)
	}
	if win.FAILED(hr) {
		fmt.eprintln("render: CreateDevice failed", hr)
		return false
	}
	base_device->QueryInterface(d3d11.IDevice_UUID, (^rawptr)(&r.device))
	base_ctx->QueryInterface(d3d11.IDeviceContext_UUID, (^rawptr)(&r.ctx))
	base_device->Release()
	base_ctx->Release()
	return true
}

// Shaders, input layout, constant buffer and fixed states: everything after the device and the frame target.
@(private)
init_pipeline :: proc(r: ^Renderer) -> bool {
	vs_code, vs_blob := shader_code(.Rect_VS) or_return
	defer shader_code_done(vs_blob)
	ps_code, ps_blob := shader_code(.Rect_PS) or_return
	defer shader_code_done(ps_blob)
	r.device->CreateVertexShader(raw_data(vs_code), uint(len(vs_code)), nil, &r.vs)
	r.device->CreatePixelShader(raw_data(ps_code), uint(len(ps_code)), nil, &r.ps)
	if r.vs == nil || r.ps == nil {
		fmt.eprintln("render: the instanced-quad shaders were refused by the device")
		return false
	}

	r.layout = create_instance_layout(r, vs_code)
	if r.layout == nil { return false }

	r.device->CreateBuffer(&{ByteWidth = size_of(Globals), Usage = .DYNAMIC, BindFlags = {.CONSTANT_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &r.globals)
	r.device->CreateBuffer(&{ByteWidth = size_of(Replay_Constants), Usage = .DYNAMIC, BindFlags = {.CONSTANT_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &r.replay_cb)
	if r.globals == nil || r.replay_cb == nil { return false }

	bd := d3d11.BLEND_DESC{}
	bd.RenderTarget[0] = {
		BlendEnable = true,
		SrcBlend = .SRC_ALPHA, DestBlend = .INV_SRC_ALPHA, BlendOp = .ADD,
		SrcBlendAlpha = .ONE, DestBlendAlpha = .INV_SRC_ALPHA, BlendOpAlpha = .ADD,
		RenderTargetWriteMask = u8(d3d11.COLOR_WRITE_ENABLE_ALL),
	}
	r.device->CreateBlendState(&bd, &r.blend)
	r.device->CreateRasterizerState(&{FillMode = .SOLID, CullMode = .NONE, ScissorEnable = true}, &r.raster)
	r.device->CreateSamplerState(&{Filter = .MIN_MAG_MIP_LINEAR, AddressU = .CLAMP, AddressV = .CLAMP, AddressW = .CLAMP}, &r.sampler)
	r.device->CreateSamplerState(&{Filter = .MIN_MAG_MIP_LINEAR, AddressU = .CLAMP, AddressV = .CLAMP, AddressW = .CLAMP, MaxLOD = max(f32)}, &r.sampler_img)
	r.device->CreateSamplerState(&{Filter = .MIN_MAG_MIP_LINEAR, AddressU = .WRAP, AddressV = .WRAP, AddressW = .CLAMP, MaxLOD = max(f32)}, &r.sampler_wrap)

	bd.RenderTarget[0] = {BlendEnable = false, RenderTargetWriteMask = u8(d3d11.COLOR_WRITE_ENABLE_ALL)}
	r.device->CreateBlendState(&bd, &r.blend_replace)
	// filter passes and reduced layers: the shader makes the transparent border itself (sample_border: the same code runs on WebGPU)
	r.device->CreateSamplerState(&{Filter = .MIN_MAG_MIP_LINEAR, AddressU = .CLAMP, AddressV = .CLAMP, AddressW = .CLAMP}, &r.sampler_border)
	fx_vs_code, fx_vs_blob := shader_code(.Filter_VS) or_return
	defer shader_code_done(fx_vs_blob)
	fx_ps_code, fx_ps_blob := shader_code(.Filter_PS) or_return
	defer shader_code_done(fx_ps_blob)
	r.device->CreateVertexShader(raw_data(fx_vs_code), uint(len(fx_vs_code)), nil, &r.fx_vs)
	r.device->CreatePixelShader(raw_data(fx_ps_code), uint(len(fx_ps_code)), nil, &r.fx_ps)
	r.device->CreateBuffer(&{ByteWidth = size_of(Pass_Constants), Usage = .DYNAMIC, BindFlags = {.CONSTANT_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &r.fx_constants)
	if r.fx_vs == nil || r.fx_ps == nil || r.fx_constants == nil || r.blend_replace == nil || r.sampler_border == nil { return false }

	if len(r.textures) > 0 { return true }   // recover: the settings stay
	append(&r.textures, Texture_Data{})   // dummy slot 0
	r.corner_smoothing = 1
	r.blur_sigma_limit = DEFAULT_BLUR_SIGMA_LIMIT
	r.text = text_rendering_default(r.space)
	return true
}

// The input layout of Rect_Inst for the vertex shaders (rect and Slug): nine attributes, naga's semantics (LOC0..LOC8, the
// @location of the WGSL: eight float4 then the uint4 `extra`).
@(private)
create_instance_layout :: proc(r: ^Renderer, vs_code: []u8) -> ^d3d11.IInputLayout {
	elem :: proc(loc: u32, format: dxgi.FORMAT) -> d3d11.INPUT_ELEMENT_DESC {
		return {SemanticName = "LOC", SemanticIndex = loc, Format = format, InputSlot = 0, AlignedByteOffset = loc * 16,
		        InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1}
	}
	elems: [9]d3d11.INPUT_ELEMENT_DESC
	for i in 0 ..< 8 { elems[i] = elem(u32(i), .R32G32B32A32_FLOAT) }
	elems[8] = elem(8, .R32G32B32A32_UINT)
	layout: ^d3d11.IInputLayout
	if hr := r.device->CreateInputLayout(&elems[0], len(elems), raw_data(vs_code), uint(len(vs_code)), &layout); win.FAILED(hr) {
		fmt.eprintln("render: CreateInputLayout failed", hr)
		return nil
	}
	return layout
}

// The constant buffer of rect.wgsl (register b0), per target.
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

// Swap chain format of a translucent window: DWM composes scRGB (linear fp16) in linear light, and 8-bit buffers as
// premultiplied sRGB values, which is exactly what each blend space produces.
@(private)
composition_format :: proc(space: Blend_Space) -> dxgi.FORMAT {
	return space == .Srgb ? .B8G8R8A8_UNORM : .R16G16B16A16_FLOAT
}

// Tells DWM how to read a translucent window's buffers: a swap chain keeps its color space through ResizeBuffers, so an
// fp16 chain switched to 8 bits would still be read as linear (and look washed out).
@(private)
set_composition_color_space :: proc(r: ^Renderer) {
	sc3: ^dxgi.ISwapChain3
	if r.swapchain == nil || win.FAILED(r.swapchain->QueryInterface(dxgi.ISwapChain3_UUID, (^rawptr)(&sc3))) { return }
	sc3->SetColorSpace1(r.space == .Srgb ? .RGB_FULL_G22_NONE_P709 : .RGB_FULL_G10_NONE_P709)
	sc3->Release()
}

@(private)
init_composition :: proc(r: ^Renderer, factory: ^dxgi.IFactory2, dxgi_device: ^dxgi.IDevice, hwnd: win.HWND, base: dxgi.SWAP_CHAIN_DESC1, size: [2]int) -> bool {
	desc := base
	desc.Width, desc.Height = u32(max(size.x, 1)), u32(max(size.y, 1))
	desc.Scaling = .STRETCH
	desc.AlphaMode = .PREMULTIPLIED
	// Linear: scRGB (linear fp16), composed by DWM in linear light like our blending. Srgb: 8-bit, which DWM takes as
	// premultiplied sRGB values, our output in that space (a linear output there would look washed out).
	desc.Format = composition_format(r.space)
	if win.FAILED(factory->CreateSwapChainForComposition(r.device, &desc, nil, &r.swapchain)) { return false }
	set_composition_color_space(r)
	ok := win.SUCCEEDED(DCompositionCreateDevice((^win.IUnknown)(dxgi_device), IDCompositionDevice_UUID, (^rawptr)(&r.dcomp)))
	ok = ok && win.SUCCEEDED(r.dcomp->CreateTargetForHwnd(hwnd, true, &r.dcomp_target))
	ok = ok && win.SUCCEEDED(r.dcomp->CreateVisual(&r.dcomp_visual))
	ok = ok && win.SUCCEEDED(r.dcomp_visual->SetContent((^win.IUnknown)(r.swapchain)))
	ok = ok && win.SUCCEEDED(r.dcomp_target->SetRoot(r.dcomp_visual))
	ok = ok && win.SUCCEEDED(r.dcomp->Commit())
	if !ok {
		if r.dcomp_visual != nil { r.dcomp_visual->Release(); r.dcomp_visual = nil }
		if r.dcomp_target != nil { r.dcomp_target->Release(); r.dcomp_target = nil }
		if r.dcomp != nil { r.dcomp->Release(); r.dcomp = nil }
		r.swapchain->Release()
		r.swapchain = nil
	}
	return ok
}

// True when the window shows through pixels with alpha < 1 (init asked for it and the system supports it).
is_transparent :: proc(r: ^Renderer) -> bool { return r.transparent }

@(private)
compile :: proc(src: string, entry, target: cstring, name: cstring = "shader.hlsl") -> (blob: ^d3d11.IBlob, ok: bool) {
	errors: ^d3d11.IBlob
	hr := d3d_compiler.Compile(raw_data(src), uint(len(src)), name, nil, nil, entry, target, 0, 0, &blob, &errors)
	if win.FAILED(hr) {
		if errors != nil {
			fmt.eprintln("render: shader error:", string(mem.slice_ptr(cast([^]u8)errors->GetBufferPointer(), int(errors->GetBufferSize()))))
			errors->Release()
		}
		return nil, false
	}
	return blob, true
}

@(private)
create_target :: proc(r: ^Renderer) {
	backbuffer: ^d3d11.ITexture2D
	r.swapchain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&backbuffer))
	// Linear: an sRGB view over a UNORM buffer: the shader writes linear colors, the hardware encodes (and blends in
	// linear light). Srgb: a UNORM view: the shader writes sRGB values, blended as they are.
	fp16 := r.transparent && r.space == .Linear
	r.frame_format = fp16 ? .R16G16B16A16_FLOAT : .B8G8R8A8_UNORM
	r.frame_view = fp16 ? .R16G16B16A16_FLOAT : (r.space == .Srgb ? .B8G8R8A8_UNORM : .B8G8R8A8_UNORM_SRGB)
	r.device->CreateRenderTargetView(backbuffer, &{Format = r.frame_view, ViewDimension = .TEXTURE2D}, &r.rtv)
	// kept for snapshots (backdrop filters, blend modes); with flip swap chains buffer 0 is always the one drawn
	r.frame_tex = backbuffer
	// the buffers' own size (resize may keep them larger than what is shown)
	if backbuffer != nil {
		desc: d3d11.TEXTURE2D_DESC
		backbuffer->GetDesc(&desc)
		r.buffer_size = {int(desc.Width), int(desc.Height)}
	}
}

// The window's client area is now `size`. ResizeBuffers is costly (1.6 to 3.5 ms a call: DXGI enumerates the outputs
// each time), so with a resize slack (set_resize_slack) the buffers are allocated with room to grow and a size that
// fits in them is only a new source region of the swap chain (IDXGISwapChain2::SetSourceSize, a few microseconds):
// a window dragged to a new size reallocates once per `slack` pixels crossed instead of at every step. The buffers are
// made smaller again once they hold more than twice the pixels shown. Without SetSourceSize (or with a slack of 0)
// the buffers follow the size exactly.
d3d_resize :: proc(r: ^Renderer, size: [2]int) {
	if size.x <= 0 || size.y <= 0 || size == r.size || r.swapchain == nil { return }
	r.size = size
	slack := resize_slack(r)
	b := r.buffer_size
	fits := size.x <= b.x && size.y <= b.y && b.x * b.y <= 2 * size.x * size.y
	if slack > 0 && fits && set_source_size(r, size) { return }
	want := size
	if slack > 0 { want = {(size.x + slack - 1) / slack * slack, (size.y + slack - 1) / slack * slack} }
	resize_buffers(r, want)
	if want != size && !set_source_size(r, size) {
		resize_buffers(r, size)   // no source region here: buffers of the exact size, as without a slack
		r.resize_slack = -1
	}
}

DEFAULT_RESIZE_SLACK :: 256

// Room the swap chain's buffers keep to grow during a resize, in pixels per axis (see resize; 0 = buffers of the exact
// size). Default DEFAULT_RESIZE_SLACK. Takes effect at the next resize.
set_resize_slack :: proc(r: ^Renderer, px: int) { r.resize_slack = px > 0 ? px : -1 }

@(private)
resize_slack :: proc(r: ^Renderer) -> int { return r.resize_slack == 0 ? DEFAULT_RESIZE_SLACK : max(r.resize_slack, 0) }

// The size of the swap chain's buffers (at least the presented size; see resize).
buffer_size :: proc(r: ^Renderer) -> [2]int { return r.buffer_size }

@(private)
resize_buffers :: proc(r: ^Renderer, size: [2]int) {
	r.ctx->OMSetRenderTargets(0, nil, nil)
	if r.rtv != nil { r.rtv->Release(); r.rtv = nil }
	if r.frame_tex != nil { r.frame_tex->Release(); r.frame_tex = nil }
	r.swapchain->ResizeBuffers(0, u32(size.x), u32(size.y), .UNKNOWN, r.swap_flags)   // flags must match creation
	create_target(r)
	r.source_size = r.buffer_size   // ResizeBuffers presents the whole buffers again
}

// Presents only the region [0, size) of the buffers. false: not available (the buffers must be the size shown).
@(private)
set_source_size :: proc(r: ^Renderer, size: [2]int) -> bool {
	if size == r.source_size { return true }
	if size.x > r.buffer_size.x || size.y > r.buffer_size.y { return false }
	sc2: ^dxgi.ISwapChain2
	if win.FAILED(r.swapchain->QueryInterface(dxgi.ISwapChain2_UUID, (^rawptr)(&sc2))) || sc2 == nil { return false }
	defer sc2->Release()
	if win.FAILED(sc2->SetSourceSize(u32(size.x), u32(size.y))) { return false }
	r.source_size = size
	return true
}

// A single-channel (coverage) texture, used for the glyph atlas.
d3d_create_texture_r8 :: proc(r: ^Renderer, size: int) -> Texture {
	td := Texture_Data{size = size, w = size, h = size, kind = .R8}
	if !texture_objects(r, &td) { return 0 }
	return add_texture(r, td)
}

// The GPU texture and view of an R8 or RGBA texture described by `td` (kind, size, mips, space), contents zeroed
// (D3D leaves DEFAULT textures undefined). Used by the create procs and to recreate textures after a device loss.
@(private)
texture_objects :: proc(r: ^Renderer, td: ^Texture_Data) -> bool {
	desc := d3d11.TEXTURE2D_DESC{
		Width = u32(td.w), Height = u32(td.h), MipLevels = 1, ArraySize = 1, Format = .R8_UNORM,
		SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.SHADER_RESOURCE},
	}
	texel := 1
	if td.kind == .RGBA {
		desc.Format = td.space == .Srgb ? .R8G8B8A8_UNORM : .R8G8B8A8_UNORM_SRGB
		texel = 4
		if td.mips { desc.MipLevels = 0; desc.BindFlags += {.RENDER_TARGET}; desc.MiscFlags = {.GENERATE_MIPS} }
	}
	#partial switch td.kind {
	case .Slug_Curves: desc.Format, texel = .R16G16B16A16_FLOAT, 8
	case .Slug_Bands: desc.Format, texel = .R16G16_UINT, 4
	}
	if win.FAILED(r.device->CreateTexture2D(&desc, nil, &td.tex)) { td.tex = nil; return false }
	if win.FAILED(r.device->CreateShaderResourceView(td.tex, nil, &td.view)) { td.tex->Release(); td.tex, td.view = nil, nil; return false }
	zero := make([]u8, td.w * texel)
	defer delete(zero)
	for y in 0 ..< td.h {
		box := d3d11.BOX{left = 0, top = u32(y), front = 0, right = u32(td.w), bottom = u32(y + 1), back = 1}
		r.ctx->UpdateSubresource(td.tex, 0, &box, raw_data(zero), u32(td.w * texel), 0)
	}
	td.mips_dirty = td.mips
	return true
}

d3d_update_texture_r8 :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, pitch: int) {
	td := r.textures[int(t)]
	box := d3d11.BOX{left = u32(x), top = u32(y), front = 0, right = u32(x + w), bottom = u32(y + h), back = 1}
	r.ctx->UpdateSubresource(td.tex, 0, &box, raw_data(pixels), u32(pitch), 0)
}

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

// Largest width / height `create_texture_rgba` accepts (from the device's feature level).
d3d_max_texture_size :: proc(r: ^Renderer) -> int {
	#partial switch r.device->GetFeatureLevel() {
	case ._9_1, ._9_2: return 2048
	case ._9_3: return 4096
	case ._10_0, ._10_1: return 8192
	}
	return d3d11.REQ_TEXTURE2D_U_OR_V_DIMENSION
}

// Size in texels (0, 0 for an invalid or destroyed texture).
texture_size :: proc(r: ^Renderer, t: Texture) -> [2]int {
	if int(t) <= 0 || int(t) >= len(r.textures) { return {} }
	td := r.textures[int(t)]
	return {td.w, td.h}
}

// A color image for `draw.image`. Contents start transparent; fill it with `update_texture_rgba`.
// `mips`: allocate a full mip chain, regenerated (GenerateMips) before the next frame that follows an update, so
// images drawn smaller than their size stay smooth instead of shimmering. Returns 0 when the size is out of range or
// the device refuses the texture.
//
// The texture is stored in the renderer's blend space at creation (texture_space), always with PREMULTIPLIED colors
// (see update_texture_rgba), so filtering never darkens the edges of transparent areas:
// - Linear: R8G8B8A8_UNORM_SRGB holding colors premultiplied in linear light: the sampler decodes sRGB to linear
//   before filtering, so bilinear filtering and mip averaging happen in linear light.
// - Srgb: R8G8B8A8_UNORM holding sRGB values premultiplied as they are: filtering and mips average sRGB values, as
//   browsers do.
// Drawn into a target of the other space, texels are converted by the shader.
d3d_create_texture_rgba :: proc(r: ^Renderer, w, h: int, mips := true) -> Texture {
	limit := max_texture_size(r)
	if w <= 0 || h <= 0 || w > limit || h > limit { return 0 }
	td := Texture_Data{w = w, h = h, size = max(w, h), kind = .RGBA, space = r.space}
	format: dxgi.FORMAT = td.space == .Srgb ? .R8G8B8A8_UNORM : .R8G8B8A8_UNORM_SRGB
	support: u32
	r.device->CheckFormatSupport(format, &support)
	td.mips = mips && support & u32(d3d11.FORMAT_SUPPORT.MIP_AUTOGEN) != 0 && (w > 1 || h > 1)
	if !texture_objects(r, &td) { return 0 }   // starts transparent
	return add_texture(r, td)
}

// Uploads a w x h block at (x, y). `pixels`: RGBA8, sRGB encoded, NOT premultiplied (what PNG / JPEG decoders and
// the web produce); `stride` = bytes per row (0: w * 4). Converted on the CPU to premultiplied alpha in the texture's
// space: in linear light, re-encoded as sRGB for storage (Linear), or on the sRGB values (Srgb). Opaque pixels go
// through unchanged.
d3d_update_texture_rgba :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, stride := 0) {
	if int(t) <= 0 || int(t) >= len(r.textures) { return }
	td := &r.textures[int(t)]
	if td.kind != .RGBA || w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > td.w || y + h > td.h { return }
	pitch := stride > 0 ? stride : w * 4
	if len(pixels) < pitch * (h - 1) + w * 4 { return }
	premultiply_upload(r, td, w, h, pixels, pitch)
	box := d3d11.BOX{left = u32(x), top = u32(y), front = 0, right = u32(x + w), bottom = u32(y + h), back = 1}
	r.ctx->UpdateSubresource(td.tex, 0, &box, raw_data(r.scratch), u32(w * 4), 0)
	if td.mips { td.mips_dirty = true }
}

// Converts a w x h block of straight sRGB RGBA8 to the texture's storage (see create_texture_rgba) into r.scratch.
@(private)
premultiply_upload :: proc(r: ^Renderer, td: ^Texture_Data, w, h: int, pixels: []u8, pitch: int) {
	srgb_tables_init()
	runtime.resize(&r.scratch, w * h * 4)
	for row in 0 ..< h {
		src := pixels[row * pitch:][:w * 4]
		dst := r.scratch[row * w * 4:][:w * 4]
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
}

// How an RGBA texture stores its texels (the renderer's blend space when it was created).
texture_space :: proc(r: ^Renderer, t: Texture) -> Blend_Space {
	if int(t) <= 0 || int(t) >= len(r.textures) { return .Linear }
	return r.textures[int(t)].space
}

// Frees the GPU texture; the handle may be reused by a later create. Drawing a destroyed texture draws nothing.
d3d_destroy_texture :: proc(r: ^Renderer, t: Texture) {
	if int(t) <= 0 || int(t) >= len(r.textures) { return }
	td := &r.textures[int(t)]
	if td.kind == .None { return }
	if td.rtv != nil { td.rtv->Release() }
	if td.view != nil { td.view->Release() }
	if td.tex != nil { td.tex->Release() }
	td^ = {}
	append(&r.free_textures, t)
}

////////////////////////////////
// Layer targets

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

// Bytes per texel of a texture (render targets and images; 0 for none).
texture_bpp :: proc(r: ^Renderer, t: Texture) -> int {
	if int(t) <= 0 || int(t) >= len(r.textures) { return 0 }
	switch r.textures[int(t)].kind {
	case .None: return 0
	case .R8: return 1
	case .RGBA, .Snapshot, .Slug_Bands: return 4
	case .Target: return r.textures[int(t)].unorm ? 4 : 8
	case .Slug_Curves: return 8
	}
	return 0
}

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

// Corner shape for every rounded rect: 0 = circular arcs, 1 = squircle (superellipse corners, continuous curvature).
set_corner_smoothing :: proc(r: ^Renderer, smoothing: f32) { r.corner_smoothing = clamp(smoothing, 0, 1) }

// Blocks until the swap chain can take a new frame (returns at once when nothing is queued). Call it BEFORE
// polling input and building the UI: then the frame you build is the next one shown.
// (platform.wait_handle on frame_waitable does the same while taking the window's input as it arrives.)
d3d_wait_for_frame :: proc(r: ^Renderer, timeout_ms := 100) -> bool {
	if r.latency_handle == nil { return true }
	return win.WaitForSingleObjectEx(r.latency_handle, u32(max(timeout_ms, 0)), true) == win.WAIT_OBJECT_0
}

// Call right after reading input: the next present is credited with this time (Displayed_Frame.input), unless
// set_frame_input gave an earlier one (the time the input arrived).
mark_input :: proc(r: ^Renderer) {
	if r.present.input._nsec == 0 { r.present.input = time.tick_now() }
}

// Clears the frame to `clear`: linear, premultiplied (the same thing for an opaque color), whatever the blend space.
d3d_frame_begin :: proc(r: ^Renderer, clear: [4]f32) {
	if r.lost && !recover(r) { return }
	c := clear
	if r.space == .Srgb && c.a > 0 {
		for k in 0 ..< 3 { c[k] = linear_to_srgb(c[k] / c.a) * c.a }
	}
	r.ctx->ClearRenderTargetView(r.rtv, &c)
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
		case .Target, .Snapshot: m.targets += td.w * td.h * (td.kind == .Snapshot || td.unorm ? 4 : 8)
		case .Slug_Curves: m.slug += td.w * td.h * 8
		case .Slug_Bands: m.slug += td.w * td.h * 4
		}
	}
	return
}

@(private)
gpu_timing_begin :: proc(r: ^Renderer) {
	q := &r.gpu_queries[r.gpu_frame % GPU_QUERY_FRAMES]
	if q[0] == nil {
		r.device->CreateQuery(&{Query = .TIMESTAMP_DISJOINT}, &q[0])
		r.device->CreateQuery(&{Query = .TIMESTAMP}, &q[1])
		r.device->CreateQuery(&{Query = .TIMESTAMP}, &q[2])
	} else if r.gpu_frame >= GPU_QUERY_FRAMES {
		// this slot was issued GPU_QUERY_FRAMES frames ago: its results are (almost always) ready
		dj: d3d11.QUERY_DATA_TIMESTAMP_DISJOINT
		t0, t1: u64
		if r.ctx->GetData((^d3d11.IAsynchronous)(q[0]), &dj, size_of(dj), 0) == 0 &&
		   r.ctx->GetData((^d3d11.IAsynchronous)(q[1]), &t0, size_of(t0), 0) == 0 &&
		   r.ctx->GetData((^d3d11.IAsynchronous)(q[2]), &t1, size_of(t1), 0) == 0 && !bool(dj.Disjoint) && dj.Frequency > 0 {
			r.gpu_last_ms = f32(f64(t1 - t0) * 1000 / f64(dj.Frequency))
			r.gpu_last_frame = r.gpu_frame - GPU_QUERY_FRAMES + 1
			profile_collect(r, r.gpu_frame % GPU_QUERY_FRAMES, r.gpu_frame - GPU_QUERY_FRAMES, t0, dj.Frequency, r.gpu_last_ms)
		}
	}
	r.ctx->Begin((^d3d11.IAsynchronous)(q[0]))
	r.ctx->End((^d3d11.IAsynchronous)(q[1]))
	profile_begin(r, r.gpu_frame % GPU_QUERY_FRAMES)
}

@(private)
gpu_timing_end :: proc(r: ^Renderer) {
	profile_end(r)
	q := &r.gpu_queries[r.gpu_frame % GPU_QUERY_FRAMES]
	r.ctx->End((^d3d11.IAsynchronous)(q[2]))
	r.ctx->End((^d3d11.IAsynchronous)(q[0]))
	r.gpu_frame += 1
}

@(private)
texture_view :: proc(r: ^Renderer, t: Texture) -> ^d3d11.IShaderResourceView {
	return int(t) > 0 && int(t) < len(r.textures) ? r.textures[int(t)].view : nil
}

// A raw view of `bytes` bytes of a buffer made with BUFFER_ALLOW_RAW_VIEWS: what a WGSL `var<storage, read>` array becomes in
// naga's HLSL (a ByteAddressBuffer, read with Load / Load2 / Load4).
@(private)
raw_buffer_view :: proc(r: ^Renderer, buf: ^d3d11.IBuffer, bytes: int) -> ^d3d11.IShaderResourceView {
	if buf == nil { return nil }
	srv := d3d11.SHADER_RESOURCE_VIEW_DESC{Format = .R32_TYPELESS, ViewDimension = .BUFFEREX}
	srv.BufferEx = {FirstElement = 0, NumElements = u32(bytes / 4), Flags = {.RAW}}
	view: ^d3d11.IShaderResourceView
	r.device->CreateShaderResourceView(buf, &srv, &view)
	return view
}

// (Re)creates a dynamic raw buffer (the tables of the frame) and its view when `n` elements do not fit, then uploads `data`.
@(private)
upload_structured :: proc(r: ^Renderer, buf: ^^d3d11.IBuffer, view: ^^d3d11.IShaderResourceView, cap: ^int, data: rawptr, n, stride: int) {
	if buf^ == nil || n > cap^ {
		if view^ != nil { view^->Release(); view^ = nil }
		if buf^ != nil { buf^->Release(); buf^ = nil }
		cap^ = max(n, cap^ * 2, 64)
		r.device->CreateBuffer(&{ByteWidth = u32(cap^ * stride), Usage = .DYNAMIC, BindFlags = {.SHADER_RESOURCE},
			CPUAccessFlags = {.WRITE}, MiscFlags = {.BUFFER_ALLOW_RAW_VIEWS}}, nil, buf)
		view^ = raw_buffer_view(r, buf^, cap^ * stride)
	}
	if n == 0 { return }
	mapped: d3d11.MAPPED_SUBRESOURCE
	r.ctx->Map(buf^, 0, .WRITE_DISCARD, {}, &mapped)
	mem.copy(mapped.pData, data, n * stride)
	r.ctx->Unmap(buf^, 0)
}

// Presents the frame: `vsync` false presents at once (with tearing where supported) whatever set_present_mode says.
d3d_frame_end :: proc(r: ^Renderer, vsync := true) {
	if r.swapchain == nil { r.ctx->Flush(); return }   // offscreen
	if hr := present_frame(r, vsync); is_device_loss(hr) || is_device_loss(r.device->GetDeviceRemovedReason()) {
		r.lost = true
	}
}
