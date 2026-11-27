package ui

import "base:runtime"
import "core:strings"
import "../platform"

// A paste asks the clipboard for text, files or an image and gives one answer in a later build (src/md/features/paste.md):
// the system's clipboard belongs to another program, which may be slow or hung, and the build never waits for it
// (platform.clipboard_request).
//
//   ask:    paste_request(key, kinds), in the build where Ctrl+V (or a menu's Paste) is seen;
//   steps:  the kinds asked one after the other, files, then text, then an image, each a Clipboard_Data event of a later
//           build (begin_build takes it); the first that comes is the answer, nothing more is asked;
//   decode: an image's pixels on the chores when the request asked for them;
//   take:   paste_answer(key, kinds), in the build of the widget `key`; when no kind asked came, the answer is .Nothing.
//
// One paste waits at a time: a new request replaces the one waiting, whose answers (and decode) are then dropped. An
// answer nobody takes in its build is dropped at the end of the build.

Paste_Kind :: enum u8 {
	Text,
	Files,     // absolute paths (a file manager's Copy or Cut)
	Image,
	// the answer only: the clipboard held none of the kinds asked (empty, or another kind), so the program can say so.
	// Asking for it changes nothing; taking it is asking for it in paste_answer's kinds (PASTE_KINDS_ALL has it)
	Nothing,
}
Paste_Kinds :: bit_set[Paste_Kind; u8]

PASTE_KINDS_ALL :: Paste_Kinds{.Text, .Files, .Image, .Nothing}

// The order the kinds are asked in, and so which wins: a file manager offers the paths as text too, a spreadsheet's cells
// come as text and as a picture of them.
@(private = "file") PASTE_ORDER :: [?]Paste_Kind{.Files, .Text, .Image}

// An image pasted: as the clipboard held it, and its pixels when the request asked to decode them.
Paste_Image :: struct {
	data: []u8,     // the file, still encoded
	mime: string,   // image/png, image/jpeg, image/bmp, image/x-bmp, or image/x-dib (a Windows bitmap)
	rgba: []u8,     // straight RGBA8, top row first: decoded on the chores (paste_request's `decode`); nil: not asked, or not readable
	size: [2]int,   // of `rgba`
}

// What a paste gives: one kind. Its strings and bytes live until the next paste_request: a program clones what it keeps.
Paste_Answer :: struct {
	kind:  Paste_Kind,
	text:  string,        // .Text
	files: []string,      // .Files
	cut:   bool,          // .Files: they were cut, a paste moves them
	image: Paste_Image,   // .Image
}

@(private)
Paste_Step :: enum u8 {
	Idle,       // nothing waits (or the answer was taken, or dropped)
	Asking,     // the request `id` for PASTE_ORDER[at] waits for its answer
	Decoding,   // the image's pixels are made on the chores
	Held,       // the answer is in: it is the next build's
	Ready,      // the answer is this build's
}

@(private)
Paste :: struct {
	key:    Key,           // the widget that asked; 0: none
	kinds:  Paste_Kinds,
	decode: bool,          // an image is decoded before it is answered
	step:   Paste_Step,
	at:     int,           // .Asking: the index in PASTE_ORDER of the kind asked
	id:     u64,           // .Asking: the window's request (platform.clipboard_request)
	serial: u64,           // counts the requests: a decode of an earlier one is stale when it comes
	answer: Paste_Answer,  // (heap)
}

// Asks the clipboard for one of `kinds` for the widget `key` (its box's key, or another key the widget is built with in
// each build). The answer comes in a later build, through paste_answer: Build_Params.clipboard_get's (the program's own
// clipboard, text only) in the next one, the window's clipboard's when its owner answers. `decode`: an image comes with
// its pixels, decoded on the chores. False: there is no clipboard to ask.
paste_request :: proc(key: Key, kinds := Paste_Kinds{.Text}, decode := false) -> bool {
	s := gs()
	p := &s.paste
	paste_answer_free(&p.answer)
	p.serial += 1
	p.key, p.kinds, p.decode, p.step, p.id = key, kinds, decode, .Idle, 0
	if s.clipboard_get != nil {
		if .Text not_in kinds { return false }
		if text := s.clipboard_get(); text != "" {
			p.answer = {kind = .Text, text = strings.clone(text, runtime.heap_allocator())}
		} else {
			p.answer = {kind = .Nothing}
		}
		p.step = .Held
		return true
	}
	if s.window == nil { return false }
	return paste_ask_from(s, p, 0)
}

// The answer of a paste of the widget `key`, in the build it came, when its kind is one of `kinds` (once: a second call
// says false). Two parties may share a key: a text field takes {.Text}, the program takes what the field left after it.
// Not ok: nothing came for `key` in this build, or of another kind.
paste_answer :: proc(key: Key, kinds := PASTE_KINDS_ALL) -> (a: Paste_Answer, ok: bool) {
	p := &gs().paste
	if p.step != .Ready || p.key != key || p.answer.kind not_in kinds { return }
	p.step = .Idle
	return p.answer, true
}

// Asks the first kind of PASTE_ORDER from `from` on that the paste wants. False: none is left, or no request could go.
@(private = "file")
paste_ask_from :: proc(s: ^State, p: ^Paste, from: int) -> bool {
	order := PASTE_ORDER
	for i in from ..< len(order) {
		if order[i] not_in p.kinds { continue }
		format: platform.Clipboard_Format
		switch order[i] {
		case .Text:  format = .Text
		case .Files: format = .Files
		case .Image: format = .Image
		case .Nothing: continue   // (never in PASTE_ORDER)
		}
		p.id = platform.clipboard_request(s.window, format)
		if p.id == 0 { break }
		p.at, p.step = i, .Asking
		return true
	}
	p.step, p.id = .Idle, 0
	return false
}

// This build's answer, when one came (begin_build, before any widget is built, after the posts: a decode's end). The
// window's other answers (the program's own requests) are left to the program.
@(private)
paste_begin_build :: proc(s: ^State, events: []platform.Event) {
	p := &s.paste
	if p.step == .Held { p.step = .Ready; return }
	if p.step != .Asking { return }
	for e in events {
		if e.kind != .Clipboard_Data || e.clipboard.id != p.id { continue }
		r := e.clipboard
		p.id = 0
		order := PASTE_ORDER
		kind := order[p.at]
		h := runtime.heap_allocator()
		got := false
		switch kind {
		case .Text:
			if got = r.ok && r.text != ""; got { p.answer = {kind = .Text, text = strings.clone(r.text, h)} }
		case .Files:
			if got = r.ok && len(r.files) > 0; got {
				files := make([]string, len(r.files), h)
				for f, i in r.files { files[i] = strings.clone(f, h) }
				p.answer = {kind = .Files, files = files, cut = r.cut}
			}
		case .Image:
			if got = r.ok && len(r.data) > 0; got {
				data := make([]u8, len(r.data), h)
				copy(data, r.data)
				p.answer = {kind = .Image, image = {data = data, mime = strings.clone(r.mime, h)}}
			}
		case .Nothing:
		}
		switch {
		case !got:
			// (the next kind's answer comes in a later build; none left: the clipboard held nothing asked, said now)
			if !paste_ask_from(s, p, p.at + 1) {
				p.answer = {kind = .Nothing}
				p.step = .Ready
			}
		case kind == .Image && p.decode:   paste_decode_start(s, p)
		case:                              p.step = .Ready
		}
		return
	}
}

// An answer nobody took in its build is dropped (end_build). Its memory stays until the next request.
@(private)
paste_end_build :: proc(s: ^State) { if s.paste.step == .Ready { s.paste.step = .Idle } }

@(private)
paste_destroy :: proc(p: ^Paste) {
	paste_answer_free(&p.answer)
	p^ = {}
}

@(private = "file")
paste_answer_free :: proc(a: ^Paste_Answer) {
	h := runtime.heap_allocator()
	delete(a.text, h)
	for f in a.files { delete(f, h) }
	delete(a.files, h)
	delete(a.image.data, h)
	delete(a.image.mime, h)
	delete(a.image.rgba, h)
	a^ = {}
}

////////////////////////////////
// The decode of an image, on the chores: a 4K screenshot is tens of milliseconds.

@(private = "file")
Paste_Decode :: struct {
	s:      ^State,
	serial: u64,                       // the request it is for
	data:   []u8,                      // the file (heap): the job's while it runs, the answer's again at its end
	mime:   string,                    // (heap)
	img:    platform.Clipboard_Image,  // what came of it (heap)
	ok:     bool,
}

// The answer's file goes to the job (a new request frees the answer while the job reads it otherwise).
@(private = "file")
paste_decode_start :: proc(s: ^State, p: ^Paste) {
	job := new(Paste_Decode, runtime.heap_allocator())
	job^ = {s = s, serial = p.serial, data = p.answer.image.data, mime = p.answer.image.mime}
	p.answer.image.data, p.answer.image.mime = nil, ""
	p.step = .Decoding
	task(s, paste_decode_run, paste_decode_done, job, paste_decode_lost)
}

@(private = "file")
paste_decode_run :: proc(data: rawptr) {
	job := (^Paste_Decode)(data)
	job.img, job.ok = platform.clipboard_image_decode(job.mime, job.data, runtime.heap_allocator())
}

// On the interface's thread, at the start of a build (its posts): the pixels go to the answer of the request they were
// decoded for, else they are dropped.
@(private = "file")
paste_decode_done :: proc(data: rawptr, _: u64) {
	job := (^Paste_Decode)(data)
	p := &job.s.paste
	if p.step != .Decoding || p.serial != job.serial { paste_decode_lost(job); return }
	p.answer.image.data, p.answer.image.mime = job.data, job.mime
	if job.ok { p.answer.image.rgba, p.answer.image.size = job.img.rgba, job.img.size }
	p.step = .Held   // (the build that runs these posts makes it Ready: paste_begin_build)
	free(job, runtime.heap_allocator())
}

@(private = "file")
paste_decode_lost :: proc(data: rawptr) {
	job := (^Paste_Decode)(data)
	h := runtime.heap_allocator()
	delete(job.data, h)
	delete(job.mime, h)
	platform.clipboard_image_destroy(&job.img, h)
	free(job, h)
}
