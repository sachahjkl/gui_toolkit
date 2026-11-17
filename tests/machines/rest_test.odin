package machines_test

// The rest of what lasts over frames: what a colour's text says after it was left, a focus stepped into a paragraph from
// behind, where a find lights a match while the view glides, what a screen reader is told of what went, the title bar forgotten.

import "core:testing"
import "gt:platform"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") WINDOW :: [2]int{600, 500}
@(private = "file") SCROLL_SIZE :: 300
@(private = "file") LINES :: 40
@(private = "file") LINE_HEIGHT :: 30
@(private = "file") WHEEL_NOTCHES :: 3
@(private = "file") SETTLE_FRAMES :: 4
// A match's rect is its box's layout, whatever the scroll: to a fraction of a pixel.
@(private = "file") SAME_PLACE_PX :: 0.5

@(private = "file")
Pick :: struct { cp: ui.Color_Pick }

@(private = "file")
pick_build :: proc(s: ^session.Session) {
	r := (^Pick)(s.user)
	ui.button("away", "Away")
	ui.color_picker("###pick", &r.cp)
}

@(private = "file")
typed_then_left :: proc(t: ^testing.T, text: string, want: string) {
	r: Pick
	defer ui.color_pick_destroy(&r.cp)
	ui.color_pick_set(&r.cp, {1, 0, 0, 1}, {.Hex, false})
	s := session.start(t, {size = WINDOW, user = &r, build = pick_build})
	session.frames(s, 2)
	session.click(s, "text")
	session.key(s, .A, {.Ctrl})
	session.type_text(s, text)
	testing.expect_value(t, ui.line_edit_string(&r.cp.field), text)
	session.click(s, "away")
	session.frames(s, SETTLE_FRAMES)
	testing.expect_value(t, ui.line_edit_string(&r.cp.field), want)
}

// Left, the field says the colour as the picker writes it: not a spelling of the user's, not what is no colour.
@(test)
a_colour_typed_is_written_anew_when_left :: proc(t: ^testing.T) { typed_then_left(t, "#F00", "#f00") }

@(test)
what_is_no_colour_goes_when_left :: proc(t: ^testing.T) { typed_then_left(t, "nonsense", "#ff0000") }

@(private = "file")
Links :: struct { rich: ui.Rich_Result, step: bool }

// focus_step into a paragraph from behind, between two builds or in one: it starts at its last link.
@(test)
a_step_back_enters_a_paragraph_by_its_last_link :: proc(t: ^testing.T) {
	r: Links
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Links)(s.user)
		ui.button("first", "First")
		ui.next({width = ui.px(SCROLL_SIZE)})
		r.rich = ui.rich_paragraph("###rich", {{text = "one", link = "a"}, {text = " and "}, {text = "two", link = "b"}})
		if r.step { r.step = false; ui.focus_step(s.state, 0, -1) }   // (after the stops of this build)
	}})
	session.frames(s, 2)
	ui.focus_step(s.state, 0, -1)
	session.frames(s, 2)
	testing.expect_value(t, r.rich.link_focused, 2)
	ui.set_focus(0)
	session.frames(s, 2)
	r.step = true
	session.frames(s, 3)
	testing.expect_value(t, r.rich.link_focused, 2)
}

@(private = "file")
glide_build :: proc(s: ^session.Session) {
	ui.next({width = ui.px(SCROLL_SIZE), height = ui.px(SCROLL_SIZE)})
	if ui.scroll_y("###region") {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column() {
			for i in 0 ..< LINES {
				ui.next({height = ui.px(LINE_HEIGHT)})
				ui.label(i == LINES / 2 ? "the needle###t" : "words###t")
			}
		}
	}
	ui.find_bar(ui.prev_box("###region"))
}

// The match lit, against its box's top.
@(private = "file")
match_in_box :: proc() -> f32 {
	ms := ui.find_matches()
	if len(ms) == 0 { return -1 }
	b := ui.box_from_key(ms[0].box)
	return ms[0].rect.min.y - b.rect.min.y
}

// A match lit while the view glides is on its letters, as one at rest is: its rect is the layout's, with the scroll that
// layout had (the find reads it before the glide moves the view).
@(test)
a_match_in_a_glide_stays_on_its_letters :: proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, smooth_scroll = .On, animations = true, build = glide_build})
	session.frames(s, 2)
	ui.find_open(session.get(s, "region").key, "needle")
	session.frames(s, 3)
	testing.expect_value(t, ui.find_count(), 1)
	at_rest := match_in_box()
	at := session.center(session.get(s, "region"))
	session.move(s, at)
	session.event(s, {kind = .Scroll, pos = at, delta = {0, WHEEL_NOTCHES}})
	session.frame(s)
	b := session.get(s, "region")
	testing.expect(t, b.view_off.y != b.view_target.y, "the view is on its way")
	gliding := match_in_box()
	testing.expectf(t, abs(gliding - at_rest) < SAME_PLACE_PX, "at rest %v, gliding %v", at_rest, gliding)
	ui.find_close()
}

// No tree made is no tree: not the last one made.
@(test)
a_tree_not_made_is_none :: proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) { ui.button("a", "A") }})
	ui.a11y_capture(s.state, true)
	session.frames(s, 2)
	testing.expect(t, len(ui.a11y_tree(s.state).nodes) > 0, "made")
	ui.a11y_capture(s.state, false)
	session.frames(s, 2)
	testing.expect_value(t, len(ui.a11y_tree(s.state).nodes), 0)
}

// A box of the last build not made in this one is no active descendant: a reader would look for a node that is not there.
@(test)
a_descendant_gone_is_not_named :: proc(t: ^testing.T) {
	Run :: struct { show: bool, key: ui.Key, holder: ui.Key }
	r := Run{show = true}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.a11y({role = .List_Box, active_descendant = r.key})
		b := ui.build_box({.Clickable}, "Holder###holder")
		r.holder = b.key
		if r.show { r.key = ui.button("row", "Row").box.key }
	}})
	ui.a11y_capture(s.state, true)
	session.frames(s, 2)
	r.show = false
	session.frame(s)
	u := ui.a11y_tree(s.state)
	i := ui.a11y_find(s.state, r.holder)
	testing.expect(t, i >= 0, "the holder is in the tree")
	for p in platform.a11y_node_props(u, i) {
		testing.expect(t, p.kind != .Active_Descendant, "no descendant named")
	}
}

// Buttons of a title bar with no caption: what no build makes any more goes from the regions, with no window to say so.
@(test)
caption_buttons_gone_are_forgotten :: proc(t: ^testing.T) {
	Run :: struct { show: bool }
	r := Run{show = true}
	s := session.start(t, {size = WINDOW, user = &r, integrated_title = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if r.show { _, _ = ui.window_buttons() }
	}})
	session.frames(s, 2)
	regions := ui.chrome_regions(s.state)
	testing.expect(t, regions.buttons != {}, "published")
	r.show = false
	session.frames(s, 2)
	testing.expect(t, regions.buttons == {}, "forgotten")
}
