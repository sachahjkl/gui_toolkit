package ui

import "../platform"

// A paste asks the clipboard for its text and inserts it in a later build: the system's clipboard belongs to another
// program, which may be slow or hung, and the build never waits for it (platform.clipboard_request).
//
//   ask:    paste_request(key), in the build where Ctrl+V (or a menu's Paste) is seen;
//   answer: the request's Clipboard_Data event, among the events of a later build (begin_build takes it);
//   insert: paste_answer(key), in the build of the widget `key`, which inserts it while it has the focus.
//
// One paste waits at a time: a new request replaces the one waiting, whose answer is then dropped. An answer the widget
// does not take in its build (it is gone, or lost the focus) is dropped at the end of the build.
@(private)
Paste :: struct {
	key:   Key,           // the widget that asked; 0: none
	id:    u64,           // the window's request waiting (platform.clipboard_request); 0: none
	held:  bool,          // Build_Params.clipboard_get answered at the request: `text` waits for the next build
	ready: bool,          // `text` is this build's answer, for the widget `key` (paste_answer)
	text:  [dynamic]u8,
}

// Asks the clipboard's text for the widget `key` (its box's key, or another key the widget is built with in each build).
// The answer comes in a later build, through paste_answer: Build_Params.clipboard_get's (the program's own clipboard) in
// the next one, the window's clipboard's when its owner answers. False: there is no clipboard to ask.
paste_request :: proc(key: Key) -> bool {
	s := gs()
	p := &s.paste
	p.key, p.id, p.held, p.ready = key, 0, false, false
	if s.clipboard_get != nil {
		clear(&p.text)
		append(&p.text, s.clipboard_get())
		p.held = true
		return true
	}
	if s.window == nil { return false }
	p.id = platform.clipboard_request(s.window, .Text)
	return p.id != 0
}

// The text a paste of the widget `key` asked for, in the build its answer came (once: a second call says false). It lives
// until the next paste_request; the widget inserts it at once. Not ok: nothing came for `key` in this build, or the
// clipboard held no text.
paste_answer :: proc(key: Key) -> (text: string, ok: bool) {
	p := &gs().paste
	if !p.ready || p.key != key { return "", false }
	p.ready = false
	return string(p.text[:]), true
}

// The answer of this build, when one came (begin_build, before any widget is built). The window's other answers (the
// requests of the program) are left to the program: they are not this state's.
@(private)
paste_begin_build :: proc(s: ^State, events: []platform.Event) {
	p := &s.paste
	p.ready = false
	if p.held {
		p.held = false
		p.ready = len(p.text) > 0
		return
	}
	if p.id == 0 { return }
	for e in events {
		if e.kind != .Clipboard_Data || e.clipboard.id != p.id { continue }
		p.id = 0
		clear(&p.text)
		append(&p.text, e.clipboard.text)
		p.ready = e.clipboard.ok && len(p.text) > 0
	}
}

// An answer no widget took in its build is dropped (end_build).
@(private)
paste_end_build :: proc(s: ^State) { s.paste.ready = false }
