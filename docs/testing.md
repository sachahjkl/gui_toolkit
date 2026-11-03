# Testing

`odin run tools/run_tests` runs every test package of this system, side by side, each its own process (`-list` names them; the first lines of
`tools/run_tests/main.odin` give the flags). On Windows it runs itself on a desktop of its own: what a test opens can take nobody's focus, mouse or keyboard.
`odin test tests/<name> -vet` runs one package; those that build an interface add `-define:ODIN_TEST_THREADS=1`. A new package is a line of the list in
`tools/run_tests/main.odin`, with its group for the WebGPU backend.

## A test of an interface

A test is an `@(test)` procedure on Odin's own test runner, and it calls the toolkit directly (`testkit/session`, `toolkit:testkit/session` from an application):

```odin
App :: struct { clicks: int, name: ui.Text_Field }

@(test)
the_button_counts :: proc(t: ^testing.T) {
	app: App
	defer ui.field_destroy(&app.name)
	s := session.start(t, {user = &app, build = proc(s: ^session.Session) {
		app := (^App)(s.user)
		if ui.button("Add###add").clicked { app.clicks += 1 }
		ui.line_edit("###name", &app.name)
	}})
	session.click(s, "add")                                  // by the name after ### in its id
	testing.expect_value(t, app.clicks, 1)
	session.click(s, "name")
	session.type_text(s, "hello")
	session.key(s, .A, {.Ctrl})
	session.key(s, .C, {.Ctrl})
	testing.expect_value(t, session.clipboard(s), "hello")   // the process's clipboard, never the machine's
	img := session.capture(s)                                // the last frame of the real renderer, offscreen
	testing.expect(t, session.pixel(img, 10, 10).a == 255)
}
```

The rules:

- **No window of the system, no real input.** The window is offscreen (`platform.open_window_offscreen`), the renderer the offscreen one (WARP on Windows, a software Vulkan on Linux), input
  goes through `platform.inject_event` and `poll_events` as a device's does. Its machine is virtual: `platform.virtual_screen_set` (size, rate), `session.set_dpi`, `session.activate`, `session.clipboard`,
  `session.cursor`. Several `session.start` in a test are several windows.
- **Barriers, never sleeps.** `session.wait_until(s, ready, "what")`, `wait_box`, `wait_text`, `wait_gone`, `wait_idle` make frames until what they wait for holds; a deadline only ends a failing run. Every input action returns once what it caused is built.
- **Time is the session's.** `session.advance(s, ms)` moves the clock (`ui.set_clock`) frame by frame: a tooltip's delay, a caret's blink, a scroll bar that hides happen with no wait. Elsewhere: a clock passed in (`Build_Params.time_ms`, `platform.cadence_*` take theirs), a semaphore or a barrier for another thread.
- **An action that fails ends the test there**, with where it was called from; what it left is in `build/session/<test>/` (`failure.png`, `failure_tree.txt`, its `save_png`s). A test checks no return; checks are `testing.expect*`.
- **A whole application**: `session.attach(t, {win = app.win, state = &app.ui_state, renderer = &app.r, frame = ..., user = app})` drives one that makes its own window (offscreen) and frames (`tests/examples`). Something the application does not let a test see: add it to the application, not to the test.
- **The devtools protocol without a port**: `devtools.start_local` and `devtools.Local_Client` (`tests/examples/whatsnew_test.odin`).
- **Pictures**: `session.expect_like(s, path)` against a reference image, `TOOLKIT_TEST_UPDATE=1` writes them: review them like code. Prefer a colour at a point (`pixel`, `count_color`): it says what is wrong.
- **The globals**: `tests/globals` reads the packages' sources (next to it, not from the working directory) and checks every package-level variable against `tools/globals_allowed.txt` (getting-started.md, "Where state lives").
- **The case of names**: `tests/unicode_case` reads the sources the same way and fails on a call of `strings.to_lower` / `to_upper` / `equal_fold` or `unicode.to_lower` / `to_upper` that `tools/unicode_case_allowed.txt` does not list with why: they fold by Unicode (the Kelvin sign U+212A is `k` to them), names and protocols take `base.ascii_lower`, `ascii_equal_fold`...
- **What needs a real window** stays in `tests/window`, `tests/cursors`, `tests/tray`: hidden windows, fed the system's messages, on the runner's desktop. **What needs a real server** on Linux: `tools/linux_desktop.sh`.

Numbers in a test are named at the top of its file.
