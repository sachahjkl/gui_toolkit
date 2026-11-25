# A window carried by a drag (Wayland)

Tearing a tab off a window makes a window that follows the pointer and can dock in another window. On Windows and X11
the program moves the window itself, from the pointer's screen position. On Wayland a client cannot move a window, and it
knows neither the pointer's screen position nor the windows' order.

## The design

- `drag_start` takes a `Drag_Carry`: a window of the same thread and connection, and where the pointer holds it
  (`grab`, in window pixels from its top left). When the compositor offers `xdg_toplevel_drag_manager_v1`, the drag's
  `wl_data_source` gets an `xdg_toplevel_drag_v1` before `start_drag`, and the window's `xdg_toplevel` is attached to it
  with `grab` scaled to surface-local logical coordinates (`grab / dpi_scale`). The compositor moves the window as if
  `xdg_toplevel.move` ran.
- Both a newly detached window and the source window itself (`carry.window == w`, a single-tab window) can be attached.
  A hidden non-overlay window is shown first so its `xdg_toplevel` exists.
- The `xdg_toplevel_drag_v1` is destroyed on `dnd_drop_performed` or `cancelled`, before `wl_data_source.destroy`:
  destroying it while the drag runs is the protocol's `ongoing_drag` error, and destroying `wl_data_source` while a
  toplevel is still attached is undefined.
- `drag_start` blocks its thread, so the carried window could draw no frame. `Drag_Carry.frame` is called right after
  `start_drag` (so a newly shown window commits its first buffer without waiting for a poll timeout) and on each turn of
  the drag's loop while it runs.
- Without the global (sway, older compositors), `carry` is ignored and `drag_carry_supported` is false. The program
  makes the window at the drop, where the compositor places it.
- Windows, X11, and other systems ignore `carry`: their programs move the window themselves.

## Refused

- Moving the window with `xdg_toplevel.move` from the program: it needs a press on that window, and the press is on the
  source window.
- A drag image showing the tab, then a window at the drop: kept as the fallback only. It shows a picture, not the window
  the user will get.
