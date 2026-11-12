# capture

The screens and the windows of the desktop, as pictures: what a screenshot tool or a screen recorder needs from the
system. The outputs (monitors) and where they are, the windows and where they are (when the system says it), and a
picture of an output, of a window, or of the whole desktop.

```odin
import "gt:capture"

s, err := capture.open()                  // the system's capture, once
outs := capture.outputs(s)                // the screens, in desktop coordinates
wins := capture.windows(s)                // the windows, front to back
d, _ := capture.desktop(s)                // every screen in one picture: what a region is cut from
part, _ := capture.crop(d, {x, y, w, h})  // a region, logical
w := capture.window_at(wins, pointer)     // the window under the pointer (when windows_have_rects)
capture.frame_free(&d)
capture.close(s)
```

## The threading rule

Every procedure may block: a round trip to the compositor, a portal's dialog, a GPU readback. Call them on a worker,
never on the interface's thread, and post the result back (`ui.post`). On Windows, a session belongs to the thread that
opened it.

## Coordinates

The desktop's, in logical pixels (what a window's size is given in), the outputs side by side as the system places them.
A `Frame` is in physical pixels, `scale` of them per logical pixel, and says where on the desktop its first pixel is
(`origin`, logical). Pixels are BGRA, 8 bits a channel, straight alpha (opaque for a screen).

## Linux

The backend is chosen at `open`, the first that the session offers:

| Backend | Outputs | Windows | A window's picture |
|---|---|---|---|
| `ext_image_copy_capture_v1` (Wayland) | yes | `ext_foreign_toplevel_list_v1` | its own content |
| `zwlr_screencopy_v1` (Wayland) | yes | as above | no |
| Portal `org.freedesktop.portal.Screenshot` | cut from the desktop | as above | no |
| X11 | RandR | `_NET_CLIENT_LIST_STACKING`, with their frames | the desktop cut to it |

The standard Wayland protocols do not say where a window is. On Wayland the rects come from, in this order:

- `zcosmic_toplevel_info_v1`, version 2 or more (COSMIC, ShojiWM): each window's rect on each output, its states, and
  with `ext_workspace_v1` its workspaces. COSMIC does not say the stacking order: the activated window is first, then
  the most recent first.
- The compositor's own IPC (`capture/wm`): Hyprland (`HYPRLAND_INSTANCE_SIGNATURE`) and sway (`SWAYSOCK`).
- `org_kde_plasma_window_management`, version 13 or more (KWin): the rects, the stacking order and the virtual desktops.
  KWin gives this global only to a program whose `.desktop` file names it:
  `X-KDE-Wayland-Interfaces=org_kde_plasma_window_management`.

A window is shown when it is not minimized and is on an active workspace (or the compositor does not say its
workspaces). Elsewhere `windows_have_rects` is false: a window is picked from a list, not framed under the pointer.

## Windows

The Windows backend of `capture` (`src/capture/capture_windows.odin`, `capture_wgc_windows.odin`). Its pure parts are
in `layout.odin` and `win32_rules.odin`, and `tests/capture` checks them on every system.

### The session's thread

A session belongs to the thread that opened it. `open` does two things on that thread, and `close` undoes them:

- It joins COM's multithreaded apartment (`CoInitializeEx`). If the thread is in a single-threaded apartment already,
  the session uses that apartment.
- It makes the thread per-monitor DPI aware (`SetThreadDpiAwarenessContext`). The capture then works whatever the
  program set for its process.

Call every later procedure of the session on the same thread.

### Coordinates

To a per-monitor aware thread, the virtual desktop is in physical pixels. The backend converts it to logical pixels
with one rule (`capture.layout_logical`):

- The scale of an output is its effective DPI divided by 96 (`GetDpiForMonitor`).
- The logical origin of an output is its physical origin divided by the smallest scale of all outputs.
- The logical size of an output is its physical size divided by its own scale.

If every output has the same scale, the result is the exact division, with no gap. If the scales differ, outputs can
have gaps between them, but they never overlap. `desktop` leaves the gaps transparent.

A window's rect goes through the output that holds most of it (`capture.output_of`, then `capture.physical_to_logical`).
A frame of an output starts at the logical origin of that output and has its scale. Thus `crop` of an output's frame at
a window's rect gives the window's physical pixels.

### Outputs

- `EnumDisplayMonitors` and `GetMonitorInfoW` give the outputs. The name is `MONITORINFOEXW.szDevice` (`\\.\DISPLAY1`).
  The rect is `rcMonitor`, physical. The id is the `HMONITOR`, which stays the same while the display layout does not
  change.
- The picture of an output comes from DXGI Desktop Duplication. The backend tries `IDXGIOutput5::DuplicateOutput1`
  first (BGRA), then `IDXGIOutput1::DuplicateOutput`. The device is a D3D11 device on the adapter of the output.
- The session keeps each duplication and its staging texture. If the screen did not change, no new frame comes, and the
  last frame in the staging texture is the answer. After `DXGI_ERROR_ACCESS_LOST` (a mode change, the secure desktop),
  the backend makes the duplication again once.
- If duplication is unavailable for an output (some remote sessions, some drivers), the backend uses GDI for that
  output: `BitBlt` with `CAPTUREBLT` from the screen DC into a 32-bit top-down DIB section. It tries duplication again
  only when that output changes.
- Rotated outputs are turned upright (`capture.win32_rotated_source`).
- `desktop` draws every output at the highest scale. An output at that scale is copied. An output at a smaller scale is
  scaled with bilinear filtering.

### Windows

`windows` lists what `EnumWindows` gives, front to back. `capture.win32_window_listed` decides, in this order:

1. If the window is not visible or is cloaked (`DWMWA_CLOAKED`), it is not listed.
2. If its class is `Progman`, `WorkerW`, `Shell_TrayWnd` or `Shell_SecondaryTrayWnd`, it is not listed.
3. If it has `WS_EX_TOOLWINDOW` or `WS_EX_NOACTIVATE` without `WS_EX_APPWINDOW`, it is not listed.
4. If it has no area and is not minimized, it is not listed.
5. If it has a title, it is listed. If it has no title, it is listed only when it has `WS_EX_APPWINDOW` and no owner.

- The rect is `DWMWA_EXTENDED_FRAME_BOUNDS`: no invisible resize border, no shadow.
- The title comes from `InternalGetWindowText`. This call sends no message, so a busy window of the same process cannot
  block the list.
- `app_id` is the file name of the executable (`notepad.exe`). For a UWP app, it is `ApplicationFrameHost.exe`.
- A minimized window has `minimized` set and `has_rect` false, because its frame is parked off screen.

### A window's picture

`window` uses Windows.Graphics.Capture (Windows 10 1903 and later). It makes a `GraphicsCaptureItem` for the window, a
free-threaded `Direct3D11CaptureFramePool` with one buffer, and a session without the pointer. It waits up to one second
for the first frame, then closes everything. The picture is the window's own content, even when other windows cover it.

If Windows.Graphics.Capture is not there, `window` crops `desktop` to the window's rect. In that case, what covers the
window shows in the picture. A minimized window gives `.Failed`.

### Tests

- `odin test tests/capture` checks the pure parts on every system.
- `CAPTURE_LIVE=1` adds a test on the real desktop (Windows only).
