package ui

// What a program says of what it just did (copied, saved, deleted): a notification of the system, which stays out of
// the window and goes to the system's own list; a toast of the window only where the system shows none, or where the
// person chose it (prefs_page's general.messages). A failure is always said, even with messages off. It is the one way
// a program says something: a toast is announce's, never the program's.
//
//   app.announcer = {mode = prefs_page.announce_mode(&app.prefs), window = app.anchor, state = &app.ui}
//   ui.announce(&app.announcer, .Good, "Copied to the clipboard")
//   ui.announce(&app.announcer, .Good, "Saved", path)
//   ui.announce(&app.announcer, .Info, "Version 2 is ready", "Click to install it", install, app)
//
// The notification goes out without waiting for the system (platform.notify_async): nothing waits on the interface's
// thread. The next one replaces the last rather than piling up. A toast goes to Announcer.state (nil: the ui state in
// use, ui.use): a command run between two builds, or a task's result, then still says it in the right window.

import "core:fmt"
import "../platform"

// Where a program's messages go: the system's notifications (else the window's toasts), the window's toasts, nowhere.
Announce_Mode :: enum u8 { System, Window, Off }

ANNOUNCE_MODE_NAMES :: [Announce_Mode]string{.System = "system", .Window = "window", .Off = "off"}

// The mode named `name` (ANNOUNCE_MODE_NAMES); System for any other.
announce_mode_of :: proc(name: string) -> Announce_Mode {
	for n, m in ANNOUNCE_MODE_NAMES { if n == name { return m } }
	return .System
}

// Kept by the program: where its messages go, and what the system said of the last one.
Announcer :: struct {
	mode:    Announce_Mode,
	window:  ^platform.Window,            // whose notifications they are: a window that lives as long as the program
	state:   ^State,                      // whose toasts they are (nil: the state in use when it is said)
	last:    platform.Notification_Id,    // the last notification shown: the next one replaces it
	missing: bool,                        // the system has no notifications: toasts from now on
}

// Says `title` (and `body`, a second line: a path, an address). kind .Bad: always said, whatever the mode. `action`:
// what a click on it does (an update to install, a report to open): such a message is a toast of the window, whatever
// the mode (a notification of the system does not call back here), and `user` must still be good when it is clicked.
announce :: proc(a: ^Announcer, kind: Toast_Kind, title: string, body := "", action: proc(user: rawptr) = nil, user: rawptr = nil) {
	mode := a.mode
	if action != nil { mode = .Window }
	if mode == .Off && kind == .Bad { mode = .System }
	switch mode {
	case .Off:
		return
	case .System:
		if !a.missing && a.window != nil {
			n := platform.Notification{title = title, body = body, silent = true, replace = a.last, urgency = kind == .Bad ? .Critical : .Normal}
			if platform.notify_async(a.window, n, announce_done, a) { return }
		}
		fallthrough
	case .Window:
		prev := current
		if a.state != nil { use(a.state) }
		defer if a.state != nil { use(prev) }
		// (a title and its words: the title in bold on its line, the words under it)
		if body != "" { toast_add(kind, action, user, body, title) } else { toast_add(kind, action, user, title) }
	}
}

// The system's answer: the notification's id, which the next one replaces; or none, and toasts from now on (that one
// message is lost from the window: written on the console).
@(private = "file")
announce_done :: proc(user: rawptr, id: platform.Notification_Id, ok: bool) {
	a := (^Announcer)(user)
	if ok { a.last = id; return }
	a.missing = true
	fmt.eprintln("ui: the system shows no notifications: messages go to the window")
}
