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
import i18n "gt:i18n"
import "gt:platform"
import store "gt:store"
import "gt:testkit/session"
import "gt:ui"

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
	railed:     bool,              // "marks" was last built in its compact form (View.rail)
	fold:       ui.Signal,         // what "marks"'s fold button gave in its last build (view_fold_button)
	wide:       bool,              // the content holds a row of WIDE_BOXES boxes, wider than the window
	bare:       bool,              // build the space "bare", without content (a centre zone)
	title_bar:  bool,              // a bar of TITLE_BAR_PX above the frame (a program's title bar)
	inset:      bool,              // the frame INSET_PX in from every edge of the window (a face at an edge has no rim)
}

@(private = "file") TITLE_BAR_PX :: 30
@(private = "file") INSET_PX :: 40

// A row of boxes of their own width, wider than the window: what a tool bar or a program's row asks of its parent.
@(private = "file") WIDE_BOXES :: 30
@(private = "file") WIDE_BOX_PX :: 100

@(private = "file")
wide_row :: proc(id: string) {
	ui.next({width = ui.children_sum(), height = ui.px(20), axis = .X})
	if ui.row(id = fmt.tprintf("###%s", id)) {
		for i in 0 ..< WIDE_BOXES {
			ui.next({width = ui.px(WIDE_BOX_PX), height = ui.px(20)})
			ui.build_box({.Draw_Background}, fmt.tprintf("###%s_box%d", id, i))
		}
	}
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
	if r.title_bar {
		ui.next({width = ui.fill(), height = ui.px(TITLE_BAR_PX)})
		ui.build_box({}, "###title_bar")
	}
	if r.inset {
		ui.spacer(ui.px(INSET_PX))
		ui.next({width = ui.fill(), height = ui.px(f32(WINDOW.y - 2 * INSET_PX)), axis = .X})
		ui.push_parent(ui.build_box({}, "###inset_row"))
		ui.spacer(ui.px(INSET_PX))
		ui.next({width = ui.px(f32(WINDOW.x - 2 * INSET_PX)), height = ui.fill(), axis = .Y})
		ui.push_parent(ui.build_box({}, "###inset_column"))
	}
	defer if r.inset { ui.pop_parent(); ui.pop_parent() }
	if ui.views_frame(&r.views, r.frame_o) {
		if ui.key_press(.F2) { r.content_k += 1 }
		if r.own_f6 && ui.key_press(.F6) { r.f6_taken += 1 }
		ui.next({width = ui.px(200)})
		ui.button("content_button", "In the content")
		if r.wide { wide_row("content_row") }
		if r.tools {
			ui.next({width = ui.fill(), height = ui.px(200)})
			if ui.views_dock(&r.views, "tools", {content = true}) { ui.label("The tools' centre###tools_centre") }
		}
		if r.bare {
			ui.next({width = ui.fill(), height = ui.px(200)})
			if ui.views_dock(&r.views, "bare", {}) {}
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

// A row of tabs on a strip in a lone panel's top band, the first chosen, a "+" after it (opencode native's server tabs at
// the top of its sidebar): the strip's right arrow lies under the panel's hover icons' corner.
@(private = "file") STRIPED_TABS :: 12
@(private = "file")
striped_view :: proc(v: ^ui.View, r: ^Dock) {
	ui.next({width = ui.fill(), height = ui.px(30), axis = .X})
	if ui.row(id = "###striped_row") {
		ui.spacer(ui.px(10))
		if ui.strip("###striped_strip") {
			for i in 0 ..< STRIPED_TABS {
				ui.next({width = ui.px(70), height = ui.pct(1)})
				b := ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###stab%d", i))
				if i == 0 { ui.strip_reveal(b) }
			}
		}
		ui.next({width = ui.px(28), height = ui.pct(1)})
		ui.build_box({.Clickable}, "###stab_add")
		ui.spacer(ui.px(10))
	}
	ui.label("The striped side's words###striped_words")
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

// A view with a compact form: minimised, its zone keeps RAIL_EM and builds it with View.rail (a column of marks). Its
// first row starts with its zone's fold button, FOLD_INSET from the left in both forms (opencode native's servers' row
// and the top of its rail).
@(private = "file") RAIL_EM :: 3.5
@(private = "file") FOLD_INSET :: 6
@(private = "file")
marks_view :: proc(v: ^ui.View, r: ^Dock) {
	r.railed = v.rail
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###marks_row") {
		ui.spacer(ui.px(FOLD_INSET))
		r.fold = ui.view_fold_button(v)
	}
	ui.label(v.rail ? "M###marks_compact" : "The marks in full###marks_full")
}

// opencode native's sidebar: its fold button in its first row, under a margin of half an em, its words under it.
@(private = "file") FOLD_MARGIN_EM :: 0.5
@(private = "file")
fold_view :: proc(v: ^ui.View, r: ^Dock) {
	ui.next({width = ui.fill(), height = ui.px(math.round(ui.font_size() * FOLD_MARGIN_EM))})
	ui.build_box({}, "###fold_margin")
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###fold_row") {
		ui.spacer(ui.px(FOLD_INSET))
		r.fold = ui.view_fold_button(v)
	}
	ui.label("The sidebar's words###fold_words")
}

@(private = "file")
wide_view :: proc(v: ^ui.View, r: ^Dock) {
	wide_row("panel_row")
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
	ui.view_register(&r.views, "striped", striped_view, ui.View_Options{title = "Striped", home = .Panel, home_place = {edge = .Left}, extent_em = SIDE_EM})
	ui.view_register(&r.views, "tool", plain_view, ui.View_Options{title = "Tool", home = .Panel, home_place = {space = "tools", edge = .Right}})
	ui.view_register(&r.views, "ask", plain_view, ui.View_Options{title = "Question"})
	ui.view_register(&r.views, "float", plain_view, ui.View_Options{title = "Floating", first = .Internal})
	ui.view_register(&r.views, "low", plain_view, ui.View_Options{title = "Low", home = .Panel, home_place = {edge = .Bottom}, extent_frac = LOW_FRAC})
	ui.view_register(&r.views, "marks", marks_view, ui.View_Options{title = "Marks", home = .Panel, home_place = {edge = .Left}, extent_em = SIDE_EM, rail_em = RAIL_EM})
	ui.view_register(&r.views, "marks_low", marks_view, ui.View_Options{title = "Low marks", home = .Panel, home_place = {edge = .Bottom}, rail_em = RAIL_EM})
	ui.view_register(&r.views, "marks_mid", marks_view, ui.View_Options{title = "Middle marks", home = .Panel, home_place = {space = "bare", edge = .Center}, rail_em = RAIL_EM})
	ui.view_register(&r.views, "right", plain_view, ui.View_Options{title = "Right", home = .Panel, home_place = {edge = .Right}, extent_em = SIDE_EM})
	ui.view_register(&r.views, "sidebar", fold_view, ui.View_Options{title = "Sidebar", home = .Panel, home_place = {edge = .Left}, extent_em = SIDE_EM})
	ui.view_register(&r.views, "wide", wide_view, ui.View_Options{title = "Wide", home = .Panel, home_place = {edge = .Left}, extent_em = SIDE_EM})
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

// A side zone minimised collapses to its rail (views.md, Minimise): one strip wide, a Restore and a button per view, no
// body; a click on the view's button brings the zone back at its extent with the view shown.
@(test)
a_side_zone_minimises_to_its_rail :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side")
	zone := wait_built(s, "view_zone_Left")
	if zone == nil { return }
	top := zone.rect.min
	session.move(s, {top.x + 30, top.y + 2})
	if wait_built(s, "view_stack_min") == nil { return }
	stack_min := built(s, "view_stack_min")
	testing.expectf(t, stack_min != nil && stack_min.rect.max.x <= zone.rect.max.x + 0.5, "its Minimise whole in the zone: %v in %v", stack_min.rect if stack_min != nil else ui.Rect{}, zone.rect)
	session.click(s, "view_stack_min")
	if wait_built(s, "view_rail_restore") == nil { return }
	zone = built(s, "view_zone_Left")
	testing.expectf(t, zone != nil && abs((zone.rect.max.x - zone.rect.min.x) - ui.DOCK_TAB_EM * r.em) <= 1.5, "one strip wide: %v", zone.rect if zone != nil else ui.Rect{})
	testing.expect(t, built(s, "view_panel_view_side") == nil, "no body")
	if wait_built(s, "view_rail_Left_0_0") == nil { return }
	session.click(s, "view_rail_Left_0_0")
	if wait_built(s, "view_panel_view_side") == nil { return }
	zone = built(s, "view_zone_Left")
	testing.expectf(t, zone != nil && abs((zone.rect.max.x - zone.rect.min.x) - SIDE_EM * r.em) <= 1.5, "back at its extent: %v", zone.rect if zone != nil else ui.Rect{})
	testing.expect(t, built(s, "view_rail_restore") == nil, "no rail")
}

// Whether two rects are the same within a pixel.
@(private = "file")
same_rect :: proc(a, b: ui.Rect) -> bool {
	return abs(a.min.x - b.min.x) <= 1 && abs(a.min.y - b.min.y) <= 1 && abs(a.max.x - b.max.x) <= 1 && abs(a.max.y - b.max.y) <= 1
}

// A view that states a rail width (View_Options.rail_em) places its zone's fold button in a row it has (views.md,
// Minimise): lone in its zone, at rest, no row of the toolkit's (its body starts at the zone's top), the button's
// Minimise folds the zone to that column, where the view is built with View.rail (its compact form) and its button,
// at the same rect, is the zone's Restore (the toolkit's rail draws none), which brings the full form back.
@(test)
a_view_with_a_rail_width_places_its_fold_button :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "marks")
	zone := wait_built(s, "view_zone_Left")
	if zone == nil { return }
	testing.expect(t, built(s, "marks_full") != nil && !r.railed, "its full form")
	fold := wait_built(s, "view_fold")
	if fold == nil { return }
	at := fold.rect
	testing.expect(t, built(s, "view_tabs") == nil, "at rest: no strip")
	body := built(s, "view_panel_view_marks")
	testing.expectf(t, body != nil && abs(body.rect.min.y - zone.rect.min.y) <= 0.5, "no row above the body: %v in %v", body.rect if body != nil else ui.Rect{}, zone.rect)
	testing.expectf(t, abs(at.min.x - (zone.rect.min.x + FOLD_INSET)) <= 1, "where the view put it: %v in %v", at, zone.rect)
	session.click(s, "view_fold")
	if wait_built(s, "marks_compact") == nil { return }
	testing.expect(t, r.railed, "built with View.rail")
	zone = built(s, "view_zone_Left")
	testing.expectf(t, zone != nil && abs((zone.rect.max.x - zone.rect.min.x) - RAIL_EM * r.em) <= 1.5, "its rail width: %v", zone.rect if zone != nil else ui.Rect{})
	testing.expect(t, built(s, "view_rail_Left_0_0") == nil, "not the icons' rail")
	testing.expect(t, built(s, "view_rail_restore") == nil, "no Restore of the toolkit's")
	text, _ := store.get(&r.views.memory, "#")
	sm, _ := ui.views_space_parse(text)
	testing.expectf(t, sm.fold[.Left].folded, "minimised, remembered: %q", text)
	fold = built(s, "view_fold")
	testing.expectf(t, fold != nil && same_rect(fold.rect, at), "Restore at Minimise's place: %v, %v", fold.rect if fold != nil else ui.Rect{}, at)
	session.click(s, "view_fold")
	if wait_built(s, "marks_full") == nil { return }
	testing.expect(t, !r.railed, "its full form again")
	fold = wait_built(s, "view_fold")
	testing.expectf(t, fold != nil && same_rect(fold.rect, at), "Minimise back at its place: %v, %v", fold.rect if fold != nil else ui.Rect{}, at)
	text, _ = store.get(&r.views.memory, "#")
	sm, _ = ui.views_space_parse(text)
	testing.expectf(t, !sm.fold[.Left].folded, "restored, remembered: %q", text)
}

// The panel that places its fold button: its strip on hover has the strip's own buttons but no Minimise (said once).
@(test)
a_fold_button_s_strip_says_minimise_once :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "marks")
	fold := wait_built(s, "view_fold")
	body := built(s, "view_panel_view_marks")
	if fold == nil || body == nil { testing.expect(t, false, "the fold button and the body"); return }
	session.move(s, {body.rect.min.x + RAIL_EM * r.em + 30, body.rect.min.y + 2})
	if wait_built(s, "view_tabs") == nil { return }
	testing.expect(t, built(s, "view_stack_max") != nil, "the strip's own buttons")
	testing.expect(t, built(s, "view_stack_min") == nil, "no second Minimise")
	testing.expect(t, built(s, "view_fold") != nil, "the view's button stays")
}

// A view with a rail width lone at the bottom or in a space's centre: its fold button builds nothing there (a bottom
// zone folds to its strips, the centre does not fold).
@(test)
a_fold_button_elsewhere_builds_nothing :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	r.bare = true
	s := dock_start(t, &r, "marks_low", "marks_mid")
	if wait_built(s, "view_panel_view_marks_low") == nil || wait_built(s, "view_panel_view_marks_mid") == nil { return }
	session.frames(s, 2)
	testing.expect(t, built(s, "view_fold") == nil, "no fold button")
	testing.expect(t, r.fold == {}, "no signal")
}

// The two rails: the icons' ("side", its toolkit Restore) and a compact form ("marks", the view's button).
@(private = "file") RAILS :: [2]string{"side", "marks"}

// Its zone minimised by the rail's kind of button: the strip's Minimise (on hover) or the view's fold button.
@(private = "file")
rail_minimise :: proc(s: ^session.Session, id: string) -> (rail: ^ui.Box) {
	zone := wait_built(s, "view_zone_Left")
	if zone == nil { return }
	if id == "marks" {
		if wait_built(s, "view_fold") == nil { return }
		session.click(s, "view_fold")
		return wait_built(s, "marks_compact") != nil ? built(s, "view_zone_Left") : nil
	}
	session.move(s, {zone.rect.min.x + 30, zone.rect.min.y + 2})
	if wait_built(s, "view_stack_min") == nil { return }
	session.click(s, "view_stack_min")
	return wait_built(s, "view_rail_restore") != nil ? built(s, "view_zone_Left") : nil
}

// The zone's width shown, and whether its memory says minimised.
@(private = "file")
zone_state :: proc(s: ^session.Session) -> (width: f32, minimised: bool) {
	r := (^Dock)(s.user)
	if z := built(s, "view_zone_Left"); z != nil { width = z.rect.max.x - z.rect.min.x }
	text, _ := store.get(&r.views.memory, "#")
	sm, _ := ui.views_space_parse(text)
	return width, sm.fold[.Left].folded
}

// A side zone's rail keeps the expanded zone's edge line (views.md, Minimise): its handle, at the rail's inner edge,
// the line view_dock_line names inside it; for both rails.
@(test)
a_rail_keeps_its_zone_s_edge_line :: proc(t: ^testing.T) {
	for id in RAILS {
		r: Dock
		defer dock_end(&r)
		s := dock_start(t, &r, id)
		rail := rail_minimise(s, id)
		if rail == nil { testing.expectf(t, false, "%s: its rail", id); continue }
		session.frames(s, 2)
		rail = built(s, "view_zone_Left")
		handle := built(s, "view_handle_Left")
		if rail == nil || handle == nil { testing.expectf(t, false, "%s: the rail and its handle", id); continue }
		testing.expectf(t, abs(handle.rect.min.x - rail.rect.max.x) <= 0.5, "%s: the handle at the rail's inner edge: %v, %v", id, handle.rect, rail.rect)
		line, ok := ui.view_dock_line(&r.views, .Left)
		testing.expectf(t, ok && line.min.x >= handle.rect.min.x && line.max.x <= handle.rect.max.x, "%s: its line in its handle: %v in %v", id, line, handle.rect)
	}
}

// Pulling a rail's edge opens its zone (views.md, Minimise): less than SIDE_PULL_EM, or inward, does nothing;
// past it the zone is no longer minimised and follows the pointer; let go, the width is kept and remembered. The same
// drag down to the rail folds it again, its extent kept. For both rails.
@(test)
pulling_a_rail_opens_its_zone :: proc(t: ^testing.T) {
	for id in RAILS {
		r: Dock
		defer dock_end(&r)
		s := dock_start(t, &r, id)
		if rail_minimise(s, id) == nil { testing.expectf(t, false, "%s: its rail", id); continue }
		session.frames(s, 2)
		handle := built(s, "view_handle_Left")
		if handle == nil { testing.expectf(t, false, "%s: the rail's handle", id); continue }
		rail_w, _ := zone_state(s)
		at := session.center(handle)
		em := r.em

		session.drag(s, at, at - {2 * em, 0})
		w, mini := zone_state(s)
		testing.expectf(t, mini && abs(w - rail_w) <= 0.5, "%s: inward, nothing: %v, %v", id, w, mini)
		session.drag(s, at, at + {0.5 * em, 0})
		w, mini = zone_state(s)
		testing.expectf(t, mini && abs(w - rail_w) <= 0.5, "%s: under the threshold, nothing: %v, %v", id, w, mini)

		session.press(s, at)
		session.move(s, at + {2 * em, 0})
		session.move(s, at + {4 * em, 0})
		w, mini = zone_state(s)
		testing.expectf(t, !mini && abs(w - (rail_w + 4 * em)) <= 1.5, "%s: open, at the pointer: %v, %v", id, w, mini)
		session.move(s, at + {6 * em, 0})
		w, mini = zone_state(s)
		testing.expectf(t, !mini && abs(w - (rail_w + 6 * em)) <= 1.5, "%s: it follows: %v", id, w)
		session.release(s, at + {6 * em, 0})
		session.frames(s, 2)
		w, mini = zone_state(s)
		text, _ := store.get(&r.views.memory, "#")
		sm, _ := ui.views_space_parse(text)
		testing.expectf(t, !mini && abs(w - (rail_w + 6 * em)) <= 1.5, "%s: let go, kept: %v", id, w)
		testing.expectf(t, abs(sm.extent[.Left] * em - (rail_w + 6 * em)) <= 1.5, "%s: remembered: %q", id, text)

		// (from expanded, the same drag down to the rail folds it; its extent stays the one it had)
		handle = built(s, "view_handle_Left")
		if handle == nil { testing.expectf(t, false, "%s: the open zone's handle", id); continue }
		from := session.center(handle)
		session.drag(s, from, from - {6 * em, 0})
		session.frames(s, 2)
		w, mini = zone_state(s)
		text, _ = store.get(&r.views.memory, "#")
		sm, _ = ui.views_space_parse(text)
		testing.expectf(t, mini && abs(w - rail_w) <= 0.5, "%s: folded to its rail: %v, %v", id, w, mini)
		testing.expectf(t, abs(sm.extent[.Left] * em - (rail_w + 6 * em)) <= 1.5, "%s: its extent kept: %q", id, text)
	}
}

// The zone's fold as its memory says it (side-panels.md: both bits).
@(private = "file")
zone_fold :: proc(s: ^session.Session) -> ui.Side_Fold {
	text, _ := store.get(&(^Dock)(s.user).views.memory, "#")
	sm, _ := ui.views_space_parse(text)
	return sm.fold[.Left]
}

// A window `w` ems of the font wide (the test window's height).
@(private = "file")
window_em :: proc(r: ^Dock, w: f32) -> [2]int { return {int(math.round(w * r.em)), WINDOW.y} }

// A space too narrow for a side zone and the content folds the zone to its rail (side-panels.md), remembered as the
// automatic state; a Restore while narrow holds through another narrow width, until the width crosses the threshold:
// wide, then narrow again, it folds again by itself; wide again it is at its extent.
// (Before 0.313: "with no change to its memory" is replaced by the memory's two bits; the other checks still hold.)
@(test)
a_narrow_space_folds_a_side_zone :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side")
	if wait_built(s, "view_panel_view_side") == nil { return }
	narrow := window_em(&r, SIDE_EM + ui.DOCK_MIN_EM * 0.5)
	session.resize(s, narrow)
	if wait_built(s, "view_rail_restore") == nil { return }
	testing.expect(t, built(s, "view_panel_view_side") == nil, "folded: no body")
	testing.expectf(t, zone_fold(s) == {folded = true, narrow = true}, "the automatic state, remembered: %v", zone_fold(s))
	session.click(s, "view_rail_restore")
	if wait_built(s, "view_panel_view_side") == nil { return }
	testing.expect(t, built(s, "view_rail_restore") == nil, "opened again while narrow")
	testing.expectf(t, zone_fold(s) == {folded = false, narrow = true}, "a manual opening, remembered: %v", zone_fold(s))
	session.resize(s, window_em(&r, SIDE_EM + ui.DOCK_MIN_EM * 0.8))
	session.frames(s, 3)
	testing.expect(t, built(s, "view_panel_view_side") != nil, "another narrow width: the opening holds")
	session.resize(s, WINDOW)
	session.frames(s, 3)
	testing.expectf(t, zone_fold(s) == {}, "wide: the automatic state again: %v", zone_fold(s))
	session.resize(s, narrow)
	if wait_built(s, "view_rail_restore") == nil { return }   // (the crossing ended the opening: narrow folds it again)
	session.resize(s, WINDOW)
	if wait_built(s, "view_panel_view_side") == nil { return }
	zone := built(s, "view_zone_Left")
	testing.expectf(t, zone != nil && abs((zone.rect.max.x - zone.rect.min.x) - SIDE_EM * r.em) <= 1.5, "wide again: at its extent: %v", zone.rect if zone != nil else ui.Rect{})
}

// A Minimise while wide holds through another wide width, until the width crosses the threshold: narrow, the zone stays
// folded (now the automatic state); wide again, it opens by itself. (Before 0.313 a Minimise was kept forever.)
@(test)
a_minimise_while_wide_holds_until_the_next_crossing :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side")
	if rail_minimise(s, "side") == nil { return }
	testing.expectf(t, zone_fold(s) == {folded = true}, "a manual fold, remembered: %v", zone_fold(s))
	session.resize(s, window_em(&r, SIDE_EM + ui.DOCK_MIN_EM + 10))
	session.frames(s, 3)
	testing.expect(t, built(s, "view_rail_restore") != nil, "another wide width: the fold holds")
	session.resize(s, window_em(&r, SIDE_EM + ui.DOCK_MIN_EM * 0.5))
	session.frames(s, 3)
	testing.expect(t, built(s, "view_rail_restore") != nil, "narrow: folded")
	testing.expectf(t, zone_fold(s) == {folded = true, narrow = true}, "the automatic state: %v", zone_fold(s))
	session.resize(s, WINDOW)
	if wait_built(s, "view_panel_view_side") == nil { return }   // (wide again: open by itself)
	testing.expectf(t, zone_fold(s) == {}, "the automatic state: %v", zone_fold(s))
}

// A sweep of the window's width around the threshold, down and up and jittering: the zone folds once on the way down,
// under the threshold, and opens once on the way up, past the threshold plus SIDE_FOLD_GAP_EM; never more.
@(test)
a_sweep_around_the_threshold_does_not_flap :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side")
	if wait_built(s, "view_panel_view_side") == nil { return }
	threshold := (SIDE_EM + ui.DOCK_MIN_EM) * r.em   // (the space less the zone leaves the content its least)
	changes := 0
	was := false
	folded_at, opened_at: f32
	step :: proc(s: ^session.Session, w: f32) -> bool {
		session.resize(s, {int(w), WINDOW.y})
		session.frames(s, 2)
		return zone_fold(s).folded
	}
	widths := make([dynamic]f32, context.temp_allocator)
	for w := threshold + 2 * r.em; w >= threshold - 2 * r.em; w -= 3 { append(&widths, w) }
	for w := threshold - 2 * r.em; w <= threshold + 2 * r.em; w += 3 { append(&widths, w) }
	for w in widths {
		now := step(s, w)
		if now != was {
			changes += 1
			if now { folded_at = w } else { opened_at = w }
		}
		was = now
	}
	testing.expectf(t, changes == 2, "once each way: %d changes", changes)
	testing.expectf(t, folded_at < threshold, "folded under the threshold: %v < %v", folded_at, threshold)
	testing.expectf(t, opened_at >= threshold + ui.SIDE_FOLD_GAP_EM * r.em - 1, "opened past the gap: %v, %v", opened_at, threshold)
	// (folded again, then a jitter of a few pixels around the threshold: no change)
	_ = step(s, threshold - r.em)
	changes = 0
	was = zone_fold(s).folded
	for i in 0 ..< 20 {
		now := step(s, threshold + f32(i % 2 == 0 ? 3 : -3))
		if now != was { changes += 1 }
		was = now
	}
	testing.expectf(t, changes == 0, "a jitter around the threshold: %d changes", changes)
}

// opencode native's frame (side-panels.md, Two sides): a sidebar at the left (BAR_EM, its least BAR_MIN_EM) and an
// aside of ASIDE_PX at the right (its least ASIDE_MIN_EM). As the window narrows, the aside narrows to its least, then
// folds to its rail; then the sidebar narrows to its least and folds. At no width does a zone or the content pass the
// window's edge.
@(private = "file") BAR_EM :: 20
@(private = "file") BAR_MIN_EM :: 14
@(private = "file") ASIDE_PX :: 448
@(private = "file") ASIDE_MIN_EM :: 18
@(test)
both_sides_fit_a_narrow_window :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r)
	session.frames(s, 2)   // (the font size, before the aside's extent in ems)
	if r.em <= 0 { testing.expect(t, false, "a build"); return }
	ui.view_register(&r.views, "bar", plain_view, ui.View_Options{title = "Sessions", home = .Panel, home_place = {edge = .Left},
		extent_em = BAR_EM, min_width_em = BAR_MIN_EM})
	ui.view_register(&r.views, "aside", plain_view, ui.View_Options{title = "Aside", home = .Panel, home_place = {edge = .Right},
		extent_em = ASIDE_PX / r.em, min_width_em = ASIDE_MIN_EM})
	append(&r.want, "bar", "aside")
	if wait_built(s, "view_zone_Right") == nil { return }
	fold :: proc(s: ^session.Session, e: ui.View_Edge) -> bool {
		text, _ := store.get(&(^Dock)(s.user).views.memory, "#")
		sm, _ := ui.views_space_parse(text)
		return sm.fold[e].folded
	}
	wide :: proc(b: ^ui.Box) -> f32 { return b != nil ? b.rect.max.x - b.rect.min.x : 0 }
	// (each width in ems, what it must show: the aside open and narrowed, the aside folded, the sidebar narrowed, both
	// folded)
	Step :: struct { em: f32, aside_open, aside_narrow, bar_open, bar_narrow: bool }
	steps := []Step{
		{60, true, false, true, false},
		{46, true, true, true, false},
		{40, false, false, true, false},
		{22, false, false, true, true},
		{16, false, false, false, false},
	}
	for st in steps {
		size := window_em(&r, st.em)
		session.resize(s, size)
		session.frames(s, 4)
		w := f32(size.x)
		for name in ([]string{"view_zone_Left", "views_content", "view_zone_Right"}) {
			b := built(s, name)
			if b == nil { testing.expectf(t, false, "%v em: %s built", st.em, name); continue }
			testing.expectf(t, b.rect.min.x >= -0.5 && b.rect.max.x <= w + 0.5, "%v em: %s inside the window (%v): %v", st.em, name, w, b.rect)
		}
		left, right := wide(built(s, "view_zone_Left")), wide(built(s, "view_zone_Right"))
		testing.expectf(t, fold(s, .Right) == !st.aside_open, "%v em: the aside open %v", st.em, st.aside_open)
		testing.expectf(t, fold(s, .Left) == !st.bar_open, "%v em: the sidebar open %v", st.em, st.bar_open)
		if st.aside_open {
			full := abs(right - ASIDE_PX) <= 1.5
			testing.expectf(t, full == !st.aside_narrow, "%v em: the aside at its extent %v: %v", st.em, !st.aside_narrow, right)
			testing.expectf(t, right >= ASIDE_MIN_EM * r.em - 1.5, "%v em: the aside no narrower than its least: %v", st.em, right)
		}
		if st.bar_open {
			full := abs(left - BAR_EM * r.em) <= 1.5
			testing.expectf(t, full == !st.bar_narrow, "%v em: the sidebar at its extent %v: %v", st.em, !st.bar_narrow, left)
			testing.expectf(t, left >= BAR_MIN_EM * r.em - 1.5, "%v em: the sidebar no narrower than its least: %v", st.em, left)
		}
	}
	// (wide again: both at their extents, which the fit did not change)
	session.resize(s, WINDOW)
	session.frames(s, 4)
	left, right := wide(built(s, "view_zone_Left")), wide(built(s, "view_zone_Right"))
	testing.expectf(t, abs(left - BAR_EM * r.em) <= 1.5 && abs(right - ASIDE_PX) <= 1.5, "wide again: at their extents: %v, %v", left, right)
}

// A restart keeps a manual choice when the window is on the same side of the threshold: a Minimise while wide, restarted
// wide, is still folded; restarted narrow (a crossing) it is the automatic state, and wide again it opens.
@(test)
a_restart_keeps_a_manual_choice_on_its_side :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r)
	path, _ := filepath.join({s.out, "views_side_fold.txt"}, context.temp_allocator)
	_ = os.remove(path)   // (the session's folder stays between runs)
	restart :: proc(s: ^session.Session, r: ^Dock, path: string) {
		ui.views_destroy(&r.views)
		ui.views_init(&r.views, {path = path})
		dock_register(r)
		ui.view_open(&r.views, "side", r, owner = s.state)
	}
	restart(s, &r, path)
	if rail_minimise(s, "side") == nil { return }
	restart(s, &r, path)
	session.frames(s, 3)
	testing.expect(t, wait_built(s, "view_rail_restore") != nil, "restarted wide: the Minimise holds")
	// (the memory says a manual fold while wide; the first measure of the new start is narrow: a crossing)
	restart(s, &r, path)
	testing.expectf(t, zone_fold(s) == {folded = true}, "the memory read back: %v", zone_fold(s))
	session.resize(s, window_em(&r, SIDE_EM + ui.DOCK_MIN_EM * 0.5))
	session.frames(s, 3)
	testing.expectf(t, zone_fold(s) == {folded = true, narrow = true}, "restarted narrow: the automatic state: %v", zone_fold(s))
	session.resize(s, WINDOW)
	testing.expect(t, wait_built(s, "view_panel_view_side") != nil, "wide again: open by itself")
}

// Test 17: a panel alone in its zone adds no tab strip, no border, no icon at rest; its body starts at the zone's top
// left. Its stack's strip comes after a rest of VIEW_HOVER_DWELL_MS at the top edge, and pushes the body down (nothing
// of it over the body); it stays while the pointer is anywhere in the panel, and goes when the pointer leaves it.
@(test)
a_lone_panel_adds_nothing :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side")
	body := wait_built(s, "view_panel_view_side")
	zone := built(s, "view_zone_Left")
	if body == nil || zone == nil { testing.expect(t, false, "the panel and its zone"); return }
	top := zone.rect.min
	testing.expect_value(t, body.rect.min, top)
	testing.expect(t, session.find(s, "view_tabs") == nil, "no tab strip")
	testing.expect(t, .Draw_Background not_in zone.flags && .Draw_Border not_in zone.flags, "the zone draws nothing")
	testing.expect(t, .Draw_Background not_in body.flags && .Draw_Border not_in body.flags, "the body draws nothing of its own")
	// (a pointer in the body, past the edge's band: nothing, however long it rests)
	session.move(s, {top.x + 30, top.y + r.em * 1.5})
	session.advance(s, 2 * ui.VIEW_HOVER_DWELL_MS)
	testing.expect(t, built(s, "view_tabs") == nil, "nothing on the hover of the body")
	// the top edge: nothing before the dwell; then the strip, the body under it
	session.move(s, {top.x + 30, top.y + 2})
	session.advance(s, ui.VIEW_HOVER_DWELL_MS - 100)
	testing.expect(t, built(s, "view_tabs") == nil, "no strip before the dwell")
	session.advance(s, 150)
	tabs := built(s, "view_tabs")
	if !testing.expect(t, tabs != nil, "the strip after a rest at the top edge") { return }
	body = built(s, "view_panel_view_side")
	testing.expectf(t, body.rect.min.y >= tabs.rect.max.y - 0.5, "the body pushed under it: %v under %v", body.rect, tabs.rect)
	testing.expect(t, session.find(s, "view_tab_view_side") != nil, "its tab: its title, its menu")
	// on the strip, then down into the body: it stays (the body never moves up under the pointer); out: it goes
	session.move(s, {top.x + 30, (tabs.rect.min.y + tabs.rect.max.y) * 0.5})
	session.frames(s, 2)
	testing.expect(t, built(s, "view_tabs") != nil, "it stays while the pointer is on it")
	session.move(s, {top.x + 30, tabs.rect.max.y + r.em * 2})
	session.frames(s, 4)
	testing.expect(t, built(s, "view_tabs") != nil, "it stays while the pointer is in the body")
	session.move(s, OUT)
	session.frames(s, 2)
	testing.expect(t, built(s, "view_tabs") == nil, "none when the pointer leaves")
	testing.expectf(t, abs((zone.rect.max.x - zone.rect.min.x) - SIDE_EM * r.em) <= 1.5, "its extent_em: %v", zone.rect)
}

// The strip's state machine (views.md, section 2.5, rule 2): a press during the dwell starts it again; shown, the strip
// stays down to the body's bottom and goes when the pointer leaves the stack; it does not come back by itself, only
// after a new full dwell; Escape hides it.
@(test)
a_lone_panel_s_strip_waits_for_a_rest :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side")
	zone := wait_built(s, "view_zone_Left")
	if zone == nil { return }
	band := [2]f32{zone.rect.min.x + 30, zone.rect.min.y + 2}
	session.move(s, band)
	session.advance(s, ui.VIEW_HOVER_DWELL_MS - 100)
	session.press(s, band)
	session.release(s, band)
	session.advance(s, ui.VIEW_HOVER_DWELL_MS - 100)
	testing.expect(t, built(s, "view_tabs") == nil, "a press during the dwell: it starts again")
	session.advance(s, 150)
	if !testing.expect(t, built(s, "view_tabs") != nil, "a full dwell after the press") { return }
	session.move(s, {band.x, zone.rect.max.y - 3})
	session.frames(s, 2)
	testing.expect(t, built(s, "view_tabs") != nil, "it stays down to the body's bottom")
	session.move(s, OUT)
	session.frames(s, 2)
	testing.expect(t, built(s, "view_tabs") == nil, "gone when the pointer leaves the stack")
	// back in the panel: no strip by itself
	session.move(s, {band.x, zone.rect.min.y + r.em * 4})
	session.advance(s, 2 * ui.VIEW_HOVER_DWELL_MS)
	testing.expect(t, built(s, "view_tabs") == nil, "back in the body: it does not come back")
	session.move(s, band)
	testing.expect(t, built(s, "view_tabs") == nil, "back in the band: not before a new dwell")
	session.advance(s, ui.VIEW_HOVER_DWELL_MS)
	if !testing.expect(t, built(s, "view_tabs") != nil, "after a new dwell") { return }
	session.key(s, .Escape)
	testing.expect(t, built(s, "view_tabs") == nil, "Escape hides it")
	session.advance(s, ui.VIEW_HOVER_DWELL_MS)
	testing.expect(t, built(s, "view_tabs") != nil, "a new dwell in the band brings it back")
}

// opencode native's sidebar: its fold button under a half em margin at the panel's top, under the title bar. The
// pointer goes down from the title bar to it, a frame a step, across the top band: nothing moves on its way, no strip
// comes, and the click folds the zone (before, the strip came at once, the button dropped, the click hit the strip).
@(test)
a_pointer_travelling_to_the_fold_button_moves_nothing :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	r.title_bar = true
	s := dock_start(t, &r, "sidebar")
	fold := wait_built(s, "view_fold")
	zone := built(s, "view_zone_Left")
	if fold == nil || zone == nil { testing.expect(t, false, "the fold button and its zone"); return }
	at := fold.rect
	top := zone.rect.min.y
	testing.expectf(t, top >= TITLE_BAR_PX - 1, "the panel under the title bar: %v", zone.rect)
	c := session.center(fold)
	in_band := false
	for y := top - 10; ; y += 4 {
		p := [2]f32{c.x, min(y, c.y)}
		if p.y >= top && p.y < top + ui.VIEW_HOVER_EDGE_EM * r.em { in_band = true }
		s.pointer = p
		session.event(s, {kind = .Mouse_Move, pos = p})
		session.frame(s)
		now := built(s, "view_fold")
		if !testing.expectf(t, now != nil && now.rect == at, "at %v the fold button stays: %v, %v", p, now.rect if now != nil else ui.Rect{}, at) { return }
		if !testing.expectf(t, built(s, "view_tabs") == nil, "at %v no strip", p) { return }
		if p.y >= c.y { break }
	}
	testing.expect(t, in_band, "the way crossed the top band")
	session.click_at(s, c)
	for _ in 0 ..< WAIT_FRAMES {
		if zone_fold(s).folded { break }
		session.frame(s)
	}
	testing.expectf(t, zone_fold(s).folded, "the click folded the zone: %v", zone_fold(s))
	testing.expect(t, ui.view_presentation(&r.views, "sidebar") == .Panel, "still a panel")
}

// A right click on the fold button opens the view's menu, which has the strip's Maximise (and then Restore).
@(test)
a_right_click_on_the_fold_button_opens_the_panel_s_menu :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "sidebar")
	fold := wait_built(s, "view_fold")
	if fold == nil { return }
	session.click_at(s, session.center(fold), .Right)
	if !click_item(s, "Maximise") { return }
	for _ in 0 ..< WAIT_FRAMES {
		if _, _, ok := ui.views_space_maximised(&r.views, ""); ok { break }
		session.frame(s)
	}
	e, _, ok := ui.views_space_maximised(&r.views, "")
	testing.expectf(t, ok && e == .Left, "its stack maximised: %v %v", e, ok)
	fold = wait_built(s, "view_fold")
	if fold == nil { return }
	session.click_at(s, session.center(fold), .Right)
	if !click_item(s, "Restore") { return }
	for _ in 0 ..< WAIT_FRAMES {
		if _, _, ok2 := ui.views_space_maximised(&r.views, ""); !ok2 { break }
		session.frame(s)
	}
	_, _, ok = ui.views_space_maximised(&r.views, "")
	testing.expect(t, !ok, "restored")
}

// A strip in a lone panel's top band, its first tab chosen: a click on its right arrow scrolls the strip and keeps it
// scrolled (opencode native's sidebar), whether the pointer comes straight to the arrow or rests first on the band's
// empty start; the click is the arrow's, never a control of the panel's (which floated it: a new strip, at its start).
@(test)
a_strip_in_a_panel_s_band_keeps_its_scroll :: proc(t: ^testing.T) {
	for from_band in ([2]bool{false, true}) {
		r: Dock
		defer dock_end(&r)
		s := dock_start(t, &r, "striped")
		body := wait_built(s, "view_panel_view_striped")
		right := wait_built(s, "strip_right")
		if body == nil || right == nil { return }
		if from_band {
			session.move(s, {body.rect.min.x + 5, body.rect.min.y + 15})   // (the row's empty start, in the top area)
			testing.expect(t, built(s, "view_tabs") == nil, "no strip of the panel's on the hover of the body's own")
		}
		session.click_at(s, session.center(right))
		session.wait_idle(s)
		testing.expectf(t, ui.view_presentation(&r.views, "striped") == .Panel, "%v: still a panel, not floated by Detach", from_band)
		testing.expectf(t, built(s, "view_tabs") == nil, "%v: no strip of the panel's over the arrow the pointer is on", from_band)
		view := built(s, "strip_view")
		if !testing.expectf(t, view != nil, "%v: the strip's view", from_band) { continue }
		testing.expectf(t, view.view_off.x > 0, "%v: the arrow scrolled the strip, and it stays: %v", from_band, view.view_off.x)
		testing.expectf(t, built(s, "strip_left") != nil, "%v: the start arrow now", from_band)
	}
}

// The panel's controls and the body's never meet: on the hover of its top edge, a lone panel's strip pushes the body's
// own strip (a sidebar's row of tabs) down under it, every control of both in reach; its tab's menu floats the panel.
@(test)
a_panel_s_strip_pushes_the_body_s_strip :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "striped")
	body := wait_built(s, "view_panel_view_striped")
	if body == nil || wait_built(s, "striped_strip") == nil { return }
	session.move(s, {body.rect.min.x + 40, body.rect.min.y + 2})
	wait_built(s, "view_tabs")   // (after the dwell, VIEW_HOVER_DWELL_MS)
	tabs, strip := built(s, "view_tabs"), built(s, "striped_strip")
	if !testing.expect(t, tabs != nil && strip != nil, "the panel's strip and the body's") { return }
	testing.expectf(t, strip.rect.min.y >= tabs.rect.max.y - 0.5, "the body's strip under the panel's: %v under %v", strip.rect, tabs.rect)
	// its tab's menu floats it
	tab := built(s, "view_tab_view_striped")
	if !testing.expect(t, tab != nil, "the panel's tab") { return }
	session.click_at(s, session.center(tab), .Right)
	if !click_item(s, "Open as a floating window") { return }
	if wait_built(s, "internal_view_striped") == nil { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "striped"), ui.View_Presentation.Internal)
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

// view_open of a docked view already open, in a tab not shown: its tab is shown, the focus goes into it, and the tabs
// keep their order (opencode native's media command and its statistics toggle).
@(test)
view_open_shows_a_docked_view_s_tab :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "side", "side2")
	wait_built(s, "view_tabs")
	if built(s, "view_panel_view_side2") == nil {
		testing.expect(t, false, "the last docked shown")
		return
	}
	first := session.find(s, "view_tab_view_side")
	second := session.find(s, "view_tab_view_side2")
	if first == nil || second == nil { testing.expect(t, false, "a tab each"); return }
	left_first := first.rect.min.x < second.rect.min.x
	if !click_named(s, "content_button") { return }
	append(&r.want, "side")
	if wait_built(s, "view_panel_view_side") == nil { return }
	testing.expect(t, built(s, "view_panel_view_side2") == nil, "one shown at a time")
	testing.expect_value(t, session.focused_name(s), "side_field")
	testing.expect(t, ui.view_has_focus(&r.views, "side"), "the panel has the focus")
	first, second = session.find(s, "view_tab_view_side"), session.find(s, "view_tab_view_side2")
	testing.expect(t, first != nil && second != nil && (first.rect.min.x < second.rect.min.x) == left_first, "the tabs keep their order")
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

// The header's menu, opened by a right click, filters what is typed as every menu: "dkr" keeps Dock right, Enter docks.
@(test)
a_views_right_click_menu_filters :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "ask")
	if wait_built(s, "modal_view_ask") == nil { return }
	header := built(s, "view_header")
	if header == nil { testing.expect(t, false, "the dialog's header"); return }
	session.click_at(s, {header.rect.min.x + 10, (header.rect.min.y + header.rect.max.y) * 0.5}, .Right)
	if wait_built(s, "menu_search") == nil { return }
	testing.expect(t, session.find_text(s, "Dock left") != nil, "every item before anything is typed")
	session.type_text(s, "dkr")
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Dock right") != nil, "the match stays")
	testing.expect(t, session.find_text(s, "Dock left") == nil && session.find_text(s, "Dock bottom") == nil, "the others went")
	session.key(s, .Return)
	if wait_built(s, "view_panel_view_ask") == nil { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Panel)
	testing.expect(t, built(s, "view_zone_Right") != nil, "in the right zone")
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

// A right click on a tab of the body in the panel's top band opens the tab's menu, not the view's; after a rest on an
// empty part of the band, the panel's strip comes, and a right click on its tab opens the view's menu.
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
	session.move(s, {panel.rect.min.x + TAB_W + 40, panel.rect.min.y + 2})
	strip_tab := wait_built(s, "view_tab_view_tabbed")   // (after the dwell, VIEW_HOVER_DWELL_MS)
	if strip_tab == nil { return }
	session.click_at(s, session.center(strip_tab), .Right)
	session.frames(s, 2)
	testing.expect(t, ui.menu_is_open(VIEW_MENU_TABBED), "the view's menu on the strip's tab")
	testing.expect(t, !ui.menu_is_open("tab_menu"))
}

// Whether a menu item with these words is in the last build.
@(private = "file")
item_shown :: proc(s: ^session.Session, words: string) -> bool {
	x := session.find_text(s, words)
	return x != nil && x.last_build == s.state.build_index
}

// A right press on the free part of a lone panel's top area opens the view's menu at the press (a tab's opens at the
// release), with no strip shown; a right press lower in the body opens nothing. Its item floats the panel.
@(test)
the_free_part_of_a_panel_s_top_area_opens_its_menu :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "tabbed")
	panel := wait_built(s, "view_panel_view_tabbed")
	if panel == nil || wait_built(s, "tab_in_band") == nil { return }
	low := [2]f32{panel.rect.min.x + TAB_W + 40, panel.rect.min.y + 4 * r.em}
	session.press(s, low, .Right)
	testing.expect(t, !ui.menu_is_open(VIEW_MENU_TABBED), "no menu of the view's below the top area")
	session.release(s, low, .Right)
	at := [2]f32{panel.rect.min.x + TAB_W + 40, panel.rect.min.y + 2}
	ui.use(s.state)
	testing.expect(t, ui.hit_box_at(at) == nil, "nothing clickable there: the area's free part")
	session.press(s, at, .Right)
	testing.expect(t, ui.menu_is_open(VIEW_MENU_TABBED), "the view's menu, at the press")
	testing.expect(t, !ui.menu_is_open("tab_menu"), "not the body's tab's")
	session.release(s, at, .Right)
	if !click_item(s, "Open as a floating window") { return }
	if wait_built(s, "internal_view_tabbed") == nil { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "tabbed"), ui.View_Presentation.Internal)
}

// The view's menu shows the acts that apply where the view is, as the palette lists them: a panel at the left has no
// "Dock left", no "Re-attach" at home, no "Detach into a window" while the program opens no windows, and its stack's
// Minimise and Maximise; none of them is ever there inactive.
@(test)
a_panel_s_menu_has_only_the_acts_that_apply :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	// ("marks": its compact form keeps the fold button, so the menu also opens on the folded zone)
	s := dock_start(t, &r, "marks")
	fold := wait_built(s, "view_fold")
	if fold == nil { return }
	session.click_at(s, session.center(fold), .Right)
	for _ in 0 ..< WAIT_FRAMES {
		if item_shown(s, "Close") { break }
		session.frame(s)
	}
	for words in ([]string{"Open as a floating window", "Dock right", "Dock bottom", "Minimise the panel", "Maximise", "Close"}) {
		testing.expectf(t, item_shown(s, words), "the item %q", words)
	}
	for words in ([]string{"Dock left", "Re-attach", "Detach into a window", "Restore"}) {
		testing.expectf(t, !item_shown(s, words), "no item %q", words)
	}
	// its Minimise is the fold button's: the zone folds
	if !click_item(s, "Minimise the panel") { return }
	if wait_built(s, "marks_compact") == nil { return }
	fold = wait_built(s, "view_fold")
	if fold == nil { return }
	session.click_at(s, session.center(fold), .Right)
	if !click_item(s, "Restore") { return }
	testing.expect(t, wait_built(s, "marks_full") != nil, "the zone open again, the marks in full")
}

// A floating window in a program with no frame space: its menu has no Dock items (absent, not inactive), and its other
// acts are there.
@(test)
a_floating_window_s_menu_without_a_frame_has_no_dock_items :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	r.no_frame = true
	s := dock_start(t, &r, "float")
	frame := wait_built(s, "internal_view_float")
	if frame == nil { return }
	session.wait_idle(s)
	header := session.find(s, "view_header", within = frame)
	if header == nil { testing.expect(t, false, "the window's header"); return }
	session.click_at(s, {header.rect.min.x + 10, (header.rect.min.y + header.rect.max.y) * 0.5}, .Right)
	for _ in 0 ..< WAIT_FRAMES {
		if item_shown(s, "Close") { break }
		session.frame(s)
	}
	testing.expect(t, item_shown(s, "Close"), "the menu, its Close")
	for words in ([]string{"Dock left", "Dock right", "Dock bottom", "Open as a floating window", "Detach into a window"}) {
		testing.expectf(t, !item_shown(s, words), "no item %q", words)
	}
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
	testing.expectf(t, sm.fold[.Bottom].folded, "remembered: %q", text)
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

// A content wider than the window (a row of boxes of their own width) asks the frame for no width
// (src/md/features/least-width.md): the right zone stays in the window, the content ends at its handle.
@(test)
a_wide_content_leaves_the_dock_zones_in_the_window :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	r.wide = true
	s := dock_start(t, &r, "side", "right")
	if wait_built(s, "view_panel_view_side") == nil || wait_built(s, "view_panel_view_right") == nil { return }
	session.frames(s, 3)
	content := built(s, "views_content")
	handle := built(s, "view_handle_Right")
	zone := built(s, "view_zone_Right")
	if content == nil || handle == nil || zone == nil { testing.expect(t, false, "the content, the handle and the right zone"); return }
	testing.expectf(t, zone.rect.max.x <= f32(WINDOW.x) + 0.5, "the right zone in the window: %v", zone.rect)
	testing.expectf(t, abs((zone.rect.max.x - zone.rect.min.x) - SIDE_EM * r.em) <= 1.5, "the right zone at its extent: %v", zone.rect)
	testing.expectf(t, abs(content.rect.max.x - handle.rect.min.x) <= 0.5 && abs(handle.rect.max.x - zone.rect.min.x) <= 0.5,
		"the content ends where the right zone begins: %v, its handle %v, the zone %v", content.rect, handle.rect, zone.rect)
}

// A panel whose content is wider than its zone keeps the zone's extent: its body is as wide as the zone.
@(test)
a_wide_panel_keeps_its_zone_s_extent :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	s := dock_start(t, &r, "wide")
	if wait_built(s, "view_panel_view_wide") == nil { return }
	session.frames(s, 3)
	body := built(s, "view_panel_view_wide")
	zone := built(s, "view_zone_Left")
	if body == nil || zone == nil { testing.expect(t, false, "the panel and its zone"); return }
	testing.expectf(t, abs((zone.rect.max.x - zone.rect.min.x) - SIDE_EM * r.em) <= 1.5, "the zone at its extent: %v", zone.rect)
	testing.expectf(t, abs(body.rect.min.x - zone.rect.min.x) <= 0.5 && abs(body.rect.max.x - zone.rect.max.x) <= 0.5, "the body as wide as the zone: %v in %v", body.rect, zone.rect)
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

// The strip of a stack docked at the bottom (Tower's terminal) is a bar, never a button: in a finish with a relief, its
// free part is the strip's ground at rest and under the pointer, with no frame round it (its edges are that ground too);
// a double click there still maximises the stack.
@(test)
a_bottom_strip_is_a_bar_not_a_button :: proc(t: ^testing.T) {
	r: Dock
	defer dock_end(&r)
	dock_register(&r)
	append(&r.want, "term")
	r.inset = true   // (the strip touches no edge of the window: there a face has no rim)
	// (Graphite: a theme of the machined finish whose bars have a rim, Tower's)
	pal := ui.palette_of("Graphite")
	pal.finish = .Machined   // (as the showcase shows it)
	s := session.start(t, {size = WINDOW, user = &r, build = dock_build, palette = pal})
	bar := wait_built(s, "view_tabs")
	if bar == nil { return }
	// the widest gap between what the strip holds: its free part
	gap_lo, gap_hi := bar.rect.min.x, bar.rect.min.x
	edges := make([dynamic][2]f32, context.temp_allocator)
	collect :: proc(b: ^ui.Box, edges: ^[dynamic][2]f32) {
		for c := b.first; c != nil; c = c.next {
			if c.rect.max.x > c.rect.min.x && c.flags & {.Clickable, .Draw_Text, .Draw_Background} != {} { append(edges, [2]f32{c.rect.min.x, c.rect.max.x}) }
			collect(c, edges)
		}
	}
	collect(bar, &edges)
	for x := bar.rect.min.x; x < bar.rect.max.x; x += 1 {
		free := true
		for e in edges { if x >= e[0] - 2 && x < e[1] + 2 { free = false; break } }
		if !free { continue }
		hi := x
		for hi < bar.rect.max.x {
			busy := false
			for e in edges { if hi >= e[0] - 2 && hi < e[1] + 2 { busy = true; break } }
			if busy { break }
			hi += 1
		}
		if hi - x > gap_hi - gap_lo { gap_lo, gap_hi = x, hi }
		x = hi
	}
	if !testing.expectf(t, gap_hi - gap_lo >= 20, "a free part on the strip (%v .. %v)", gap_lo, gap_hi) { return }
	x := int((gap_lo + gap_hi) * 0.5)
	// (its top rows, its middle, the row above its line)
	rows := []int{int(bar.rect.min.y), int(bar.rect.min.y) + 1, int((bar.rect.min.y + bar.rect.max.y) * 0.5), int(bar.rect.min.y) + 2, int(bar.rect.max.y) - 2}
	look :: proc(t: ^testing.T, img: session.Image, x: int, rows: []int, bar: ^ui.Box, when_: string) {
		ground := session.pixel(img, x, rows[2])
		for y in rows {
			q := session.pixel(img, x, y)
			testing.expectf(t, session.near(q, ground, 3), "%s: the strip's free part at row %d is %v, its ground %v (a face, a frame)", when_, y, q, ground)
		}
		// (its first columns, down to above the line: the strip's ground, no frame nor rim; the first tab's outline starts
		// past them)
		for dx in 0 ..< 3 {
			for y in rows[1:] {
				q := session.pixel(img, int(bar.rect.min.x) + dx, y)
				testing.expectf(t, session.near(q, ground, 3), "%s: the strip's left edge, column %d, row %d is %v, its ground %v", when_, dx, y, q, ground)
			}
		}
	}
	session.move(s, OUT)
	session.frames(s, 3)
	rest := session.capture(s)
	look(t, rest, x, rows, bar, "at rest")
	session.move(s, {f32(x), (bar.rect.min.y + bar.rect.max.y) * 0.5})
	session.frames(s, 6)
	hot := session.capture(s)
	look(t, hot, x, rows, bar, "under the pointer")
	testing.expectf(t, session.near(session.pixel(hot, x, rows[2]), session.pixel(rest, x, rows[2]), 3), "the strip's ground does not change under the pointer: %v, at rest %v", session.pixel(hot, x, rows[2]), session.pixel(rest, x, rows[2]))
	// still a strip that takes its presses: a double click maximises the stack
	session.click_at(s, {f32(x), (bar.rect.min.y + bar.rect.max.y) * 0.5}, count = 2)
	session.frames(s, 3)
	_, _, maxed := ui.views_space_maximised(&r.views, "")
	testing.expect(t, maxed, "a double click on the strip maximises its stack")
}
