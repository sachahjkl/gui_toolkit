package views_test

// The Panel presentation (src/md/features/views.md, section 6): a lone panel adds nothing (test 17), two in a zone have
// tabs, the hover icons only on hover, the menu's Dock items, a drop on a dock target, a tab dragged out, re-attach to a
// panel home, a home in a space not built waits, the extents remembered, the palette's commands, the keys of a panel,
// F6.

import "core:fmt"
import "core:testing"
import "../../src/platform"
import store "../../src/store"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{1000, 700}
@(private = "file") SIDE_EM :: 12
@(private = "file") GROW_PX :: 40
@(private = "file") OUT :: [2]f32{420, 300}   // (a point of the content, far from the zones and the targets)

@(private = "file")
Dock :: struct {
	views:      ui.Views,
	want:       [dynamic]string,   // open in the next build
	tools:      bool,              // build the space "tools"
	field:      ui.Line_Edit,
	panel_keys: int,               // J read by the panel's code
	content_k:  int,               // F2 read by the content's code
	answers:    [dynamic]int,
	em:         f32,               // the font size of the last build (frame px)
}

@(private = "file")
dock_build :: proc(s: ^session.Session) {
	r := (^Dock)(s.user)
	for id in r.want { ui.view_open(&r.views, id, r) }
	clear(&r.want)
	r.em = ui.font_size()
	if code, ok := ui.view_ended(&r.views, "ask"); ok { append(&r.answers, code) }
	if ui.views_frame(&r.views) {
		if ui.key_press(.F2) { r.content_k += 1 }
		ui.next({width = ui.px(200)})
		ui.button("content_button", "In the content")
		if r.tools {
			ui.next({width = ui.fill(), height = ui.px(200)})
			if ui.views_dock(&r.views, "tools", {content = true}) { ui.label("The tools' centre###tools_centre") }
		}
	}
}

@(private = "file")
side_view :: proc(v: ^ui.View, r: ^Dock) {
	ui.next({width = ui.fill(), height = ui.px(30)})
	ui.line_edit("###side_field", &r.field)
	if ui.key_press(.J) { r.panel_keys += 1 }
	ui.label("The side's words###side_words")
}

@(private = "file")
plain_view :: proc(v: ^ui.View, r: ^Dock) {
	if ui.dialog_body("plain_body") { ui.label("A question###plain_words") }
}

@(private = "file")
dock_start :: proc(t: ^testing.T, r: ^Dock, want: ..string) -> ^session.Session {
	ui.view_register(&r.views, "side", side_view, ui.View_Options{title = "Side", home = .Panel, home_place = {edge = .Left}, extent_em = SIDE_EM})
	ui.view_register(&r.views, "side2", side_view, ui.View_Options{title = "Second", home = .Panel, home_place = {edge = .Left}})
	ui.view_register(&r.views, "tool", plain_view, ui.View_Options{title = "Tool", home = .Panel, home_place = {space = "tools", edge = .Right}})
	ui.view_register(&r.views, "ask", plain_view, ui.View_Options{title = "Question"})
	ui.view_register(&r.views, "float", plain_view, ui.View_Options{title = "Floating", first = .Internal})
	for w in want { append(&r.want, w) }
	return session.start(t, {size = WINDOW, user = r, build = dock_build})
}

@(private = "file")
dock_end :: proc(r: ^Dock) {
	ui.views_destroy(&r.views)
	ui.line_edit_destroy(&r.field)
	delete(r.want)
	delete(r.answers)
}

@(private = "file")
built :: proc(s: ^session.Session, name: string) -> ^ui.Box {
	b := session.find(s, name)
	if b == nil || b.last_build != s.state.build_index || b.transparency >= 1 { return nil }
	return b
}

// (a bound in frames, well under the runner's timeout: a wait that fails says what it waited for and where the views
// were, and the test goes on to its end; session.failed would stop the test silently until the runner kills it)
@(private = "file") WAIT_FRAMES :: 120

@(private = "file")
wait_built :: proc(s: ^session.Session, name: string, loc := #caller_location) -> ^ui.Box {
	for _ in 0 ..< WAIT_FRAMES {
		if b := built(s, name); b != nil { return b }
		session.frame(s)
	}
	testing.expectf(s.t, false, "%s not built in %d frames; the views: %s", name, WAIT_FRAMES, views_said(s), loc = loc)
	return nil
}

// Where each open view is: "ask=Panel(Shown) ...".
@(private = "file")
views_said :: proc(s: ^session.Session) -> string {
	r := (^Dock)(s.user)
	out := ""
	for id in ([]string{"side", "side2", "tool", "ask", "float"}) {
		if ui.view_is_open(&r.views, id) { out = fmt.tprintf("%s %s=%v", out, id, ui.view_presentation(&r.views, id)) }
	}
	return out == "" ? "none open" : out
}

// A menu's item, by the words it shows (a row's box is named mi_<index>_<id>: its words are what stays), clicked when it
// is there and active; else the test says so and the caller stops.
@(private = "file")
click_item :: proc(s: ^session.Session, words: string, loc := #caller_location) -> bool {
	b: ^ui.Box
	for _ in 0 ..< WAIT_FRAMES {
		if x := session.find_text(s, words); x != nil && x.last_build == s.state.build_index { b = x; break }
		session.frame(s)
	}
	if b == nil {
		testing.expectf(s.t, false, "no menu item %q in %d frames; the views: %s", words, WAIT_FRAMES, views_said(s), loc = loc)
		return false
	}
	for x := b; x != nil; x = x.parent {
		if .Disabled in x.flags { testing.expectf(s.t, false, "the menu item %q is inactive", words, loc = loc); return false }
		if .Clickable in x.flags { break }
	}
	session.click_text(s, words, loc = loc)
	return true
}

// A click on the box `name`, when there is one and it is active; else the test says so and the caller stops.
@(private = "file")
click_named :: proc(s: ^session.Session, name: string, button := platform.Mouse_Button.Left, loc := #caller_location) -> bool {
	b := built(s, name)
	if b == nil {
		testing.expectf(s.t, false, "no box %s to click; the views: %s", name, views_said(s), loc = loc)
		return false
	}
	if .Disabled in b.flags {
		testing.expectf(s.t, false, "%s is inactive", name, loc = loc)
		return false
	}
	session.click_at(s, session.center(b), button)
	return true
}

// Test 17: a panel alone in its zone adds no tab strip, no border, no icon at rest; its body starts at the zone's top
// left. Its two icons show while the pointer is over its top area, and go when it leaves.
@(test)
a_lone_panel_adds_nothing :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side")
	body := wait_built(s, "view_panel_view_side")
	zone := built(s, "view_zone_Left")
	if body == nil || zone == nil { testing.expect(t, false, "the panel and its zone"); return }
	testing.expect_value(t, body.rect.min, zone.rect.min)
	testing.expect(t, session.find(s, "view_tabs") == nil, "no tab strip")
	testing.expect(t, .Draw_Background not_in zone.flags && .Draw_Border not_in zone.flags, "the zone draws nothing")
	testing.expect(t, .Draw_Background not_in body.flags && .Draw_Border not_in body.flags, "the body draws nothing of its own")
	testing.expect(t, built(s, "view_panel_icons") == nil, "no icon at rest")
	session.move(s, {body.rect.min.x + 30, body.rect.min.y + 8})
	session.frames(s, 2)
	testing.expect(t, built(s, "view_panel_icons") != nil, "its icons on the hover of its top area")
	session.move(s, OUT)
	session.frames(s, 2)
	testing.expect(t, built(s, "view_panel_icons") == nil, "gone when the pointer leaves")
	testing.expectf(t, abs((zone.rect.max.x - zone.rect.min.x) - SIDE_EM * r.em) <= 1.5, "its extent_em: %v", zone.rect)
}

// Two views in one zone: the tab strip, a tab each; a click on a tab shows its view.
@(test)
two_panels_in_a_zone_are_tabs :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side", "side2")
	wait_built(s, "view_tabs")
	testing.expect(t, session.find(s, "view_tab_view_side") != nil && session.find(s, "view_tab_view_side2") != nil, "a tab each")
	testing.expect(t, built(s, "view_panel_view_side2") != nil, "the last docked shown")
	if !click_named(s, "view_tab_view_side") { return }
	if wait_built(s, "view_panel_view_side") == nil { return }
	testing.expect(t, built(s, "view_panel_view_side2") == nil, "one shown at a time")
}

// The header's menu docks a dialog at the right; re-attach brings it back a dialog.
@(test)
the_menu_docks_a_dialog :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "ask")
	if wait_built(s, "modal_view_ask") == nil { return }
	header := built(s, "view_header")
	if header == nil { testing.expect(t, false, "the dialog's header"); return }
	session.click_at(s, {header.rect.min.x + 10, (header.rect.min.y + header.rect.max.y) * 0.5}, .Right)
	if !click_item(s, "Dock right") { return }   // (in the menu the right click opened)
	if wait_built(s, "view_panel_view_ask") == nil { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Panel)
	testing.expect(t, built(s, "view_zone_Right") != nil, "in the right zone")
	ui.view_reattach(&r.views, "ask")
	if wait_built(s, "modal_view_ask") == nil { return }
	testing.expect(t, built(s, "view_panel_view_ask") == nil, "the panel went")
}

// An internal window's header menu docks it at the left.
@(test)
the_menu_docks_an_internal_window :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "float")
	frame := wait_built(s, "internal_view_float")
	if frame == nil { return }
	header := session.find(s, "view_header", within = frame)
	if header == nil { testing.expect(t, false, "the window's header"); return }
	session.click_at(s, {header.rect.min.x + 10, (header.rect.min.y + header.rect.max.y) * 0.5}, .Right)
	if !click_item(s, "Dock left") { return }
	if wait_built(s, "view_panel_view_float") == nil { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "float"), ui.View_Presentation.Panel)
	testing.expect(t, built(s, "view_zone_Left") != nil, "in the left zone")
	testing.expect(t, built(s, "internal_view_float") == nil, "the window went")
}

// A dialog's header dragged onto the right target: the targets show while it is dragged, and it docks there.
@(test)
a_dialog_dropped_on_a_target_docks :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "ask")
	if wait_built(s, "modal_view_ask") == nil { return }
	testing.expect(t, session.find(s, "view_target__Right") == nil, "no target at rest")
	header := built(s, "view_header")
	if header == nil { testing.expect(t, false, "the dialog's header"); return }
	from := [2]f32{header.rect.min.x + 10, (header.rect.min.y + header.rect.max.y) * 0.5}
	session.press(s, from)
	session.move(s, from + {30, 0})
	session.move(s, from + {60, 0})
	target := wait_built(s, "view_target__Right")
	if target == nil { return }
	at := session.center(target)
	session.move(s, at)
	session.release(s, at)
	wait_built(s, "view_panel_view_ask")
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Panel)
	session.frames(s, 2)
	testing.expect(t, session.find(s, "view_target__Right") == nil || built(s, "view_target__Right") == nil, "the targets go with the drag")
}

// A tab dragged out of its zone: an internal window under the pointer.
@(test)
a_tab_dragged_out_floats :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side", "side2")
	tab := wait_built(s, "view_tab_view_side")
	if tab == nil { return }
	session.drag(s, session.center(tab), OUT)
	if wait_built(s, "internal_view_side") == nil { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "side"), ui.View_Presentation.Internal)
	testing.expect(t, built(s, "view_tabs") == nil, "one left in the zone: no tabs")
	// re-attach: back to its home zone
	if !click_named(s, "view_reattach") { return }
	if wait_built(s, "view_panel_view_side") == nil { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "side"), ui.View_Presentation.Panel)
}

// A view homed in a space not built waits there, Shown; it is built when the space is.
@(test)
a_home_in_a_hidden_space_waits :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "tool")
	session.frames(s, 3)
	testing.expect(t, ui.view_is_open(&r.views, "tool"), "open")
	testing.expect(t, built(s, "view_panel_view_tool") == nil, "not built: its space is not")
	r.tools = true
	wait_built(s, "view_panel_view_tool")
	testing.expect(t, built(s, "tools_centre") != nil, "the space's centre")
}

// The zone's extent follows its handle and is remembered in the space's line once let go.
@(test)
a_zone_s_extent_is_remembered :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side")
	zone := wait_built(s, "view_zone_Left")
	handle := session.find(s, "view_handle_Left")
	if zone == nil || handle == nil { testing.expect(t, false, "the zone and its handle"); return }
	was := zone.rect.max.x - zone.rect.min.x
	at := session.center(handle)
	session.drag(s, at, at + {GROW_PX, 0})
	session.frames(s, 2)
	zone = built(s, "view_zone_Left")
	testing.expectf(t, zone != nil && abs(zone.rect.max.x - zone.rect.min.x - (was + GROW_PX)) <= 1.5, "wider by the drag: %v, then %v", was, zone.rect)
	text, ok := store.get(&r.views.memory, "#")
	ext, parsed := ui.views_space_parse(text)
	testing.expect(t, ok && parsed, "the space's line")
	testing.expectf(t, ext[.Left] > SIDE_EM, "its left extent: %v", ext)
}

// The palette's commands: one per act of each open view, in words; running one does it.
@(test)
the_palette_s_commands_move_views :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "ask")
	wait_built(s, "modal_view_ask")
	commands, acts := ui.views_commands(&r.views)
	found := -1
	for c, i in commands { if c.label == "Dock Question to the right" { found = i } }
	testing.expect(t, found >= 0, "Dock Question to the right")
	labels: [dynamic]string
	defer delete(labels)
	for c in commands { append(&labels, c.label) }
	has :: proc(labels: []string, l: string) -> bool { for x in labels { if x == l { return true } }; return false }
	testing.expect(t, has(labels[:], "Float Question") && has(labels[:], "Close Question"), "Float and Close")
	testing.expect(t, !has(labels[:], "Re-attach Question"), "no Re-attach at home")
	version := ui.views_version(&r.views)
	if found >= 0 { ui.views_command_run(&r.views, acts[found]) }
	wait_built(s, "view_panel_view_ask")
	testing.expect(t, ui.views_version(&r.views) != version, "the list changed")
}

// A panel's keys: with the focus in its field, the field takes the letters and the content's F2 still works; with
// the focus in the content, the panel's code reads no key. F6 moves the focus into the panel.
@(test)
a_panel_s_keys_are_its_own_only_with_the_focus :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side")
	if wait_built(s, "view_panel_view_side") == nil { return }
	if !click_named(s, "content_button") { return }
	session.key(s, .J)
	testing.expect_value(t, r.panel_keys, 0)
	session.key(s, .F6)
	if focused := session.focused_name(s); focused != "side_field" {
		testing.expectf(t, false, "F6 to the panel's field: the focus is on %q", focused)
		return
	}
	session.type_text(s, "abc")
	testing.expect_value(t, ui.line_edit_string(&r.field), "abc")
	session.key(s, .F2)
	testing.expect_value(t, r.content_k, 1)
	// Escape: the focus back to the content, the panel stays
	session.key(s, .Escape)
	session.frames(s, 2)
	testing.expect(t, session.focused_name(s) != "side_field", "the focus left the panel")
	testing.expect(t, ui.view_is_open(&r.views, "side"), "the panel stays")
}
