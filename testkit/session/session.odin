// Package session: what a test of an interface calls. A test is a `@(test)` procedure on Odin's test runner:
//
//   @(test)
//   the_button_counts :: proc(t: ^testing.T) {
//       App :: struct { clicks: int }
//       app: App
//       s := session.start(t, {user = &app, build = proc(s: ^session.Session) {
//           app := (^App)(s.user)
//           if ui.button("Add###add").clicked { app.clicks += 1 }
//       }})
//       session.click(s, "add")
//       testing.expect_value(t, app.clicks, 1)
//       testing.expect(t, session.pixel(session.capture(s), 10, 10).a == 255)
//   }
//
// Everything runs in the test's own thread and process, through the toolkit's own paths: the window is offscreen (no window of
// the system exists, nothing can take the focus, the mouse or the keyboard of whoever is at the machine), its events go through
// platform.inject_event and poll_events, the frames are the real renderer's, offscreen, made as fast as they are asked for and
// readable pixel by pixel. Its time is a clock of its own: `advance` moves it, and nothing here sleeps. A barrier makes frames
// until what it waits for holds; a deadline only ends a failing run.
//
// `start` makes a whole application around a `build` procedure. `attach` drives an application that makes its own window,
// renderer and frames (an example, a browser): the same input, barriers and pixels.
//
// An action that fails ends the test there, with where it was called from and what it left (build/session/<test>/failure.png
// and the tree of boxes): a test checks no return. Checks are testing.expect*.
//
// One test at a time in a process (-define:ODIN_TEST_THREADS=1): the ui package's current state is the process's. Several sessions in a
// test are several windows on one virtual screen.
package tk_session

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"
import "../../ui"

// What a test may take in all before the runner stops it (a barrier's deadline comes first).
TEST_LIMIT :: 5 * time.Minute
// How long a barrier may take before the test is said to have failed (real time).
DEFAULT_DEADLINE :: 60 * time.Second
// The window when a test does not say.
DEFAULT_SIZE :: [2]int{800, 600}
// One frame of the clock, ms: a screen of 60 Hz.
FRAME_MS :: 1000.0 / 60
// Where a session's clock starts, ms (0 is "not set" to the ui package).
CLOCK_START_MS :: 1000.0
// The root style when a test does not say, in logical pixels: what the examples use.
BASE_FONT_SIZE :: 15
BASE_ROW_HEIGHT :: 30
BASE_TEXT_PAD :: 6
// Builds in a row with nothing moving that make "idle": an app may react to a frame with one more frame.
IDLE_BUILDS :: 3
// How far above a test program the repository is looked for.
@(private) REPO_MAX_DEPTH :: 6
// The folder of what a test leaves when it fails, under the build folder.
OUT_DIR :: "session"
FAILURE_CAPTURE :: "failure.png"
FAILURE_TREE :: "failure_tree.txt"

Options :: struct {
	build:      proc(s: ^Session),   // the interface: called between ui.begin_build and ui.end_build, once a frame
	user:       rawptr,              // what `build` works on
	size:       [2]int,              // the client area in physical pixels (0: DEFAULT_SIZE)
	dpi_scale:  f32,                 // dpi / 96 (0: 1)
	palette:    Maybe(ui.Palette),   // nil: PALETTE_MIDNIGHT
	animations: bool,                // false: every transition jumps to its end
	smooth_scroll: ui.Smooth_Scroll,
	no_renderer: bool,               // build and layout only: no device is made, `capture` is refused. For what no pixel depends on
	space:      render.Blend_Space,
	system_fonts: bool,              // the system's font first, as an application does (false: the fonts compiled in: the same on every machine)
}

// What `attach` needs of an application that makes its own frames.
Application :: struct {
	win:      ^platform.Window,      // offscreen (open_window_offscreen)
	state:    ^ui.State,
	renderer: ^render.Renderer,      // nil: no pixels
	frame:    proc(user: rawptr),    // one frame of the application: polls, builds, draws
	user:     rawptr,
	allocator: runtime.Allocator,    // what its frames allocate with (zero: the test's: what it keeps beyond a frame must be freed by the test's end)
}

Session :: struct {
	t:        ^testing.T,
	user:     rawptr,
	win:      ^platform.Window,
	state:    ^ui.State,
	renderer: ^render.Renderer,
	clock:    f64,                   // the state's time (ui.set_clock): `advance` moves it
	frames:   int,                   // made so far
	buttons:  platform.Mouse_Buttons,   // held (press, release)
	pointer:  [2]f32,                // where the last pointer event was
	name:     string,                // the test's
	out:      string,                // the folder of what it leaves
	// The application's frames run under a context of their own: each frees its temporary memory, which must not be the one a test holds strings in.
	ctx:      runtime.Context,
	test:     runtime.Context,
	temp:     runtime.Default_Temp_Allocator,
	thread:   int,
	// an application of ours (start)
	own:      ^Own,
	// an application of its own (attach)
	app_frame: proc(user: rawptr),
	app_user:  rawptr,
	// what the next frame says has changed, for a test of partial redraw (draw.set_partial_redraw through draw_context): nil is the whole frame
	damage:    Maybe(draw.Rect),
}

// What `start` makes.
Own :: struct {
	build:      proc(s: ^Session),
	state:      ui.State,
	renderer:   render.Renderer,
	fonts:      font.State,
	dc:         draw.Context,
	theme:      ui.Theme,
	ui_font:    font.Font_Id,
	mono_font:  font.Font_Id,
	icon_font:  font.Font_Id,
	animations: bool,
	smooth_scroll: ui.Smooth_Scroll,
	no_renderer: bool,
}

// The session a frame runs for (the clipboard callbacks of Build_Params take no argument). A test's only: one test at a time.
@(private) current: ^Session
// The thread of the test running, while one runs: a second thread at once means the runner was not told -define:ODIN_TEST_THREADS=1.
@(private) owner_thread: int    // (atomic)
@(private) live_sessions: int   // (atomic)

// An application around `o.build`, offscreen, with the embedded fonts and the offscreen renderer. It ends with the test.
start :: proc(t: ^testing.T, o: Options, loc := #caller_location) -> ^Session {
	s := session_new(t, loc)
	s.user = o.user
	own := new(Own)
	s.own = own
	own.build = o.build
	own.animations = o.animations
	own.smooth_scroll = o.smooth_scroll
	own.no_renderer = o.no_renderer
	context = s.ctx
	size := o.size.x > 0 ? o.size : DEFAULT_SIZE
	s.win = platform.open_window_offscreen(s.name, size, o.dpi_scale)
	if s.win == nil { failed(s, "no offscreen window", loc) }
	font.init(&own.fonts)
	ok: bool
	if o.system_fonts {
		own.ui_font, ok, _ = font.load_system_or_embedded(&own.fonts, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	} else {
		own.ui_font, ok = font.load_embedded(&own.fonts, font.FALLBACK_UI_DATA)
	}
	if !ok { failed(s, "no interface font", loc) }
	own.mono_font, ok = font.load_embedded(&own.fonts, font.FALLBACK_MONO_DATA)
	if !ok { failed(s, "no monospaced font", loc) }
	own.icon_font, ok = font.load_embedded(&own.fonts, ui.ICON_FONT_DATA)
	if !ok { failed(s, "no icon font", loc) }
	if !o.no_renderer {
		if !render.init_offscreen(&own.renderer, s.win.size, warp = true, space = o.space) { failed(s, "no offscreen renderer on this machine", loc) }
		s.renderer = &own.renderer
		draw.init(&own.dc, &own.renderer, &own.fonts)
	}
	palette := o.palette.? or_else ui.PALETTE_MIDNIGHT
	ui.apply_palette(&own.theme, palette, o.space)
	ui.init(&own.state, &own.fonts, &own.theme)
	own.state.icon_font = own.icon_font
	own.state.mono_font = own.mono_font
	s.state = &own.state
	ui.set_clock(s.state, &s.clock)
	frame(s)   // (a test begins with the interface there: boxes to look for)
	return s
}

// A test of an application that makes its own window, renderer and frames (`app.win` is offscreen). The application ends it
// itself, after the session (a testing.cleanup made before this call).
attach :: proc(t: ^testing.T, app: Application, loc := #caller_location) -> ^Session {
	s := session_new(t, loc)
	s.user = app.user
	s.win, s.state, s.renderer = app.win, app.state, app.renderer
	s.app_frame, s.app_user = app.frame, app.user
	if app.allocator.procedure != nil { s.ctx.allocator = app.allocator }
	ui.set_clock(s.state, &s.clock)
	if !platform.is_offscreen(s.win) { failed(s, "attach: this window is a real one", loc) }
	return s
}

@(private)
session_new :: proc(t: ^testing.T, loc: runtime.Source_Code_Location) -> ^Session {
	testing.set_fail_timeout(t, TEST_LIMIT, loc)
	me := sync.current_thread_id()
	if sync.atomic_add(&live_sessions, 1) > 0 && sync.atomic_load(&owner_thread) != me { stop_test(t, "two tests at once: run this package with -define:ODIN_TEST_THREADS=1", loc) }
	sync.atomic_store(&owner_thread, me)
	s := new(Session)
	s.t = t
	s.test = context
	s.name = strings.clone(loc.procedure)
	s.out = strings.clone(fmt.tprintf("%s/build/%s/%s", repo_root(), OUT_DIR, s.name))
	s.thread = me
	s.clock = CLOCK_START_MS
	runtime.default_temp_allocator_init(&s.temp, 0, context.allocator)
	s.ctx = context
	s.ctx.temp_allocator = {runtime.default_temp_allocator_proc, &s.temp}
	testing.cleanup(t, proc(p: rawptr) { session_end((^Session)(p)) }, s)
	return s
}

// The test is over (testing.cleanup: on the runner's main thread when it was stopped by a failure).
@(private)
session_end :: proc(s: ^Session) {
	sync.atomic_sub(&live_sessions, 1)
	if s.thread != sync.current_thread_id() { return }   // (stopped in the middle of what it was doing: its state stays as it was, with the process)
	context = s.ctx
	if testing.failed(s.t) { keep_failure(s) }
	if current == s { current = nil }
	if s.state != nil { ui.set_clock(s.state, nil) }
	if own := s.own; own != nil {
		platform.clipboard_set(s.win, {})   // (the process's store outlives the test)
		ui.destroy(&own.state)
		ui.theme_destroy(&own.theme)
		if !own.no_renderer {
			draw.destroy(&own.dc)
			render.destroy(&own.renderer)
		}
		font.destroy(&own.fonts)
		platform.destroy_window(s.win)
		free(own)
	}
	context = s.test
	runtime.default_temp_allocator_destroy(&s.temp)
	delete(s.name)
	delete(s.out)
	free(s)
}

// The repository: this program is in its build folder (TOOLKIT_REPO says otherwise). For what a test reads or leaves.
repo_root :: proc(allocator := context.temp_allocator) -> string {
	if r, ok := os.lookup_env("TOOLKIT_REPO", allocator); ok && r != "" { return r }
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil { return strings.clone(".", allocator) }
	// (the folder above the program's that has this package: a test program may be in build/ or build/tests/)
	dir := filepath.dir(exe)
	for _ in 0 ..< REPO_MAX_DEPTH {
		if os.exists(fmt.tprintf("%s/testkit/session", dir)) { return strings.clone(dir, allocator) }
		dir = filepath.dir(dir)
	}
	return strings.clone(".", allocator)
}

// A file of this test's folder (what is there stays only as long as the next run of the test).
out_path :: proc(s: ^Session, name: string) -> string {
	_ = os.make_directory_all(s.out)
	return fmt.aprintf("%s/%s", s.out, name, allocator = s.test.temp_allocator)
}

// Ends the test here: its message is logged at the place given, and the runner ends this thread (its "Test timed out" follows
// the message: a limit of 0 is the one way of being ended that core:testing gives a test twice in a run: testing.fail_now raises a
// signal, and on Windows the runner lets go of a lock it does not hold when it handles one, so that the next signal waits for ever).
stop_test :: proc(t: ^testing.T, message: string, loc: runtime.Source_Code_Location) -> ! {
	log.error(message, location = loc)
	testing.set_fail_timeout(t, 0, loc)
	for { time.sleep(time.Hour) }
}

// An action failed: the test ends here, and says what to read.
failed :: proc(s: ^Session, why: string, loc := #caller_location) -> ! {
	context = s.test
	message := fmt.tprintf("%s (what it left: %s)", why, s.out)
	keep_failure(s)
	context = s.test
	stop_test(s.t, message, loc)
}

// What a failure is read with: the last frame as it was, the tree of boxes.
@(private)
keep_failure :: proc(s: ^Session) {
	if s.win == nil || s.state == nil || ui.building() { return }
	if s.renderer != nil && render.is_offscreen(s.renderer) { save_png(s, FAILURE_CAPTURE) }
	_ = os.write_entire_file(out_path(s, FAILURE_TREE), transmute([]byte)tree_text(s))
}

////////////////////////////////
// Frames and time

// One frame of the application.
frame :: proc(s: ^Session) {
	if ui.building() { return }
	test := context
	defer context = test
	current = s
	context = s.ctx
	s.frames += 1
	s.clock += FRAME_MS
	if s.app_frame != nil {
		s.app_frame(s.app_user)
	} else {
		own_frame(s)
	}
	free_all(context.temp_allocator)
}

@(private)
own_frame :: proc(s: ^Session) {
	own := s.own
	events := platform.poll_events(s.win, false)
	if s.renderer != nil { render.resize(s.renderer, s.win.size) }
	size := ui.Vec2{f32(s.win.size.x), f32(s.win.size.y)}
	ui.begin_build(s.state, {
		window_size = size, events = events, dt = FRAME_MS / 1000, animations = own.animations, smooth_scroll = own.smooth_scroll,
		dpi_scale = s.win.dpi_scale, window = s.win,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(BASE_ROW_HEIGHT)}, font = own.ui_font, font_size = BASE_FONT_SIZE, text_pad = BASE_TEXT_PAD, cursor = .Arrow},
		clipboard_get = clipboard_of_current, clipboard_set = set_clipboard_of_current,
		inactive = !s.win.active,
	})
	if own.build != nil { own.build(s) }
	ui.end_build()
	platform.set_cursor(s.win, ui.cursor(s.state))
	if s.renderer == nil { return }
	render.frame_begin(s.renderer, ui.theme_lookup(&own.theme, {}, "background"))
	draw.begin_frame(&own.dc, size)
	if region, partial := s.damage.?; partial {
		draw.damage_begin(&own.dc)
		draw.damage(&own.dc, region)
		s.damage = nil
	}
	ui.draw_tree(s.state, &own.dc)
	draw.end_frame(&own.dc)
	render.frame_end(s.renderer, false)
}

@(private) clipboard_of_current :: proc() -> string { return platform.get_clipboard(current.win, context.temp_allocator) }
@(private) set_clipboard_of_current :: proc(text: string) { platform.set_clipboard(current.win, text) }

// `n` frames.
frames :: proc(s: ^Session, n: int) { for _ in 0 ..< n { frame(s) } }

// `ms` of the clock go by, frame by frame: what is due on the way (a caret's blink, a tooltip's delay, the end of an animation) happens.
advance :: proc(s: ^Session, ms: f64, loc := #caller_location) {
	if ui.building() { failed(s, "advance inside a build: no frame can be made, the clock would never move", loc) }
	end := s.clock + ms
	for s.clock < end {
		frame(s)
	}
}

// Nothing moves any more: the frames it takes, each one of the usual length to the clock. A timed wake is no movement (a
// caret blinks for ever): what it waits for is `advance`'s.
wait_idle :: proc(s: ^Session, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	end := time.tick_add(time.tick_now(), deadline)
	quiet := 0
	for quiet < IDLE_BUILDS {
		if time.tick_diff(time.tick_now(), end) <= 0 { failed(s, fmt.tprintf("%v passed and something still moves", deadline), loc) }
		frame(s)
		quiet = ui.needs_frame(s.state) ? 0 : quiet + 1
	}
}

// Any condition: `ready(s)` is looked at before each frame. What it needs comes as `data` in the second form.
wait_until_plain :: proc(s: ^Session, ready: proc(s: ^Session) -> bool, what := "a condition", deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	end := time.tick_add(time.tick_now(), deadline)
	for !ready(s) {
		if time.tick_diff(time.tick_now(), end) <= 0 { failed(s, fmt.tprintf("%v passed waiting for %s", deadline, what), loc) }
		frame(s)
	}
}

wait_until_with :: proc(s: ^Session, data: $D, ready: proc(s: ^Session, data: D) -> bool, what := "a condition", deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	end := time.tick_add(time.tick_now(), deadline)
	for !ready(s, data) {
		if time.tick_diff(time.tick_now(), end) <= 0 { failed(s, fmt.tprintf("%v passed waiting for %s", deadline, what), loc) }
		frame(s)
	}
}

wait_until :: proc { wait_until_plain, wait_until_with }

// A box with this name is in the tree.
wait_box :: proc(s: ^Session, name: string, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) -> ^ui.Box {
	wait_until(s, name, proc(s: ^Session, name: string) -> bool { return find(s, name) != nil }, fmt.tprintf("the box %q", name), deadline, loc)
	return find(s, name)
}

// A box shows this text (ASCII case does not count).
wait_text :: proc(s: ^Session, text: string, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) -> ^ui.Box {
	wait_until(s, text, proc(s: ^Session, text: string) -> bool { return find_text(s, text) != nil }, fmt.tprintf("the text %q", text), deadline, loc)
	return find_text(s, text)
}

// No box with this name any more.
wait_gone :: proc(s: ^Session, name: string, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	wait_until(s, name, proc(s: ^Session, name: string) -> bool { return find(s, name) == nil }, fmt.tprintf("the box %q to go", name), deadline, loc)
}

////////////////////////////////
// The window

// The client area changes (physical pixels), as a resize by the system would.
resize :: proc(s: ^Session, size: [2]int) {
	platform.set_size(s.win, size)
	if s.renderer != nil { render.resize(s.renderer, s.win.size) }
	frames(s, 2)
}

// The window moves to a monitor of another scale: its logical size stays, its pixels change.
set_dpi :: proc(s: ^Session, dpi_scale: f32) {
	platform.set_offscreen_dpi(s.win, int(dpi_scale * DPI_BASE))
	if s.renderer != nil { render.resize(s.renderer, s.win.size) }
	frames(s, 2)
}
@(private) DPI_BASE :: 96   // dpi of a scale of 1

// The drawing context of an application of `start`.
draw_context :: proc(s: ^Session, loc := #caller_location) -> ^draw.Context {
	if s.own == nil { failed(s, "draw_context: an attached application draws with its own", loc) }
	return &s.own.dc
}

// The window becomes the one the user is in, or stops being it (another session's window takes it: `activate(b, true)` after `activate(a, false)`).
activate :: proc(s: ^Session, on: bool) {
	platform.set_offscreen_active(s.win, on)
	frames(s, 2)
}

// The clipboard (the process's store: the machine's is not touched).
clipboard :: proc(s: ^Session) -> string { return platform.get_clipboard(s.win, s.test.temp_allocator) }
set_clipboard :: proc(s: ^Session, text: string) { platform.set_clipboard(s.win, text) }

// The cursor the window asks for now.
cursor :: proc(s: ^Session) -> platform.Cursor { return s.win.cursor }
