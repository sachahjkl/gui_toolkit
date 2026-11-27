# The first frame drawn on the CPU

A person sees content when the first picture is on the screen. Before this work, that picture waited for the graphics
device, the window's surface and the two first pipelines: 175 to 205 ms after the process started on lavapipe
([fast-start.md](fast-start.md)), most of it after the window was already open. The window is open, the font is loaded
and the interface can be built 30 to 60 ms after the start. Only the GPU is missing.

## The constraint, reduced

To show the first frame, three things are necessary: the frame's description (`render.Frame_Data`, which `gt:draw`
builds without the GPU), the pixels of what it samples (the glyph pages, the Slug curves, the images: all made on the
CPU and only uploaded), and a way to put pixels in the window. None of these needs a device. The device is necessary
only to draw fast and to draw every effect.

So the renderer gets a stage before its device: the **CPU stage**. During this stage, the renderer keeps what it is
given on the CPU, rasterises each frame on the CPU and gives the pixels to the window through the platform.

## Decisions

- **A stage of the renderer, not a second renderer.** `render.init_window(..., cpu_first = true)` returns at once in the
  CPU stage when the device made early (`preload_device`) is still being made. The texture handles, the retained heaps
  and the draw context are the renderer's from the start. At the end of the stage, each texture gets its GPU object in
  the same slot and its pixels are uploaded, as the recovery after a lost device remakes them (`wgpu_recover`). A draw
  context, a picture and a program keep their handles. Refused: a throwaway CPU renderer and draw context for the first
  frame. The program's textures, the atlas pages and the pictures made during the first frame would belong to the wrong
  renderer.
- **One frame on the CPU, then the GPU.** The stage draws one frame. The next `frame_begin` ends the stage. It waits for
  the device as `init_window` did, makes the surface and the pipelines, moves the textures and the heaps to the device,
  and then draws that frame on the GPU. The wait after the first picture is the wait that was before it. The host asks
  for that second frame at once: nothing else would (a window at rest on X11 gets no other event).
- **One more CPU frame at each new size, three at most.** A tiling compositor (sway) gives the window its tile when the
  first picture maps it, and shows the window only once a picture of that size comes, or after its own wait (200 ms).
  A renderer that waits for its device then commits nothing, and sway showed the first picture at its old size in a
  larger black tile, 200 ms late. So a frame whose size is not the last CPU frame's is drawn on the CPU again
  (`CPU_STAGE_FRAMES_MAX`), and the Wayland commit of a CPU picture is followed by a roundtrip, so that the tile's
  configure is read before the next frame. Refused for now:
  more CPU frames until the device is ready, with no wait. This needs a wake from the device's thread and a CPU frame
  for each input during the stage. The gain (input answered about 100 ms earlier on lavapipe) is small compared with
  the risk (the whole frame loop on the CPU path). See ROADMAP.md, Later.
- **The caller asks for it.** `host_open` asks for the CPU stage. A program with its own loop (fidget) calls
  `init_window` without `cpu_first` and keeps the old start, until it asks too. Its `frame_begin` ends the stage by
  itself, so a program that asks for the stage needs no other call.
- **A CPU copy only while a CPU rasteriser can read it.** The texture uploads, the Slug pages and the heap writes keep a
  CPU copy (`Cpu_Mirror`) while the stage is active, or while the CPU shadow of a test is on (`TOOLKIT_CPU_SHADOW=1`, see
  below). At the end of the stage the copies are freed. A frame on the GPU costs nothing more.
- **The rasteriser is the shaders, in Odin.** `cpu_raster.odin` evaluates rect.wgsl's `ps_main` and slug.wgsl's
  `ps_slug` and `ps_slug_dual` per pixel, with the same formulas: the rounded rectangle's distance with the corner
  smoothing, the borders, the soft shapes, the analytic shadows, the gradients, the atlas glyphs with their text
  correction, the Slug coverage with its supersampling and its colour stripes, the clip shapes. It covers the pixels the
  GPU covers: the pixel centres in the quad, and the half-pixel dilation of a Slug glyph. It accumulates in linear light
  in f32 and encodes to 8-bit sRGB once, where the GPU encodes after each blend. The two differ by one step of 8 bits
  at most where nothing clamps.
- **What it cannot draw exactly is drawn plainly.** During the stage, `acquire_target` gives no layer: `gt:draw` then
  draws a layer's content with the layer's alpha on each primitive (the path it already has when a target is refused).
  Filters (blur, backdrop, masks), blend modes, planes in perspective, application shaders and video frames are left
  out of the CPU frame. A frame that had one of these is reported (`cpu_frame_exact`), and its next frame on the GPU
  changes those regions. Retained pictures (`ui.swap` during a transition) are not drawn on the CPU: a first frame
  has none.
- **The colour stripes are decided before the device.** `gt:draw` asks the renderer whether text can have a coverage
  per colour stripe. During the stage, the answer is yes, because the CPU blends each channel by itself. A device
  without dual-source blending then draws the next frame in grey text. Every Vulkan driver the toolkit meets has the
  feature.
- **The window shows pixels through the platform** (`platform.show_pixels`): on Wayland, a `wl_shm` buffer attached
  to the window's surface and committed (the first commit with a buffer maps the window, as the first present did); on
  X11, `PutImage` in strips under the largest request. The swap chain's first present replaces the picture: on Wayland
  the WSI attaches its own buffer to the same surface, which the protocol allows; on X11 the presented image covers the
  window. The shm buffer is destroyed after the first present on the GPU (`platform.drop_pixels`), never before: a
  buffer destroyed while attached can make the surface's content undefined. Refused: MIT-SHM on X11. It saves one copy
  of about 1 MB for one frame, and costs a shared segment, an extension query and its fallback.
- **No colour flash.** The CPU frame starts with the same clear colour, and the GPU frame replaces it at the same size
  and with the same layout (the same build and the same fonts: shaping is on the CPU in both).

## Subtle points

- The stage starts only if the device is still being made, and only once the device's thread has said its adapter
  (`preload_adapter_wait`): the adapter answers in milliseconds, the device and its pipelines take a hundred. No adapter:
  `init_window` fails as before, and the no-graphics sentence is that of a failed `host_open`
  ([no-graphics.md](no-graphics.md)). Without this wait, a child of `tests/no_graphics` with no Vulkan driver, under
  sway, opened its window before its adapter request failed: `host_open` returned true, and the failure came after
  the first picture. GL (the fallback of a machine without Vulkan): no stage either; the window makes its own device
  there, and `adapter_info` must say OpenGL as soon as `host_open` returns. During the stage `adapter_info` says the
  adapter that will draw.
- If the device fails after its adapter answered (rare), the end of the stage fails: `render.init_failure` says why,
  the renderer stays on the CPU, and the host reports it as a failed `host_open` does (log, standard error, box) and
  closes the window. A program then ends with its normal exit code, not with the code of a failed `host_open`.
- A present on the CPU counts as a present (`present_totals`): the host's request for the compositor's word
  (`frame_shown_ask`, Wayland) goes with the shm commit, so the next frame waits for the word as after any present.
- X11 with a window manager: the window is mapped when the manager decides. A `PutImage` before that is lost. Then the
  first picture on the screen is the GPU's, as before. Xvfb without a manager and Wayland show the CPU picture.
- `TOOLKIT_CPU_FIRST=0` in the environment turns the stage off: for a measure before and after, and for a machine where
  it is wrong.
- Windows is not done. A GDI picture (a DIB section copied on `WM_PAINT`) followed by a flip-model swap chain on the same
  window must be checked on a real machine for a blank frame between the two. DWM is expected to show the redirection
  surface until the first present of the swap chain, but this is not verified. See ROADMAP.md.

- On X11, the loop's wait drained what XCB had read before it polled the socket, and an event handled there (the
  window's `MapNotify`) ended no wait: a window with nothing else to say slept before its first frame. The CPU stage
  shows the window sooner and loads the CPU while it is shown, so this happened in 2 to 5 starts in 100. `x11_wait` now
  counts what its first drain handled.

## Measured

hello, `-o:speed`, lavapipe, the times from the process's start, the stage off (`TOOLKIT_CPU_FIRST=0`, the start before
this work) and on, started one after the other. The machine was loaded by other builds (load average on 16 cores in the
first column), which moves every number: compare a row's columns, not the rows.

| | load | the first picture, stage off | the first picture, stage on | the GPU's picture, stage on |
|---|---|---|---|---|
| Xvfb, no window manager, 9 starts | 40 | 324 to 524 ms (median 392) | 62 to 104 ms (median 88) | 293 to 499 ms |
| headless sway, 7 starts, before the adapter wait | 27 | 352 to 667 ms (median 398) | 83 to 321 ms (median 127), at the tile's size | 347 to 525 ms |

Where the time goes, on Xvfb at load 22 (6 starts): the window is open at 28 to 55 ms, the adapter has answered at 48
to 100 ms, the CPU picture is shown at 57 to 113 ms (median 64). Building, rasterising and encoding a 640 x 400 frame takes
6 to 9 ms; the wait for the adapter takes 15 to 70 ms, and is the price of the no-graphics sentence (above). Before that
wait, at load 20, the CPU picture came at 30 to 42 ms (median 37) where the GPU's came at 189 to 213 ms. On sway the
first CPU picture is held by the compositor until the second, at the tile's size; a compositor that does not tile shows
the first one. On a real GPU the device comes in 30
to 80 ms and its pipelines come from the driver's cache, so its first picture is close to the CPU's: the CPU stage
mostly helps software drivers, virtual machines and a cold driver cache. With the NVIDIA GPU not used in the tests, this
is an estimate.

The CPU picture and the GPU picture are the same on the screen: on sway, 0 pixels of 1600 x 1000 differ by more than 3 %
(`grim` before and after the switch).

## Cost

The rasteriser is in `render`. It adds 64 KB of code to hello (42.42 MB to 42.49 MB, `-o:speed`): small enough to be
in every program by default. `-define:TOOLKIT_CPU_FIRST=false` removes the stage, the copies and the rasteriser at
compile time. At run time the stage costs nothing after its end: the CPU copies are freed.

## The test that breaks it

`tests/cpu_first`: fidget's first screens (Controls, Inputs, blended in sRGB values, a light palette), drawn on lavapipe
offscreen, and the same `Frame_Data` rasterised on the CPU (`TOOLKIT_CPU_SHADOW=1`). Measured: 1 to 5 pixels of 920 400
differ by more than 6 steps of 8 bits, a channel by 0.002 to 0.011 steps on average. A wrong distance, a wrong glyph band or a wrong colour space changes thousands of pixels by
much more. An opt-in test (`TOOLKIT_TIMING_TESTS=1`) starts examples/hello on Xvfb with and without the stage, and reads
the start marks: the first picture on the CPU comes before the first picture on the GPU.
