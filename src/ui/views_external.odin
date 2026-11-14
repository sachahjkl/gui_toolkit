package ui

// The External presentation (src/md/features/views.md, section 4): a view in a window of the system of its own, with a
// State of its own on the program's Views. `ui` cannot open a window: a backend does (View_Windows; host.view_windows
// for a host.Host program, session.view_windows for a test). Nothing here enters the system in a build: an effect
// marks the record, and views_windows_step, called by the backend between two frames, opens, shows, moves and closes.
//
//   ui.views_set_windows(&app.views, host.view_windows(&app.shared))   once, at start-up, for every owner window
//   (the host calls ui.views_windows_step after each frame of a window, then makes the frames of its views' windows)

import "core:fmt"
import "core:math"
import "core:strings"
import lucide "../lucide"
import "../platform"

// What a backend is asked to open: hidden, at this size, where the system puts it unless `at` says.
View_Window_Ask :: struct {
	title:          string,          // the view's title, as it shows it now (temporary)
	size:           [2]int,          // the client area, logical pixels
	at:             Maybe([2]int),   // its outer top left on the screen, physical pixels (nil: the system's choice)
	owner:          ^platform.Window,
	owner_state:    ^State,          // the window that owns the view: its backend frames the view's window after its frames
	under_children: bool,            // View_Options.under_children: it gets a native child window (a web view)
}

// What opens and closes the views' windows. `open` makes a window, hidden, and a State for it whose builds call
// views_window_build; nil: refused (the view stays where it was, or floats inside its owner, and says why). `show` puts it
// on the screen and activates it; the backend draws its next frame at once. `close` ends it (ui.destroy of its State):
// never from inside that window's frame.
View_Windows :: struct {
	open:         proc(user: rawptr, ask: View_Window_Ask) -> (state: ^State, win: ^platform.Window, handle: rawptr),
	show:         proc(user: rawptr, handle: rawptr),
	hide:         proc(user: rawptr, handle: rawptr),   // off the screen, its State kept (its owner hid: views_windows_follow)
	close:        proc(user: rawptr, handle: rawptr),
	no_positions: bool,   // a test's: as on Wayland, whatever platform.positions_known says
	user:         rawptr,
}

// A drag of an external window's header (where positions are known): the window follows the pointer on the screen.
@(private)
View_Window_Drag :: struct {
	press_screen: [2]int,   // the pointer on the screen when the press began
	press_outer:  [2]int,   // the window's outer top left then
	owner_at:     Vec2,     // the pointer in the owner window's pixels (its dock targets)
	over_owner:   bool,
}

// Where an external window's height comes from when nothing else says (ems).
VIEW_WINDOW_HEIGHT_EM :: f32(24)
// The least size a view's window opens at (logical pixels).
VIEW_WINDOW_MIN :: [2]int{240, 160}

// The backend of the external windows of `vs`. Without one, a view asked to be External floats inside its owner and
// says so (Window_Refused).
views_set_windows :: proc(vs: ^Views, w: View_Windows) { vs.windows = w }

// Whether `vs` can open windows (the header's "Detach into a window", the menu's, the palette's command are active).
views_windows_ready :: proc(vs: ^Views) -> bool { return vs.windows.open != nil }

// The State of the window a view is in now (nil: it is in no window of its own).
view_window_state :: proc(vs: ^Views, id: string, instance := "") -> ^State {
	r := view_record_find(vs, id, instance)
	return r != nil ? r.w_state : nil
}

@(private)
views_positions :: proc(vs: ^Views, w: ^platform.Window) -> bool {
	return !vs.windows.no_positions && w != nil && platform.positions_known(w)
}

////////////////////////////////
// Between two frames

// Between two frames of `s` (never in a build): the system's part of the windows of the views it owns. Opens the
// windows wanted (hidden), shows each one whose layout settled, moves one dragged, closes those no presentation uses.
// The backend calls it after each frame of `s`, then draws the frames of the windows.
views_windows_step :: proc(s: ^State) {
	assert(!building(), "views_windows_step: between two frames, not in a build")
	for vi := 0; vi < len(s.views_attached); vi += 1 {
		vs := s.views_attached[vi]
		vs.building += 1
		for i := 0; i < len(vs.records); i += 1 {
			r := vs.records[i]
			if r.owner == s { view_window_step(vs, r) }
		}
		vs.building -= 1
		views_sweep(vs)
	}
}

@(private = "file")
view_window_step :: proc(vs: ^Views, r: ^View_Record) {
	if r.w_close {
		view_window_close(vs, r, true)
		return
	}
	if r.w_want && r.w_state == nil {
		r.w_want = false
		view_window_open(vs, r)
		return
	}
	st := r.w_state
	if st == nil { return }
	style_follow(st, r.owner)
	if title := view_title_shown(r); title != r.w_title {
		platform.set_title(r.w_win, title)
		delete(r.w_title, vs.allocator)
		r.w_title = strings.clone(title, vs.allocator)
	}
	if at, ok := r.w_move_to.?; ok {
		platform.move_window(r.w_win, at.x, at.y)
		r.w_move_to = nil
	}
	if r.w_shown_build != 0 { return }
	// its unseen layouts, as an internal window's: shown once two agree (or after MODAL_MEASURES_MAX)
	b := st.boxes[r.roots[.External]] or_else nil
	if b == nil || r.roots[.External] == 0 || b.last_build != st.build_index { return }
	sig := modal_layout_signature(b)
	settled := r.w_measures > 0 && sig == r.w_layout
	r.w_layout = sig
	r.w_measures += 1
	if !settled && r.w_measures < MODAL_MEASURES_MAX { return }
	// (its owner is hidden: it shows with it, views_windows_follow)
	if r.owner != nil && r.owner.views_hidden { return }
	vs.windows.show(vs.windows.user, r.w_handle)
	r.w_shown_build = st.build_index
	r.focus_in = true
	// (its owner settles once the window drew a frame after this: views_frame or end_build, view_settle)
	if r.owner != nil { r.owner.anim_busy = true }
}

@(private = "file")
view_window_open :: proc(vs: ^Views, r: ^View_Record) {
	if !views_windows_ready(vs) || r.owner == nil {
		view_apply(vs, r, {kind = .Window_Refused})
		return
	}
	title := view_title_shown(r)
	ask := View_Window_Ask{title = title, size = view_window_size(vs, r), at = r.w_at, owner = r.owner.window, owner_state = r.owner, under_children = r.kind.o.under_children}
	if ask.at == nil && views_positions(vs, r.owner.window) { ask.at = views_memory_of(vs, r.kind.id).at }
	r.w_at = nil
	st, win, handle := vs.windows.open(vs.windows.user, ask)
	if st == nil || win == nil {
		view_apply(vs, r, {kind = .Window_Refused})
		return
	}
	r.w_state, r.w_win, r.w_handle = st, win, handle
	r.w_shown_build, r.w_measures, r.w_layout, r.w_move_to, r.w_hidden = 0, 0, 0, nil, false
	r.roots[.External] = 0
	delete(r.w_title, vs.allocator)
	r.w_title = strings.clone(title, vs.allocator)
	set_views(st, vs)
	views_attach_state(vs, st)
	style_follow(st, r.owner)
	// (the State in use stays the owner's: a view opened outside a build belongs to it)
	use(r.owner)
	if r.owner != nil { r.owner.anim_busy = true }
}

// Its window goes (the backend's close). `remember`: its size and its place are written first.
@(private)
view_window_close :: proc(vs: ^Views, r: ^View_Record, remember: bool) {
	r.w_close, r.w_want = false, false
	st := r.w_state
	if st == nil { return }
	win := r.w_win
	if remember && win != nil && r.w_shown_build != 0 {
		m := views_memory_of(vs, r.kind.id)
		sc := max(win.dpi_scale, 0.01)
		m.window = {i32(math.round(f32(win.size.x) / sc)), i32(math.round(f32(win.size.y) / sc))}
		if views_positions(vs, win) {
			o := platform.outer_rect(win)
			m.at = [2]int{o[0], o[1]}
		}
		views_memory_write(vs, r.kind.id, m)
	}
	active := win != nil && win.active
	handle := r.w_handle
	r.w_state, r.w_win, r.w_handle, r.w_shown_build = nil, nil, nil, 0
	r.roots[.External] = 0
	for x, i in vs.states {
		if x == st { unordered_remove(&vs.states, i); break }
	}
	if vs.windows.close != nil { vs.windows.close(vs.windows.user, handle) }
	// (the window had the user: the owner gets them back)
	if active && r.owner != nil && r.owner.window != nil { platform.raise_window(r.owner.window) }
	// (a step's close: the State in use stays the owner's; a close at an owner's end leaves the State in use alone)
	if remember && r.owner != nil {
		use(r.owner)
		r.owner.anim_busy = true
	}
}

// The size it opens at: the memory's, else the place it shows in now (a dialog, a floating window, a panel), else its
// width_em by VIEW_WINDOW_HEIGHT_EM (or height_em). Logical pixels.
@(private = "file")
view_window_size :: proc(vs: ^Views, r: ^View_Record) -> [2]int {
	m := views_memory_of(vs, r.kind.id)
	if m.window[0] > 0 && m.window[1] > 0 { return {int(m.window[0]), int(m.window[1])} }
	s := r.owner
	sc := max(s.scale, 0.01)
	em := f32(15)
	if len(s.style_stack) > 0 { em = s.style_stack[0].font_size / sc }
	size: [2]f32
	from := view_shown_in(r.machine)
	if b := s.boxes[r.roots[from]] or_else nil; b != nil && r.roots[from] != 0 && from != .External {
		size = (b.rect.max - b.rect.min) / sc
		if from == .Panel { size.y += em * DIALOG_HEADER_EM }   // (a panel has no header: the window's adds one)
	} else {
		o := r.kind.o
		size = {(o.width_em > 0 ? o.width_em : DIALOG_WIDTH_EM) * em, (o.height_em > 0 ? o.height_em : VIEW_WINDOW_HEIGHT_EM) * em}
	}
	return {max(int(math.round(size.x)), VIEW_WINDOW_MIN.x), max(int(math.round(size.y)), VIEW_WINDOW_MIN.y)}
}

// `s`, a window that owns views, hides (`shown` false) or shows again: the windows of its views do the same (section
// 4.1, decision 9). Between two frames; the host's host_hide and host_show call it. A window shown again comes back
// where it was (where the system keeps places), with its State as it was.
views_windows_follow :: proc(s: ^State, shown: bool) {
	if s == nil || s.views_hidden == !shown { return }
	s.views_hidden = !shown
	for vs in s.views_attached {
		for r in vs.records {
			if r.owner != s || r.w_state == nil || r.w_shown_build == 0 { continue }
			if !shown && !r.w_hidden && vs.windows.hide != nil {
				vs.windows.hide(vs.windows.user, r.w_handle)
				r.w_hidden = true
			} else if shown && r.w_hidden {
				vs.windows.show(vs.windows.user, r.w_handle)
				r.w_hidden = false
			}
			// (its own views' windows follow it too)
			views_windows_follow(r.w_state, shown)
		}
	}
	if shown { s.anim_busy = true }
}

// The system asked the window of `s` to close (its title bar, Alt+F4, the compositor): the view goes back to its home,
// it stays open. The backend's close_asked.
view_window_close_asked :: proc(s: ^State) {
	for vs in s.views_attached {
		for r in vs.records {
			if r.w_state != s || r.machine.state == .Closed { continue }
			view_apply(vs, r, {kind = .Reattach})
			if r.owner != nil { r.owner.anim_busy = true }
			return
		}
	}
}

////////////////////////////////
// The window's build

// Inside a build of a view's window (the build procedure the backend gives its State): the view it is for, with its
// header, its body and Escape. The window's own dialogs are built by end_build, as in any window.
views_window_build :: proc() {
	s := gs()
	for vs in s.views_attached {
		for r in vs.records {
			if r.w_state != s || r.machine.state == .Closed { continue }
			vs.building += 1
			view_external_build(vs, r)
			vs.building -= 1
			return
		}
	}
}

@(private = "file")
view_external_build :: proc(vs: ^Views, r: ^View_Record) {
	s := gs()
	k := r.kind
	shown := r.w_shown_build != 0
	r.flag, r.ending, r.tools, r.header = true, nil, 0, 0
	push_tags_isolated("floating")   // (its surface and its header are a floating window's)
	next({width = fill(), height = fill(), axis = .Y})
	frame := build_box({.Draw_Background}, fmt.tprintf("###external_%s", r.modal_name))
	r.panel, r.roots[.External] = frame.key, frame.key
	view_input_arrive(r, shown)
	push_parent(frame)
	v := View{id = k.id, instance = r.instance, presentation = .External, place = r.machine.place, shown = shown, record = r}
	if k.o.backdrop != nil { k.o.backdrop(&v, r.data) }
	view_header_begin(vs, r, .External)
	next({width = fill(), height = fill(), axis = .Y})
	body := build_box({.Clip}, "###view_body")
	push_parent(body)
	k.build(&v, r.data)
	pop_parent()
	view_header_end(vs, r, .External)
	pop_parent()
	pop_tags_isolated()
	if !shown {
		s.anim_busy = true   // (each unseen layout at once: views_windows_step shows it)
	} else {
		if r.flag && r.ending == nil && (key_press(.Escape) || key_press(.W, {.Ctrl})) { r.flag = false }
		if r.focus_in {
			r.focus_in = false
			if !view_focus_inside(s, frame.key) { if first := view_first_stop(frame); first != 0 { s.focus_key = first } }
		}
	}
	view_build_ended(vs, r)
}

// The buttons of an external window's header: Re-attach (not at home), Close view.
@(private)
view_window_header_buttons :: proc(vs: ^Views, r: ^View_Record, at_home: bool) {
	labels := view_labels(vs)
	if !at_home && view_header_icon("view_reattach", lucide.UNDO_2, labels.reattach, true) { view_apply(vs, r, {kind = .Reattach}) }
	if view_header_icon("view_close", lucide.X, labels.close_view, true) { r.flag = false }
}

// A drag of an external window's header, where the system gives positions: the window follows the pointer, and the
// owner shows its dock targets while the pointer is over it; let go over one, the view docks there. Elsewhere (Wayland)
// nothing: the system's title bar moves the window.
@(private)
view_window_header_drag :: proc(vs: ^Views, r: ^View_Record, hb: ^Box, sig: Signal, em: f32) {
	s := gs()
	win := r.w_win
	if win == nil || r.owner == nil || !views_positions(vs, win) { return }
	o := platform.client_origin(win)
	m := mouse_pos()
	screen := [2]int{o.x + int(math.round(m.x)), o.y + int(math.round(m.y))}
	d := &r.w_drag
	if r.machine.state == .Dragged {
		if s.active_key[.Left] != hb.key {
			// released: on a target of the owner, a panel there (this window goes at the next step); else here
			if target, ok := view_target_at(r.owner, d.owner_at); ok && d.over_owner {
				view_target_drop(vs, r, target)
			} else {
				view_apply(vs, r, {kind = .Drop, as = .External})
			}
			r.owner.anim_busy = true
			return
		}
		if key_press(.Escape) {
			r.w_move_to = d.press_outer
			view_apply(vs, r, {kind = .Drag_Cancel})
			r.owner.anim_busy = true
			return
		}
		// (only from a move of the pointer: its position is the window's where it is now; the last one, once the
		// window moved under it, would move it again and again)
		if !s.mouse_moved { return }
		r.w_move_to = d.press_outer + (screen - d.press_screen)
		if r.owner.window != nil {
			oo := platform.client_origin(r.owner.window)
			d.owner_at = {f32(screen.x - oo.x), f32(screen.y - oo.y)}
			ws := r.owner.window_size
			d.over_owner = d.owner_at.x >= 0 && d.owner_at.y >= 0 && d.owner_at.x < ws.x && d.owner_at.y < ws.y
		}
		r.owner.anim_busy = true   // (its targets follow the pointer)
		s.anim_busy = true
		return
	}
	if !sig.dragging || r.machine.state != .Shown { return }
	dd := sig.drag_delta
	if math.sqrt(dd.x * dd.x + dd.y * dd.y) < DOCK_DRAG_EM * em { return }
	outer := platform.outer_rect(win)
	d^ = {press_screen = screen - {int(math.round(dd.x)), int(math.round(dd.y))}, press_outer = {outer[0], outer[1]}}
	view_apply(vs, r, {kind = .Drag_Start})
}

// A drag of an internal window released outside its owner, where the system gives positions: the view opens in a window
// of its own there (Drop_Outside). The window's top left is where the internal window's would be.
@(private)
view_drop_outside :: proc(vs: ^Views, r: ^View_Record) -> bool {
	s := gs()
	if !views_windows_ready(vs) || s.window == nil || !views_positions(vs, s.window) { return false }
	p := mouse_pos()
	ws := s.window_size
	if p.x >= 0 && p.y >= 0 && p.x < ws.x && p.y < ws.y { return false }
	o := platform.client_origin(s.window)
	grab := p - r.irect.min
	r.w_at = [2]int{o.x + int(math.round(p.x - grab.x)), o.y + int(math.round(p.y - grab.y))}
	view_apply(vs, r, {kind = .Drop_Outside})
	return true
}
