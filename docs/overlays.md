# Overlay windows (`platform.open_overlay`)

An overlay is a window above all other windows. It covers one whole output and is transparent where the program draws
nothing. It does not move the other windows, it is in no task bar, and it takes the keyboard only when the user clicks
it. A screen recorder uses one to show the frame of the region it records and a bar of buttons.

The input region sets which parts of the overlay take the pointer. Elsewhere, clicks and moves go to the windows below.

```odin
// with gt:host: the first window of the program, or a later one
o := host.Open_Options{title = "cliche", overlay = true, overlay_area = output.rect}   // output: a capture.Output
host.host_open(&app.bar, &app.shared, o, build_bar, app)

// in the build, each frame: only the bar takes the pointer
platform.set_input_region(app.bar.win, {{bar_x, bar_y, bar_width, bar_height}})
```

Without gt:host:

```odin
w := platform.open_overlay("cliche", area)
if w == nil { /* the system has no overlay window: use a normal window */ }
render.init_window(&r, w, w.size, transparent = true)
```

| Procedure | |
|---|---|
| `open_overlay(title, area, user = nil, on_frame = nil) -> ^Window` | opens and shows the overlay over the output at `area`. nil when the system has no such window. |
| `set_input_region(w, rects)` | only `rects` take the pointer. Window-relative logical pixels. Empty: no part of the window takes it. |
| `open_overlay(title, area, keyboard)` | `keyboard`: `.On_Demand` (default) takes the keyboard once clicked, for a bar of buttons over a desktop still in use; `.Exclusive` takes it from its showing until it goes, for a selection read with Escape, the arrows and Enter. `host.Open_Options.overlay_keyboard` passes it. |
| `clear_input_region(w)` | the whole window takes the pointer again. |
| `overlay_move(w, area) -> bool` | moves the overlay over the output at `area`, at its size and scale (Windows, X11). False on Wayland: a layer surface stays on its output, so close it and open another. |
| `is_overlay(w) -> bool` | the window was opened with `open_overlay`. |
| `overlay_output_index(outputs, area) -> int` | the output an area names (pure; see below). |

## The output

`area` is x, y, width and height of the output to cover, in the desktop's logical coordinates: the ones that
`gt:capture` gives (`capture.Output.rect`). If all four are zero, the system chooses the output. The output is
chosen in this order:

1. the output whose place is `area`;
2. the output that holds the centre of `area`;
3. the output that overlaps `area` most.

The overlay's size is its output's. `set_size` does nothing on an overlay.

## The input region

The rects are in logical pixels, relative to the window: physical pixels divided by `dpi_scale`. Set the region again
when the bar moves. The region stays until the next call.

## The systems

| System | Window | Input region |
|---|---|---|
| Wayland | `zwlr_layer_shell_v1` surface: layer `overlay`, anchored to the four edges, exclusive zone -1, keyboard `on_demand` (version 4; before it, no keyboard) or `exclusive`. The surface is composited with its alpha (`Surface_Handles.see_through`: the renderer picks a premultiplied mode the surface offers), so what it does not draw shows the windows below. The output is matched with `zxdg_output_v1`. | `wl_surface.set_input_region`. The surface is committed at once so the region applies without a new picture; a repaint is also asked for. |
| X11 | override-redirect window with a 32-bit visual, over the RandR monitor, raised on map. A click gives it the keyboard (`SetInputFocus`). | XFIXES region set as the SHAPE extension's input shape. Without XFIXES the whole window takes the pointer. |
| Windows | `WS_POPUP` with `WS_EX_TOPMOST`, `WS_EX_TOOLWINDOW`, `WS_EX_NOACTIVATE`, `WS_EX_NOREDIRECTIONBITMAP`, over the monitor. A click makes it the foreground window. | `SetWindowRgn` with the union of the rects. The region also clips what is drawn: draw only inside it. |

Limits:

- Wayland: a compositor without the layer shell (GNOME) has no overlay window: `open_overlay` returns nil.
- X11: without a compositing manager, the transparent parts show black. A window that the window manager raises later
  can cover the overlay.
- X11 has no logical pixels: `area` is in root pixels.

## gt:host

`Open.overlay` opens the window with `open_overlay`, at `Open.overlay_area`. The window is shown at once. Its frames are
cleared to transparent whatever `Host.background` says: only what the build draws shows. An overlay can be the program's
first window or a later one.

Tests: `tests/overlay` (the output an area names, the monitors' logical places, the input region in physical pixels).
No window opens.

## Popups over native child views

When a program embeds a native child window inside its layout (for example, a Windows WebView2 child HWND), call
`ui.native_child(box)` each frame on the box that holds it. `gt:host` automatically places the main DirectComposition
surface below child windows (`render.set_under_children`), draws any overlapping tooltips, menus, toasts, text-reveal
bubbles, floating views, and dialogs on a second `topmost = TRUE` DirectComposition surface of the same window (with
full premultiplied alpha and unclipped drop shadows), and routes pointer input over interactive intersections through an
invisible owned input shield (`platform.set_native_input_shield`, hidden when idle or when only tooltips are shown).

| Procedure | |
|---|---|
| `ui.native_child(b)` | Registers `b` as hosting a native child window for the current build. |
| `ui.has_native_children(s) -> bool` | True when the last build registered a visible native child box. |
| `ui.has_native_overlay(s) -> bool` | True when an overlay element visually overlaps a native child (including drop-shadow reach). |
| `ui.native_child_rects(s) -> []ui.Rect` | Visible native child rectangles from the last build. |
| `ui.native_input_rects(s) -> []ui.Rect` | Window-pixel rectangles where interactive overlays need pointer input above native children. |
| `ui.draw_tree_base(s, dc)` / `ui.draw_tree_overlay(s, dc)` | Draws the base layer (up to the last native child's root ancestor) and the overlay layer separately. |
| `platform.set_native_input_shield(w, rects)` | Updates the Windows invisible input shield to `rects` (physical client pixels; empty hides it; no-op on Linux). |

Why: [src/md/features/popup-over-native.md](../src/md/features/popup-over-native.md).
