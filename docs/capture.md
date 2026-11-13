# capture

The screens and the windows of the desktop, as pictures: what a screenshot tool or a screen recorder needs from the
system. The outputs (monitors) and where they are, the windows and where they are (when the system says it), and a
picture of an output, of a window, or of the whole desktop. For a recording, a stream of the frames of an output, a
window or a region ([Streams](#streams)).

```odin
import "gt:capture"

s, err := capture.open()                  // the system's capture, once
outs := capture.outputs(s)                // the screens, in desktop coordinates
wins := capture.windows(s)                // the windows, front to back
d, _ := capture.desktop(s)                // every screen in one picture, at the highest scale
part, _ := capture.crop(d, {x, y, w, h})  // a region, logical
w := capture.window_at(wins, pointer)     // the window under the pointer (when windows_have_rects)
capture.frame_free(&d)
capture.close(s)
```

A session lives as long as the program. When its connection to the display server breaks (a protocol error, the
compositor restarted), the next call opens it again before it acts: the program does not open another. A session with a
stream open waits for that stream to close (the stream uses the connection, and ends with an error of its own).

## The threading rule

Every procedure may block: a round trip to the compositor, a portal's dialog, a GPU readback. Call them on a worker,
never on the interface's thread, and post the result back (`ui.post`). On Windows, a session belongs to the thread that
opened it.

## Coordinates

The desktop's, in logical pixels (what a window's size is given in), the outputs side by side as the system places them.
A `Frame` is in physical pixels, `scale` of them per logical pixel, and says where on the desktop its first pixel is
(`origin`, logical). Pixels are BGRA, 8 bits a channel, straight alpha (opaque for a screen).

## Outputs at different scales

`desktop` is one picture at the highest scale of the outputs. An output at a lower scale is enlarged into it by the
nearest pixel: beside a screen at 1.33, a screen at 1 gets one row and one column in four twice, and its text looks
uneven once cut, or once shown on that screen again. A program that cuts a region or shows one screen at a time keeps
each output's own picture instead:

```odin
parts, err := capture.desktop_parts(s)          // each output's picture, at its own scale, taken together
defer capture.frames_free(parts)
cut, ok := capture.crop_parts(parts, region)    // inside one output: its pixels as they are
i := capture.part_holding(parts, outs[0].rect)  // the part that shows that output (-1: none holds it all)
```

- `desktop_parts` gives a frame per output, each with its `origin` and `scale`. Wayland and Windows capture each output
  on its own; the portal and X11 read the desktop as one picture, and give that one.
- `crop_parts` cuts a region from the part that holds all of it, at that part's scale. A region across outputs is cut
  from the parts it meets composed (`compose`, at the highest of their scales), as `desktop` would give it.
- `part_holding` is the part that holds a rectangle, or -1.

`tests/capture/capture_parts_test.odin` checks them with made-up frames: an output at 4/3 beside one at 1.

## The pointer

`pointer` says where the pointer is: a point on the desktop, logical, and the id of the output it is on.

```odin
at, output, ok := capture.pointer(s)   // blocks for at most one round trip: call it on the session's worker
if ok { o := output_by_id(outs, output) }
```

- **Wayland.** A compositor tells a client where the pointer is only over the client's own surfaces. `pointer` asks
  through `ext_image_copy_capture_cursor_session_v1`. At the first call it gets a `wl_pointer` of the first `wl_seat`
  and makes a cursor session per output. The sessions stay with their outputs; an output plugged in later gets one at
  the next call. Each call then makes one round trip and reads what the sessions said last (`enter`, `position`,
  `leave`). The session's position is in the output's physical pixels as seen; `pointer` turns it logical with the
  output's place and size (`pointer_from_buffer`). `ok` is false when the compositor has no
  `ext_image_copy_capture_manager_v1` or no output source manager, when the seat has no pointer, or when no session
  says the pointer is on its output.
- **X11.** `QueryPointer` on the root window. The output is the RandR monitor that holds the point.
- **Windows.** `GetCursorPos`, physical pixels to the session's thread, turned logical through the output that holds
  the point, as a window's rect is.
- **Elsewhere and with the portal alone** (no Wayland connection), `ok` is false.

`pointer_from_buffer(pos, size, turn, place)` is the pure part: a point of a buffer of `size` physical pixels, shown
turned as `turn` says, on an output at `place`. The buffer once upright covers `place` exactly, so the scale is the
ratio of the two. `tests/capture/capture_pointer_test.odin` checks it against `frame_from_buffer` for the eight turns.

## Streams

A screen recorder needs frames, not pictures: `stream_open` keeps the capture of one source open, and `stream_next`
gives a frame each time the source changed, at most `fps` a second.

```odin
st, err := capture.stream_open(s, capture.Stream_Output{outs[0].id}, {fps = 30, cursor = true})
for recording {
	f, ok, err := capture.stream_next(st, 100 * time.Millisecond)   // blocks
	if err != .None { break }                                       // .Gone: the source went away
	if ok { encode(f.pixels, f.width, f.height, f.timestamp) }      // ok false: nothing changed meanwhile
}
capture.stream_close(st)
```

- **Sources.** `Stream_Output{id}` is a whole output. `Stream_Window{id}` is one window. `Stream_Region{rect}` is a
  rectangle of the desktop, logical: the frames of the output that holds most of it, cut to it (a region across two
  outputs gives the part on one of them).
- **When a frame comes.** `stream_next` returns when the source changed (the backend's damage), and never sooner than
  `1 / fps` after the frame before. If nothing changes before `timeout`, it returns `ok = false` with no error: ask
  again. An error ends the stream.
- **Timestamps.** `timestamp` is in nanoseconds since the first frame, which is 0. It always increases. It is the time
  the compositor presented the frame where the backend says it, else the time the frame came.
- **Pixels.** A frame is BGRA, opaque, rows packed (`stride = width * 4`). Its pixels belong to the stream: do not free
  them. They stay valid until `stream_next` is called twice more: two buffers are used in turn, so the frame before the
  last one can still be read while the next one is made.
- **Size.** The frames of an output or a region keep one size while the output's mode does not change. A window's
  frames keep the size it had at the start on Windows and on X11 (cut or padded with black); on Wayland they follow the
  window's size.
- **The pointer.** `options.cursor` asks for the pointer in the frames; `Stream.cursor` says whether the backend draws it.
- **Threads.** Call the three procedures on the session's thread, and no other procedure of the session while a stream
  is open. A recorder opens a session of its own on its own thread.

| Backend | Output, region | Window | Changes | Pointer |
|---|---|---|---|---|
| `ext_image_copy_capture_v1` | a session kept open | a session kept open | the compositor's damage | `paint_cursors` |
| `zwlr_screencopy_v1` | a frame per picture, `copy_with_damage` | no | the compositor's damage | `overlay_cursor` |
| Portal | no | no | | |
| X11 | `GetImage` at the pace | the root at its frame | the pixels compared | no |
| Windows | Windows.Graphics.Capture, else Desktop Duplication | Windows.Graphics.Capture | the system's | Graphics Capture only |

The portal backend has no stream: the ScreenCast portal hands a PipeWire stream, which needs libpipewire and is not
written. On X11 there is no MIT-SHM nor XDamage yet: a still screen costs one read and one comparison per interval.

The pure parts are public and tested on every system (`tests/capture/capture_stream_test.odin`): `Stream_Pacer` (when
the next capture may start, each frame's timestamp), `Frame_Ring` (the two buffers) and `crop_into` / `crop_size` (a
region cut into a buffer of the caller's).

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
