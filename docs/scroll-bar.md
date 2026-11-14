# The scroll bar

Every view of the toolkit that scrolls has the same scroll bar: a box with `.View_Scroll_Y` or `.View_Scroll_X` (`scroll_y`,
lists, menus that scroll, the palette, a terminal's scrollback), a `text_edit`, a bar with marks
([scroll-marks.md](scroll-marks.md)). Its form is the scroll bar of a desktop (ShojiWM's, after Windows 7): a trough, an
arrow button at each end, a thumb with a gradient across it and a grip. Why it is so: the intent,
[src/md/features/scroll-bar.md](../src/md/features/scroll-bar.md).

A row of choices (tabs, chips) has no bar: it is a strip ([strip.md](strip.md)), which scrolls with arrows over its
edges.

## What it shows

A bar shows while the content is longer than the view, and only then. By default it never hides. With
`scrolling.scrollbar_autohide` on (`ui.set_scrollbar_autohide(s, true)`), a bar shows only while its view moves, while
the pointer is over its box, while it is held, and for a moment after `ui.scrollbar_reveal(box)` (call it when the keyboard
moves a view); it fades otherwise, and the pointer that comes over the box brings it back. A bar with marks always shows.

- **Rest**: the trough, the thumb with a quiet border and a dark grip, a triangle at each end.
- **Lit**, while the pointer is over the bar or a part of it is held: the arrow buttons get their border and their fill,
  the thumb the theme's accent and a light grip.
- **Hot**: the arrow button under the pointer takes the accent.
- **Pressed**: the arrow button or the thumb held, a deeper accent.

The colours come from the theme: its surfaces for the trough and the thumb at rest, its accent for what the pointer
lights. A dark theme gives the desktop's dark bar, a light theme its light bar.

## What it does

| The pointer | The view |
|---|---|
| A press on an arrow button | moves one line (a line of the box's font; a text area's line), at once |
| The arrow button held | moves a line again after 400 ms, then every 60 ms, while the pointer is on the button |
| A press on the track | moves one page (the view's length) toward the press |
| The thumb dragged | follows the pointer, also outside the bar; a press with no move moves nothing |
| The wheel over the bar | scrolls the view |
| A press on a mark (a bar with marks) | goes to its item |

The bar takes no key and is not a stop of Tab.

## Its size

| Setting | `ui` | Thickness |
|---|---|---|
| `scrolling.scrollbar_size` = `thin` (the default) | `ui.set_scrollbar_size(s, .Thin)` | 9 px |
| `scrolling.scrollbar_size` = `wide` | `ui.set_scrollbar_size(s, .Wide)` | 17 px |

The pixels are multiplied by the window's scale (the system's scale times the zoom) and kept odd: 25 px for wide at
150 %. Each arrow button is a square as long as the bar is thick. A bar shorter than three thicknesses has no arrow
button. The thumb is at least 8 % of the track, and at least as long as the bar is thick.

## Where it is

A vertical bar is at the right edge of its box (`.Scrollbar_Left`: the left one), a horizontal bar at its bottom edge,
short of the vertical one, both inside the box's border. In a box with rounded corners, the bar keeps the drawn radius
from each corner. `.Scrollbar_None`: a box that scrolls with no bar and no room for one (a table's titles, which follow
its rows; a strip).

**Nothing is drawn under a bar.** While a bar shows, the scroll box's layout keeps its room: the content is laid out in
the box less the bar (a `fill()` row ends at the bar, a row's right-aligned words and buttons stay left of it), and a box
sized by its children grows by it. This holds for every scroll box (lists, tables, menus, the palette, markdown, the
settings page) and for a `text_edit`; a widget leaves no room for a bar itself. When the content stops overflowing the
room comes back; a content that overflows only beside the bar does not take it, so the room never flickers.

**The room is kept only while the content overflows, by default.** A box that must not narrow when its content grows
past the view (a list that loads more rows, a log that runs) keeps the room while it fits too: give it
`.Scrollbar_Reserve`, as `ui.next({flags = {.Scrollbar_Reserve}})` before the widget (`scroll_y`, `list`, `vlist`,
`text_edit`, a box of your own). The room of each bar the box can show is kept: a vertical bar's for `.View_Scroll_Y`, a
horizontal bar's for `.View_Scroll_X` (a `text_edit` that wraps has none). The bar itself shows only on overflow. With
`scrolling.scrollbar_overlay` no room is kept, reserved or not.

With
auto-hide the room stays: the bar fades in it. `scrolling.scrollbar_overlay` (off by default, `ui.set_scrollbar_overlay`)
draws the bars over the edge of the content and keeps no room. A box outside the scroll box that lines up with its
content (a table's titles) reads `ui.scrollbar_room(box, .X)`.

## API

| Call | What it does |
|---|---|
| `ui.set_scrollbar_size(s, size)` | `Thin` (the default) or `Wide`, for every bar of the State's window. `prefs_page.standard_watch` applies `scrolling.scrollbar_size`; `ui.style_follow` copies it to a view's window. |
| `ui.set_scrollbar_autohide(s, on)` | Off (the default): every bar shows while its content overflows. On: bars hide at rest (above). Setting `scrolling.scrollbar_autohide`. |
| `ui.scrollbar_reveal(box)` | With auto-hide: the box's bar shows for a moment (900 ms), wherever the pointer is. |
| `ui.scrollbar_opacity(s, box)` | How much the box's bar shows, 0 to 1 (1 without auto-hide). |
| `ui.set_scrollbar_overlay(s, on)` | Off (the default): a scroll box keeps its bars' room. On: bars over the content's edge. Setting `scrolling.scrollbar_overlay`. |
| `ui.scrollbar_room(box, axis)` | The room a scroll box keeps for its bars at its last layout: along `.X` a vertical bar's, along `.Y` a horizontal bar's (0: none). |
| `ui.scrollbar_gutter()` | A bar's thickness, in pixels. |
| `ui.scrollbar_rects(box, axis)` | The track and the thumb a scroll box shows (`ok` false: everything fits), window pixels. For tests and tools. |
| `ui.scrollbar_arrow_rects(box, axis)` | Its arrow buttons, at the start and at the end (`ok` false: no bar, or a bar too short for them). |
| `ui.scrollbar_under(box, point)` | Which bar of a box takes a press at a point: a program that hears the pointer before the interface (a terminal's grid) leaves that press to the bar. |
| `ui.scrollbar_paint(s, dc, box, parts, look)` | Draws a bar at any place, in a state (`Scrollbar_Parts`, `Scrollbar_Look`): for a widget that scrolls itself. `text_edit` uses it. |

The former set_scrollbar_arrows and the setting `scrolling.scrollbar_arrows` are gone: the arrows are part of the bar. The
setting `scrolling.autohide_scrollbars` is now `scrolling.scrollbar_autohide`.

## Tests

`tests/scenarios/scrollbar_test.odin`: by default a bar always shows while the content overflows (by its pixels, the
pointer away for seconds); with auto-hide it is hidden at rest and shows while its view moves or the pointer is over it, the two sizes, an arrow steps a line, a held arrow repeats by the standard's times on the session's clock
(`session.advance`, no wait), a press on the track pages, a press on the thumb with no move moves nothing, the states by
their pixels, a row's right-aligned button left of the bar, no oscillation at the threshold, the overlay option.
`tests/ui_robust` holds the geometry at 100 % and 200 %; `tests/keyboard/text_edit_keys_test.odin` a text
area's bars.
