package theme_look_test

// A segmented control with no choice (-1: a value that is none of its labels, the mark editor's text size of 40) draws
// no key: its key was drawn one segment before the control, over what stands at its left. Chosen later, the key is in
// the control.

import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
None_Probe :: struct { chosen: int }

@(private = "file")
none_build :: proc(s: ^session.Session) {
	p := (^None_Probe)(s.user)
	ui.next({axis = .X, width = ui.fill(), height = ui.children_sum()})
	if ui.row() {
		ui.spacer(ui.px(120))
		_ = ui.segmented("###seg_none", {"16", "24", "32", "48"}, &p.chosen)
	}
}

@(test)
a_segmented_with_no_choice_draws_no_key :: proc(t: ^testing.T) {
	p := None_Probe{chosen = -1}
	s := session.start(t, {size = {600, 120}, user = &p, no_renderer = false, build = none_build})
	session.frames(s, 4)
	before := session.capture(s)
	none := make([]u8, len(before.rgba))
	defer delete(none)
	copy(none, before.rgba)
	testing.expect_value(t, p.chosen, -1)
	// (chosen: the key's colour as the screen has it, at the left of the chosen segment, clear of its label)
	p.chosen = 2
	session.frames(s, 30)
	img := session.capture(s)
	seg := session.get(s, "seg_none")
	item := session.get(s, "seg2")
	key := session.pixel(img, int(item.rect.min.x) + 4, int((item.rect.min.y + item.rect.max.y) * 0.5))
	inside := session.count_color(img, {int(seg.rect.min.x), int(seg.rect.min.y)}, {int(seg.rect.max.x), int(seg.rect.max.y)}, key, 8)
	testing.expectf(t, inside > 50, "chosen, its key is drawn in it (%d pixels of %v)", inside, key)
	testing.expect_value(t, session.count_color(img, {0, 0}, {int(seg.rect.min.x), img.height}, key, 8), 0)
	// (none chosen: not one pixel of the key, in the control or before it)
	testing.expect_value(t, session.count_color({none, before.width, before.height}, {0, 0}, {before.width, before.height}, key, 8), 0)
}
