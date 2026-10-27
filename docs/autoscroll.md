# Middle-click autoscroll (`ui.autoscroll_*`)

Autoscroll is the "press the wheel, then move to scroll" mode that Chrome, Firefox and Edge give on Windows: a middle
click on a scrollable area drops an anchor, and how far the pointer is from that anchor sets the scroll speed — the
farther, the faster, along an acceleration curve. A marker is drawn at the anchor and the cursor shows the direction.

There are two layers:

- a **pure** core (`ui/autoscroll.odin`): the `Autoscroll` state, the acceleration curve and the engage/latch/end state
  machine. It has no window or box dependency, so it can be unit tested on its own (`tests/autoscroll`) and reused by an
  application for its own document view (for instance a web page, which does not live in the box tree).
- the toolkit's **wiring** of its scroll regions (`ui/autoscroll_region.odin`): a middle press on a box with
  `.View_Scroll_X` / `.View_Scroll_Y` starts a session, every frame its velocity is integrated into the box's scroll
  target, the marker is drawn and the cursor follows.

## Turning it on for the toolkit's scroll regions

Off by default, so adding the toolkit never changes an app's middle-click behaviour silently. Opt in once after `init`:

```odin
ui.set_autoscroll_enabled(&s, true)
// optional: tune the curve
ui.set_autoscroll_settings(&s, ui.Autoscroll_Settings{
	dead_zone = 12, max_speed = 2800, full_dist = 420, exponent = 2,
	toggle = true, tap_ms = 250, tap_slop = 4,
})
```

Every `scroll_y`, `list` and `vlist` region then gets autoscroll with no extra code: a middle click inside one starts
it, the pointer offset scrolls, and the usual smooth easing (`set_scroll_settings`) still carries the motion, so it stays
smooth even if a frame is late. The loop keeps asking for frames (`needs_frame`) while a session is live.

## The two modes

Both are live at once, as in the browsers; the toolkit tells them apart from the button and the elapsed time:

- **Hold**: press the wheel, keep it down, move, release. The move ends when the button is released.
- **Toggle**: a quick press and release (shorter than `tap_ms`, with less than `tap_slop` px of movement) latches the
  mode on. It stays on, scrolling as the pointer moves with no button held, until the next click anywhere — that click
  is swallowed (it only ends the mode, as the browsers do).

A session also ends on Escape, a wheel notch, the pointer leaving the window, or the scrolled area going away.

## The acceleration curve (`autoscroll_axis_speed`)

Pure and fully parameterised. For a pointer offset `off` (px) from the anchor on one axis it returns a speed in scroll
units per second:

- **Dead zone**: `|off| <= dead_zone` → `0` (a disc of stillness around the anchor).
- past it, the speed rises with the distance: `t = (|off| - dead_zone) / full_dist`, clamped to `0..1`, then
  `speed = t^exponent * max_speed`. `exponent = 1` is linear; `> 1` eases in near the anchor and climbs steeply far out;
  `< 1` is the opposite.
- **capped** at `max_speed`, reached `full_dist` px past the dead zone.
- **symmetric**: `f(-off) == -f(off)`.

Because it is a *speed*, the caller integrates it against its own frame `dt`, so the travel is the same at 60 Hz and at
180 Hz. `autoscroll_velocity` returns the vector for the axes the area offers (`Autoscroll_Axes`: `Y`, `X` or `Both`).

## Using the core directly (an application's own view)

```odin
auto: ui.Autoscroll
cfg := ui.DEFAULT_AUTOSCROLL

// a middle press on a scrollable region, at pointer `p`:
ui.autoscroll_begin(&auto, p, .Both, held = true, now_ms = clock_ms)

// every frame, with the latest pointer:
ui.autoscroll_point(&auto, pointer)
v := ui.autoscroll_velocity(&auto, cfg)   // scroll units / second
my_scroll += v * f32(dt)                   // integrate against your dt
set_cursor(ui.autoscroll_cursor(&auto, cfg))

// the middle button came up: a tap latches toggle mode, otherwise hold mode ends
if !ui.autoscroll_release(&auto, cfg, now_ms = clock_ms) { /* ended */ }

// any other click ends a latched session; the returned bool says to swallow that click:
if ui.autoscroll_click(&auto) { /* swallow it */ }

// Escape, a wheel notch, lost capture, a window move:
ui.autoscroll_cancel(&auto)
```

## The cursor (`autoscroll_cursor`)

`All_Scroll` inside the dead zone, then the directional resize cursor nearest the offset (the eight compass directions,
restricted to the axes the area scrolls). A platform whose cursor set lacks these can fall back to `All_Scroll` for the
whole session.
