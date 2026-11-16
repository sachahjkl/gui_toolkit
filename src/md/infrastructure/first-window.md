# The first window can close

The first window a program opens holds what its windows share: the renderer and its device, the fonts, the theme, the
views. Closing it ended all of that, so a program could never close its first window while it had others. Cliche shows
why that matters: started from the tray, its first window is the region's overlay, a Wayland layer surface that cannot
move to another output. It had to stay on the output of the first capture, because closing it and opening another
would have ended the renderer.

## The constraint, reduced

What makes the first window special is one thing: the renderer draws on the first window's swap chain (its own
`Window_Target`), and every other window on a `Surface` that `surface_use` exchanges with it. The rest (fonts, theme,
`Shared.main` for `ui.use`, the pacer) belongs to the program, not to one window.

A `Surface` and the renderer's own target are the same `Window_Target`. That is the whole answer.

## Decision: the renderer passes to another window

`host_close` of the first window, while another window with a surface is open, hands over instead of ending:

1. It picks the next window that has a surface (not a headless one: it has none).
2. It exchanges that window's `Surface` with the renderer's target, for good: the renderer now draws on that window as
   its own, and the `Surface` holds the closing window's swap chain.
3. It destroys that `Surface`, as `host_close` destroys any other window's.
4. The other window becomes `Shared.main`: it is paced, `ui.use` falls back to its state, and its `surface` is no
   longer valid (the first window's never is).

The closing window's `ui.State` is destroyed as any window's. The views stay in `Shared.views`: they are the program's.
A view whose window was the closing one closes with it, as it did.

When no other window has a surface, `host_close` ends everything, as before. A headless first window (the offscreen
renderer) never hands over: its renderer has no window to give.

## Refused

- **A renderer with no window of its own,** every window on a `Surface`. It removes the special case at its root, but
  it changes how every renderer starts (Direct3D 11 without a swap chain at `init`, WebGPU without a surface to choose
  its adapter with, which `no-graphics.md` relies on), for a case one program meets. The hand-over reaches the same
  result with the exchange that already exists.
- **A hidden first window kept alive** by the program. It is a window the program must manage and the system lists,
  for a limit of the toolkit.

## Subtle points

- Direct3D 11: a swap chain made with `fixed_size` keeps it when it moves into the renderer; `set_fixed_surface` is a
  field of the target, so it moves with it.
- The hand-over happens outside any build (`host_close` already asserts it).
- A program reads `Shared.main` after a close: it may be another window than before. Cliche's checks
  (`app.shared.main == &o.host`) stay true for the window that holds the renderer now.

## The test that breaks it

Open a window, open a second, draw both, close the first, draw the second again and read its pixels: they must be the
second window's frame. Then close the second: nothing is left (no leak report).
