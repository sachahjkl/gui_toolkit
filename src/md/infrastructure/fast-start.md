# A fast start

The time a person waits is from the click to the first frame shown. The toolkit measures it from the process's start
(`base.start_*`), and makes the long steps of a start run side by side.

## What took the time

A small window (a label and a button), `-o:speed`, lavapipe (Vulkan on the CPU), Xvfb; the times since the process
started, medians of 7 runs:

| step | before | after |
|---|---|---|
| `main` | 4 ms | 5 ms |
| the window open (`platform.open_window`) | 58 ms | 57 ms, while the device is made |
| the device (instance, adapter, device) | +32 ms after the window | 70 ms, on its thread from the start |
| surface, its configuration, shaders | 7 ms | 1 ms (shaders made with the device) |
| the pipelines | 455 ms (8, one after the other; the first frame waited for all) | 111 ms (2, side by side) |
| the first frame shown | 592 ms | 205 ms |

In the window open, the toolkit's part is small: the xcb library loaded (0.3 to 11 ms), the atoms (1 ms: 46 round
trips, now one), xkb (1 ms), the dark-mode read (2.5 ms). The rest, about 40 ms, is Xvfb's connection setup: `xprop`
alone takes 50 ms on the same server. The font loads in 0.1 ms (the embedded face).

## The decisions

- **The pipelines with the device, never in the window's way.** `preload_device`'s thread makes the shaders, then
  starts the two pipelines of a window's first frame (its rectangles and its Slug text) on two threads of their own
  (`Wgpu_Early`) and says the device ready without waiting for them. A pipeline needs no surface, only its target's
  format: `early_pipeline_format` predicts it as `wgpu_frame_formats` will choose it, from the window's `transparent`
  and `space` (`preload_device`'s, a host window's by default). Half floats depend on what the surface offers, not known
  before it exists: the guess is none (Mesa's surfaces). A wrong guess costs two compiles on other cores and no wait: a
  thread waits for the early pipelines (`wgpu_early_adopt`) only when it wants one of their key, which it would compile
  otherwise. Where compiles run one at a time (Windows: `COMPILES_SERIAL`), an early pipeline would queue in front of
  the window's own (seconds with FXC when the guess is wrong, as for a DirectComposition window in half floats): none is
  made there, the device and the shaders are. Refused: making them for every format (each costs 50 to 110 ms on
  lavapipe, seconds with FXC). Refused: the device's thread compiling into the lists of the state it makes: that state
  moves into the renderer, so the init had to wait for both compiles, needed or not.
- **The device asked by `host_open`.** The first `host_open` asks for the device before it opens the window, and
  loads the font before the renderer's init waits for the device. A probe that opens its window through `host_open`
  measures the start a person has; plume's `--probe-start` skipped the device made early, its `main` asked for it.
- **A frame never waits for a compile it does not need.** The pipeline lists held their lock during each compile: the
  first frame, which needed two pipelines made already, waited for the pre-warming thread's eight. Now a thread claims
  a pipeline (an entry not ready), compiles it without the lock, then gives it; another thread that wants the same one
  waits for it, one that wants another goes on.
- **Compiles side by side.** The process's compile lock is a read-write lock: the toolkit's own pipelines compile
  side by side (the first two on two threads), an application's shader alone (an error during it is its own). On
  Direct3D 12 every compile is alone: DXC crashes when two meet.

- **The shaders go with their device.** A window whose surface the device made early cannot present to releases that
  device and makes its own; the shaders and pipelines made with the first one are released with it
  (`wgpu_release_shaders`), or the pre-warming thread compiles with released objects and wgpu aborts (`tests/no_graphics`,
  `a_driver_opens_the_window`, under sway, found it).

Not yet: a pipeline cache on disk (Vulkan's `VkPipelineCache`). `vendor:wgpu` over wgpu-native 29 names the feature
(`FeatureName.PipelineCache`) but has no call that makes a cache; when it does, the two first pipelines can come from the
disk (ROADMAP.md, Later).

The test that breaks the design: `src/render/device_preload_test.odin` checks that the device made early holds the
shaders and the early pipelines started, that a pipeline of another format is made without them, and that the
renderer's pipeline of their format is the one made early. `early_pipelines_are_made_in_the_window_s_format` checks the
prediction.
