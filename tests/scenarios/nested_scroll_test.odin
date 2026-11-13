package scenarios_test

// Two views that scroll the same way, one in the other: one bar on that axis, the innermost's.

import "core:fmt"
import "core:strings"
import "core:testing"
import "../../src/markdown"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") VIEW_W :: 400
@(private = "file") INNER_W :: 800   // the inner view's own width: wider than the outer view
@(private = "file") CELLS :: 12
@(private = "file") CELL_W :: 100    // a row of cells wider than both

@(private = "file")
Nested :: struct { doc: markdown.Doc, text: string, markdown: bool }

// The outer view: it scrolls both ways, and lets what it holds be wider than itself.
@(private = "file")
nested_build :: proc(s: ^session.Session) {
	n := (^Nested)(s.user)
	ui.next({width = ui.px(VIEW_W), height = ui.px(300), axis = .Y})
	outer := ui.build_box({.Clip, .View_Scroll_X, .View_Scroll_Y, .Allow_Overflow_X, .Allow_Overflow_Y}, "###outer")
	_ = ui.signal(outer)
	ui.push_parent(outer)
	defer ui.pop_parent()
	if n.markdown {
		markdown.view(&n.doc, "md", n.text, {})
		return
	}
	// a table of its own: a box that scrolls sideways, as wide as the program said, its cells wider still
	ui.next({width = ui.px(INNER_W), height = ui.children_sum(), axis = .X})
	inner := ui.build_box({.Clip, .View_Scroll_X}, "###inner")
	_ = ui.signal(inner)
	ui.push_parent(inner)
	defer ui.pop_parent()
	for i in 0 ..< CELLS {
		ui.next({width = ui.px(CELL_W), height = ui.px(30)})
		ui.label(fmt.tprintf("Cell %d###c%d", i, i))
	}
}

// The boxes that show a horizontal bar, by name.
@(private = "file")
x_bars :: proc(b: ^ui.Box, out: ^[dynamic]string) {
	if b == nil { return }
	if _, _, ok := ui.scrollbar_rects(b, .X); ok { append(out, b.name) }
	for c := b.first; c != nil; c = c.next { x_bars(c, out) }
}

@(private = "file")
one_bar :: proc(t: ^testing.T, n: ^Nested, inner: string) {
	s := session.start(t, {size = {500, 400}, user = n, no_renderer = true, build = nested_build})
	session.frames(s, 4)
	bars := make([dynamic]string, context.temp_allocator)
	x_bars(s.state.root, &bars)
	testing.expectf(t, len(bars) == 1 && bars[0] == inner, "one bar, the %s's: %v", inner, bars[:])
	if b := session.find(s, inner); testing.expect(t, b != nil, "the inner view") {
		testing.expectf(t, b.size.x <= VIEW_W, "the inner view within the outer one: %v", b.size.x)
	}
}

// A view wider than the view that scrolls it the same way: it is held to that view's room and scrolls itself.
@(test)
a_wide_view_in_a_view_has_one_bar :: proc(t: ^testing.T) {
	n: Nested
	one_bar(t, &n, "inner")
}

// A Markdown table wider than its place, in a view that scrolls sideways: the table's bar alone.
@(test)
a_wide_table_in_a_view_has_one_bar :: proc(t: ^testing.T) {
	n := Nested{markdown = true}
	n.doc.alloc = context.allocator
	defer markdown.doc_destroy(&n.doc)
	wide := strings.repeat("word ", 30, context.temp_allocator)
	n.text = strings.concatenate({"Text before.\n\n| A | B | C |\n|---|---|---|\n| ", wide, " | ", wide, " | ", wide, " |\n"}, context.temp_allocator)
	one_bar(t, &n, "hs")
}
