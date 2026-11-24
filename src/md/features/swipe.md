# Swipe

A viewer goes to the next or the previous picture when a person swipes two fingers across the touchpad. The code is
`src/ui/swipe.odin`; the source of a scroll is in `src/platform`.

## The step

A swipe is one step, not a scroll. `ui.swipe_step` sums the x and y deltas of one gesture. It gives +1 or -1 once,
when the x sum passes `SWIPE_STEP_NOTCHES` and is `SWIPE_ACROSS_RATIO` times the y sum. It gives no other step until
the gesture ends. A long swipe is still one picture: a person who wants three pictures swipes three times.

The ratio keeps a vertical scroll that drifts sideways from stepping. The sum starts again with each gesture, so a
drift does not build up across gestures.

## The end of a gesture

A gesture ends in two ways:

- The fingers leave the touchpad: `Event.scroll_end`. Only Wayland says it (`wl_pointer.axis_stop`).
- No finger scroll comes for `SWIPE_PAUSE_MS` (150 ms). Windows sends its own inertia after the lift as more deltas:
  only the pause ends a gesture there.

The pause is read when the next delta comes, not by a timer. An idle program makes no build, and it needs none: the
first delta after the pause starts a new gesture. A build that takes longer than the pause in the middle of a gesture
splits it in two; a build does not take that long.

## Fingers, not a wheel

`Event.scroll_source` says what made a scroll. Only `.Finger` deltas count (`State.swipe_delta`); a wheel's notches
never do, whatever their sum. Each platform says it as well as it can:

- Wayland: `wl_pointer.axis_source` is `finger`. The axis events of one pointer frame become one Scroll event,
  because the source can come after the axis in the frame. A pointer older than version 5 has no frame and no source:
  each axis event goes alone, as a wheel's.
- Windows: `WM_MOUSEWHEEL` does not say its source. A delta that is not a whole notch (120 units) counts as fingers. A
  high-resolution wheel that spins free counts too; a notched wheel and a tilt wheel do not.
- X11: the core events give notches only (buttons 4 to 7). No swipe. XInput 2's smooth-scroll valuators can give it.

Ctrl with the fingers is a pinch on Windows: it zooms, and it is no swipe.

## Refused

- A step per threshold passed (one gesture, several pictures): a viewer that skips pictures on a long swipe.
- A gesture API of the system (Windows' Direct Manipulation, Wayland's pointer gestures): they give pinch and three
  fingers, not the two-finger scroll that browsers read as a swipe.
- A timer that ends the gesture: the next delta reads the pause.
