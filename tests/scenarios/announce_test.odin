package scenarios_test

// What a program says of what it did: a toast where it asked for the window, or where the system shows no
// notification (no window to notify from here); nothing with messages off, but a failure all the same.

import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file")
Said :: struct { announcer: ui.Announcer, kind: ui.Toast_Kind, said: bool }

@(private = "file")
said_build :: proc(s: ^session.Session) {
	r := (^Said)(s.user)
	if !r.said {
		r.said = true
		ui.announce(&r.announcer, r.kind, "Copied to the clipboard")
	}
}

@(private = "file")
toasts_alive :: proc(s: ^session.Session) -> (n: int) {
	for &x in s.state.toasts { if x.alive { n += 1 } }
	return
}

@(private = "file")
toasts_after :: proc(t: ^testing.T, mode: ui.Announce_Mode, kind: ui.Toast_Kind) -> int {
	r := new(Said, context.temp_allocator)
	r^ = {announcer = {mode = mode}, kind = kind}
	s := session.start(t, {size = {600, 300}, user = r, build = said_build})
	session.frames(s, 3)
	return toasts_alive(s)
}

@(test)
announce_to_the_window_is_a_toast :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) { testing.expect_value(t, toasts_after(t, .Window, .Good), 1) }) }

// (no window to notify from here, as where the system shows no notification)
@(test)
announce_without_a_system_is_a_toast :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) { testing.expect_value(t, toasts_after(t, .System, .Good), 1) }) }

@(test)
announce_off_says_nothing :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) { testing.expect_value(t, toasts_after(t, .Off, .Good), 0) }) }

@(test)
announce_off_still_says_a_failure :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	testing.expect_value(t, toasts_after(t, .Off, .Bad), 1)
	testing.expect_value(t, ui.announce_mode_of("window"), ui.Announce_Mode.Window)
	testing.expect_value(t, ui.announce_mode_of("nonsense"), ui.Announce_Mode.System)
}) }

// Said between builds while another window's state is in use (a command, a task's result): the toast goes to the
// announcer's own state.
@(test)
announce_between_builds_goes_to_its_state :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {600, 300}, build = proc(s: ^session.Session) {}})
	other := session.start(t, {size = {300, 200}, build = proc(s: ^session.Session) {}})
	a := ui.Announcer{mode = .Window, state = s.state}
	ui.use(other.state)
	ui.announce(&a, .Good, "Copied to the clipboard")
	testing.expect_value(t, toasts_alive(s), 1)
	testing.expect_value(t, toasts_alive(other), 0)
}) }

// A title and its words: the title on its line, the words under it (a titled toast), not one line of both.
@(test)
announce_keeps_the_title_and_the_body_apart :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {600, 300}, build = proc(s: ^session.Session) {}})
	a := ui.Announcer{mode = .Window, state = s.state}
	ui.announce(&a, .Good, "Saved", "~/Pictures/a.png")
	session.frames(s, 3)
	title, body := session.find_text(s, "Saved"), session.find_text(s, "~/Pictures/a.png")
	if !testing.expect(t, title != nil && body != nil, "the title and the body, each its own line") { return }
	testing.expect(t, body.rect.min.y >= title.rect.max.y, "the body under the title")
}) }

// A message with an action is a toast whatever the mode: a click on it does it (a notification of the system cannot).
@(test)
announce_with_an_action_is_a_toast_even_off :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {600, 300}, build = proc(s: ^session.Session) {}})
	a := ui.Announcer{mode = .Off, state = s.state}
	ui.announce(&a, .Info, "Version 2 is ready", action = proc(user: rawptr) {})
	testing.expect_value(t, toasts_alive(s), 1)
}) }
