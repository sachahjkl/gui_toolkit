package scenarios_test

// What a program says of what it did: a toast where it asked for the window, or where the system shows no
// notification (no window to notify from here); nothing with messages off, but a failure all the same.

import "core:testing"
import "../../src/testkit/session"
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
	ui.toasts_build()
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
announce_to_the_window_is_a_toast :: proc(t: ^testing.T) { testing.expect_value(t, toasts_after(t, .Window, .Good), 1) }

// (no window to notify from here, as where the system shows no notification)
@(test)
announce_without_a_system_is_a_toast :: proc(t: ^testing.T) { testing.expect_value(t, toasts_after(t, .System, .Good), 1) }

@(test)
announce_off_says_nothing :: proc(t: ^testing.T) { testing.expect_value(t, toasts_after(t, .Off, .Good), 0) }

@(test)
announce_off_still_says_a_failure :: proc(t: ^testing.T) {
	testing.expect_value(t, toasts_after(t, .Off, .Bad), 1)
	testing.expect_value(t, ui.announce_mode_of("window"), ui.Announce_Mode.Window)
	testing.expect_value(t, ui.announce_mode_of("nonsense"), ui.Announce_Mode.System)
}
