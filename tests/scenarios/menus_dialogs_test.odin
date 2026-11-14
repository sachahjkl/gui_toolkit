package scenarios_test

// Menus as wide as what they show, dialogs that open where they stay and fade in, the close button of a dialog's header,
// the menu of a text area.

import "core:fmt"
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
	width:    f32,    // menu's `width` (a minimum)
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
		key := "wide_menu"
		if m.open_now { ui.menu_open(key, ui.Vec2{40, 40}); m.open_now = false }
		if ui.menu(key, m.width) {
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
			if ui.modal("fit", &o.open, {width_em = 320 / ui.font_size(), min_width_em = 200 / ui.font_size(), min_height_em = 80 / ui.font_size(), size = &o.size}) {
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
			if ui.modal("tall", &o.open, {width_em = 300 / ui.font_size()}) {
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

// A resizable modal of height_em 0 is as tall as what is in it (a region that scrolls counted whole), from its first
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
// No dialog moves after its first frame shown

// A title longer than a dialog's default width: the dialog grows to it, then it wraps.
@(private = "file") FS_LONG_TITLE :: "A title much longer than the width a dialog has by default, so that it grows to it and then wraps"
// The height of the program's own measure before it knew its width, and its height for a width (px).
@(private = "file") FS_LATE_LEAST :: 40
@(private = "file") FS_LATE_PER_WIDTH :: 0.5
@(private = "file") FS_BUTTONS :: 9
// The frames a dialog has to show and end its fade; the frames that let the last one go.
@(private = "file") FS_FRAMES :: 60
@(private = "file") FS_SETTLE_FRAMES :: 4

@(private = "file")
First_Shown_Kind :: enum { Late, Buttons, Confirm, Prompt, Palette, Sheet }

// Each kind's dialog, by its id (session.find: "modal_<id>", "modal_scrim_<id>"), and a box in it that must not move either.
// (variables, read only: a constant array cannot be indexed by a value known at run time)
@(private = "file", rodata) FS_ID := [First_Shown_Kind]string{.Late = "late", .Buttons = "buttons", .Confirm = "ask", .Prompt = "pin", .Palette = "palette", .Sheet = "keys"}
@(private = "file", rodata) FS_INNER := [First_Shown_Kind]string{.Late = "late_body", .Buttons = "fs_b8", .Confirm = "confirm_act", .Prompt = "prompt_ok", .Palette = "", .Sheet = "sheet_title"}

@(private = "file")
FS_COMMANDS := [?]ui.Command{
	{label = "End task", group = "Processes", keys = {{.Delete, {}}}},
	{label = "Kill", group = "Processes", keys = {{.Delete, {.Shift}}}},
	{label = "Start", group = "Services", keys = {{.S, {.Ctrl}}}},
	{label = "Command palette", group = "Window", keys = {{.P, {.Ctrl, .Shift}}}},
}

@(private = "file")
First_Shown :: struct {
	kind:     First_Shown_Kind,
	open_now: bool,   // the next build opens the dialog of `kind`
	open:     bool,
	late_w:   f32,    // the late body's width at the last layout: a program's own measure, known one frame late
	field:    ui.Line_Edit,
	pal:      ui.Command_Palette,
	sheet:    ui.Shortcuts_Sheet,
}

@(private = "file")
first_shown_build :: proc(s: ^session.Session) {
	r := (^First_Shown)(s.user)
	if r.open_now {
		r.open_now = false
		switch r.kind {
		case .Palette: ui.palette_open(&r.pal)
		case .Sheet:   r.sheet.open = true
		case .Late, .Buttons, .Confirm, .Prompt: r.open = true
		}
	}
	switch r.kind {
	case .Late:
		if ui.modal("late", &r.open, {}) {
			if ui.dialog_header("fs_head", FS_LONG_TITLE, {close = true}) {}
			if ui.dialog_body("fs_body") {
				ui.paragraph("A sentence that wraps at the width the dialog has.###fs_note")
				// (as tall as its width asks, the width it had at the last layout: as a program's own measure is)
				ui.next({width = ui.fill(), height = ui.px(r.late_w > 0 ? r.late_w * FS_LATE_PER_WIDTH : FS_LATE_LEAST)})
				b := ui.build_box({}, "###late_body")
				r.late_w = b.rect.max.x - b.rect.min.x
			}
		}
	case .Buttons:
		if ui.modal("buttons", &r.open, {}) {
			if ui.dialog_header("fs_head", "Many buttons", {close = true}) {}
			if ui.dialog_buttons("fs_row") {
				for i in 0 ..< FS_BUTTONS { _ = ui.button(fmt.tprintf("fs_b%d", i), fmt.tprintf("Button number %d", i)) }
			}
		}
	case .Confirm:
		lines := []string{"first.txt", "second.txt", "third.txt"}
		_ = ui.confirm("ask", &r.open, {title = FS_LONG_TITLE, note = "They do not go to the trash.", lines = lines, act = "Delete"})
	case .Prompt:
		_ = ui.prompt("pin", &r.open, &r.field, {title = FS_LONG_TITLE, note = "Type the PIN of the key."})
	case .Palette:
		_, _ = ui.palette(&r.pal, FS_COMMANDS[:])
	case .Sheet:
		ui.shortcuts_sheet(&r.sheet, "keys", FS_COMMANDS[:])
	}
}

// Frame by frame from the one that opens it: the scrim and the panel have one transparency, unseen (1) until the frame
// that shows them; from that frame on, neither the panel nor `inner` moves, and the fade goes on to its end.
@(private = "file")
first_shown_expect :: proc(t: ^testing.T, s: ^session.Session, kind: First_Shown_Kind) {
	panel_name := fmt.tprintf("modal_%s", FS_ID[kind])
	scrim_name := fmt.tprintf("modal_scrim_%s", FS_ID[kind])
	shown, inner_shown: ui.Rect
	seen, done := false, false
	for i in 0 ..< FS_FRAMES {
		session.frame(s)
		panel, scrim := session.find(s, panel_name), session.find(s, scrim_name)
		if panel == nil || scrim == nil { continue }
		testing.expectf(t, panel.transparency == scrim.transparency, "%v, frame %d: the scrim and the panel fade as one: %v, %v", kind, i, scrim.transparency, panel.transparency)
		inner := FS_INNER[kind] != "" ? session.find(s, FS_INNER[kind]) : nil
		if panel.transparency >= 1 {
			testing.expectf(t, !seen, "%v, frame %d: unseen again after it showed", kind, i)
			continue
		}
		if !seen {
			seen, shown = true, panel.rect
			if inner != nil { inner_shown = inner.rect }
			testing.expectf(t, panel.transparency > 0, "%v: its first frame shown starts its fade (%v)", kind, panel.transparency)
			continue
		}
		testing.expectf(t, panel.rect == shown, "%v, frame %d: the rect of its first frame shown %v, now %v", kind, i, shown, panel.rect)
		if inner != nil { testing.expectf(t, inner.rect == inner_shown, "%v, frame %d: %s at %v when it showed, now %v", kind, i, FS_INNER[kind], inner_shown, inner.rect) }
		if panel.transparency == 0 { done = true; break }
	}
	testing.expectf(t, seen && done, "%v: it shows and ends its fade within %d frames (seen %v)", kind, FS_FRAMES, seen)
}

// The first frame where a dialog is seen has it at its size and place, and what is in it where it stays: a dialog that
// grows to a long title and wraps it, one of a row of buttons on several lines, one whose content measures itself on the
// last layout (as a program's own widget does), a confirmation, a prompt, the palette, the sheet of the keys. Its scrim
// and its panel fade in as one, from the same frame.
@(test)
a_dialog_does_not_move_after_its_first_frame_shown :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := First_Shown{}
	defer ui.line_edit_destroy(&r.field)
	defer ui.palette_destroy(&r.pal)
	defer ui.shortcuts_sheet_destroy(&r.sheet)
	s := session.start(t, {size = MD_WINDOW, user = &r, animations = true, no_renderer = true, build = first_shown_build})
	for kind in First_Shown_Kind {
		r.kind, r.late_w = kind, 0
		session.frames(s, FS_SETTLE_FRAMES)   // (the last one's dialog gone)
		r.open_now = true
		first_shown_expect(t, s, kind)
		r.open, r.pal.open, r.sheet.open = false, false, false
	}
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
	Run :: struct { area: ui.Text_Edit }
	r: Run
	defer ui.text_edit_destroy(&r.area)
	s := session.start(t, {size = MD_WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.px(300), height = ui.px(160)})
		ui.text_edit("###area", &r.area)
	}})
	session.click(s, "area")
	session.type_text(s, "one\ntwo")
	session.click(s, "area", .Right)
	session.frames(s, 2)
	testing.expect(t, ui.menu_any_open(), "a right click opens it")
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
	testing.expect_value(t, ui.text_edit_string(&r.area), "")
	testing.expect_value(t, session.clipboard(s), "one\ntwo")
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, ui.text_edit_string(&r.area), "one\ntwo")
}) }
