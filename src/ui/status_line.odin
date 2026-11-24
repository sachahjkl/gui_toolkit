package ui

// A short message in a program's status bar that goes away by itself: "Copied", "Saved", "3 files removed". papier,
// inspecteur, feuille and classeur each kept the same text, end time and wake. The program keeps its bar's layout and its
// words; the line keeps the text and its time. The intent: src/md/features/status-line.md.
//
//	ui.status_say(&app.status, "Saved %s", name)                  // 3 s (STATUS_SHOWN_MS)
//	ui.status_say(&app.status, "Copied", shown_ms = 5000)
//	if msg := ui.status_text(&app.status); msg != "" { ui.label(msg) } else { ... the bar's usual words }
//	ui.status_destroy(&app.status)                                 // at the end

import "core:fmt"

// How long a message shows by default, in ms.
STATUS_SHOWN_MS :: 3000

// One status message: the program's, on the interface's thread.
Status_Line :: struct {
	text:  string,   // owned ("": none)
	until: f64,      // the interface's clock (now_ms) when it goes
}

// Shows a message for `shown_ms`, in place of the one shown. In a build, the window wakes when it goes. Outside a build
// (a worker's answer read in the loop), the program makes a frame for it as for any change (host_settle): that frame's
// status_text asks the wake.
status_say :: proc(s: ^Status_Line, format: string, args: ..any, shown_ms := STATUS_SHOWN_MS) {
	delete(s.text)
	s.text = fmt.aprintf(format, ..args)
	s.until = now_ms() + f64(shown_ms)
	if st := current_state(); st != nil { wake_within(st, shown_ms + 1) }
}

// The message while it shows, "" once its time is past. In a build, the window wakes when it goes.
status_text :: proc(s: ^Status_Line) -> string {
	if s.text == "" { return "" }
	left := s.until - now_ms()
	if left <= 0 { return "" }
	if st := current_state(); st != nil { wake_within(st, int(left) + 1) }
	return s.text
}

// The message goes now.
status_clear :: proc(s: ^Status_Line) {
	delete(s.text)
	s^ = {}
}

// At the end: frees the message.
status_destroy :: proc(s: ^Status_Line) { status_clear(s) }
