# Testing

`odin run tools/run_tests` runs every test package of this system, side by side, each its own process (`-list` names them; the first lines of
`tools/run_tests/main.odin` give the flags). On Windows it runs itself on a desktop of its own: what a test opens can take nobody's focus, mouse or keyboard.
`odin run tools/run_tests -- <name>` runs one package with what its line gives it: its defines, one test at a time when it
builds an interface, the failure hooks, and on Linux the native text library. A bare `odin test tests/<name>
-collection:gt=src` (the tests import the toolkit as `gt:`) has none of these, so a test that draws text or drives the ui package's state fails there for no fault of its own: use `run_tests`.
A new package is a line of the list in
`tools/run_tests/main.odin`, with its group for the WebGPU backend.

## A test of an interface

A test is an `@(test)` procedure on Odin's own test runner, and it calls the toolkit directly (`src/testkit/session`, `toolkit:testkit/session` from an application):

```odin
App :: struct { clicks: int, name: ui.Line_Edit }

@(test)
the_button_counts :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.name)
	s := session.start(t, {user = &app, build = proc(s: ^session.Session) {
		app := (^App)(s.user)
		if ui.button("add", "Add").clicked { app.clicks += 1 }
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
- **The views' windows**: `ui.views_set_windows(&app.views, session.view_windows(s, o))` is the test backend of the
  External presentation. Each window a view asks for is an offscreen window with its own State, a session of its own
  (`find`, `click`, `key` on it); its frames are the application's. `session.view_window(s, vs, id)` gives it (nil:
  none), `session.window_shown(w)` whether it is on the screen, `session.system_close(w)` is the system's close,
  `session.hide(s)` and `session.show(s)` the application hiding its window and showing it again (its views' windows
  follow).
  `o.refuse` refuses every window; `o.no_positions` is Wayland's rule (no drop outside, no drag of a window onto the
  owner's targets). An action that fails ends the test with its message (Linux: `testing.fail_now`; Windows: a time
  limit of 0 after the message, the runner's signal handling allows no more).
- **Barriers, never sleeps.** `session.wait_until(s, ready, "what")`, `wait_box`, `wait_text`, `wait_gone`, `wait_idle` make frames until what they wait for holds; a bound (`bound`, 60 s by default) only ends a failing run. Every input action returns once what it caused is built.
- **Time is the session's.** `session.advance(s, ms)` moves the clock (`ui.set_clock`) frame by frame: a tooltip's delay, a caret's blink, a held scroll bar arrow's repeat, a scroll bar that hides happen with no wait. Elsewhere: a clock passed in (`Build_Params.time_ms`, `platform.cadence_*` take theirs), a semaphore or a barrier for another thread.
- **An action that fails ends the test there**, with where it was called from; what it left is in `build/session/<test>/` (`failure.png`, `failure_tree.txt`, its `save_png`s). A test checks no return; checks are `testing.expect*`.
- **A whole application**: `session.attach(t, {win = app.win, state = &app.ui_state, renderer = &app.r, frame = ..., user = app})` drives one that makes its own window (offscreen) and frames (`tests/examples`). Something the application does not let a test see: add it to the application, not to the test.
- **The devtools protocol without a port**: `devtools.start_local` and `devtools.Local_Client` (`tests/examples/whatsnew_test.odin`).
- **Pictures**: `session.expect_like(s, path)` against a reference image, `TOOLKIT_TEST_UPDATE=1` writes them: review them like code. Prefer a colour at a point (`pixel`, `count_color`): it says what is wrong.
- **The frame of a translucent window**: `Options.half_float` stores the session's frame in half floats, as a translucent
  window's in linear light (`render.init_offscreen(..., half_float = true)`). An 8-bit frame clamps what is drawn to
  [0, 1]; a half-float one keeps it, as the window gets it. `session.capture` gives it as an 8-bit frame would hold it;
  `session.capture_float` gives its values as they are stored (`render.read_pixels_float`), and
  `session.out_of_range(img, least_alpha, margin)` finds a value that is not finite or out of [0, 1], or an alpha under
  `least_alpha` (`1 - margin` for a scene that must be opaque). `tests/partial_redraw` runs its scenes in both formats.
- **What blocks the window**: with `TOOLKIT_BLOCKING_CHECK` (a program's tests have it: `toolbox.odin_command`), a session
  counts the calls that wait on the system in its frames (`Session.blocking`) and the test fails at its end for any;
  `session.allow_blocking(s)` for a test of a step meant to wait ([tasks.md](tasks.md), "Finding what blocks").
- **Partial redraw**: `session.damage_verify(s)` turns partial redraw on and draws each partial frame whole on the side;
  `session.damage_settle(s, frames)` runs frames until 12 in a row redraw nothing (the largest region on the way),
  `session.damage_px(s)` gives the last frame's region; `session.damage_expect_exact(t, s, what)` fails when a partial
  frame differed from the whole one or the last frame is not opaque (`session.expect_opaque`). On WebGPU's WARP the
  verify draws each frame twice: keep a package of such scenes small (`tests/partial_redraw`,
  `tests/partial_redraw_layers`, each a process of its own under the CI's 420 s).
- **The globals**: `tests/globals` reads the packages' sources (next to it, not from the working directory) and checks every package-level variable against `tools/globals_allowed.txt` (getting-started.md, "Where state lives").
- **The case of names**: `tests/unicode_case` reads the sources the same way and fails on a call of `strings.to_lower` / `to_upper` / `equal_fold` or `unicode.to_lower` / `to_upper` that `tools/unicode_case_allowed.txt` does not list with why: they fold by Unicode (the Kelvin sign U+212A is `k` to them), names and protocols take `ascii.lower`, `ascii.equal_fold`...
- **What needs a real window** stays in `tests/window`, `tests/cursors`, `tests/tray`: hidden windows, fed the system's messages, on the runner's desktop. **What needs a real server** on Linux: `tk desktop_tests`. Each server and the test program run in a process group of their own, stopped whole when they end, on a failure, a time limit or a signal to `tk`; their output goes to files, the test program's printed when it ends.

Numbers in a test are named at the top of its file.
