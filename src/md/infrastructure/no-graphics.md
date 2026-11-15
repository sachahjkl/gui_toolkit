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

## Not done

- **The GL backend as a fallback.** The pinned wgpu-native (29.0.1.1) has its GLES backend compiled in, but its
  `wgpuCreateInstance` gives wgpu-hal no display handle, so on Linux an instance with `backends = {.GL}` has no backend at
  all: no adapter, and the same panic at the surface (checked under headless sway). It becomes possible when wgpu-native
  takes the display in its instance descriptor.
- **A Vulkan driver without the window extension.** When the instance has an adapter but its driver lacks
  `VK_KHR_wayland_surface` or `VK_KHR_xcb_surface`, `wgpuInstanceCreateSurface` still panics. Every known driver has them.
  Checking them means loading the Vulkan loader and asking it for its instance extensions, which loads every driver a
  second time at start.
