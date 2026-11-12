#+build windows
package tk_shortcuts

// Windows: RegisterHotKey on the program's window (platform.hotkey_register), one id per shortcut from 1, from the
// window's thread. A press comes as a Hotkey event of that window: feed turns it into an activation.

import "core:strings"
import "../platform"

@(private = "file")
Windows :: struct {
	list: [dynamic]Shortcut,   // the set bound (ids and descriptions owned)
	held: [dynamic]bool,       // registered now
	hold: bool,
}

@(private)
system_start :: proc(s: ^Service) {
	w := new(Windows, s.allocator)
	w.list.allocator = s.allocator
	w.held.allocator = s.allocator
	s.impl = w
	set_backend(s, s.options.window != nil ? .Windows : .None, false)
}

@(private)
system_stop :: proc(s: ^Service) {
	w := (^Windows)(s.impl)
	release(s, w)
	forget(s, w)
	delete(w.list)
	delete(w.held)
	free(w, s.allocator)
}

@(private)
system_bind :: proc(s: ^Service, list: []Shortcut) {
	w := (^Windows)(s.impl)
	release(s, w)
	forget(s, w)
	for sc in list {
		append(&w.list, Shortcut{id = strings.clone(sc.id, s.allocator), description = strings.clone(sc.description, s.allocator), trigger = sc.trigger})
		append(&w.held, false)
	}
	if !w.hold { register(s, w) }
}

@(private)
system_configure :: proc(s: ^Service) -> bool { return false }

@(private)
system_feed :: proc(s: ^Service, e: platform.Event) -> bool {
	w := (^Windows)(s.impl)
	if e.kind != .Hotkey || e.hotkey < 1 || e.hotkey > len(w.list) { return false }
	push_activated(s, w.list[e.hotkey - 1].id)
	return true
}

@(private)
system_hold :: proc(s: ^Service, held: bool) {
	w := (^Windows)(s.impl)
	if held == w.hold { return }
	w.hold = held
	if held { release(s, w) } else { register(s, w) }
}

@(private = "file")
register :: proc(s: ^Service, w: ^Windows) {
	if s.options.window == nil { set_all(s, .Unavailable); return }
	for sc, i in w.list {
		if sc.trigger.key == .None && sc.trigger.char == 0 { set_status(s, sc.id, .No_Keys, ""); continue }
		if platform.hotkey_register(s.options.window, i + 1, sc.trigger) {
			w.held[i] = true
			set_status(s, sc.id, .Bound, platform.hotkey_text(sc.trigger))
		} else {
			set_status(s, sc.id, .Taken, platform.hotkey_text(sc.trigger))
		}
	}
}

@(private = "file")
release :: proc(s: ^Service, w: ^Windows) {
	for &h, i in w.held {
		if h && s.options.window != nil { platform.hotkey_unregister(s.options.window, i + 1) }
		h = false
	}
}

@(private = "file")
forget :: proc(s: ^Service, w: ^Windows) {
	for sc in w.list { delete(sc.id, s.allocator); delete(sc.description, s.allocator) }
	clear(&w.list)
	clear(&w.held)
}
