# A machine with no graphics driver

A program started where its graphics API has no device (no Vulkan driver, a loader the program cannot reach, a virtual
machine, a broken driver) ends with a sentence for the person and the exit code the program chose. It never aborts.

## What aborted

wgpu-native ends the process on some errors: `handle_error_fatal` in its `lib.rs` is a Rust `panic!`, and a panic cannot
unwind through the C ABI, so the process aborts (SIGABRT, and `gt:crash` wrote a crash report). `wgpuInstanceCreateSurface`
is one of them: when the instance has no backend (wgpu-hal could not load the Vulkan loader or its driver), it fails with
"Failed to create surface for any enabled backend: {}". The renderer made the window's surface before it asked for an
adapter, so a machine with no driver never got as far as the adapter request, which fails cleanly.

The error callbacks do not help: `handle_error_fatal` reads none of them. The only defence is never to make the calls
that panic in a state where they fail.

## The rule

A surface is made only on an instance that has given an adapter. `wgpu_make_surface` returns nil on an instance without
one, whatever the caller.

`wgpu_create_device_here` therefore asks for the adapter first, without a surface (as `preload_device` already did), then
makes the window's surface and checks that the adapter can present to it (`wgpu_surface_fits`). Only when it cannot is an
adapter asked for again, with the surface. On one GPU (the common case) this costs nothing: one adapter request, as before.

Refused: counting the adapters before the surface (`wgpuInstanceEnumerateAdapters`). It costs 1 to 15 ms at each start
on a machine with a driver, to detect a machine without one.

## What the renderer reports

`init`, `init_window` and `init_offscreen` return false and keep why in `Renderer.failure` (`render.init_failure`):

- `No_Driver`: the graphics API found no device. The detail is wgpu's own clause for the backend ("vulkan
  drivers/libraries could not be loaded"), taken from the adapter request's message (`wgpu_failure_reason`).
- `No_Window`: a device exists but cannot draw into this window.
- `Failed`: the device, its swap chain or its pipelines failed after the driver answered.

A failed init releases what it made, and keeps only the failure. `init_failure_text` writes the sentence for a person: what
is missing, the driver's words, and what to install. The hint depends on the system: on Linux, the Vulkan driver (the
package `mesa-vulkan-drivers` on Debian and Ubuntu); on Windows, the graphics driver.

## What the person sees

`host.host_open` returns false. It also says why, once, where the person looks:

- the program's log (`core:log`, the program's logger: the log file and the tail of a crash report);
- standard error, as `<program>: <sentence>`;
- on Windows, a message box: a program built with `-subsystem:windows` has no console.

`host.open_error(h)` gives the same sentence to a program that shows it its own way. The program then ends with its exit
code after `crash.end_session`, and the next start finds no crash: a clean end, not a crash report.

The message box is shown only when standard error goes nowhere (no handle: a `-subsystem:windows` program started from
the desktop). A program with a console has read the line, and a box would hold a test run until someone closes it.

## Direct3D 11

A window's renderer falls back to WARP, the system's software rasterizer, when no hardware device can be made, as the
offscreen renderer already did. WARP is slow but draws everything. A failure of both is `No_Driver`.

## The GL fallback (Linux)

A machine with OpenGL and no Vulkan driver (an old graphics card, a virtual machine with a GL-only virtual GPU) draws
through wgpu's GL backend over EGL: a desktop OpenGL 3.3 core context where EGL offers desktop OpenGL (Mesa does, and
gives its highest version, 4.6 on llvmpipe), else OpenGL ES 3. `adapter_info` says which: "OpenGL" or "OpenGL ES". The code is `wgpu_open_adapter` (wgpu_core.odin) and
`wgpu_gl_linux.odin`.

**When.** The Vulkan instance is made first, as before. Only when it gives no adapter (no loader, no driver, no device)
is it released and an instance of `backends = {.GL}` made. GL is never tried when Vulkan gives an adapter, even one that
then cannot present to the window: that is `No_Window`, as before. Vulkan draws everything the renderer has; GL draws
most of it, slower. `TOOLKIT_WGPU_BACKEND=gl` in the environment skips Vulkan: for the tests, and for a machine whose
Vulkan driver exists but misbehaves. It is read once per process (`wgpu_gl_forced`), so every renderer of a process has
the same backend.

**The display.** wgpu's GL backend makes its EGL display when the instance is made, from
`InstanceExtras.displayHandle` (wgpu-native 29.0.1.1 has the field; before it, a GL instance had no backend on Linux).
The renderer gives it the display of the window it is made for: the Wayland `wl_display`, or on X11 an Xlib connection.

**X11: Xlib, not XCB.** wgpu-hal 29's EGL code (`gles/egl.rs`) makes a display from an Xlib `Display` only
(`EGL_PLATFORM_X11_KHR`); its XCB case is `todo!("xcb")`, a panic that ended the child of the X11 desktop test. The
toolkit's windows are XCB's, with no Xlib. So a GL instance on X11 opens an Xlib connection of its own to the same
server: libX11 is loaded with dlopen on this path only (`platform.xlib_display_open`, `XInitThreads` first: EGL uses the
connection from the device's, the render and the pre-warming threads), `XOpenDisplay(nil)` reads the same `DISPLAY`. The
instance gets `NativeDisplayHandle{type = .Xlib}` with that connection and its default screen, and the window's surface
is `SurfaceSourceXlibWindow{display, window}` with the XCB window's id: an X window id is the server's, valid on every
connection to it (wgpu-hal hands EGL a pointer to it as the native window). The connection lives as long as the instance
(`Wgpu_State.gl_xlib`) and is closed after the instance is released, since the instance's EGL display is terminated on it.
Without libX11, or when `XOpenDisplay` fails, the GL adapter is refused with that reason: no panic. Refused: an XCB
handle (the panic), and the toolkit moving its own X11 backend to Xlib (Xlib for every X11 program, for the rare
machine without Vulkan).

An offscreen renderer gives none: Mesa's EGL then takes `EGL_MESA_platform_surfaceless`, which draws and presents nothing. A GL
instance therefore serves one display connection: `wgpu_make_surface` makes no surface on a GL instance made for another
connection or for none. A device made early (`preload_device`, no window yet) is surfaceless on GL: the window does not
take it and makes its own. A recovery after a lost device is given the window's handles for the same reason.

**What GL lacks, and what the renderer does about it.** Read in wgpu-hal's GLES adapter (`adapter.rs`,
`surface_capabilities`):

- *Texture views of another format* (downlevel flags `VIEW_FORMATS`, `SURFACE_VIEW_FORMATS`). The renderer stores an
  8-bit frame as `BGRA8Unorm` and draws into it through a `BGRA8UnormSrgb` view in the linear blend space. On GL the frame
  is stored in its view format (`wgpu_frame_formats`): `BGRA8UnormSrgb` holds the same sRGB-encoded bytes, so captures,
  read-backs and snapshots read it the same. The kept target's copy to the surface then decodes and encodes sRGB again,
  which is exact on 8 bits.
- *A surface to copy from.* GL's surface textures are render targets only, and `SurfaceConfigure` ends the process on a
  usage the surface lacks. The usage is now `CopySrc` only where the surface offers it (`Wgpu_State.surface_copy`).
  Without it, every frame is composed into the kept target of partial redraw (`wgpu_damage_setup`) and drawn to the
  surface; the copies of a frame (backdrops, snapshots) and a capture read that target. A frame that draws nothing
  (`wgpu_clear_frame`: only the clear) goes the same way, the kept target cleared and drawn to the surface: whatever
  is presented, the kept target holds it, so the capture of a presented frame always has a source (`damage_ready`).
  With partial redraw on, a partial frame loads the kept target and draws its region, as on Vulkan; off, every frame
  is drawn whole into it.
- *A surface format the EGL config lacks.* GL offers the sRGB formats only when its EGL config has them.
  `wgpu_configure_surface` configures only a format the surface offers (and returns false otherwise) instead of letting
  wgpu-native end the process.
- *Present modes and alpha.* FIFO only, opaque only. The renderer already reads both from the surface's capabilities:
  no tearing, no mailbox, no translucent window on GL.
- *Limits below WebGPU's defaults.* Asking for the defaults fails the device on such a driver, so on GL the device asks
  for the adapter's own limits. `wgpu_gl_lacks` refuses an adapter below what the renderer binds: 8 storage buffers in a
  fragment stage (the seven tables of group 0 and an application shader's parameters), 128 MiB storage buffers (the GLES
  3.1 minimum), 9 sampled textures and 3 samplers in a stage, 3 bind groups, 2 dynamic uniform buffers, uniform buffers
  of 1280 bytes, a uniform offset alignment of 256 bytes at most, 14 values between stages (rect.wgsl's locations).
- *What the C API does not report.* Storage buffers in a vertex shader (downlevel `VERTEX_STORAGE`: the transforms and
  slots are read there) and a half-float render target (the layers are `RGBA16Float`; GLES draws into one only with
  `EXT_color_buffer_half_float` or `EXT_color_buffer_float`). `wgpu_gl_probe` makes one of each in a validation error
  scope after the device: an error refuses the adapter.
- *Features.* Dual-source blending (`GL_EXT_blend_func_extended`), timestamps and 16-bit norm textures are asked for only
  when the adapter has them, as on Vulkan: text per colour stripe, GPU times and 10-bit video take their existing
  fallbacks without them. The shaders use no compute, no storage textures, no writable storage, no `f16`.

A refused GL adapter is `No_Driver`, its detail Vulkan's reason then GL's ("vulkan drivers/libraries could not be loaded;
OpenGL has fewer than 8 storage buffers in a shader stage"): the sentence still tells the person to install the Vulkan
driver, which is what draws everything. When GL is forced, the sentence names OpenGL and its EGL driver.

**The pipelines, made at start.** The limits and the probe do not prove that naga can write the shaders. wgpu-hal
makes a desktop GL context when EGL offers desktop OpenGL (Mesa does), takes storage buffers from
`GL_ARB_shader_storage_buffer_object`, and so reports them; naga then writes GLSL of the context's version, and below
4.00 (desktop) or 3.10 (ES) GLSL has no buffer blocks. `DeviceCreateRenderPipeline` fails ("The selected version doesn't
support Features(BUFFER_STORAGE | DYNAMIC_ARRAY_SIZE)"), and wgpu-native ends the process at the first `QueueSubmit` that
sets that pipeline. Seen with NVIDIA's EGL: wgpu-hal asks a desktop 3.3 core context, NVIDIA gives exactly 3.3 (GLSL
330), and the adapter is refused. Mesa gives its highest version (4.6 core on llvmpipe, GLSL 460, capped to 450 by
wgpu), which draws. The fallback therefore serves Mesa's drivers, which are what a machine without Vulkan has (an old
GPU, a virtual machine), and ES 3.1+ drivers; on a machine whose libglvnd picks NVIDIA's EGL first it is refused,
cleanly. The tests run on Mesa's EGL alone: the dev shell names its vendor file (`TOOLKIT_TEST_MESA_EGL`, flake.nix),
and the GL tests set `__EGL_VENDOR_LIBRARY_FILENAMES` to it before the first EGL call.
`gles3MinorVersion` does not help: wgpu-hal ignores it when it makes a desktop context. So on GL `wgpu_init_pipeline`
makes the pipelines every frame uses (shapes, blends, text, a layer and its filters, the kept target's copy to the
surface) inside a validation error scope (wgpu-native 29 takes only Validation and OutOfMemory filters, an Internal one
is a panic, and it reports naga's failures as validation errors), before anything is submitted and
before the pre-warming thread starts (error scopes are the calling thread's). An error refuses the adapter (`No_Driver`,
"OpenGL has shaders it cannot compile (...)"). This costs their compiles on the start of a GL window, which the
pre-warming thread would otherwise pay; it is the price of never aborting. The GL adapter's strings (vendor, device,
description, architecture: GL_VERSION is among them) are written on standard error, for a report.

**One sampler per texture.** GLSL has no separate textures and samplers: a `sampler2D` is both, so naga's GLSL writer
pairs each texture with one sampler per entry point and refuses a second ("A image was used with multiple samplers").
This was the next refusal on llvmpipe (GL 4.6 core), after the GLSL version. Every texture sampled by the WGSL compiled
on wgpu, and its samplers:

- rect.wgsl: `image` through `samp_img` (clamp: plain images, layers scaled down, planes) and `samp_wrap` (repeat:
  `draw.image_tiled`, FLAG_TILE) — the only conflict; `atlas` through `samp` only; `backdrop` by textureLoad only.
- slug.wgsl, slug_dual.wgsl (added to rect.wgsl): the curve and band textures by textureLoad only; rect.wgsl's as above.
- filter.wgsl: `src` and `src2` through `samp` only. mip.wgsl: `mip_src` through `mip_samp`. video.wgsl: the planes
  through `samp`.
- app.wgsl and the application's code (added to rect.wgsl): as the application writes them. The licence card's samples
  its textures through `samp_img` alone.
- canvas.wgsl samples `src_tex` through five samplers, but it is Direct3D 11's only: wgpu never compiles it.

So on GL `wgpu_module` compiles a variant of every module that holds rect.wgsl (`wgpu_gl_source`): each sampling of
`image` goes through `samp_image`, a sampler at group 1, binding 5, beside `image` itself. Group 1 is already made per
batch (`walk_bind`), so the sampler is the batch's: `s_wrap` for a batch of tiled images, `s_img` otherwise (both
trilinear: filtering never differed, only the address mode). `gt:draw` gives each batch one mode: where a draw of the same
texture goes from clamped to tiled or back, it starts a new batch (`image_batch`, when `render.image_wrap_splits_batches`
says so, on GL only). Pictures keep the mode of their batches (`Batch.image_wrap`).

Cost: a new batch only where the same texture is drawn clamped and tiled one after the other, which a frame rarely does:
a different image already starts a new batch. Elsewhere it is one more sampler in a group that is made anyway.

Kept the same on every other backend: the WGSL compiled there, group 1's layout (five entries), and the batches. Vulkan and
Direct3D pick the sampler per instance in the shader, as before.

Refused: a define or `override` for the variant (WGSL has no preprocessor, and an `override` cannot choose a sampler);
emulating repeat with `fract` on the clamp sampler (the seams would clamp instead of wrapping, half a texel at every
mip level); and filtering tiled images by hand with textureLoad (eight fetches for trilinear, and a level of detail that
differs from the hardware's).

The start-time check makes the pipelines that these variants change: shapes and images (both blend modes), text, text per
colour stripe where the device blends that way, a layer's content and filters, and the copy to the surface. An application
shader is made when the program asks for it: a refusal there leaves its draws to the submit guard below.

Refused: a vertex path without storage buffers for GL (instance data in vertex buffers). Below GLSL 4.00 / ES 3.10 the
fragment shaders cannot read storage buffers either: the transforms, clips, points, gradients and retained heaps would
all have to move to textures, a second binding model for a rare machine.

**Never abort later.** A pipeline made after start (an application shader, a filter of another format) can be refused
the same way. wgpu reports the error to `uncaptured_error` during the call, and on GL `wgpu_submit` skips a submit when
the device's error count changed since the last one: the frame is lost, the process is not. Vulkan keeps submitting as
before: an error there is the renderer's bug.

**Said once.** A fallback writes one line on standard error, `render: wgpu: Vulkan gives no adapter (...): drawing with
OpenGL`, and `adapter_info(&r).api` says "OpenGL" or "OpenGL ES", as wgpu reports the context: the Diagnostics page shows it on its "Graphics API" line.

Refused: trying GL for a Vulkan adapter that cannot present to the window. Every known driver presents; a GL instance
for that case would hide a bug of the Vulkan path behind a slower renderer.

## Tested

- **Linux:** a child in a headless sway whose Vulkan loader points at a driver list that does not exist, and libglvnd's
  EGL at no vendor: no device, the sentence. With EGL left: the window opens on OpenGL, presents, and a capture reads
  its frame back; the same with `TOOLKIT_WGPU_BACKEND=gl` and Vulkan there (`tests/no_graphics`). `tests/gl_fallback`
  draws a known frame offscreen on GL (colours, an opacity group in a half-float layer, a blur) and compares its pixels
  with Vulkan's values. `tests/linux_desktop` opens a GL window on Xvfb (EGL on XCB) and on headless sway. Where the system
  has no EGL, these tests write a `SKIPPED` warning in the log and draw nothing.
- **Windows:** render's fault `D3D_Device` refuses `CreateDevice` call by call (`TOOLKIT_RENDER_FAULTS`). One refusal: the
  window draws on WARP. Two: no device. The child then runs twice: with standard error in a file (no box, the sentence
  there), and with no console and no standard handles, as a `-subsystem:windows` program from the desktop (a box, which
  the test finds by its class and closes). A real machine without a driver is not needed: what the program sees is the
  same failed call.

## Not done

- **A Vulkan driver without the window extension.** When the instance has an adapter but its driver lacks
  `VK_KHR_wayland_surface` or `VK_KHR_xcb_surface`, `wgpuInstanceCreateSurface` still panics. Every known driver has them.
  Checking them means loading the Vulkan loader and asking it for its instance extensions, which loads every driver a
  second time at start.
