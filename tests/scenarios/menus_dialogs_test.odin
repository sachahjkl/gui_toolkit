package scenarios_test

// Menus as wide as what they show, dialogs that open where they stay and fade in, the close button of a dialog's header,
// the menu of a text area.

import "core:strings"
import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") MD_WINDOW :: [2]int{800, 600}
// A row's label laid out wider than its text by less than this is not cut (sub-pixel rounding).
@(private = "file") MD_EPS :: 0.01

////////////////////////////////
// The width of a menu

@(private = "file")
Wide_Menu :: struct {
	width:    f32,    // ctx_menu's `width` (a minimum)
	text_pad: f32,    // the window's style's text_pad (0: the session's)
	label:    string,
	open_now: bool,   // the next build opens it (anew)
}

@(private = "file")
wide_menu_start :: proc(t: ^testing.T, m: ^Wide_Menu) -> ^session.Session {
	m.open_now = true
	return session.start(t, {size = MD_WINDOW, user = m, no_renderer = true, build = proc(s: ^session.Session) {
		m := (^Wide_Menu)(s.user)
		// (a theme of wider padding: the window's style, which a menu's rows are built in)
		if m.text_pad > 0 { s.state.style_stack[0].text_pad = m.text_pad }
		key := ui.key_from_string(0, "wide_menu")
		if m.open_now { ui.ctx_menu_open(key, {40, 40}); m.open_now = false }
		if ui.ctx_menu(key, m.width) {
			_ = ui.menu_item(m.label, "Ctrl+Shift+Q")
			_ = ui.menu_item("Copy", "Ctrl+C")
			if ui.menu_submenu("Show as a list of things") { _ = ui.menu_item("Inner") }
		}
	}})
}

// The label of the first row shows whole: its box is as wide as its text and its padding.
@(private = "file")
expect_whole_label :: proc(t: ^testing.T, s: ^session.Session, what: string) {
	b := session.find(s, "lbl")
	if !testing.expectf(t, b != nil, "%s: the row's label", what) { return }
	room := (b.rect.max.x - b.rect.min.x) - 2 * b.text_pad
	testing.expectf(t, b.text_dim.x <= room + MD_EPS, "%s: the label needs %v px, it has %v", what, b.text_dim.x, room)
	key := session.find(s, "key")
	if testing.expectf(t, key != nil, "%s: the shortcut", what) {
		testing.expectf(t, key.rect.min.x >= b.rect.max.x - MD_EPS, "%s: the shortcut is after the label", what)
	}
}

// A menu is as wide as its widest row: an item with a long label and a long shortcut is not cut, with no width given, with
// a width smaller than its content (a minimum, not a cut), and in a style of wider padding.
@(test)
a_menu_is_as_wide_as_its_widest_row :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	cases := []Wide_Menu{
		{label = "Show as QR code"},
		{label = "Show as QR code", width = 40},
		{label = "Show as QR code", text_pad = 18},
		{label = "Show as QR code", width = 40, text_pad = 18},
	}
	m := cases[0]
	s := wide_menu_start(t, &m)
	for c in cases {
		m = c
		m.open_now = true
		session.frames(s, 3)
		expect_whole_label(t, s, strings.concatenate({m.label, m.width > 0 ? " (width given)" : "", m.text_pad > 0 ? " (wide padding)" : ""}, context.temp_allocator))
	}
}) }

// A width larger than the content is the menu's width.
@(test)
a_menu_s_width_is_a_minimum :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	m := Wide_Menu{label = "Cut", width = 420}
	s := wide_menu_start(t, &m)
	session.frames(s, 3)
	r, _, ok := ui.menu_rect(0)
	testing.expect(t, ok, "the menu")
	testing.expectf(t, r.max.x - r.min.x >= 420, "at least the width given: %v", r.max.x - r.min.x)
}) }

// A menu wider than the window is as wide as the window: the row it cuts shows its whole label as a tooltip.
@(test)
a_menu_cut_by_the_window_says_its_rows_whole :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	m := Wide_Menu{label = strings.repeat("A very long label ", 12, context.temp_allocator)}
	s := wide_menu_start(t, &m)
	session.frames(s, 3)
	r, _, ok := ui.menu_rect(0)
	testing.expect(t, ok, "the menu")
	testing.expectf(t, r.min.x >= 0 && r.max.x <= f32(MD_WINDOW.x), "in the window: %v", r)
	row, row_ok := ui.menu_item_rect(0, 0)
	if !testing.expect(t, row_ok, "the first row") { return }
	session.move(s, {(row.min.x + row.max.x) * 0.5, (row.min.y + row.max.y) * 0.5})
	session.advance(s, 800)
	session.frames(s, 3)
	tip := session.find(s, "tooltip_text")
	if testing.expect(t, tip != nil, "a tooltip on the cut row") { testing.expect_value(t, tip.text, m.label) }
}) }

////////////////////////////////
// A dialog opens where it stays

@(private = "file")
Opening :: struct {
	open:  bool,
	sized: bool,
	size:  ui.Vec2,
}

@(private = "file")
opening_start :: proc(t: ^testing.T, o: ^Opening) -> ^session.Session {
	return session.start(t, {size = MD_WINDOW, user = o, animations = true, no_renderer = true, build = proc(s: ^session.Session) {
		o := (^Opening)(s.user)
		if o.sized {
			if ui.modal_sized("fit", {320, 0}, &o.size, &o.open, {200, 80}) {
				ui.next({width = ui.fill(), height = ui.px(40)})
				ui.build_box({}, "###fit_top")
				ui.next({width = ui.fill(), height = ui.fill()})
				if ui.scroll_y("###fit_scroll") {
					ui.next({width = ui.fill(), height = ui.px(150)})
					ui.build_box({}, "###fit_inner")
				}
			}
		} else {
			// (taller than the window's lower part: its first place, at y_fraction, would go past the bottom)
			if ui.modal("tall", 300, &o.open) {
				ui.next({width = ui.fill(), height = ui.px(480)})
				ui.build_box({}, "###tall_body")
			}
		}
	}})
}

// The first frame that shows a dialog has it at its size and place: the frame after it has the same rect. Its scrim and its
// panel fade in together.
@(test)
a_dialog_opens_where_it_stays :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	o := Opening{}
	s := opening_start(t, &o)
	session.frames(s, 2)
	o.open = true
	shown: ui.Rect
	seen := false
	faded := false
	for _ in 0 ..< 30 {
		session.frame(s)
		panel, scrim := session.find(s, "modal_tall"), session.find(s, "modal_scrim_tall")
		if panel == nil || scrim == nil { continue }
		testing.expectf(t, panel.transparency == scrim.transparency, "the scrim and the panel together: %v, %v", scrim.transparency, panel.transparency)
		if panel.transparency >= 1 { continue }   // (measured, unseen)
		if !seen {
			seen, shown = true, panel.rect
			faded = panel.transparency > 0
			continue
		}
		testing.expectf(t, panel.rect == shown, "the rect of its first frame shown %v, of the next %v", shown, panel.rect)
		break
	}
	testing.expect(t, seen, "the dialog shows")
	testing.expect(t, faded, "it fades in (its first frame shown is not at full strength)")
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		b := session.find(s, "modal_tall")
		return b != nil && b.transparency == 0
	}, "the fade's end")
}) }

// A modal_sized of preferred height 0 is as tall as what is in it (a region that scrolls counted whole), from its first
// frame shown.
@(test)
a_fitted_dialog_is_as_tall_as_its_content :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	o := Opening{sized = true}
	s := opening_start(t, &o)
	session.frames(s, 2)
	o.open = true
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		b := session.find(s, "modal_fit")
		return b != nil && b.transparency < 1
	}, "the dialog shows")
	panel, top, scroll, inner := session.find(s, "modal_fit"), session.find(s, "fit_top"), session.find(s, "fit_scroll"), session.find(s, "fit_inner")
	if !testing.expect(t, panel != nil && top != nil && scroll != nil && inner != nil, "the dialog and its parts") { return }
	testing.expectf(t, inner.rect.max.y <= scroll.rect.max.y + MD_EPS, "nothing hidden: the content ends at %v, its view at %v", inner.rect.max.y, scroll.rect.max.y)
	border := panel.rect.max.y - scroll.rect.max.y
	testing.expectf(t, border >= 0 && border <= 2, "the view ends at the dialog's bottom: %v px apart", border)
	h := panel.rect.max.y - panel.rect.min.y
	testing.expectf(t, h < f32(MD_WINDOW.y) * 0.5, "not as tall as the window: %v", h)
	testing.expectf(t, h >= 190, "as tall as its content: %v", h)
}) }

////////////////////////////////
// A dialog's close button

// A confirmation has a close button in its header's corner: it cancels.
@(test)
a_confirmation_closes_from_its_corner :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { open: bool, answer: ui.Confirm_Answer }
	r := Run{open = true}
	s := session.start(t, {size = MD_WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if a := ui.confirm("ask", &r.open, {title = "Delete it?", act = "Delete"}); a != .None { r.answer = a }
	}})
	session.frames(s, 3)
	x := session.find(s, "dialog_close")
	if !testing.expect(t, x != nil, "the close button") { return }
	session.click(s, "dialog_close")
	session.frames(s, 2)
	testing.expect(t, !r.open, "closed")
	testing.expect_value(t, r.answer, ui.Confirm_Answer.Cancelled)
}) }

////////////////////////////////
// The menu of a text area

// A right click in a text area opens the field's menu: Select all, then Cut, empties it.
@(test)
a_text_area_has_the_field_menu :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { area: ui.Text_Area }
	r: Run
	defer ui.area_destroy(&r.area)
	s := session.start(t, {size = MD_WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.px(300), height = ui.px(160)})
		ui.text_edit("###area", &r.area)
	}})
	session.click(s, "area")
	session.type_text(s, "one\ntwo")
	session.click(s, "area", .Right)
	session.frames(s, 2)
	testing.expect(t, ui.ctx_menu_any_open(), "a right click opens it")
	testing.expect(t, session.find(s, "menu_search") != nil, "it searches, as every context menu")
	icons := 0
	for i := 0; session.find(s, "ico", i) != nil; i += 1 { icons += 1 }
	testing.expectf(t, icons == 7, "an icon on each item: %d", icons)
	session.click_text(s, "Select all")
	session.frames(s, 2)
	testing.expect_value(t, r.area.mark, 0)
	testing.expect_value(t, r.area.cursor, len("one\ntwo"))
	session.click(s, "area", .Right)
	session.frames(s, 2)
	session.click_text(s, "Cut")
	session.frames(s, 2)
	testing.expect_value(t, ui.area_string(&r.area), "")
	testing.expect_value(t, session.clipboard(s), "one\ntwo")
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, ui.area_string(&r.area), "one\ntwo")
}) }
