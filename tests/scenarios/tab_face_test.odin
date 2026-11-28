package scenarios_test

// A program's own tab strip (docs/widgets.md, "Your own tab strip"): its boxes with ui.tab_face, its content in
// ui.tab_body, ui.tab_strip_start before the first tab and the line under the strip draw the same pixels as ui.tabs
// (a Folder, the style of a strip with no tabs_over around it) for the same tabs; a mark lies along the chosen tab's top.

import "core:fmt"
import "core:testing"
import "gt:draw"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file", rodata) FACE_TABS := [?]string{"Files", "Search", "Changes"}
@(private = "file") FACE_MARK :: draw.Color{1, 0, 0, 1}

@(private = "file")
Face_Run :: struct { hand, mark: bool, sel: int }

@(private = "file")
face_build :: proc(s: ^session.Session) {
	r := (^Face_Run)(s.user)
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.px(math_round(em * 2.4)), axis = .X})
	in_row := ui.parent(ui.build_box({}, "###row"))
	if !in_row { return }
	if !r.hand {
		ui.tabs("###tabs", FACE_TABS[:], nil, &r.sel)
		return
	}
	// the program's own: what ui.tabs builds, with the public pieces
	if ui.strip("###mine") {
		if outer := ui.parent_box().parent; outer != nil { outer.custom = ui.tab_line_draw }
		ui.tab_strip_start()
		for words, i in FACE_TABS {
			on := i == r.sel
			ui.next({width = ui.children_sum(0), height = ui.pct(1)})
			b := ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###mine_%d", i))
			ui.tab_face(b, on, r.mark && on ? FACE_MARK : {})
			if ui.parent(b) { if ui.tab_body() {
				if !on { ui.push_tags("weak") }
				pad := math_round(em * 0.7)
				ui.spacer(ui.px(pad))
				ui.next({width = ui.tab_title_width(words, 0, 0), height = ui.pct(1), text_pad = 0})
				ui.build_box({.Draw_Text}, words)
				ui.spacer(ui.px(pad))
				if !on { ui.pop_tags() }
			} }
		}
	}
}

@(private = "file")
math_round :: proc(v: f32) -> f32 { return f32(int(v + 0.5)) }

@(test)
a_hand_built_strip_with_tab_face_draws_as_tabs :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Face_Run{sel = 1}
	s := session.start(t, {size = {420, 120}, user = &r, build = face_build})
	session.move(s, {400, 110})   // (the pointer on no tab)
	session.wait_idle(s)
	theirs := session.capture(s)
	r.hand = true
	session.wait_idle(s)
	mine := session.capture(s)
	session.save_png(s, "hand_built.png")
	differ := 0
	for i in 0 ..< len(mine.rgba) { if mine.rgba[i] != theirs.rgba[i] { differ += 1 } }
	testing.expectf(t, differ == 0, "the same pixels as ui.tabs: %d bytes differ", differ)

	// the mark: along the chosen tab's top, not elsewhere
	r.mark = true
	session.wait_idle(s)
	marked := session.capture(s)
	session.save_png(s, "marked.png")
	tab := session.get(s, "mine_1")
	reds, outside := 0, 0
	for y in 0 ..< marked.height {
		for x in 0 ..< marked.width {
			c := session.pixel(marked, x, y)
			if c.r < 200 || c.g > 60 || c.b > 60 { continue }
			inside := f32(x) >= tab.rect.min.x && f32(x) < tab.rect.max.x && f32(y) < tab.rect.min.y + (tab.rect.max.y - tab.rect.min.y) * 0.5
			if inside { reds += 1 } else { outside += 1 }
		}
	}
	testing.expectf(t, reds > 20, "the mark along the chosen tab's top: %d pixels", reds)
	testing.expect_value(t, outside, 0)
}) }
