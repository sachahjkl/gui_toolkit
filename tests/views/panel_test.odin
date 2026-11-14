package views_test

// The Panel presentation (src/md/features/views.md, section 6): a lone panel adds nothing (test 17), two in a zone have
// tabs, the hover icons only on hover, the menu's Dock items, a drop on a dock target, a tab dragged out, re-attach to a
// panel home, a home in a space not built waits, the extents remembered, the palette's commands, the keys of a panel,
// F6.

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"
import i18n "../../src/i18n"
import "../../src/platform"
import store "../../src/store"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{1000, 700}
@(private = "file") SIDE_EM :: 12
@(private = "file") GROW_PX :: 40
@(private = "file") OUT :: [2]f32{420, 300}   // (a point of the content, far from the zones and the targets)
@(private = "file") LOW_FRAC :: f32(0.25)     // the view "low"'s zone: a quarter of the window's height
@(private = "file") LEFT_FRAC :: f32(0.3)     // the frame's left zone, when the program gives it
@(private = "file") TAB_W :: 80               // the width of the tab in "tabbed"'s top band (px)
@(private = "file") VIEW_MENU_TABBED :: "###view_menu_view_tabbed"   // (views_builders.odin's view_menu_id)

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
	own_f6:     bool,              // the program binds F6 itself, read after views_frame (in its content)
	f6_taken:   int,
	frame_o:    ui.View_Dock_Options,   // what views_frame is given (its zones' extents at first)
	side_cover: int,               // the floating views over the panel "side", as its last build saw them (view_occluders)
	terms:      int,               // the terminals the "+" asked for (term_new)
	later:      bool,              // term_new only asks: the test opens the instance frames later (a server's answer)
	hug_w:      f32,               // the width "hug" asks for this opening (view_size), in ems
	no_frame:   bool,              // the window builds no views_frame (its content alone)
}

@(private = "file")
dock_build :: proc(s: ^session.Session) {
	r := (^Dock)(s.user)
	for id in r.want { ui.view_open(&r.views, id, r) }
	clear(&r.want)
	r.em = ui.font_size()
	if code, ok := ui.view_ended(&r.views, "ask"); ok { append(&r.answers, code) }
	if r.no_frame {
		ui.label("The page alone###page_alone")
		return
	}
	if ui.views_frame(&r.views, r.frame_o) {
		if ui.key_press(.F2) { r.content_k += 1 }
		if r.own_f6 && ui.key_press(.F6) { r.f6_taken += 1 }
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
	r.side_cover = len(ui.view_occluders(v))
}

// A panel with a tab of its own in its top band, whose right click opens the tab's menu.
@(private = "file")
tabbed_view :: proc(v: ^ui.View, r: ^Dock) {
	ui.next({width = ui.px(TAB_W), height = ui.px(20)})
	tab := ui.build_box({.Clickable, .Draw_Background}, "###tab_in_band")
	if ui.signal(tab).right_clicked { ui.menu_open("tab_menu", ui.mouse_pos()) }
	if ui.menu("tab_menu") { _ = ui.menu_item("Rename the tab") }
}

// A terminal: tabs always, a "+" that opens the next one (as ocn's: the program names the instance).
@(private = "file")
term_view :: proc(v: ^ui.View, r: ^Dock) {
	ui.label(fmt.tprintf("The shell %s###term_words", v.instance))
}

@(private = "file")
term_new :: proc(data: rawptr) {
	r := (^Dock)(data)
	r.terms += 1
	if r.later { return }
	ui.view_open(&r.views, "term", r, fmt.tprintf("t%d", r.terms))
}

@(private = "file")
hug_view :: proc(v: ^ui.View, r: ^Dock) {
	ui.view_size(v, r.hug_w, 0)
	if ui.dialog_body("hug_body") { ui.label("A picture###hug_words") }
}

@(private = "file")
plain_view :: proc(v: ^ui.View, r: ^Dock) {
	if ui.dialog_body("plain_body") { ui.label("A question###plain_words") }
}

@(private = "file")
dock_start :: proc(t: ^testing.T, r: ^Dock, want: ..string) -> ^session.Session {
	dock_register(r)
	for w in want { append(&r.want, w) }
	return session.start(t, {size = WINDOW, user = r, build = dock_build})
}

@(private = "file")
dock_register :: proc(r: ^Dock) {
	ui.view_register(&r.views, "log", plain_view, ui.View_Options{title = "Log"})   // (an instance per name)
	ui.view_register(&r.views, "hug", hug_view, ui.View_Options{title = "Picture"})
	ui.view_register(&r.views, "term", term_view, ui.View_Options{title = "Terminal", home = .Panel, home_place = {edge = .Bottom},
		extent_em = 12, tabs_always = true, new_tab = term_new, new_tab_label = "New terminal"})
	ui.view_register(&r.views, "tabbed", tabbed_view, ui.View_Options{title = "Tabbed", home = .Panel, home_place = {edge = .Left}, extent_em = 20})
	ui.view_register(&r.views, "side", side_view, ui.View_Options{title = "Side", home = .Panel, home_place = {edge = .Left}, extent_em = SIDE_EM})
	ui.view_register(&r.views, "side2", side_view, ui.View_Options{title = "Second", home = .Panel, home_place = {edge = .Left}})
	ui.view_register(&r.views, "tool", plain_view, ui.View_Options{title = "Tool", home = .Panel, home_place = {space = "tools", edge = .Right}})
	ui.view_register(&r.views, "ask", plain_view, ui.View_Options{title = "Question"})
	ui.view_register(&r.views, "float", plain_view, ui.View_Options{title = "Floating", first = .Internal})
	ui.view_register(&r.views, "low", plain_view, ui.View_Options{title = "Low", home = .Panel, home_place = {edge = .Bottom}, extent_frac = LOW_FRAC})
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
	session.click_at(s, seen_center(s, b), button)
	return true
}

// The middle of what a person sees of `b`: inside the boxes that clip it, clear of a strip's arrows over it (a tab half
// under an arrow is clicked on its seen half, as a person does).
@(private = "file")
seen_center :: proc(s: ^session.Session, b: ^ui.Box) -> [2]f32 {
	r := b.rect
	for p := b.parent; p != nil; p = p.parent {
		if .Clip not_in p.flags { continue }
		r = {{max(r.min.x, p.rect.min.x), max(r.min.y, p.rect.min.y)}, {min(r.max.x, p.rect.max.x), min(r.max.y, p.rect.max.y)}}
	}
	for name in ([]string{"strip_left", "strip_right"}) {
		a := built(s, name)
		if a == nil || a.rect.max.x <= r.min.x || a.rect.min.x >= r.max.x || a.rect.max.y <= r.min.y || a.rect.min.y >= r.max.y { continue }
		if name == "strip_left" { r.min.x = max(r.min.x, a.rect.max.x) } else { r.max.x = min(r.max.x, a.rect.min.x) }
	}
	return (r.min + r.max) * 0.5
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
	session.drag(s, seen_center(s, tab), OUT)
	if wait_built(s, "internal_view_side") == nil { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "side"), ui.View_Presentation.Internal)
	testing.expect(t, built(s, "view_tabs") == nil, "one left in the zone: no tabs")
	// re-attach: back to its home zone
	if !click_named(s, "view_reattach") { return }
	if wait_built(s, "view_panel_view_side") == nil { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "side"), ui.View_Presentation.Panel)
}

// A view homed in a space of the program's that is not built (a section not shown) waits there: open, not built, not
// floating over the page; it shows in its space when the space is built, and waits again when the space goes (section
// 8.2, decision 2).
@(test)
a_home_in_a_hidden_space_waits_until_it_shows :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "tool")
	session.frames(s, 6)
	testing.expect(t, ui.view_is_open(&r.views, "tool"), "open")
	testing.expect_value(t, ui.view_presentation(&r.views, "tool"), ui.View_Presentation.Panel)
	testing.expect(t, built(s, "view_panel_view_tool") == nil, "no panel: its space is not built")
	testing.expect(t, session.find(s, "internal_view_tool") == nil, "no floating window over the page: it waits")
	r.tools = true
	if wait_built(s, "view_panel_view_tool") == nil { return }
	testing.expect(t, built(s, "tools_centre") != nil, "the space's centre")
	testing.expect(t, session.find(s, "internal_view_tool") == nil, "never floating")
	r.tools = false
	session.frames(s, 3)
	testing.expect(t, built(s, "view_panel_view_tool") == nil && session.find(s, "internal_view_tool") == nil, "waiting again")
	testing.expect(t, ui.view_is_open(&r.views, "tool"), "still open")
	r.tools = true
	wait_built(s, "view_panel_view_tool")
}

// A panel of the window's frame in a window that builds no views_frame floats at once (no space to wait for); it goes
// to the frame once the window builds one.
@(test)
a_frameless_window_s_panel_floats :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	r.no_frame = true
	s := dock_start(t, &r, "side")
	if wait_built(s, "internal_view_side") == nil { return }
	testing.expect(t, built(s, "view_panel_view_side") == nil, "no frame: no panel")
	r.no_frame = false
	if wait_built(s, "view_panel_view_side") == nil { return }
	session.frames(s, 2)
	testing.expect(t, built(s, "internal_view_side") == nil, "in the frame now, floating no more")
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
	sm, parsed := ui.views_space_parse(text)
	testing.expect(t, ok && parsed, "the space's line")
	testing.expectf(t, sm.extent[.Left] > SIDE_EM, "its left extent: %v", sm.extent)
}

// A zone sized by a share of its space (the view's extent_frac): that share of the window; the drag is remembered as a
// share. The program's default for a zone of its frame (View_Dock_Options.extent_frac) comes before its view's.
@(test)
a_zone_sized_by_a_share_follows_its_space :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "low")
	zone := wait_built(s, "view_zone_Bottom")
	space := built(s, "views_space_")
	handle := session.find(s, "view_handle_Bottom")
	if zone == nil || space == nil || handle == nil { testing.expect(t, false, "the zone, its space and its handle"); return }
	height :: proc(b: ^ui.Box) -> f32 { return b.rect.max.y - b.rect.min.y }
	whole := height(space)
	was := height(zone)
	testing.expectf(t, abs(was - LOW_FRAC * whole) <= 1.5, "a quarter of its space: %v of %v", was, whole)
	at := session.center(handle)
	session.drag(s, at, at - {0, GROW_PX})
	session.frames(s, 2)
	zone = built(s, "view_zone_Bottom")
	testing.expectf(t, zone != nil && abs(height(zone) - (was + GROW_PX)) <= 1.5, "taller by the drag: %v, then %v", was, zone != nil ? height(zone) : 0)
	text, ok := store.get(&r.views.memory, "#")
	sm, parsed := ui.views_space_parse(text)
	testing.expect(t, ok && parsed, "the space's line")
	testing.expectf(t, abs(sm.frac[.Bottom] - (was + GROW_PX) / whole) <= 0.01, "remembered as a share: %q", text)
	testing.expectf(t, sm.extent[.Bottom] == 0, "not in ems: %q", text)

	// the program's default for its frame's left zone, before the view's own extent_em
	r.frame_o = {extent_frac = #partial [ui.View_Edge]f32{.Left = LEFT_FRAC}}
	append(&r.want, "side")
	left := wait_built(s, "view_zone_Left")
	space = built(s, "views_space_")
	if left == nil || space == nil { return }
	w := left.rect.max.x - left.rect.min.x
	testing.expectf(t, abs(w - LEFT_FRAC * (space.rect.max.x - space.rect.min.x)) <= 1.5, "the frame's share: %v", w)
}

// The layout as at first (views_space_reset): the zone's extent the default again, its line gone, a view the user
// floated back in its zone, one the user docked there back at its home.
@(test)
views_space_reset_puts_the_layout_back :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side")
	zone := wait_built(s, "view_zone_Left")
	handle := session.find(s, "view_handle_Left")
	if zone == nil || handle == nil { testing.expect(t, false, "the zone and its handle"); return }
	at := session.center(handle)
	session.drag(s, at, at + {GROW_PX, 0})
	session.frames(s, 2)
	_, had := store.get(&r.views.memory, "#")
	testing.expect(t, had, "the space's line, after the drag")
	// (the dialog opens after the drag: a press outside a dialog, the handle's, closes it)
	append(&r.want, "ask")
	if wait_built(s, "modal_view_ask") == nil { return }
	ui.view_present(&r.views, "side", .Internal)
	ui.view_present(&r.views, "ask", .Panel, {edge = .Left})
	if wait_built(s, "internal_view_side") == nil { return }
	if wait_built(s, "view_panel_view_ask") == nil { return }

	ui.views_space_reset(&r.views, "")
	_, has := store.get(&r.views.memory, "#")
	testing.expect(t, !has, "its line went")
	if wait_built(s, "view_panel_view_side") == nil { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "side"), ui.View_Presentation.Panel)
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Dialog)
	session.frames(s, 4)
	zone = built(s, "view_zone_Left")
	testing.expectf(t, zone != nil && abs((zone.rect.max.x - zone.rect.min.x) - SIDE_EM * r.em) <= 1.5, "its extent_em again: %v", zone != nil ? zone.rect : ui.Rect{})
}

// view_dock_line says where the handle's rule is drawn, at a fractional scale and after a drag: the pixel column it
// names is the rule's, so a program's line across a bar meets it.
@(test)
the_dock_line_is_where_the_rule_is_drawn :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side")
	session.set_dpi(s, 1.25)
	if wait_built(s, "view_zone_Left") == nil { return }
	handle := session.find(s, "view_handle_Left")
	if handle == nil { testing.expect(t, false, "its handle"); return }
	at := session.center(handle)
	session.drag(s, at, at + {7, 0})
	session.wait_idle(s)
	line, ok := ui.view_dock_line(&r.views, .Left)
	if !testing.expect(t, ok, "a line: the left zone has its handle") { return }
	handle = session.find(s, "view_handle_Left")
	testing.expectf(t, line.min.x >= handle.rect.min.x && line.max.x <= handle.rect.max.x, "inside its handle: %v in %v", line, handle.rect)
	testing.expectf(t, line.min.x == math.round(line.min.x), "on a whole pixel, not across two: %v", line)
	// (moved off the handle: its rule is drawn at rest, not hot)
	session.move(s, {line.min.x + 200, line.min.y + 40})
	session.wait_idle(s)
	img := session.capture(s)
	y := int(line.min.y + 40)
	x := int(line.min.x)
	rule := session.pixel(img, x, y)
	testing.expectf(t, !session.near(rule, session.pixel(img, x - 3, y), 6) || !session.near(rule, session.pixel(img, x + 3, y), 6),
		"the rule's colour at x %d: %v, beside it %v and %v", x, rule, session.pixel(img, x - 3, y), session.pixel(img, x + 3, y))

	ui.view_close(&r.views, "side")
	session.wait_idle(s)
	_, still := ui.view_dock_line(&r.views, .Left)
	testing.expect(t, !still, "no line once nothing is docked there")
}

// Instances open at the quit are listed at the next start (view_restored_instances), each reopened by the program
// where it was; one closed before the quit is not; a quit with none open lists none.
@(test)
instances_reopen_where_they_were :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r)
	path, _ := filepath.join({s.out, "views_instances.txt"}, context.temp_allocator)
	_ = os.remove(path)   // (the session's folder stays between runs)
	restart :: proc(r: ^Dock, path: string) {
		ui.views_destroy(&r.views)
		ui.views_init(&r.views, {path = path})
		dock_register(r)
	}
	restart(&r, path)
	for n in ([]string{"alpha", "beta", "gamma"}) { ui.view_open(&r.views, "log", &r, n, owner = s.state) }
	session.frames(s, 3)
	ui.view_present(&r.views, "log", .Panel, {edge = .Right}, "beta")
	ui.view_close(&r.views, "log", "gamma")
	if wait_built(s, "view_panel_view_log/beta") == nil { return }

	restart(&r, path)
	names := ui.view_restored_instances(&r.views, "log", context.temp_allocator)
	has :: proc(names: []string, n: string) -> bool { for x in names { if x == n { return true } }; return false }
	testing.expectf(t, len(names) == 2 && has(names, "alpha") && has(names, "beta"), "alpha and beta: %v", names)
	for n in names { ui.view_open(&r.views, "log", &r, n, owner = s.state) }
	if wait_built(s, "view_panel_view_log/beta") == nil { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "log", "beta"), ui.View_Presentation.Panel)
	testing.expect_value(t, ui.view_presentation(&r.views, "log", "alpha"), ui.View_Presentation.Dialog)

	for n in names { ui.view_close(&r.views, "log", n) }
	restart(&r, path)
	testing.expect_value(t, len(ui.view_restored_instances(&r.views, "log", context.temp_allocator)), 0)
}

// A floating window over a panel: the panel's build sees it (view_occluders), and views_floating_rects lists it where
// it is; once it goes, nothing covers the panel.
@(test)
a_panel_knows_what_floats_over_it :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side", "float")
	if wait_built(s, "view_panel_view_side") == nil { return }
	frame := wait_built(s, "internal_view_float")
	if frame == nil { return }
	session.frames(s, 2)
	testing.expect_value(t, r.side_cover, 1)
	rects := ui.views_floating_rects(&r.views, s.state)
	testing.expect(t, len(rects) == 1 && rects[0] == built(s, "internal_view_float").rect, "the floating window's rect")
	ui.view_close(&r.views, "float")
	session.frames(s, 3)
	testing.expect_value(t, r.side_cover, 0)
	testing.expect_value(t, len(ui.views_floating_rects(&r.views, s.state)), 0)
}

// A right click on a tab of the body in the panel's top band opens the tab's menu, not the view's; on an empty part of
// the band, the view's menu.
@(test)
the_band_s_menu_gives_way_to_the_body_s :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "tabbed")
	panel := wait_built(s, "view_panel_view_tabbed")
	tab := built(s, "tab_in_band")
	if panel == nil || tab == nil { testing.expect(t, false, "the panel and its tab"); return }
	session.click_at(s, session.center(tab), .Right)
	session.frames(s, 2)
	testing.expect(t, ui.menu_is_open("tab_menu"), "the tab's menu")
	testing.expect(t, !ui.menu_is_open(VIEW_MENU_TABBED), "not the view's")
	session.key(s, .Escape)
	session.frames(s, 2)
	empty := [2]f32{panel.rect.min.x + TAB_W + 40, panel.rect.min.y + 8}
	session.click_at(s, empty, .Right)
	session.frames(s, 2)
	testing.expect(t, ui.menu_is_open(VIEW_MENU_TABBED), "the view's menu on the empty band")
	testing.expect(t, !ui.menu_is_open("tab_menu"))
}

// hit_box_at and pointer_on_at: what is at a point, by the last layout, wherever the pointer is.
@(test)
what_is_at_a_point :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "tabbed")
	panel := wait_built(s, "view_panel_view_tabbed")
	tab := built(s, "tab_in_band")
	if panel == nil || tab == nil { testing.expect(t, false, "the panel and its tab"); return }
	session.move(s, OUT)   // (the pointer elsewhere: the answers are of the point asked)
	ui.use(s.state)
	at := session.center(tab)
	testing.expect(t, ui.hit_box_at(at) == tab, "the tab takes a press there")
	testing.expect(t, ui.hit_box_at({panel.rect.min.x + TAB_W + 40, panel.rect.min.y + 8}) == nil, "nothing clickable beside it")
	testing.expect(t, ui.pointer_on_at(tab, at), "the tab is in front there")
	testing.expect(t, ui.pointer_on_at(panel, at), "and so is the panel around it")
	testing.expect(t, !ui.pointer_on_at(tab, OUT), "not elsewhere")
}

// tabs_always: a lone terminal has its strip. Its "+" calls new_tab; the new tab comes right after the last one, shown,
// the "+" after it; the moves sit after the "+", the stack's buttons at the right end.
@(test)
the_strip_of_a_terminal :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "term")
	if wait_built(s, "view_panel_view_term") == nil { return }
	testing.expect(t, built(s, "view_tabs") != nil, "a strip for one tab (tabs_always)")
	first := built(s, "view_tab_view_term")
	plus := built(s, "view_new_tab")
	if first == nil || plus == nil { testing.expect(t, false, "its tab and its +"); return }
	testing.expect(t, plus.rect.min.x >= first.rect.max.x, "the + after the tab")
	session.click_at(s, session.center(plus))
	if wait_built(s, "view_panel_view_term/t1") == nil { return }
	testing.expect_value(t, r.terms, 1)
	testing.expect_value(t, ui.view_presentation(&r.views, "term", "t1"), ui.View_Presentation.Panel)
	session.frames(s, 2)
	first, plus = built(s, "view_tab_view_term"), built(s, "view_new_tab")
	second := built(s, "view_tab_view_term/t1")
	detach, close := built(s, "view_detach"), built(s, "view_stack_close")
	strip := built(s, "view_tabs")
	if first == nil || plus == nil || second == nil || detach == nil || close == nil || strip == nil { testing.expect(t, false, "the strip's parts"); return }
	testing.expect(t, second.rect.min.x >= first.rect.max.x, "the new tab right after the last one")
	testing.expect(t, plus.rect.min.x >= second.rect.max.x, "the + after it")
	testing.expect(t, detach.rect.min.x >= plus.rect.max.x, "the moves after the +")
	testing.expectf(t, abs(close.rect.max.x - strip.rect.max.x) <= 1, "Close at the strip's right end: %v in %v", close.rect, strip.rect)
	testing.expect(t, built(s, "view_panel_icons") == nil, "no hover icons: the strip has them")
	// the palette offers it too, in the program's words
	commands, acts := ui.views_commands(&r.views)
	found := -1
	for c, i in commands { if c.label == "New terminal" { found = i } }
	testing.expect(t, found >= 0, "New terminal in the palette")
	if found >= 0 {
		ui.views_command_run(&r.views, acts[found])
		wait_built(s, "view_panel_view_term/t2")
	}
}

// A "+" whose new_tab answers later (a shell a server makes): the instance opened frames after the click joins the
// stack clicked, not where its kind's memory says. One that comes after NEW_TAB_WAIT_MS opens where the memory says.
@(test)
a_new_tab_that_comes_later_joins_its_stack :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "term")
	if wait_built(s, "view_panel_view_term") == nil { return }
	// (another terminal moved to the right: the kind's memory says the right from now on)
	ui.view_open(&r.views, "term", &r, "a", owner = s.state)
	session.frames(s, 2)
	ui.view_present(&r.views, "term", .Panel, {edge = .Right}, "a")
	if wait_built(s, "view_panel_view_term/a") == nil { return }
	session.frames(s, 2)
	bottom_plus :: proc(s: ^session.Session) -> ^ui.Box {
		zone := session.find(s, "view_zone_Bottom")
		return zone != nil ? session.find(s, "view_new_tab", within = zone) : nil
	}
	plus := bottom_plus(s)
	if plus == nil { testing.expect(t, false, "the bottom stack's +"); return }
	r.later = true
	session.click_at(s, session.center(plus))
	session.frames(s, 5)
	testing.expect_value(t, r.terms, 1)
	testing.expect(t, !ui.view_is_open(&r.views, "term", "t1"), "not open yet: the server answers later")
	ui.view_open(&r.views, "term", &r, "t1", owner = s.state)
	if wait_built(s, "view_panel_view_term/t1") == nil { return }
	session.frames(s, 2)
	zone := session.find(s, "view_zone_Bottom")
	testing.expect(t, zone != nil && session.find(s, "view_tab_view_term/t1", within = zone) != nil, "it joined the stack clicked")

	// too late: where the memory says (the right)
	plus = bottom_plus(s)
	if plus == nil { return }
	session.click_at(s, session.center(plus))
	session.advance(s, ui.NEW_TAB_WAIT_MS + 100)
	ui.view_open(&r.views, "term", &r, "t2", owner = s.state)
	if wait_built(s, "view_panel_view_term/t2") == nil { return }
	session.frames(s, 2)
	zone = session.find(s, "view_zone_Bottom")
	testing.expect(t, zone == nil || session.find(s, "view_tab_view_term/t2", within = zone) == nil, "after the wait: not in that stack")
	testing.expect(t, ui.view_presentation(&r.views, "term", "t2") == .Panel && session.find(s, "view_tab_view_term/t2", within = session.find(s, "view_zone_Right")) != nil, "where the memory says")
}

// The program's words are translated when shown: a language changed during the session shows in the palette's "New
// terminal" at once (new_tab_label), and in the views' own words.
@(test)
the_words_follow_the_language :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "term")
	if wait_built(s, "view_panel_view_term") == nil { return }
	label :: proc(r: ^Dock) -> string {
		commands, acts := ui.views_commands(&r.views)
		for a, i in acts { if a.act == .New_Tab { return commands[i].label } }
		return ""
	}
	testing.expect_value(t, label(&r), "New terminal")
	l, _ := i18n.load("fr", {{"fr", "language fr\n\nen New terminal\nfr Nouveau terminal\n\nen Terminal\nfr Console\n"}})
	defer { i18n.use(nil); i18n.destroy(l) }
	i18n.use(l)
	session.frames(s, 2)
	testing.expect_value(t, label(&r), "Nouveau terminal")
	testing.expect(t, session.find_text(s, "Console") != nil, "the tab's title, translated")
}

// Maximise: the stack fills the dock space, the content is not seen; again restores. Minimise: the zone is its strip
// only, remembered; a click on a tab restores it. Close: every view of the stack.
@(test)
a_stack_maximises_minimises_and_closes :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "term")
	if wait_built(s, "view_panel_view_term") == nil { return }
	space := built(s, "views_space_")
	if space == nil || !click_named(s, "view_stack_max") { return }
	session.frames(s, 2)
	_, _, maxed := ui.views_space_maximised(&r.views, "")
	testing.expect(t, maxed, "maximised")
	zone := built(s, "view_zone_Bottom")
	testing.expectf(t, zone != nil && abs((zone.rect.max.y - zone.rect.min.y) - (space.rect.max.y - space.rect.min.y)) <= 1, "the whole space: %v", zone != nil ? zone.rect : ui.Rect{})
	// (session.find finds only boxes laid out with a width: the content's box at no size is not found. What is in it
	// keeps its own width, clipped away by it: not a sign)
	testing.expect(t, session.find(s, "views_content") == nil, "the content laid out at no size: not seen")
	if !click_named(s, "view_stack_max") { return }
	session.frames(s, 2)
	_, _, maxed = ui.views_space_maximised(&r.views, "")
	testing.expect(t, !maxed, "restored")

	if !click_named(s, "view_stack_min") { return }
	session.frames(s, 2)
	zone = built(s, "view_zone_Bottom")
	testing.expectf(t, zone != nil && abs((zone.rect.max.y - zone.rect.min.y) - ui.DOCK_TAB_EM * r.em) <= 1.5, "its strip only: %v", zone != nil ? zone.rect : ui.Rect{})
	testing.expect(t, built(s, "view_panel_view_term") == nil, "no body")
	text, _ := store.get(&r.views.memory, "#")
	sm, _ := ui.views_space_parse(text)
	testing.expectf(t, sm.minimised[.Bottom], "remembered: %q", text)
	if !click_named(s, "view_tab_view_term") { return }
	if wait_built(s, "view_panel_view_term") == nil { return }

	term_new(&r)
	if wait_built(s, "view_panel_view_term/t1") == nil { return }
	if !click_named(s, "view_stack_close") { return }
	session.frames(s, 3)
	testing.expect(t, !ui.view_is_open(&r.views, "term") && !ui.view_is_open(&r.views, "term", "t1"), "both tabs closed")
}

// A floating window with no rect opens centred over the program's content, not over the whole window: with a panel at
// the left, its middle is the content's middle, across and down, and it does not cover the panel.
@(test)
a_floating_window_opens_over_the_content :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side")
	if wait_built(s, "view_panel_view_side") == nil { return }
	append(&r.want, "float")
	frame := wait_built(s, "internal_view_float")
	if frame == nil { return }
	session.frames(s, 2)
	frame = built(s, "internal_view_float")
	content := built(s, "views_content")
	zone := built(s, "view_zone_Left")
	if frame == nil || content == nil || zone == nil { testing.expect(t, false, "the window, the content and the zone"); return }
	mid :: proc(r: ui.Rect) -> [2]f32 { return (r.min + r.max) * 0.5 }
	d := mid(frame.rect) - mid(content.rect)
	testing.expectf(t, abs(d.x) <= 2 && abs(d.y) <= 2, "centred over the content: %v in %v", frame.rect, content.rect)
	testing.expectf(t, frame.rect.min.x >= zone.rect.max.x, "not over the panel: %v, the zone %v", frame.rect, zone.rect)
}

// view_size: this opening's dialog as wide as asked, past DIALOG_MAX_WIDTH_EM (a viewer that hugs its picture).
@(test)
a_dialog_takes_the_size_of_its_opening :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	r.hug_w = ui.DIALOG_MAX_WIDTH_EM + 4
	s := dock_start(t, &r, "hug")
	b := wait_built(s, "modal_view_hug")
	if b == nil { return }
	session.frames(s, 2)
	b = built(s, "modal_view_hug")
	w := b != nil ? b.rect.max.x - b.rect.min.x : 0
	testing.expectf(t, abs(w - r.hug_w * r.em) <= 2, "%v ems wide: %v px at %v px an em", r.hug_w, w, r.em)
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
	// the program asks where the focus is, rather than guess it
	testing.expect(t, ui.view_has_focus(&r.views, "side"), "the panel has the focus")
	id, _, has := ui.views_focus(&r.views)
	testing.expect(t, has && id == "side", "views_focus says it")
	session.type_text(s, "abc")
	testing.expect_value(t, ui.line_edit_string(&r.field), "abc")
	session.key(s, .F2)
	testing.expect_value(t, r.content_k, 1)
	// Escape: the focus back to the content, the panel stays
	session.key(s, .Escape)
	session.frames(s, 2)
	testing.expect(t, session.focused_name(s) != "side_field", "the focus left the panel")
	testing.expect(t, ui.view_is_open(&r.views, "side"), "the panel stays")
	testing.expect(t, !ui.view_has_focus(&r.views, "side"), "no view has the focus now")
	_, _, has = ui.views_focus(&r.views)
	testing.expect(t, !has, "views_focus: none")
}

// A program that binds F6 itself, read in its content (after views_frame): its binding wins, the toolkit's F6 moves no
// focus (it acts only on an F6 nothing in the build took).
@(test)
a_program_s_own_f6_wins :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	r.own_f6 = true
	s := dock_start(t, &r, "side")
	if wait_built(s, "view_panel_view_side") == nil { return }
	if !click_named(s, "content_button") { return }
	session.key(s, .F6)
	testing.expect_value(t, r.f6_taken, 1)
	testing.expect(t, session.focused_name(s) != "side_field", "the toolkit did not move the focus")
	r.own_f6 = false
	session.key(s, .F6)
	testing.expect_value(t, session.focused_name(s), "side_field")
}

// view_restore: at the very first start (no line), opened when asked; a line that says closed keeps it closed, one
// that says open opens it.
@(test)
view_restore_respects_the_user_s_choice :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r)
	testing.expect(t, !ui.view_restore(&r.views, "side2", &r, owner = s.state), "no line, not asked: closed")
	testing.expect(t, ui.view_restore(&r.views, "side", &r, first_start_open = true, owner = s.state), "no line, asked: opened")
	ui.view_close(&r.views, "side")
	_ = store.set(&r.views.memory, "side", "v1 open=0")
	testing.expect(t, !ui.view_restore(&r.views, "side", &r, first_start_open = true, owner = s.state), "the user closed it: stays closed")
	_ = store.set(&r.views.memory, "side", "v1 open=1")
	testing.expect(t, ui.view_restore(&r.views, "side", &r, first_start_open = true, owner = s.state), "open at the last quit: opened")
}
