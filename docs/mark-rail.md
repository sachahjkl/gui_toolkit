# A rail of marks beside a view (`ui.mark_rail`)

A narrow rail beside a view that scrolls, as the small map at the side of a code editor. It has a dot for each item that
counts: a prompt in a conversation, a heading in a document, a day in a journal. Each dot is at the height where its item
stands in the view's content. A band over the rail shows the part that the view shows.

- The pointer over a dot shows the item's first line, beside the rail.
- A press on a dot puts its item at the top of the view at once. The view does not glide: on a long content, a glide is a wait.
- A press elsewhere on the rail puts that part of the content in the middle of the view. A drag goes along.
- The wheel over the rail scrolls the view, as over the view.
- The keyboard: Up and Down go from mark to mark. Home and End go to the first and the last mark. Enter or Space jumps.
- The filter: the magnifier at the top of the rail, or a character typed on the rail, opens a field at the rail's left.
  Only the marks whose text holds every word typed stay on the rail. Up, Down and Enter work in the field too. Escape
  empties the filter and closes the field.

`src/ui/mark_rail.odin`; the scenario test is `tests/scenarios/mark_rail_test.odin`.

## Use

The program keeps a `ui.Mark_Rail` between builds. It gives the marks when its items change, with a version of its own,
and it gives each mark's place at each build, where it already goes over its items:

```odin
rail: ui.Mark_Rail                                         // the program's; ui.mark_rail_destroy frees it

if ui.mark_rail_stale(&rail, version) {                    // the items changed
	ui.mark_rail_set(&rail, version, marks)                // []ui.Rail_Mark{id, text, weak}: copied
}
ui.next({fixed_x = x, fixed_y = 0, width = ui.px(em * 1.5), height = ui.px(h)})
if i := ui.mark_rail("###rail", &rail, ui.prev_box("###doc"), {name = "Headings"}); i >= 0 {
	focus_item(ui.mark_rail_id(&rail, i))                  // the view jumped to mark i in this build
}
ui.next({width = ui.fill(), height = ui.fill()})
if ui.scroll_y("###doc") {
	lz := ui.lazy_begin()
	k := 0
	for item in items {
		if item.heading { ui.mark_rail_place(&rail, k, lz.y); k += 1 }   // where the item starts in the content
		if ui.lazy_item(lz, item.id) { ... }
	}
}
```

- `ui.mark_rail(id, rail, view, options) -> int` builds the rail in a box of the size that `next` gives. `view` is the
  scroll box of the last build (`prev_box`). The result is the mark that the view jumped to in this build, or -1. The
  program can give the keyboard to that item.
- `Mark_Rail_Options`: `name` (what a screen reader calls the rail; "" is "Marks"), `margin` (pixels left above an item
  that the view jumps to; 0 is half a line), `no_filter`, `filter_w` (the field's width in pixels; 0 is 16 lines' height).
- `ui.mark_rail_set(rail, version, marks)` copies the marks, in the order of their items in the content. `weak` marks a
  lesser item: its dot is smaller and fainter. `ui.mark_rail_stale(rail, version)` says that the rail has other marks.
- `ui.mark_rail_place(rail, i, top)` gives where mark `i` starts in the view's content at this build. A lazy column's
  `Lazy.y` before its item is that place, built or not. Out of range, it does nothing.
- `ui.mark_rail_id`, `ui.mark_rail_shown` (the marks that the filter keeps, by index), `ui.mark_rail_query` (the filter's
  text) and `ui.mark_rail_dot` (where a mark's dot is, in window pixels) are for the program and its tests.

## Build it before the view

Build the rail before the view's content when the layout lets you: a floating rail (`fixed_x`), with a spacer that keeps
its room after the view. A jump then moves the view before the content is built, and the lazy column builds the items at
the new place in the same build. A rail built after the view jumps too, but the content shows its new place one build later.

The filter's field is built at the window's root. It shows over what is built after the rail.

## What it costs

The rail copies and filters the marks only when they change or when the filter changes. At each build, it reads only the
marks near the pointer: the marks are in the content's order, so it finds them with a binary search. The drawing reads
each mark shown once, with the places of the build that it draws. The places are the program's: it gives them where it
already goes over its items, so the rail adds no pass over the content.

Tags used: `mark_rail`; its field has `input`. Colours: the dots are `weak text`, a dot under the pointer is `text`, the
keyboard's dot on a focused rail is `accent`, the line is `border`, the band is a tint of `text`.
