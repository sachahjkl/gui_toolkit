// ui.Status_Line: a message shown for its time, then gone, on the session's clock; the window's wake at its end, also for
// a message said outside a build; a time of its own.
//   odin run tools/run_tests -- status_line
package status_line_test

import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
App :: struct {
	line:  ui.Status_Line,
	say:   int,      // ms to say "Saved 3" for at the next build (0: nothing)
	shown: string,   // what the last build read
}

@(private = "file")
build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	if app.say > 0 {
		ui.status_say(&app.line, "Saved %d", 3, shown_ms = app.say)
		app.say = 0
	}
	app.shown = ui.status_text(&app.line)
}

@(test)
a_status_message_goes_by_itself :: proc(t: ^testing.T) {
	app: App
	defer ui.status_destroy(&app.line)
	s := session.start(t, {build = build, user = &app, no_renderer = true})
	testing.expect_value(t, app.shown, "")

	app.say = ui.STATUS_SHOWN_MS
	session.frames(s, 1)
	testing.expect_value(t, app.shown, "Saved 3")
	wake := ui.wake_ms(s.state)
	testing.expectf(t, wake > 0 && wake <= ui.STATUS_SHOWN_MS + 1, "the window wakes at its end: %d", wake)
	session.advance(s, ui.STATUS_SHOWN_MS - 100)
	testing.expect_value(t, app.shown, "Saved 3")
	session.advance(s, 200)
	testing.expect_value(t, app.shown, "")
	testing.expect_value(t, ui.status_text(&app.line), "")

	// a time of its own
	app.say = 5000
	session.frames(s, 1)
	session.advance(s, ui.STATUS_SHOWN_MS + 100)
	testing.expect_value(t, app.shown, "Saved 3")
	session.advance(s, 2000)
	testing.expect_value(t, app.shown, "")

	// said outside a build: the next frame shows it and asks the wake
	ui.status_say(&app.line, "Copied")
	session.frames(s, 1)
	testing.expect_value(t, app.shown, "Copied")
	wake = ui.wake_ms(s.state)
	testing.expectf(t, wake > 0 && wake <= ui.STATUS_SHOWN_MS + 1, "the window wakes at its end: %d", wake)

	ui.status_clear(&app.line)
	session.frames(s, 1)
	testing.expect_value(t, app.shown, "")
}
