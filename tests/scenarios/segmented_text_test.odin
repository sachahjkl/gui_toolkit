package scenarios_test

// A segmented control in words (look = .Text): "All / Active 2 / Done 1", the chosen word bold and underlined, a click on
// another chooses it.

import "core:testing"
import "../../src/font"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file")
Words :: struct { sel: int }

@(test)
a_segmented_control_in_words :: proc(t: ^testing.T) {
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
}
