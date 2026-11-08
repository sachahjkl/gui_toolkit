package scenarios_test

// The verbs of a scroll box's view (ui/scroll_anim.odin): how far it goes, what comes into view, a jump, content moving
// under the view.

import "core:fmt"
import "core:testing"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") VIEW_H :: 200
@(private = "file") ROW_H :: 30
@(private = "file") ROWS :: 50
@(private = "file") WHEEL_NOTCHES :: 3
@(private = "file") FAR :: 400
@(private = "file") SHIFT :: 25

@(private = "file")
rows_build :: proc(s: ^session.Session) {
	ui.next({width = ui.px(300), height = ui.px(VIEW_H)})
	if ui.scroll_y("###view") {
		for i in 0 ..< ROWS {
			ui.next({width = ui.fill(), height = ui.px(ROW_H)})
			ui.label(fmt.tprintf("Row %d###row%d", i, i))
		}
	}
}

@(test)
the_limit_is_what_does_not_fit :: proc(t: ^testing.T) {
	b := ui.Box{size = {100, 200}, view_bounds = {300, 150}}
	testing.expect_value(t, ui.view_limit(&b), 0)
	testing.expect_value(t, ui.view_limit(&b, .X), 200)
	b.view_bounds.y = 500
	testing.expect_value(t, ui.view_limit(&b), 300)
}

@(test)
what_is_revealed_moves_the_view_no_further_than_it_must :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.view_reveal_offset(100, 150, 180, 200), 100)   // shown: stays
	testing.expect_value(t, ui.view_reveal_offset(100, 40, 70, 200), 40)      // above
	testing.expect_value(t, ui.view_reveal_offset(100, 320, 350, 200), 150)   // below
}

// A row taller than the view shows its top, from above as from below: that is where it is read from.
@(test)
what_is_taller_than_the_view_keeps_its_top :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.view_reveal_offset(0, 300, 800, 200), 300)
	testing.expect_value(t, ui.view_reveal_offset(900, 300, 800, 200), 300)
	testing.expect_value(t, ui.view_reveal_offset(900, 300, 800, 200, 10), 290)
}

// The margin is where a move lands: what already shows, however near an edge, does not move for it.
@(test)
a_margin_is_for_what_had_to_move :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.view_reveal_offset(100, 102, 130, 200, 16), 100)
	testing.expect_value(t, ui.view_reveal_offset(100, 40, 70, 200, 16), 24)
	testing.expect_value(t, ui.view_reveal_offset(100, 320, 350, 200, 16), 166)
}

// view_reveal glides: it moves the target and says so, the offset is the update's. Asked again, nothing moves.
@(test)
a_reveal_heads_there_and_says_it_moved :: proc(t: ^testing.T) {
	b := ui.Box{size = {100, 200}, view_off = {0, 100}, view_target = {0, 100}}
	testing.expect(t, ui.view_reveal(&b, 320, 350), "the target moved")
	testing.expect_value(t, b.view_target.y, 150)
	testing.expect_value(t, b.view_off.y, 100)
	testing.expect(t, !ui.view_reveal(&b, 320, 350), "already there")
}

@(test)
a_reveal_along_x :: proc(t: ^testing.T) {
	b := ui.Box{size = {100, 200}}
	testing.expect(t, ui.view_reveal(&b, 150, 180, .X), "along X")
	testing.expect_value(t, b.view_target, [2]f32{80, 0})
}

// The target being the glide's own target is the case where a jump that left the glide running would be pulled back on
// its curve by the next update.
@(test)
a_jump_ends_a_glide_even_onto_its_target :: proc(t: ^testing.T) {
	s := session.start(t, {build = rows_build, no_renderer = true, smooth_scroll = .On, animations = true})
	b := session.get(s, "view")
	session.wheel(s, session.center(b), {0, WHEEL_NOTCHES})
	session.frames(s, 1)
	to := b.view_target.y
	if !testing.expect(t, b.view_anim[1].active && b.view_off.y != to, "gliding") { return }
	ui.view_jump(b, to)
	testing.expect(t, !b.view_anim[1].active, "the glide is over")
	session.frames(s, 1)
	testing.expect_value(t, b.view_off.y, to)
	testing.expect_value(t, b.view_target.y, to)
}

@(test)
a_jump_elsewhere_does_not_glide :: proc(t: ^testing.T) {
	s := session.start(t, {build = rows_build, no_renderer = true, smooth_scroll = .On, animations = true})
	b := session.get(s, "view")
	session.wheel(s, session.center(b), {0, WHEEL_NOTCHES})
	session.frames(s, 1)
	if !testing.expect(t, b.view_anim[1].active, "gliding") { return }
	ui.view_jump(b, FAR)
	session.frames(s, 1)
	testing.expect_value(t, b.view_off.y, FAR)
	testing.expect_value(t, b.view_target.y, FAR)
}

// Content moved under a glide: the glide goes on, from the same point of its curve, by as much.
@(test)
a_shift_carries_a_glide_along :: proc(t: ^testing.T) {
	s := session.start(t, {build = rows_build, no_renderer = true, smooth_scroll = .On, animations = true})
	b := session.get(s, "view")
	session.wheel(s, session.center(b), {0, WHEEL_NOTCHES})
	session.frames(s, 1)
	if !testing.expect(t, b.view_anim[1].active, "gliding") { return }
	was, off, target := b.view_anim[1], b.view_off.y, b.view_target.y
	ui.view_shift(b, SHIFT, ui.view_limit(b))
	testing.expect_value(t, b.view_off.y, off + SHIFT)
	testing.expect_value(t, b.view_target.y, target + SHIFT)
	testing.expect_value(t, b.view_anim[1].from, was.from + SHIFT)
	testing.expect_value(t, b.view_anim[1].to, was.to + SHIFT)
	session.frames(s, 1)
	testing.expect_value(t, b.view_anim[1].start, was.start)   // (a new move would have started now)
}

// A view on its way back to the top ends there, however much the content above it grew meanwhile.
@(test)
a_shift_leaves_the_top_the_top :: proc(t: ^testing.T) {
	s := session.start(t, {build = rows_build, no_renderer = true, smooth_scroll = .On, animations = true})
	b := session.get(s, "view")
	ui.view_jump(b, FAR)
	session.frames(s, 1)
	b.view_target.y = 0
	session.frames(s, 1)
	if !testing.expect(t, b.view_anim[1].active && b.view_off.y > 0, "on its way") { return }
	off := b.view_off.y
	ui.view_shift(b, SHIFT, ui.view_limit(b))
	testing.expect_value(t, b.view_off.y, off + SHIFT)
	testing.expect_value(t, b.view_target.y, 0)
	session.wait_idle(s)
	testing.expect_value(t, b.view_off.y, 0)
}

@(test)
a_shift_stays_in_the_content :: proc(t: ^testing.T) {
	b := ui.Box{view_off = {0, 280}, view_target = {0, 280}}
	ui.view_shift(&b, 50, 300)
	testing.expect_value(t, b.view_off.y, 300)
	testing.expect_value(t, b.view_target.y, 300)
	ui.view_shift(&b, -400, 300)
	testing.expect_value(t, b.view_off.y, 0)
	testing.expect_value(t, b.view_target.y, 0)
}
