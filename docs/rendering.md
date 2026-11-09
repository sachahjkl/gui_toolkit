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

The device can be made before the window exists, on a thread of its own: the first device of a process loads the graphics
driver, the longest step of a renderer's start. The init of the same kind (hardware, or WARP with `warp = true`) takes it,
waiting for the thread if it has not finished, and makes only the swap chain or the offscreen target:

```odin
render.preload_device()                 // first thing: Not_Started -> Creating -> Ready (or Failed)
// ... the window, the program's own start ...
render.init_window(&r, w, w.size)       // takes it; render.device_preload_state() is Not_Started again
```

A device of the other kind, or one that failed, is released and init makes its own as before; `render.release_preloaded_device`
lets an unused one go. On wgpu the adapter is chosen without a surface; init makes the window's surface on its instance and
makes its own device when that adapter cannot present to it.

Second windows (the developer tools, a detached panel) use the same neutral handles:

```odin
render.surface_init(&r, &surface, platform.native_surface_handles(second_window), size, transparent, fixed_size, under_children)
render.surface_use(&r, &surface)   // the renderer now draws to the second window; call again to go back
```

`render.surface_drop(&r)`: the window of the current surface leaves the screen (`platform.hide_window`): the wgpu surface
and its swap chain go before the window's native surface does (Wayland destroys it); frames are skipped until
`render.surface_remake(&r, platform.native_surface_handles(win))` makes one on the window's handles again, configured at the
next frame. A Direct3D swap chain survives a hide (both do nothing). `host.host_hide` calls the first, `host_frame` the
second when `Window.shown_again` changed.

Everything else — `frame_begin` / `frame_submit` / `frame_end`, textures, pooled targets, capture
(`src/render/capture.odin`), the blend space, `set_max_frame_latency` (it returns false on wgpu), resize, DPI — is the same call on every
system; each dispatches to its backend behind `when USE_WGPU`.

## What differs between the backends

- **Present pacing.** Direct3D uses a DXGI waitable swap chain (a frame-latency object) and DWM timing for the frame
  statistics (shown / missed refreshes). wgpu on Linux has neither: the FIFO present mode paces frames at the vblank,
  `render.wait_for_frame` just acquires the next surface texture, and the per-frame statistics stay off. Tearing (`set_present_mode`) maps to wgpu's `Immediate` where the surface offers it. Both backends take the decision from `render.present_call(mode, tearing_ok, interval, vsync)`: the sync interval (0: at once), the tearing flag (only with no wait, only where the system and the swap chain allow it) and the mode the frame is presented in; `src/render/present_test.odin` checks it as data.
- **Translucency.** A translucent window (`transparent`) goes through DirectComposition on Windows (premultiplied
  alpha). On Linux the compositor blends the alpha surface directly — there is no extra effect to turn on.
- **The 2D canvas** (`canvas.odin`) is Direct3D only for now; `render.canvas_supported` reports `false` on the wgpu
  backend and the canvas procedures are no-ops there.
- **Device loss / recovery** exists on both (`render.recover`); on Linux it recreates the wgpu device and surface from
  the stored `Surface_Handles`.

## Adding another backend

A new backend implements the `when USE_WGPU` / `when !USE_WGPU` set that `api.odin` dispatches
(`<prefix>_init`, `_init_offscreen`, `_set_blend_space`, `_frame_begin` / `_submit` / `_end`, the texture and heap
procedures, `_recover`). The shared types and the backend-agnostic procedures in `render.odin`, `filter.odin`,
`damage.odin`, `present.odin`, `capture.odin` do not change.
