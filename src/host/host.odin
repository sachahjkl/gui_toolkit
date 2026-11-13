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
// The dt of a frame after a rest (the loop slept: nothing moved), when the display's refresh is not measured yet. The
// time slept is no animation's: a switch clicked then would make most of its way in the first frame.
DT_RESTED_S :: 1.0 / 60

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
	// an overlay window (platform.open_overlay) over the output at `overlay_area` (logical, on the desktop; all zero:
	// the system's choice), shown at once. Its frames are cleared to transparent: only what the build draws shows
	overlay:          bool,
	overlay_area:     [4]int,
	overlay_keyboard: platform.Overlay_Keyboard,   // On_Demand: the keyboard once clicked; Exclusive: from its showing
}

Host :: struct {
	shared:     ^Shared,
	win:        ^platform.Window,
	state:      ui.State,
	surface:    render.Surface,   // (not valid for the first window: surface_use then does nothing, the renderer's own is drawn on)
	pacer:      render.Pacer,
	paced:      bool,             // frames follow the pacer; else each is shown at once. The first window's by default
	user:       rawptr,
	background: draw.Color,       // what the frame is cleared to (an overlay's: always transparent)
	partial_redraw: bool,         // each frame redraws only what changed in the interface (ui.set_partial_redraw); read at every frame
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
	rested:  bool,     // this frame comes after a sleep: its dt is one refresh (host_picture)
	times:   Host_Times,   // the last picture's steps
	shown:   [2]int,   // the size of the last picture
	shown_again: u32,  // the window's count of shows after a hide, as of the last frame (a new one remakes the swap chain)
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
	} else if o.overlay {
		h.win = platform.open_overlay(o.title, o.overlay_area, o.overlay_keyboard)
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
	ui.apply_palette(&sh.theme, ui.palette_of("Midnight"))
	return true
}

@(private = "file")
surface_open :: proc(h: ^Host, o: Open) -> bool {
	sh := h.shared
	ok := render.surface_init(&sh.r, &h.surface, platform.native_surface_handles(h.win), h.win.size, transparent = true,
		fixed_size = platform.monitor_size(h.win), under_children = o.under_children)
	if !ok { fmt.eprintln("host: the renderer refused a window"); return false }
	// (not the paced window: its frames never wait for the screen, which may not show it)
	render.surface_scope(&sh.r, &h.surface)
	render.set_present_wait(&sh.r, false)
	return true
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
		clipboard_set = ui.window_clipboard_set,   // (a paste asks the window's clipboard without waiting: `window`)
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
	if h.win.shown_again != h.shown_again {   // (before the pace: its wait would be on the old swap chain)
		h.shown_again = h.win.shown_again
		render.surface_scope(&sh.r, &h.surface)
		render.surface_remake(&sh.r, platform.native_surface_handles(h.win))
	}
	// (the last picture not shown yet: the compositor does not show the window, covered or minimized. No picture in this
	// frame: its swap chain's image is not even taken (a present in Fifo would wait for ever for that word, and an image
	// taken and not presented would hold the next). Decided once, here: the word may come while the input is read)
	pending := platform.frame_shown_pending(h.win)
	// (a present that cannot wait (a mailbox): a word kept FRAME_SHOWN_PATIENCE_MS is waited for no longer, so a compositor
	// that keeps it for a window it shows does not freeze it)
	free := pending && host_present_free(h)
	if free && platform.frame_shown_waited_ms(h.win) >= FRAME_SHOWN_PATIENCE_MS {
		platform.frame_shown_forget(h.win)
		pending = false
	}
	shown := !pending
	at_once := shown ? host_pace(h, inner) : false
	h.rested = h.slept
	h.slept = false
	if h.before_input != nil { h.before_input(h) }
	events := platform.poll_events(h.win, false)
	// (the user's input: they look at the window, whatever the compositor says. Drawn at once, when that cannot wait)
	if !shown && free && len(events) > 0 {
		platform.frame_shown_forget(h.win)
		shown = true
	}
	// (this frame is the repaint the system asked for: a request left would end every wait, and the loop would never sleep)
	_ = platform.take_paint_request(h.win)
	if platform.is_closed(h.win) { return }
	ui.use(&h.state)   // (a frame of another window may have run in that call)
	host_picture(h, events, at_once, shown)
	if h.after_frame != nil { h.after_frame(h) }
	// (a frame that drew no picture, held for the compositor's word, owes it still: the patience above draws it)
	if !inner && h.settle > 0 && shown { h.settle -= 1 }
	free_all(context.temp_allocator)
}

// How long a window whose presents cannot wait waits for the compositor's word that it showed its last picture, when it
// has another to show. A compositor may keep the word for a window it shows (ShojiWM, counting the window on another
// output, sent it once a second).
FRAME_SHOWN_PATIENCE_MS :: 250

// Whether the window's presents never wait for the compositor (render.present_may_block): it may present before the word.
@(private = "file")
host_present_free :: proc(h: ^Host) -> bool {
	render.surface_scope(&h.shared.r, &h.surface)
	return !render.present_may_block(&h.shared.r)
}

// Takes the window off the screen, its interface kept: the renderer's surface goes first, then the window's (Wayland
// destroys its surface: platform.hide_window). Make no frame of it until host_show. Not from inside its frame.
host_hide :: proc(h: ^Host) {
	if !platform.is_window_visible(h.win) { return }
	render.surface_scope(&h.shared.r, &h.surface)
	render.surface_drop(&h.shared.r)
	platform.hide_window(h.win)
}

// Brings back a window host_hide took off the screen (or shows it the first time): its next frame makes the renderer's
// surface again (host_frame, Window.shown_again).
host_show :: proc(h: ^Host) {
	platform.show_window(h.win)
	h.settle = max(h.settle, h.after_input)
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
// `shown`: the last picture was shown (else this frame reads and builds, and draws nothing).
host_picture :: proc(h: ^Host, read: []platform.Event, at_once, shown: bool) {
	sh := h.shared
	r := &sh.r
	render.surface_scope(r, &h.surface)
	render.mark_input(r)
	events := read
	if len(events) > 0 { h.settle = max(h.settle, h.after_input) }
	if h.still != nil && h.still(h, events) { return }
	if h.input != nil { events = h.input(h, events) }
	size := Vec2{f32(h.win.size.x), f32(h.win.size.y)}
	now := ui.now_ms()
	dt := clamp(f32((now - h.last_ms) / 1000), DT_MIN_S, DT_MAX_S)
	if h.rested {
		hz := render.measured_refresh_hz(r)
		dt = hz > 0 ? f32(1 / hz) : DT_RESTED_S
	}
	h.last_ms = now
	if h.builds != nil { h.builds(h, size, events, dt) } else { host_build(h, size, events, dt) }
	platform.set_cursor(h.win, ui.cursor(&h.state))
	if h.after_build != nil { h.after_build(h) }
	if left := h.hold != nil ? h.hold(h, size) : 0; left > 0 {
		ui.wake_within(&h.state, left)
		return
	}
	// (the input was read and built; the word that the last picture is shown asks for the next, drawn against the last one
	// drawn)
	if !shown {
		platform.frame_shown_held(h.win)   // (the word, when it comes, asks for the picture)
		return
	}
	// (the swap chain at the window's size only for a picture drawn: a resize's sizes that no picture showed (held, or the
	// last one not shown yet) cost a reconfigure each, three for every one presented)
	render.resize(r, h.win.size)
	t_draw := time.tick_now()
	draw.begin_frame(&sh.dc, size)
	// (an overlay shows the windows below wherever the build draws nothing, whatever `background` says)
	render.frame_begin(r, platform.is_overlay(h.win) ? draw.Color{} : h.background)
	ui.set_partial_redraw(&h.state, h.partial_redraw)
	ui.draw_tree(&h.state, &sh.dc)
	draw.end_frame(&sh.dc)
	t_present := time.tick_now()
	presents, _, _ := render.present_totals(r)
	platform.frame_shown_ask(h.win)   // (with the picture's commit)
	render.frame_end(r, h.paced && !at_once)
	// (nothing presented: nothing changed on screen, or no image. The word would come with a later commit, or never)
	if after, _, _ := render.present_totals(r); after == presents { platform.frame_shown_forget(h.win) }
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
		if platform.events_waiting(h.win) { return true, 0 }
		// (its last picture not shown yet: what moves or settles waits for the compositor's word, which wakes the loop; a
		// timer still wakes it: the word may never come, on a hidden workspace or an output with nothing else to draw,
		// and the program's own work (a sample) goes on, its picture held)
		pending := platform.frame_shown_pending(h.win)
		if !pending && (h.settle > 0 || ui.needs_frame(&h.state)) { return true, 0 }
		if w := ui.wake_in_ms(&h.state); w > 0 && (wake_ms == 0 || w < wake_ms) { wake_ms = w }
		// (and when the word is given up, if it does not come: host_frame)
		if pending && (h.settle > 0 || ui.needs_frame(&h.state)) && host_present_free(h) {
			w := max(FRAME_SHOWN_PATIENCE_MS - platform.frame_shown_waited_ms(h.win), 1)
			if wake_ms == 0 || w < wake_ms { wake_ms = w }
		}
	}
	return
}

// Before a round of frames: sleeps until one is due. 0 % CPU at rest. The input of any of them ends it; offscreen windows
// have no shared sleep, and only the first of those wakes this.
hosts_wait :: proc(hosts: []^Host) {
	now, wake := hosts_due(hosts)
	if now { return }
	wins := make([dynamic]^platform.Window, 0, len(hosts), context.temp_allocator)
	for h in hosts { if !platform.is_closed(h.win) { append(&wins, h.win) } }
	if len(wins) == 0 { return }
	// (any of them ends the sleep: on Wayland a wait on one window alone sleeps through the others' input and the
	// compositor's word for them, to the timeout)
	platform.wait_event_any(wins[:], wake)
	for o in hosts { o.slept = true }
}
