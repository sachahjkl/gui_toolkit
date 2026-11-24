# The wheel and the touchpad in a program

Most boxes take the wheel themselves: a scroll view scrolls, a number field steps, a preview zooms. One box takes the
wheel of a build: the innermost under the pointer that scrolls the way the wheel goes. This page is for a program that
reads the wheel or the touchpad itself. The design: [src/md/features/wheel-owner.md](../src/md/features/wheel-owner.md)
and [src/md/features/swipe.md](../src/md/features/swipe.md).

## The wheel that no box took

`ui.wheel_consumed()` says whether a box took the wheel of this build. `ui.wheel_free()` gives the wheel that no box
took, in notches as `platform.Event.delta` (`+y` scrolls the content down), and the modifiers held with it:

```odin
if d, mods := ui.wheel_free(); .Shift in mods && d.y != 0 {
	viewer_go(app, d.y > 0 ? 1 : -1)   // Shift+wheel: the next or the previous picture
}
```

Two flags leave part of the wheel to what is around a box that scrolls itself (`.Scroll_Self`):

| Flag | Over the box |
|---|---|
| `.Ctrl_Wheel` | Ctrl+wheel is the box's (a zoom of its content), not the interface's zoom |
| `.Shift_Wheel_Free` | Shift+wheel goes to the box around it that scrolls, else to the program (`wheel_free`) |

`ui.preview` sets `.Shift_Wheel_Free` with `Preview_Options.shift_wheel_free` ([preview.md](preview.md)).

## A swipe on the touchpad

`ui.swipe_step(&sw, area)` reads a horizontal swipe of the fingers in `area` as one step: +1 when the fingers scroll
the content to the right (the next), -1 to the left, else 0. Call it once per build; the program keeps the
`ui.Swipe`.

```odin
app.swipe: ui.Swipe
view := ui.build_box({}, "###view")
if step := ui.swipe_step(&app.swipe, view.rect); step != 0 { viewer_go(app, step) }
```

- One step per gesture, when the gesture's x sum passes `SWIPE_STEP_NOTCHES` (4 notches) and is `SWIPE_ACROSS_RATIO`
  (2) times its y sum.
- A gesture ends when the fingers lift (Wayland), or after `SWIPE_PAUSE_MS` (150 ms) with no finger scroll.
- A wheel's notches never count. `platform.Event.scroll_source` (`.Wheel`, `.Finger`) says what made a scroll:
  Wayland says it; on Windows a delta that is not a whole notch counts as fingers; X11 gives notches only, so no swipe.
  `Event.scroll_end` says the fingers left the touchpad.
- Ctrl with the fingers is a pinch (Windows): no swipe.

The deltas still reach the box under the pointer that scrolls. A viewer whose area scrolls sideways reads one or the
other.

## In a test

`session.finger_scroll(s, at, delta)` scrolls with fingers (`.Finger`); `session.wheel(s, at, notches)` turns a wheel.
`session.finger_lift(s)` lifts the fingers. `session.advance(s, ui.SWIPE_PAUSE_MS)` makes the pause.
`tests/scenarios/swipe_test.odin` and `tests/preview` test them.
