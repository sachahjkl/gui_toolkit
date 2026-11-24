# Middle-click autoscroll (`ui.autoscroll_*`)

Autoscroll is the "press the wheel, then move to scroll" mode that Chrome, Firefox and Edge give on Windows: a middle
click on a scrollable area drops an anchor, and how far the pointer is from that anchor sets the scroll speed — the
farther, the faster, along an acceleration curve. A marker is drawn at the anchor and the cursor shows the direction.

There are two layers:

- a **pure** core (`src/ui/autoscroll.odin`): the `Autoscroll` state, the acceleration curve and the engage/latch/end state
  machine. It has no window or box dependency, so it can be unit tested on its own (`tests/autoscroll`) and reused by an
  application for its own document view (for instance a web page, which does not live in the box tree).
- the toolkit's **wiring** of its scroll regions (`src/ui/autoscroll_region.odin`): a middle press on a box with
  `.View_Scroll_X` / `.View_Scroll_Y` starts a session, every frame its velocity is integrated into the box's scroll
  target, the marker is drawn and the cursor follows.

## The toolkit's scroll regions

On by default: every scroll region of every program takes the wheel's click. A box that handles the middle button
itself keeps it: give it `.Middle_Click` (a link that opens in a new tab, a tab that closes). A middle press on it, or
on a box inside it, starts no autoscroll, and `signal(b).middle_clicked` is true at the release. A middle press
elsewhere (on text, on the background, on a clickable box without the flag) starts autoscroll. The design:
[src/md/features/middle-press.md](../src/md/features/middle-press.md).

```odin
link := ui.build_box({.Clickable, .Middle_Click}, "###link")
if ui.signal(link).middle_clicked { open_in_new_tab(url) }
```

A box of which only a part takes the middle button sets `Box.middle_at` after `build_box` (it is reset each build): the
region asks it at a middle press, with the point in window coordinates. It runs before the next build, when the last
build's frame memory is gone (`Box.text`, `Box.custom_user`): it reads the box's rect and what its widget keeps across
builds. A `rich_paragraph` with links sets it: a middle
press on a link is the link's (`Rich_Result.link_middle_clicked` at the release), a middle press on its plain text starts
autoscroll.

```odin
row := ui.build_box({.Clickable}, "###row")
row.middle_at = proc(b: ^ui.Box, p: ui.Vec2) -> bool { return p.x > b.rect.max.x - 40 }   // (its right end only)
```

A program whose middle button does something else everywhere in a scroll region turns autoscroll off once after `init`:

```odin
ui.set_autoscroll_enabled(&s, false)
// optional: tune the curve
ui.set_autoscroll_settings(&s, ui.Autoscroll_Settings{
	dead_zone = 12, max_speed = 15000, full_dist = 300, doubling = 60,
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

A session also ends on Escape, a wheel notch, the pointer leaving the window, a press on the window's frame (`Event.Frame_Press`), the window moving or losing the user, the system taking the pointer (`Event.lost`), or the scrolled area going away.

## The acceleration curve (`autoscroll_axis_speed`)

Pure and fully parameterised. For a pointer offset `off` (px) from the anchor on one axis it returns a speed in scroll
units per second:

- **Dead zone**: `|off| <= dead_zone` → `0` (a disc of stillness around the anchor).
- past it, the speed grows **geometrically** with the distance. With `x = clamp(|off| - dead_zone, 0, full_dist)`, `D = doubling`,
  `F = full_dist` and `V = max_speed`:

  ```
  speed(x) = V * (2^(x/D) - 1) / (2^(F/D) - 1)
  ```

  Every `D` px farther from the anchor multiplies the speed by 2 (exactly: `speed + c` doubles, `c = V / (2^(F/D) - 1)`; the
  `- 1` only makes the curve start at 0). Near the anchor it is gentle, far out it climbs by a constant factor per distance.
  With the defaults (`D = 60`, `F = 300`, `V = 15000`), x px past the dead zone: 484 px/s at 60, 1452 at 120, 3387 at 180, 7258 at 240, 15000 at 300 (`F`). A `doubling` much larger than `full_dist` tends to the straight line
  `x / F * V`.
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

## A selection dragged to an edge (`ui.drag_autoscroll`)

A selection that the person drags near or past the edge of a scroll view scrolls that view, so a selection can span
several screens. Near means in a band of 2 em inside the edge. The speed is the curve above with no dead zone, of the
distance past the inner edge of the band, from a floor: 600 px/s as soon as the pointer is in the band, about 830 px/s
at the edge, 3000 px/s 100 px past it, 8000 px/s from 170 px past it (`DRAG_AUTOSCROLL`; `Autoscroll_Settings.min_speed`
is the floor). The view is the innermost one around the dragged box that can still scroll that way, so a list
in a page scrolls to its end, then the page.

The toolkit's selecting drags already do it: the selection of `.Selectable` text (labels, paragraphs, rich text,
`markdown`, `diff`), `text_edit`, `line_edit` and the terminal's grid (`gt:term`). A widget of a program marks its own
selecting drag with one call in each build while the drag is held, then turns the pointer into its selection's moving
end as usual. The mark lives one build: when the widget stops calling, the scroll stops.

```odin
sig := ui.signal(b)
if sig.dragging {
	ui.drag_autoscroll(b.key)            // .Both by default; .Y or .X for one axis
	extend_selection(view, ui.mouse_pos())
}
```

A widget that scrolls itself (`.Scroll_Self`) moves its own offset with `ui.drag_autoscroll_own`. An axis its own
offset cannot move that way goes to the views around it:

```odin
// view: the text's rect in window coordinates; scroll: [2]f32 within 0 .. limit
if sig.dragging && !sig.pointer_pressed {
	ui.drag_autoscroll_own(b.key, view, &my.scroll, limit)
}
```

`ui.drag_autoscroll_speed(p, lo, hi, band)` is the pure speed of one axis, for a view outside the box tree. Nothing
scrolls while a middle-click session runs.

## The cursor (`autoscroll_cursor`)

`All_Scroll` inside the dead zone, then the directional resize cursor nearest the offset (the eight compass directions,
restricted to the axes the area scrolls). A platform whose cursor set lacks these can fall back to `All_Scroll` for the
whole session.
