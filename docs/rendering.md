# Rendering backends (`render` package)

`render` draws the toolkit's frames on the GPU. Most things are instanced quads of one shader (`rect.wgsl`); Slug text, filters,
mips and video have shaders of their own. It has two backends, chosen at build time:

| Backend | `TOOLKIT_RENDER` | Systems | Files |
|---|---|---|---|
| Direct3D 11 | `d3d11` (default on Windows) | Windows | `render_d3d.odin`, `frame.odin`, `canvas.odin`, `slug_d3d.odin`, `video.odin`, `app_shader_d3d.odin`, `shaders_d3d.odin`, `damage_d3d.odin`, `dcomp.odin` |
| WebGPU (wgpu-native) | `wgpu` (forced on every non-Windows target) | Windows, Linux | `wgpu_*.odin`, `damage_wgpu.odin` |

On a non-Windows target `TOOLKIT_RENDER` is ignored and the WebGPU backend is the only one compiled: the Direct3D files
are built behind `when !USE_WGPU` (and `#+build windows`), so they contribute nothing to a Linux build.

## The neutral public API

A program never names Direct3D, DXGI or Win32 to the renderer. It opens the renderer on a window's **native handles**,
which the platform package fills:

```odin
import "gt:platform"
import "gt:render"

w := platform.open_window("App", {1280, 800})
r: render.Renderer
render.init_window(&r, w, w.size)                      // or:
render.init(&r, platform.native_surface_handles(w), w.size, transparent = false, space = .Linear)
```

`platform.Surface_Handles` is a neutral struct the renderer reads: on Windows the `HWND` (and module handle), on Linux
the Wayland `wl_display` + `wl_surface` or the XCB connection + window id (`platform.Surface_Backend` says which). An
offscreen renderer has no window:

```odin
render.init_offscreen(&r, {w, h}, warp = true, space = .Srgb)   // tests, image export; WARP on Direct3D
```

**When init fails.** `init`, `init_window` and `init_offscreen` return false and keep why in the renderer; the rest of it
is released. `render.init_failure(&r)` gives an `Init_Error` and the driver's words; `render.init_failure_text(&r, allocator)`
gives the sentence for a person:

```odin
if !render.init_window(&r, w, w.size) {
	fmt.eprintfln("myapp: %s", render.init_failure_text(&r, context.temp_allocator))
	// no graphics device this program can draw with (Vulkan): vulkan drivers/libraries could not be loaded.
	// Install your system's Vulkan driver (the package mesa-vulkan-drivers on Debian and Ubuntu).
	return 1
}
```

| `Init_Error` | |
|---|---|
| `No_Driver` | the graphics API found no device: no driver, one the program cannot load, a virtual machine without one |
| `No_Window` | a device exists but cannot draw into this window |
| `Failed` | the device, its swap chain or its pipelines failed after the driver answered |

`render.graphics_api()` names the API ("Vulkan", "Direct3D 12", "Direct3D 11", "OpenGL" when forced). A machine without
a driver never ends the process: on WebGPU the adapter is asked for before the window's surface is made, because
wgpu-native aborts the process when it makes a surface on an instance with no backend. On Direct3D 11 a window falls back
to WARP, the software rasterizer, when no hardware device can be made. Why: [src/md/infrastructure/no-graphics.md](../src/md/infrastructure/no-graphics.md).
`host.host_open` reports it by itself (getting-started.md).

**OpenGL on Linux.** When Vulkan gives no adapter, the renderer asks wgpu's GL backend for one (EGL on the window's
Wayland or X11 connection; EGL surfaceless offscreen), and draws the same frames with it. It writes one line on standard
error: `render: wgpu: Vulkan gives no adapter (...): drawing with OpenGL`. A GL device that lacks what the renderer
needs (storage buffers in vertex shaders, half-float targets, the limits of its bind groups, a GLSL version whose shaders
can read storage buffers: the renderer's pipelines are made at start on GL to find out) is refused, and init fails with
`No_Driver` and both reasons. Vulkan is never left for GL when it gives an adapter. `TOOLKIT_WGPU_BACKEND=gl` in the
environment forces GL (read once per process), for a test or a machine whose Vulkan driver misbehaves. On GL the window
presents at the display's rate only (FIFO), opaque, and every frame is composed into the kept target and drawn to the
surface (a GL surface cannot be copied from). `adapter_info(&r).api` is "OpenGL" for a desktop context (what Mesa gives)
or "OpenGL ES" for an ES one.

GLSL samples a texture through one sampler only (a `sampler2D` is both), and naga refuses a shader that samples one texture
through two. The renderer's own WGSL samples one texture through two samplers in one place: an image clamps, or repeats
for `draw.image_tiled`. On GL the modules that hold `rect.wgsl` get a variant, made by text replacement when the module is
compiled, where `image` has one sampler of its own beside it in group 1. That sampler is chosen per batch: repeating for
tiled images, clamping otherwise. `render.image_wrap_splits_batches(&r)` is true there, and `gt:draw` then starts a new
batch where a draw of the same texture changes from clamped to tiled or back (`Batch.image_wrap`). Elsewhere it is false,
and batches and shaders are what they were. An application shader (`draw.app_shader`) that samples one of its textures
through two samplers does not compile on GL: its draws are skipped there, and the process goes on.

The device can be made before the window exists, on a thread of its own: the first device of a process loads the graphics
driver, the longest step of a renderer's start. The init of the same kind (hardware, or WARP with `warp = true`) takes it,
waiting for the thread if it has not finished, and makes only the swap chain or the offscreen target:

```odin
render.preload_device()                 // first thing: Not_Started -> Creating -> Ready (or Failed)
// ... the window, the program's own start ...
render.init_window(&r, w, w.size)       // takes it; render.device_preload_state() is Not_Started again
```

A program whose loop sleeps until an event (one living in the notification area, its windows opened later) passes
`done`: `render.preload_device(done = wake, user = app)` calls it on the thread once the device is Ready or Failed, and
the loop opens its window then, hidden, so that showing it later costs no driver load.

On WebGPU the thread also makes the shaders, then starts the two pipelines of a window's first frame (its rectangles and
its text) on two threads of their own, in the frame format that window will have: `preload_device(transparent, space)`
says which window (by default a host's: transparent, linear light). The device is ready without waiting for them; the
first frame waits for them only if it is of their format, and a frame of another format never does. Where compiles run
one at a time (Windows) they are not made: they would queue in front of the window's own. `host.host_open` asks for the device itself before it opens its first window (the device, the
window and the font are then made side by side); a program that asked earlier keeps its device. Measured on lavapipe (a
small window, `-o:speed`, Xvfb): the first frame shown 592 ms after the process started before, 205 ms after
([src/md/infrastructure/fast-start.md](../src/md/infrastructure/fast-start.md)).

A device of the other kind, or one that failed, is released and init makes its own as before; `render.release_preloaded_device`
lets an unused one go. On wgpu the adapter is chosen without a surface; init makes the window's surface on its instance and
makes its own device when that adapter cannot present to it.

Second windows (the developer tools, a detached panel) use the same neutral handles:

```odin
render.surface_init(&r, &surface, platform.native_surface_handles(second_window), size, transparent, fixed_size, under_children)
render.surface_use(&r, &surface)   // the renderer now draws to the second window; call again to go back
render.surface_adopt(&r, &surface) // for good: the renderer's own window is released, the first window may close
```

`host.host_close` of the first window calls `surface_adopt` with another open window's surface: that window becomes
`Shared.main`, paced, and the renderer goes on. With no other window (or a headless first window), it ends what is
shared, as before.

`render.surface_drop(&r)`: the window of the current surface leaves the screen (`platform.hide_window`): the wgpu surface
and its swap chain go before the window's native surface does (Wayland destroys it); frames are skipped until
`render.surface_remake(&r, platform.native_surface_handles(win))` makes one on the window's handles again, configured at the
next frame. A Direct3D swap chain survives a hide (both do nothing). `host.host_hide` calls the first, `host_frame` the
second when `Window.shown_again` changed.

Everything else — `frame_begin` / `frame_submit` / `frame_end`, textures, pooled targets, capture
(`src/render/capture.odin`), the blend space, `set_max_frame_latency` (it returns false on wgpu), resize, DPI — is the same call on every
system; each dispatches to its backend behind `when USE_WGPU`.

`render.adapter_info(&r)` says what draws the frames, for a report of slowness: the adapter's `name`, the graphics `api`
("Direct3D 11", "Vulkan", "D3D12", "OpenGL", "OpenGL ES"), and `software`, true for a software rasterizer (WARP on Windows: DXGI's vendor 0x1414 and device
0x8C; llvmpipe and the like on WebGPU: a CPU adapter). It waits on nothing: WebGPU's names were read when the device was
made, Direct3D's come from the device's adapter object. The settings' Diagnostics page shows it ([prefs_page.md](prefs_page.md)).

## Staged upload

A large picture's upload (its premultiplication, the copy the driver makes, its mips) took one frame of the interface's
thread: a 186 MB picture held it 84 to 140 ms on the software device. `render.Upload` spreads it over frames, a band of
rows (`UPLOAD_BAND_BYTES`, 1 MiB) at a time, as many bands as a frame's budget holds (`UPLOAD_BUDGET_DEFAULT`, 2 ms),
one at least; the mip chain is made once, after the last band. The same picture then takes 15 to 19 frames of at most
2.7 ms each. `gt:pictures` does it for every picture of 16 MiB and more ([pictures.md](pictures.md)).

```odin
u, ok := render.upload_begin(r, pixels, w, h)       // the texture made, nothing written; pixels stay the caller's
// each frame, on the interface's thread:
if render.upload_step(r, &u) { ready(u.texture) }   // done: drawable (its mips come before its first draw)
render.upload_cancel(r, &u)                          // given up: the texture destroyed
```

The texture must not be drawn before `upload_step` says done: rows past `u.row` are undefined (Direct3D) or zero
(WebGPU). A device recovered during the upload (`device_generation` changed: the texture came back empty) starts its
bands again from the top at the next step. What each backend allows off the interface's thread, and why the toolkit spreads instead:
[src/md/features/staged-upload.md](../src/md/features/staged-upload.md).

## A frame of any size

A frame holds as many instances as the program draws. The renderer uploads them in pages, each under the device's
largest buffer (WebGPU's `maxBufferSize`, 256 MiB by default; 128 MiB on Direct3D 11), and cuts a draw where a page ends.
The tables an instance indexes (transforms, clips, points, gradients) are bound whole: past the device's limit for a
binding (`maxStorageBufferBindingSize`, 128 MiB by default) what is past it is not drawn, and the renderer says so once on
standard error. A retained heap that would pass its limit refuses the picture. An error in a frame's commands loses that
frame, never the process. `gt:draw` makes no instance of a rectangle or an image wholly outside the clip ([draw.md](draw.md),
"Clips"). Why: [src/md/infrastructure/frame-limits.md](../src/md/infrastructure/frame-limits.md).

## What differs between the backends

- **Present pacing.** Direct3D uses a DXGI waitable swap chain (a frame-latency object) and DWM timing for the frame
  statistics (shown / missed refreshes). wgpu on Linux has no frame-latency object: the present mode paces frames at
  the vblank, and `render.wait_for_frame` just acquires the next surface texture. The statistics come from the
  display server (Wayland's `wp_presentation`, X11's Present: [platform.md](platform.md), "Vblank timing"); without its
  answers they stay off. Tearing (`set_present_mode`) maps to wgpu's `Immediate` where the surface offers it. Both backends take the decision from `render.present_call(mode, tearing_ok, interval, vsync)`: the sync interval (0: at once), the tearing flag (only with no wait, only where the system and the swap chain allow it) and the mode the frame is presented in; `src/render/present_test.odin` checks it as data.
- **Translucency.** A translucent window (`transparent`) goes through DirectComposition on Windows (premultiplied
  alpha). On Linux the compositor blends the alpha surface directly — there is no extra effect to turn on. The frame's
  clear decides whether the alpha is read: a frame cleared with an alpha of 1 (`render.frame_begin`, an opaque theme's
  background) is presented with its alpha ignored (`DXGI_ALPHA_MODE_IGNORE`, wgpu's `.Opaque` where the surface offers
  it), so nothing behind the window can show through it; a clear of alpha < 1 (a translucent theme, an overlay) keeps
  premultiplied alpha. The renderer changes mode by itself when the clear does (a theme switch): nothing to call.
  See [src/md/infrastructure/window-alpha.md](../src/md/infrastructure/window-alpha.md).
- **The 2D canvas** (`canvas.odin`) is Direct3D only for now; `render.canvas_supported` reports `false` on the wgpu
  backend and the canvas procedures are no-ops there.
- **Device loss / recovery** exists on both (`render.recover`); on Linux it recreates the wgpu device and surface from
  the stored `Surface_Handles`.

## Adding another backend

A new backend implements the `when USE_WGPU` / `when !USE_WGPU` set that `api.odin` dispatches
(`<prefix>_init`, `_init_offscreen`, `_set_blend_space`, `_frame_begin` / `_submit` / `_end`, the texture and heap
procedures, `_recover`). The shared types and the backend-agnostic procedures in `render.odin`, `filter.odin`,
`damage.odin`, `present.odin`, `capture.odin` do not change.
