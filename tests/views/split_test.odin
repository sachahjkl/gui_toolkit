package views_test

// Splits inside a dock zone (src/md/features/views.md, section 6): a view dropped on a side of a stack's cross makes a
// new stack beside it (each lone, no tab strip, a handle between), on its middle a tab of it; a space without content
// has a centre zone; the space's line keeps the zones' axes and the stacks' shares.

import "core:testing"
import store "gt:store"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") WINDOW :: [2]int{1000, 700}
@(private = "file") FRAMES_MAX :: 60

@(private = "file")
Split :: struct {
	views:   ui.Views,
	want:    [dynamic]string,
	mission: bool,   // build a space without content, "mission"
}

@(private = "file")
split_build :: proc(s: ^session.Session) {
	r := (^Split)(s.user)
	for id in r.want { ui.view_open(&r.views, id, r) }
	clear(&r.want)
	if ui.views_frame(&r.views) {
		ui.label("The content###content_words")
		if r.mission {
			ui.next({width = ui.fill(), height = ui.px(400)})
			if ui.views_dock(&r.views, "mission", {}) {}
		}
	}
}

@(private = "file")
words_view :: proc(v: ^ui.View, r: ^Split) {
	if ui.dialog_body("words_body") { ui.label("Some words###words") }
}

@(private = "file")
split_start :: proc(t: ^testing.T, r: ^Split, want: ..string) -> ^session.Session {
	ui.view_register(&r.views, "side", words_view, ui.View_Options{title = "Side", home = .Panel, home_place = {edge = .Left}, extent_em = 14})
	ui.view_register(&r.views, "ask", words_view, ui.View_Options{title = "Question"})
	ui.view_register(&r.views, "machine", words_view, ui.View_Options{title = "Machine", home = .Panel, home_place = {space = "mission", edge = .Center}})
	for w in want { append(&r.want, w) }
	return session.start(t, {size = WINDOW, user = r, build = split_build})
}

@(private = "file")
split_end :: proc(r: ^Split) {
	ui.views_destroy(&r.views)
	delete(r.want)
}

@(private = "file")
built :: proc(s: ^session.Session, name: string, within: ^ui.Box = nil) -> ^ui.Box {
	b := session.find(s, name, within = within)
	if b == nil || b.last_build != s.state.build_index || b.transparency >= 1 { return nil }
	return b
}

@(private = "file")
wait_built :: proc(s: ^session.Session, name: string, loc := #caller_location) -> ^ui.Box {
	for _ in 0 ..< FRAMES_MAX {
		if b := built(s, name); b != nil { return b }
		session.frame(s)
	}
	testing.expectf(s.t, false, "%s not built in %d frames", name, FRAMES_MAX, loc = loc)
	return nil
}

// The dialog "ask" dragged by its header over the left zone's stack, then let go on the square `target` of its cross.
@(private = "file")
drop_ask_on :: proc(s: ^session.Session, target: string, loc := #caller_location) -> bool {
	if wait_built(s, "modal_view_ask", loc) == nil { return false }
	header := built(s, "view_header")
	zone := built(s, "view_zone_Left")
	if header == nil || zone == nil { testing.expect(s.t, false, "the dialog's header and the left zone", loc = loc); return false }
	stack := built(s, "view_stack_0", zone)
	if stack == nil { testing.expect(s.t, false, "the left zone's stack", loc = loc); return false }
	from := [2]f32{header.rect.min.x + 10, (header.rect.min.y + header.rect.max.y) * 0.5}
	session.press(s, from)
	session.move(s, from + {30, 0})
	session.move(s, from + {60, 0})
	session.move(s, session.center(stack))
	t := wait_built(s, target, loc)
	if t == nil { return false }
	at := session.center(t)
	session.move(s, at)
	session.release(s, at)
	return true
}

// A view let go on the bottom side of a lone stack: a stack of its own under it; each lone (no tab strip), a handle
// between; the zone's axis remembered, and the place of each view.
@(test)
a_drop_on_a_stack_s_side_splits_it :: proc(t: ^testing.T) {
	r: Split
	defer split_end(&r)
	s := split_start(t, &r, "side", "ask")
	if !drop_ask_on(s, "view_target__Left_0_bottom") { return }
	if wait_built(s, "view_panel_view_ask") == nil { return }
	zone := built(s, "view_zone_Left")
	if zone == nil { return }
	top, below := built(s, "view_stack_0", zone), built(s, "view_stack_1", zone)
	testing.expect(t, top != nil && below != nil, "two stacks")
	if top != nil && below != nil { testing.expectf(t, below.rect.min.y >= top.rect.max.y, "one above the other: %v, %v", top.rect, below.rect) }
	testing.expect(t, built(s, "view_tabs") == nil, "each lone: no tab strip")
	testing.expect(t, built(s, "view_stack_handle_Left_0") != nil, "a handle between")
	text, _ := store.get(&r.views.memory, "#")
	sm, ok := ui.views_space_parse(text)
	a, has_axis := sm.axis[.Left].?
	testing.expectf(t, ok && has_axis && a == .Y, "the zone's axis remembered: %q", text)
	line, _ := store.get(&r.views.memory, "ask")
	m, _ := ui.views_parse(line)
	d, docked := m.dock.?
	testing.expectf(t, docked && d.place.edge == .Left && d.place.stack == 1, "its place: %q", line)
}

// A view let go on the middle of a stack's cross: a tab of it (the tab strip comes with the second view).
@(test)
a_drop_on_a_stack_s_middle_makes_a_tab :: proc(t: ^testing.T) {
	r: Split
	defer split_end(&r)
	s := split_start(t, &r, "side", "ask")
	if !drop_ask_on(s, "view_target__Left_0_tab") { return }
	if wait_built(s, "view_tabs") == nil { return }
	zone := built(s, "view_zone_Left")
	testing.expect(t, zone != nil && built(s, "view_stack_1", zone) == nil, "one stack")
	testing.expect(t, built(s, "view_tab_view_ask") != nil && built(s, "view_tab_view_side") != nil, "a tab each")
}

// A space without content: its centre is a zone, where a view homed there shows.
@(test)
a_space_without_content_has_a_centre :: proc(t: ^testing.T) {
	r: Split
	defer split_end(&r)
	r.mission = true
	s := split_start(t, &r, "machine")
	if wait_built(s, "view_panel_view_machine") == nil { return }
	testing.expect(t, built(s, "view_zone_Center") != nil, "the centre zone")
}

// The palette's commands of the views, kept: made again only when the views changed (a move, a new view), and their
// strings outlive the frame.
@(test)
the_views_commands_are_kept_until_the_views_change :: proc(t: ^testing.T) {
	r: Split
	defer split_end(&r)
	vc: ui.View_Commands
	defer ui.views_commands_destroy(&vc)
	s := split_start(t, &r, "ask")
	if wait_built(s, "modal_view_ask") == nil { return }
	testing.expect(t, ui.views_commands_update(&vc, &r.views), "made the first time")
	n := len(vc.commands)
	testing.expect(t, n > 0 && len(vc.acts) == n, "a command per act")
	session.frames(s, 3)
	testing.expect(t, !ui.views_commands_update(&vc, &r.views), "nothing changed: kept")
	label := vc.commands[0].label
	ui.view_present(&r.views, "ask", .Internal)
	if wait_built(s, "internal_view_ask") == nil { return }
	testing.expect(t, ui.views_commands_update(&vc, &r.views), "the view moved: made again")
	testing.expect(t, label != "", "(the old label was the kept memory's until then)")
}

// The space's line: extents, axes, shares, and back.
@(test)
the_space_line_round_trips :: proc(t: ^testing.T) {
	m: ui.View_Space_Memory
	m.extent[.Left], m.extent[.Bottom] = 18, 12.5
	m.axis[.Left] = .X
	m.shares[.Left][0], m.shares[.Left][1] = 0.4, 0.35
	text := ui.views_space_format(m)
	got, ok := ui.views_space_parse(text)
	testing.expect(t, ok, text)
	testing.expect_value(t, got.extent[.Left], 18)
	testing.expect_value(t, got.extent[.Bottom], 12.5)
	a, has := got.axis[.Left].?
	testing.expect(t, has && a == .X, "the axis")
	testing.expect(t, got.axis[.Bottom] == nil, "no axis said: none")
	testing.expect(t, abs(got.shares[.Left][0] - 0.4) < 0.001 && abs(got.shares[.Left][1] - 0.35) < 0.001, "the shares")
	_, refused := ui.views_space_parse("v1 left.shares=1.5")
	testing.expect(t, !refused, "a share of the whole or more is refused")
	// (a view's place keeps its stack; a line of three fields is the first stack)
	vm, vok := ui.views_parse("v1 open=1 dock=mission:center:0.0")
	d, docked := vm.dock.?
	testing.expect(t, vok && docked && d.place.edge == .Center && d.place.stack == 0, "an old dock field")
	vm, vok = ui.views_parse(ui.views_format({dock = ui.View_Dock_Memory{place = {space = "mission", edge = .Left, stack = 3}}}))
	d, docked = vm.dock.?
	testing.expect(t, vok && docked && d.place.stack == 3, "the stack kept")
}
