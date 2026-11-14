# Marks on a scroll bar (`ui.scroll_marks`)

A view's vertical scroll bar can carry marks, as the overview ruler at the side of a code editor. Each mark is an item
that counts: a prompt in a conversation, a heading in a document, a day in a journal. Each mark is a short bar across the
track, at the height where its item stands in the content. The marks and the bar are one column: no second rail beside it.

- The marks within the thumb's span are drawn over it, a little brighter. They say where the view is among the marks.
- Marks closer than 6 px are drawn as one, the same as a single mark: a dense content shows at most one mark every 6 px.
- The bar is wider than a plain bar, and it widens more under the pointer and while its marks have the keyboard.
- The pointer over a mark makes it larger and shows the item's card beside the bar: its name (`label`, "#12") in the
  accent, when it was made (`time_ms`, as `timefmt.moment` says it: "today 14:32", "yesterday 09:10", "Nov 10, 14:32")
  and the first three lines of its text, wrapped, the last one ending in "…" when there is more. Over a merged mark, the
  card has a line for each of its items (five at most, then how many more): its name, its first line, its time ("14:32",
  "yesterday", "Nov 10"). The keyboard's mark shows its card too.
- A press on a mark puts its item at the top of the view at once. The view does not glide: on a long content, a glide is
  a wait. The marks then have the keyboard.
- A mark under the thumb is the thumb's: a press there drags the thumb. A press on the track away from any mark does what
  it does on every bar.
- The wheel over the bar scrolls the view, as over the view.
- The keyboard: Up and Down go from mark to mark. Home and End go to the first and the last mark. Enter or Space jumps.
- The filter: the magnifier button above the bar, or a character typed while the marks have the keyboard, opens a field
  beside the button. Only the marks whose text holds every word typed stay on the bar. Up, Down and Enter work in the
  field too. Escape empties the filter and closes the field.

`src/ui/scroll_marks.odin` (the bar's part is in `src/ui/scrollbar.odin`); the scenario test is
`tests/scenarios/scroll_marks_test.odin`.

## Use

The times are read on the program's clock: `Scroll_Marks_Options.now_ms` (now, ms since 1970; 0: dates shown whole) and
`hours12`. The local clock's offset is the toolkit's (`timefmt.local_offset_minutes`): the program passes none.

The program keeps a `ui.Scroll_Marks` between builds. It gives the marks when its items change, with a version of its own,
and it gives each mark's place at each build, where it already goes over its items:

```odin
marks: ui.Scroll_Marks                                     // the program's; ui.scroll_marks_destroy frees it

if ui.scroll_marks_stale(&marks, version) {                // the items changed
	ui.scroll_marks_set(&marks, version, items)            // []ui.Scroll_Mark{id, text, label, time_ms, weak}: copied
}
if i := ui.scroll_marks("###marks", &marks, ui.prev_box("###doc"), {name = "Headings"}); i >= 0 {
	focus_item(ui.scroll_marks_id(&marks, i))              // the view jumped to mark i in this build
}
ui.next({width = ui.fill(), height = ui.fill()})
if ui.scroll_y("###doc") {
	lz := ui.lazy_begin()
	k := 0
	for item in items {
		if item.heading { ui.scroll_marks_place(&marks, k, lz.y); k += 1 }   // where the item starts in the content
		if ui.lazy_item(lz, item.id) { ... }
	}
}
```

- `ui.scroll_marks(id, marks, view, options) -> int` puts the marks on the vertical bar of the scroll box `view`: the last
  build's (`prev_box`), or the one being built. `id` is the filter's button, built over the view above the bar: it is
  the marks' own box, the keyboard's stop and what a screen reader reads. The result is the mark that the view jumped to
  in this build, or -1. The program can give the keyboard to that item. A view whose content fits shows no bar, and no
  marks.
- `Scroll_Marks_Options`: `name` (what a screen reader calls the marks; "" is "Marks"), `margin` (pixels left above an item
  that the view jumps to; 0 is half a line).
- `ui.scroll_marks_set(marks, version, items)` copies the marks, in the order of their items in the content. `weak` marks
  a lesser item: its mark is shorter and fainter. `ui.scroll_marks_stale(marks, version)` says that other marks are kept.
- `ui.scroll_marks_place(marks, i, top)` gives where mark `i` starts in the view's content at this build. A lazy column's
  `Lazy.y` before its item is that place, built or not. Out of range, it does nothing.
- `ui.scroll_marks_id`, `ui.scroll_marks_shown` (the marks that the filter keeps, by index), `ui.scroll_marks_query` (the
  filter's text) and `ui.scroll_marks_at` (where a mark is on the bar, in window pixels) are for the program and its tests.

## Give them before the view's content

Call `scroll_marks` before the view's content: before the view, with `prev_box`, or first in its block. A jump then moves
the view before the content is built, and the lazy column builds the items at the new place in the same build. Called
before the view, the marks also take Up and Down before keys that the program reads for the view.

The filter's button and its field are built at the window's root. They show over what is built after them.

## What it costs

The marks are copied and filtered only when they change or when the filter changes. They are merged only when they, their
places, the filter, the content's height or the bar's length change. At each build, the bar reads only the marks near the
pointer: the marks are in the content's order, so it finds them with a binary search. The drawing reads each merged mark
once: no more than the bar has room for. The places are the program's: it gives them where it already goes over its items,
so the marks add no pass over the content.

Tags used: `scroll_marks`; its field has `input`. Colours: a mark is a thin tick (2 px, short of the track's sides) in a
muted `accent` (a weak mark fainter, and shorter). The marks within the thumb's span are drawn over it, a little brighter:
they say where the view is. The mark under the pointer and the keyboard's are the full `accent`, twice as tall, across the
track. The track at rest is a lighter `track` (flat: a tint of `text`); the thumb is a plain bar's, without its grip lines.
The magnifier is `weak text`, `accent` under the pointer and while a filter is typed. With `set_scrollbar_autohide`, a bar
with marks still shows.
