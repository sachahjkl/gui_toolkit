// Package tk_shortcuts: a program's global shortcuts, keys that reach it wherever the keyboard is (a screenshot tool's,
// a launcher's). The program says which actions it has and the keys it would like for each; the system says which keys
// each one got, and when one is pressed.
//
//   s := shortcuts.start({app_id = "cliche", window = anchor, wake = wake_loop, user = app})
//   shortcuts.bind(s, {{id = "region", description = "Capture a region", trigger = hk}})   // the whole set, again at each change
//   each turn of the loop: for id in shortcuts.take(s) { ... }   (Windows: shortcuts.feed(s, e) for each window event)
//   shortcuts.status(s, "region")   // Bound and the keys the system shows, Taken, Refused...
//   shortcuts.stop(s)
//
// Linux: the desktop portal's GlobalShortcuts (KDE, GNOME, Hyprland's portal, ShojiWM's desktop), on a thread of its own
// with its own bus connection: the system may ask the user to confirm, and may give other keys than the ones asked
// (Status.trigger says which). Windows: RegisterHotKey on `window`, from the thread that owns it. Elsewhere: none
// (Unavailable). See docs/shortcuts.md.
package tk_shortcuts

import "base:runtime"
import "core:strings"
import "core:sync"
import "../platform"

// An action that takes a shortcut.
Shortcut :: struct {
	id:          string,            // stable: the system keeps the user's keys under it
	description: string,            // what it does, as the system's list of shortcuts shows it
	trigger:     platform.Hotkey,   // the keys asked; zero: none (the system may still let the user give some)
}

State :: enum u8 {
	Waiting,       // asked, no answer yet
	Bound,         // it works: Status.trigger says with which keys
	No_Keys,       // none were asked, and the system gave none
	Taken,         // another program holds these keys (Windows)
	Refused,       // the user or the system said no
	Unavailable,   // this desktop has no global shortcuts
}

Status :: struct {
	state:   State,
	trigger: string,   // the keys as the system words them ("Ctrl+Shift+4", "Print"); "": none
}

Backend :: enum u8 { None, Portal, Windows }

Options :: struct {
	app_id: string,              // Linux: the name of the program's .desktop file, without ".desktop"
	window: ^platform.Window,    // Windows: the window RegisterHotKey reports to
	// called from any thread when there is something to take (an activation, a status): wake the program's loop
	wake:   proc(user: rawptr),
	user:   rawptr,
}

Service :: struct {
	options:      Options,
	lock:         sync.Mutex,
	activated:    [dynamic]string,       // guarded by lock; owned
	statuses:     map[string]Status,     // guarded by lock; keys and triggers owned
	backend:      Backend,               // guarded by lock
	configurable: bool,                  // guarded by lock: the system has a page of its own for them (configure)
	impl:         rawptr,                // the system's (shortcuts_<system>.odin)
	allocator:    runtime.Allocator,
}

start :: proc(o: Options, allocator := context.allocator) -> ^Service {
	s := new(Service, allocator)
	s.options = o
	s.options.app_id = strings.clone(o.app_id, allocator)
	s.allocator = allocator
	s.activated.allocator = allocator
	s.statuses.allocator = allocator
	system_start(s)
	return s
}

stop :: proc(s: ^Service) {
	if s == nil { return }
	system_stop(s)
	for id in s.activated { delete(id, s.allocator) }
	delete(s.activated)
	for id, st in s.statuses { delete(id, s.allocator); delete(st.trigger, s.allocator) }
	delete(s.statuses)
	delete(s.options.app_id, s.allocator)
	free(s, s.allocator)
}

// The actions and their keys: the whole set, which replaces the one before (call it again after a change of keys).
// Each one is Waiting until the system answers.
bind :: proc(s: ^Service, list: []Shortcut) {
	if s == nil { return }
	{
		sync.guard(&s.lock)
		for id, st in s.statuses { delete(id, s.allocator); delete(st.trigger, s.allocator) }
		clear(&s.statuses)
		for sc in list { s.statuses[strings.clone(sc.id, s.allocator)] = {state = .Waiting} }
	}
	system_bind(s, list)
}

// The ids of the shortcuts pressed since the last take, in order.
take :: proc(s: ^Service, allocator := context.temp_allocator) -> []string {
	if s == nil { return nil }
	sync.guard(&s.lock)
	out := make([]string, len(s.activated), allocator)
	for id, i in s.activated {
		out[i] = strings.clone(id, allocator)
		delete(id, s.allocator)
	}
	clear(&s.activated)
	return out
}

// What the system said of one shortcut (the trigger in `allocator`).
status :: proc(s: ^Service, id: string, allocator := context.temp_allocator) -> Status {
	if s == nil { return {state = .Unavailable} }
	sync.guard(&s.lock)
	st, ok := s.statuses[id]
	if !ok { return {state = .Unavailable} }
	return {state = st.state, trigger = strings.clone(st.trigger, allocator)}
}

backend :: proc(s: ^Service) -> Backend {
	if s == nil { return .None }
	sync.guard(&s.lock)
	return s.backend
}

// Whether the system has a page of its own where the user changes the keys (configure opens it).
can_configure :: proc(s: ^Service) -> bool {
	if s == nil { return false }
	sync.guard(&s.lock)
	return s.configurable
}

// Opens the system's page of this program's shortcuts. False: there is none.
configure :: proc(s: ^Service) -> bool {
	if !can_configure(s) { return false }
	return system_configure(s)
}

// Windows: a window event that is one of the service's shortcuts, taken (true). Elsewhere always false.
feed :: proc(s: ^Service, e: platform.Event) -> bool {
	if s == nil { return false }
	return system_feed(s, e)
}

// While `held`, the shortcuts let their keys go (Windows: a field that records keys would never get the very keys it
// records). Elsewhere nothing: the system takes the keys only when they are pressed outside the program's own window.
hold :: proc(s: ^Service, held: bool) {
	if s == nil { return }
	system_hold(s, held)
}

// The keys of a combination as the portal's preferred_trigger reads them (the XDG shortcuts format: "CTRL+SHIFT+a",
// "LOGO+Print"); "" for none.
portal_trigger :: proc(hk: platform.Hotkey, allocator := context.temp_allocator) -> string {
	key := platform.keysym_of(hk, context.temp_allocator)
	if key == "" { return "" }
	b := strings.builder_make(allocator)
	if .Ctrl in hk.mods  { strings.write_string(&b, "CTRL+") }
	if .Alt in hk.mods   { strings.write_string(&b, "ALT+") }
	if .Shift in hk.mods { strings.write_string(&b, "SHIFT+") }
	if hk.super          { strings.write_string(&b, "LOGO+") }
	strings.write_string(&b, key)
	return strings.to_string(b)
}

////////////////////////////////
// For the systems' files

@(private)
set_backend :: proc(s: ^Service, b: Backend, configurable: bool) {
	{
		sync.guard(&s.lock)
		s.backend, s.configurable = b, configurable
	}
	notify(s)
}

// Sets one shortcut's status; unknown ids are let go (a bind replaced the set since).
@(private)
set_status :: proc(s: ^Service, id: string, state: State, trigger: string) {
	{
		sync.guard(&s.lock)
		st, ok := &s.statuses[id]
		if !ok { return }
		delete(st.trigger, s.allocator)
		st^ = {state = state, trigger = strings.clone(trigger, s.allocator)}
	}
	notify(s)
}

// Every shortcut of the set in `state` (the system said no to all of them, or has none).
@(private)
set_all :: proc(s: ^Service, state: State) {
	{
		sync.guard(&s.lock)
		for _, &st in s.statuses {
			delete(st.trigger, s.allocator)
			st = {state = state}
		}
	}
	notify(s)
}

@(private)
push_activated :: proc(s: ^Service, id: string) {
	{
		sync.guard(&s.lock)
		append(&s.activated, strings.clone(id, s.allocator))
	}
	notify(s)
}

@(private)
notify :: proc(s: ^Service) {
	if s.options.wake != nil { s.options.wake(s.options.user) }
}
