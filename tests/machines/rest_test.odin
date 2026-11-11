package machines_test

// The rest of what lasts over frames: what a colour's text says after it was left, a focus stepped into a paragraph from
// behind, what a sweep measures while the view glides, what a screen reader is told of what went, the title bar forgotten.

import "core:testing"
import "../../src/platform"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{600, 500}
@(private = "file") SCROLL_SIZE :: 300
@(private = "file") LINES :: 40
@(private = "file") LINE_HEIGHT :: 30
@(private = "file") WHEEL_NOTCHES :: 3
@(private = "file") SETTLE_FRAMES :: 4
@(private = "file") SWEEP_WAIT_MS :: 600
// The sweep's coordinates are the content's, whatever the scroll: to a fraction of a pixel.
@(private = "file") SAME_PLACE_PX :: 0.5

@(private = "file")
Pick :: struct { cp: ui.Color_Pick }

@(private = "file")
pick_build :: proc(s: ^session.Session) {
	r := (^Pick)(s.user)
	ui.button("Away###away")
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
	testing.expect_value(t, ui.field_string(&r.cp.field), text)
	session.click(s, "away")
	session.frames(s, SETTLE_FRAMES)
	testing.expect_value(t, ui.field_string(&r.cp.field), want)
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
		ui.button("First###first")
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
Sweep :: struct { refresh: bool }

@(private = "file")
sweep_build :: proc(s: ^session.Session) {
	r := (^Sweep)(s.user)
	ui.find("needle", ui.key_from_string(ui.key_from_string(0, "root"), "###region"))   // (the scope whose content find_all speaks of)
	if r.refresh { r.refresh = false; ui.find_refresh() }
	sweep := ui.find_sweep()
	ui.next({width = ui.px(SCROLL_SIZE), height = ui.px(SCROLL_SIZE)})
	if ui.scroll_y("###region") {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column() {
			lz := ui.lazy_begin(sweep = sweep)
			for i in 0 ..< LINES {
				if ui.lazy_item(lz, item_id(i)) {
					ui.next({height = ui.px(LINE_HEIGHT)})
					ui.label(i == LINES - 1 ? "the needle" : "words")
				}
			}
		}
	}
}

@(private = "file")
item_id :: proc(i: int) -> string {
	buf := make([]u8, 8, context.temp_allocator)
	buf[0], buf[1], buf[2] = '#', '#', '#'
	buf[3], buf[4] = 'a' + u8(i / 26), 'a' + u8(i % 26)
	return string(buf[:5])
}

// A sweep that runs while the view glides says where the match is in the content, as one at rest does.
@(test)
a_sweep_in_a_glide_finds_the_same_place :: proc(t: ^testing.T) {
	r: Sweep
	s := session.start(t, {size = WINDOW, user = &r, smooth_scroll = .On, animations = true, build = sweep_build})
	session.advance(s, SWEEP_WAIT_MS)
	testing.expect_value(t, ui.find_count(), 1)
	at_rest := ui.find_all()[0].rect.min.y
	session.advance(s, SWEEP_WAIT_MS)
	at := session.center(session.get(s, "region"))
	session.move(s, at)
	session.event(s, {kind = .Scroll, pos = at, delta = {0, WHEEL_NOTCHES}})
	session.frame(s)
	r.refresh = true
	session.frame(s)
	b := session.get(s, "region")
	testing.expect(t, b.view_off.y != b.view_target.y, "the view is on its way")
	gliding := ui.find_all()[0].rect.min.y
	testing.expectf(t, abs(gliding - at_rest) < SAME_PLACE_PX, "at rest %v, gliding %v", at_rest, gliding)
}

// No tree made is no tree: not the last one made.
@(test)
a_tree_not_made_is_none :: proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) { ui.button("A###a") }})
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
		if r.show { r.key = ui.button("Row###row").box.key }
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
