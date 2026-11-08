// A window as an object: its window of the system, its interface, what it is drawn on and how its frames go. Above ui and
// render, which do not know each other. The loop every application wrote, once:
//
//   app.main.background = ...
//   host.host_open(&app.main, &app.shared, {title = "My app", size = {640, 400}}, build, app)
//   platform.show_window(app.main.win)
//   for !platform.is_closed(app.main.win) {
//       host.hosts_wait({&app.main})
//       host.host_frame(&app.main)
//   }
//   host.host_close(&app.main)
//
// The windows of a program share a device, fonts and a theme (Shared). The first one opened is the renderer's own; each of
// the others is a Surface on it, its own ui.State, built in turn on the same thread.
//
// What a frame does is the order the real loops came to, and each part of it has a reason:
//   * The surface is taken around the pacing and given back before the input is read. Reading input can enter a loop of
//     the system (a border held), whose frames want the renderer and the interface as a frame leaves them; they are other
//     windows' too. It may also leave this window closed.
//   * A step of a resize is that window's alone, at once (host_paint): waiting for another window's frame, or drawing
//     that one first, is what shows a window late on its border. When its border rests, the program's whole frame goes
//     on from there (rest_frame).
//   * Every window has a composition surface whose buffers keep the size of the monitor, shown 1:1 and clipped by the window:
//     nothing is ever stretched, and on_frame draws from inside the system's loop for as long as the border is held.
//   * Only the first window is paced. All of them are drawn on one thread: each waiting for its own slot and its own screen,
//     the waits would add up. The others go out as soon as they are drawn, in the rhythm of the first (`paced`).
//
// A rich application is no less at home here: the hooks are the parts of a frame that are its own. Several builds in a frame
// (`builds`), a frame held back (`hold`), input taken before the interface sees it (`input`). None of this is required:
// the way of docs/getting-started.md, each call by hand, keeps working, and a program may use both.
package host

import "core:fmt"
import "core:time"
import "../draw"
import "../font"
import "../platform"
import "../render"
import "../ui"

Vec2 :: draw.Vec2

// A frame's dt stays within this: after a long stall the animations go on, they do not jump.
DT_MIN_S :: 0.0005
DT_MAX_S :: 0.1

// The base style's defaults, in logical pixels (Build_Params.base; `params` changes them).
BASE_ROW_HEIGHT :: 30
BASE_FONT_SIZE :: 15
BASE_TEXT_PAD :: 6

// What the windows of a program share. Filled by the first host_open, ended with the last host_close.
Shared :: struct {
	r:     render.Renderer,
	dc:    draw.Context,
	fonts: font.State,
	theme: ui.Theme,
	font:  font.Font_Id,   // the interface's
	main:  ^Host,          // the first window: the renderer's own, and the interface that is current between frames
}

Open :: struct {
	title:            string,
	size:             [2]int,
	integrated_title: bool,   // platform.open_window's
	headless:         bool,   // the first window only: no window of the system, the software renderer, the font compiled in
	under_children:   bool,   // render.surface_init's: a window that gets a child window from elsewhere (a web view)
}

Host :: struct {
	shared:     ^Shared,
	win:        ^platform.Window,
	state:      ui.State,
	surface:    render.Surface,   // (not valid for the first window: surface_use then does nothing, the renderer's own is drawn on)
	pacer:      render.Pacer,
	paced:      bool,             // frames follow the pacer; else each is shown at once. The first window's by default
	user:       rawptr,
	background: draw.Color,       // what the frame is cleared to
	settle:     int,              // frames still owed, whatever else asks for one (what a change set off settles)
	after_input: int,             // frames owed after an event

	build: proc(h: ^Host, size: Vec2),   // the widgets, between begin_build and end_build

	// The hooks, all optional, in the order of a frame.
	before_input: proc(h: ^Host),                                      // before the input is read (a remote control's commands: this frame's)
	still:        proc(h: ^Host, events: []platform.Event) -> bool,   // nothing it shows changed: no build, no picture (the last one stays)
	dragging:     proc(h: ^Host) -> bool,                              // the pacer paces as a drag. nil: a press is held
	input:        proc(h: ^Host, events: []platform.Event) -> []platform.Event,   // what is left of the input for the interface
	params:       proc(h: ^Host, p: ^ui.Build_Params),                 // what each build is given
	builds:       proc(h: ^Host, size: Vec2, events: []platform.Event, dt: f32),  // the frame's builds. nil: one host_build
	after_build:  proc(h: ^Host),                                      // the interface is built, nothing is drawn
	hold:         proc(h: ^Host, size: Vec2) -> (ms: int),             // > 0: no picture this frame, and a wake within that
	rest_frame:   proc(h: ^Host),   // from the system's loop, no step of a resize to show: the program's whole frame. nil: this window's
	after_frame:  proc(h: ^Host),   // the picture is out (or held): what the program does between two frames. Not after a frame that found its window closed

	slept:   bool,     // the loop slept before this frame (hosts_wait)
	times:   Host_Times,   // the last picture's steps
	shown:   [2]int,   // the size of the last picture
	last_ms: f64,      // the clock at the last frame
}

// How long the steps of the last picture took. (The builds are the application's to time: `builds` may make several.)
Host_Times :: struct { draw, present: time.Duration }

// A window and a renderer the application made itself, in its own order of start (a device loaded on a thread while its fonts load, its
// own faces): the host takes them as they are, `sh` filled. The first one adopted is the main one. Its state is the application's to
// init (ui.init), as it was before.
host_adopt :: proc(h: ^Host, sh: ^Shared, w: ^platform.Window, build: proc(h: ^Host, size: Vec2), user: rawptr = nil) {
	first := sh.main == nil
	h.shared, h.win, h.build, h.user, h.paced = sh, w, build, user, first
	if first { sh.main = h }
	h.last_ms = ui.now_ms()
	w.user, w.on_frame = h, host_paint
}

// Opens a window: the first one makes what is shared, the others a surface on it. `h` stays where it is until host_close (the window
// calls back with it). False: it cannot open, has said why and has left nothing behind.
host_open :: proc(h: ^Host, sh: ^Shared, o: Open, build: proc(h: ^Host, size: Vec2), user: rawptr = nil) -> bool {
	first := sh.main == nil
	h.shared, h.build, h.user, h.paced = sh, build, user, first
	if first { font.init(&sh.fonts) }
	if o.headless {
		h.win = platform.open_window_offscreen(o.title, o.size)
	} else {
		h.win = platform.open_window(o.title, o.size, transparent = true, integrated_title = o.integrated_title)
	}
	if h.win == nil {
		fmt.eprintln("host: no window")
		if first { font.destroy(&sh.fonts) }
		return false
	}
	ok := first ? shared_open(sh, h.win, o.headless) : surface_open(h, o)
	if !ok {
		if first { font.destroy(&sh.fonts) }
		platform.destroy_window(h.win)
		h.win = nil
		return false
	}
	if first { sh.main = h }
	ui.init(&h.state, &sh.fonts, &sh.theme)
	ui.use(&sh.main.state)
	h.last_ms = ui.now_ms()
	h.win.user, h.win.on_frame = h, host_paint
	return true
}

@(private = "file")
shared_open :: proc(sh: ^Shared, w: ^platform.Window, headless: bool) -> bool {
	if headless {
		if !render.init_offscreen(&sh.r, w.size, warp = true) { fmt.eprintln("host: no renderer"); return false }
	} else {
		if !render.init_window(&sh.r, w, w.size, transparent = true) { fmt.eprintln("host: no renderer"); return false }
		render.set_fixed_surface(&sh.r, platform.monitor_size(w))
	}
	ok: bool
	sh.font, ok, _ = font.load_system_or_embedded(&sh.fonts, headless ? "" : platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	if !ok {
		fmt.eprintln("host: no UI font")
		render.destroy(&sh.r)
		return false
	}
	draw.init(&sh.dc, &sh.r, &sh.fonts)
	ui.apply_palette(&sh.theme, ui.PALETTE_MIDNIGHT)
	return true
}

@(private = "file")
surface_open :: proc(h: ^Host, o: Open) -> bool {
	sh := h.shared
	ok := render.surface_init(&sh.r, &h.surface, platform.native_surface_handles(h.win), h.win.size, transparent = true,
		fixed_size = platform.monitor_size(h.win), under_children = o.under_children)
	if !ok { fmt.eprintln("host: the renderer refused a window") }
	return ok
}

// Closes a window. The first one ends what is shared: it goes last. Not from inside this window's own frame.
host_close :: proc(h: ^Host) {
	sh := h.shared
	first := sh.main == h
	assert(!first || !ui.building(), "host: host_close inside a build")
	if !first { render.surface_destroy(&sh.r, &h.surface) }
	ui.destroy(&h.state)
	if first {
		sh.main = nil
		ui.theme_destroy(&sh.theme)
		draw.destroy(&sh.dc)
		render.destroy(&sh.r)
		font.destroy(&sh.fonts)
	} else {
		ui.use(&sh.main.state)
	}
	platform.destroy_window(h.win)
	h.win = nil
}

// One build of this window's interface. `builds` calls it as many times as a frame needs; a build after the first takes no input
// (`nil`, dt 0: it was the first one's).
host_build :: proc(h: ^Host, size: Vec2, events: []platform.Event, dt: f32) {
	p := ui.Build_Params{
		window_size = size, events = events, dt = dt, animations = platform.os_animations_enabled(),
		dpi_scale = h.win.dpi_scale, window = h.win,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(BASE_ROW_HEIGHT)}, font = h.shared.font, font_size = BASE_FONT_SIZE, text_pad = BASE_TEXT_PAD, cursor = .Arrow},
		clipboard_get = ui.window_clipboard_get, clipboard_set = ui.window_clipboard_set,
	}
	if h.params != nil { h.params(h, &p) }
	ui.begin_build(&h.state, p)
	h.build(h, size)
	ui.end_build()
}

// One frame of this window. `inner`: asked for from a loop of the system.
host_frame :: proc(h: ^Host, inner := false) {
	if ui.building() { return }   // (a loop of the system entered from a build)
	sh := h.shared
	defer ui.use(&sh.main.state)
	ui.use(&h.state)
	at_once := host_pace(h, inner)
	h.slept = false
	if h.before_input != nil { h.before_input(h) }
	events := platform.poll_events(h.win, false)
	if platform.is_closed(h.win) { return }
	ui.use(&h.state)   // (a frame of another window may have run in that call)
	host_picture(h, events, at_once)
	if h.after_frame != nil { h.after_frame(h) }
	if !inner && h.settle > 0 { h.settle -= 1 }
	free_all(context.temp_allocator)
}

// The wait of the frame, on this window's swap chain. (Its own scope: the surface goes back before the input is read.)
@(private = "file")
host_pace :: proc(h: ^Host, inner: bool) -> (at_once: bool) {
	if !h.paced { return }
	render.surface_scope(&h.shared.r, &h.surface)
	dragging := h.dragging != nil ? h.dragging(h) : ui.active_key() != 0
	return render.pace_frame(&h.pacer, &h.shared.r, h.win, idled = h.slept, dragging = dragging, inner = inner)
}

@(private = "file")
host_picture :: proc(h: ^Host, read: []platform.Event, at_once: bool) {
	sh := h.shared
	r := &sh.r
	render.surface_scope(r, &h.surface)
	render.mark_input(r)
	events := read
	if len(events) > 0 { h.settle = max(h.settle, h.after_input) }
	if h.still != nil && h.still(h, events) { return }
	if h.input != nil { events = h.input(h, events) }
	render.resize(r, h.win.size)
	size := Vec2{f32(h.win.size.x), f32(h.win.size.y)}
	now := ui.now_ms()
	dt := clamp(f32((now - h.last_ms) / 1000), DT_MIN_S, DT_MAX_S)
	h.last_ms = now
	if h.builds != nil { h.builds(h, size, events, dt) } else { host_build(h, size, events, dt) }
	platform.set_cursor(h.win, ui.cursor(&h.state))
	if h.after_build != nil { h.after_build(h) }
	if left := h.hold != nil ? h.hold(h, size) : 0; left > 0 {
		ui.wake_within(&h.state, left)
		return
	}
	t_draw := time.tick_now()
	draw.begin_frame(&sh.dc, size)
	render.frame_begin(r, h.background)
	ui.draw_tree(&h.state, &sh.dc)
	draw.end_frame(&sh.dc)
	t_present := time.tick_now()
	render.frame_end(r, h.paced && !at_once)
	if h.paced { render.paced_present(&h.pacer) }
	h.times = {draw = time.tick_diff(t_draw, t_present), present = time.tick_since(t_present)}
	h.shown = h.win.size
}

// What the window calls from inside the system's loop (platform.Window.on_frame).
host_paint :: proc(user: rawptr) {
	h := (^Host)(user)
	if ui.building() { return }
	if h.rest_frame != nil && h.win.size == h.shown {
		h.rest_frame(h)
	} else {
		host_frame(h, inner = true)
	}
}

// A frame of each window still open. `inner`: from rest_frame.
hosts_frame :: proc(hosts: []^Host, inner := false) {
	for h in hosts { if !platform.is_closed(h.win) { host_frame(h, inner) } }
}

// Whether a frame of these windows is due now (input read for one of them, a change that settles, something that moves); else how
// long the loop may sleep: the soonest of what they asked for (0: until input).
hosts_due :: proc(hosts: []^Host) -> (now: bool, wake_ms: int) {
	for h in hosts {
		if platform.is_closed(h.win) { continue }
		if h.settle > 0 || ui.needs_frame(&h.state) || platform.events_waiting(h.win) { return true, 0 }
		if w := ui.wake_in_ms(&h.state); w > 0 && (wake_ms == 0 || w < wake_ms) { wake_ms = w }
	}
	return
}

// Before a round of frames: sleeps until one is due. 0 % CPU at rest. A sleep is for the whole thread's windows, so one of them
// can stand for all; an offscreen window has no such thing, and only the first of those wakes this.
hosts_wait :: proc(hosts: []^Host) {
	now, wake := hosts_due(hosts)
	if now { return }
	for h in hosts {
		if platform.is_closed(h.win) { continue }
		platform.wait_event(h.win, wake)
		for o in hosts { o.slept = true }
		return
	}
}
