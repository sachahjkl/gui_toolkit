# What changed in gui_toolkit 0.58

For an application on the toolkit (Wren first). 0.57's report is docs/changes-0.57.md. The public API stays compatible, except
`Picker_Draw.ring`, removed because nothing used it. What can change for an application is behaviour:

- **Escape in a dialog**: the dialog takes it after its content. With a field focused, the first Escape leaves the field and the
  second closes the dialog. With nested dialogs the inner one closes first.
- **Sizes that ignored the scale now follow it** (a tab's underline, rings, knobs, the scroll bar's grab). Nothing changes at
  100 %, they are thicker above it.
- **Autoscroll's distances and speed follow the scale**: its feel changes above 100 %.
- **A double click is one duration everywhere**, 450 ms, and `.Hot_Within` reaches 64 ancestors.
- **Partial redraw** works on Direct3D and WebGPU: the region is drawn into a kept target, copied whole to the window. A frame that
  reads itself (a backdrop, a blend mode) is drawn whole. `damage_scroll` redraws where the content was and where it is.
- **`wait_event`** no longer ends at once on events already handed out.
- **DevTools**: what the server cannot do is refused instead of pretending, and `DOM.undo` works.
- **Linux**: X11 copy and paste and drag and drop work, for the first time on X11 for copy and paste. Wayland reads its socket during
  an animation, repeats keys, and a window's wake works. All run on real servers in the CI (`tk desktop_tests`).

New: `platform.window_on_destroy`, `ui.scrollbar_rects`, `render.damage_verify_differences`, `render.capture_poll_raw`,
`render.capture_raw_finish`; `-define:TOOLKIT_DAMAGE_CHECK=true` to check partial frames against whole ones,
`-define:TOOLKIT_RENDER_FAULTS=true` in tests. CHANGELOG.md has the rest.

## What was checked, and what was not

Windows: the whole suite, on Direct3D 11 and on WebGPU. Linux: X11 under Xvfb, RandR on Xorg's dummy driver, Wayland under headless
sway, in an Ubuntu 24.04 tree and in the CI. Not tried: a drag between two different programs on X11, a real system drag on Windows
to another window of the same program, Wren's own tests on this version.
