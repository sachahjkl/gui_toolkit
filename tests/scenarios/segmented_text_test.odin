package scenarios_test

// A segmented control in words (look = .Text): "All / Active 2 / Done 1", the chosen word bold and underlined, a click on
// another chooses it.

import "core:testing"
import "gt:font"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Words :: struct { sel: int }

@(private = "file")
Narrow :: struct { sel: int, width: f32 }

// A row too narrow for a segmented control's labels makes it a dropdown of the same choices, at the room the row has; a
// row that holds them again makes it a segmented control again. The size it asks is the same in both forms: it stays in
// one form from one frame to the next.
@(test)
a_segmented_control_too_wide_for_its_row_is_a_dropdown :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	n := Narrow{sel = 1, width = 1100}
	s := session.start(t, {size = {1160, 80}, user = &n, build = proc(s: ^session.Session) {
		n := (^Narrow)(s.user)
		ui.next({fixed_x = 10, fixed_y = 10, width = ui.px(n.width), height = ui.px(40), axis = .X})
		if ui.row(id = "###row") {
			ui.segmented("###kind", {"Plain", "Font family", "Theme", "Colour", "Path", "Address", "Keys"}, &n.sel)
		}
	}})
	session.frames(s, 3)
	testing.expect(t, session.find(s, "seg0") != nil, "its segments while the row holds them")
	n.width = 220
	session.frames(s, 3)
	kind := session.find(s, "kind")
	testing.expect(t, session.find(s, "seg0") == nil, "no segment in a row that cannot hold them")
	if testing.expect(t, kind != nil, "a dropdown in its place") {
		testing.expectf(t, kind.rect.max.x <= 10 + 220 + 0.5, "within its row: %v", kind.rect)
		testing.expect(t, kind.a11y != nil && kind.a11y.role == .Combo_Box, "a list to choose from")
	}
	session.frames(s, 3)
	testing.expect(t, session.find(s, "seg0") == nil, "the same form from one frame to the next")
	n.width = 1100
	session.frames(s, 3)
	testing.expect(t, session.find(s, "seg0") != nil, "its segments again when the row holds them")
	testing.expect_value(t, n.sel, 1)
}) }

@(test)
a_segmented_control_in_words :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	w: Words
	s := session.start(t, {size = {360, 80}, user = &w, build = proc(s: ^session.Session) {
		w := (^Words)(s.user)
		ui.next({fixed_x = 10, fixed_y = 10, height = ui.px(30)})
		ui.segmented("###filter", {"All", "Active 2", "Done 1"}, &w.sel, look = .Text)
	}})
	session.frames(s, 2)
	all, active := session.find(s, "seg0"), session.find(s, "seg1")
	if !testing.expect(t, all != nil && active != nil, "its words") { return }
	bold := font.styled_face(s.state.fonts, active.font, true, false)
	testing.expect(t, all.font == bold && all.font != active.font, "the chosen one bold")
	testing.expect(t, all.custom != nil && active.custom == nil, "the chosen one underlined")
	testing.expect(t, session.find(s, "sep1") != nil && session.find(s, "sep2") != nil, "a separator between them")
	box := session.find(s, "filter")
	testing.expectf(t, box.rect.max.x - box.rect.min.x < 300, "as wide as its words: %v", box.rect)
	session.save_png(s, "segmented_text.png")
	session.click(s, "seg2")
	session.frames(s, 2)
	testing.expect_value(t, w.sel, 2)
	testing.expect(t, session.find(s, "seg2").custom != nil && session.find(s, "seg0").custom == nil, "the underline went with it")
}) }
