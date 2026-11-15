package scenarios_test

// A paste of text, files or an image (src/md/features/paste.md): one kind wins, files then text then an image; a text
// field takes only text; an image's pixels are decoded on the chores. The clipboard is the process's store (an offscreen
// window's): the machine's is not touched.

import "core:slice"
import "core:strings"
import "core:testing"
import "gt:platform"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") EDITOR_SIZE :: [2]f32{300, 120}
// The key of a view that pastes pictures, not a box: a program may ask with any key it builds with.
@(private = "file") VIEWER :: ui.Key(0x7a57e)
// The frames after an answer in which nothing more may come: more than the steps of a paste (three requests, a decode).
@(private = "file") QUIET_FRAMES :: 6
// Two pixels: an opaque red, a half-transparent blue.
@(private = "file") PIXELS :: [8]u8{255, 0, 0, 255, 0, 0, 255, 128}

// What the program took of a paste, cloned (an answer lives until the next request).
@(private = "file")
Taken :: struct {
	kind:  ui.Paste_Kind,
	files: [dynamic]string,
	cut:   bool,
	mime:  string,
	data:  int,           // the encoded image's size
	rgba:  [dynamic]u8,
	size:  [2]int,
}

@(private = "file")
Paster :: struct {
	rich:     ui.Text_Edit,   // asks for files, text and an image: the program takes the files and the image
	plain:    ui.Text_Edit,   // asks for text only
	ask_view: bool,           // the next build asks for a picture for VIEWER, decoded
	taken:    int,
	last:     Taken,
}

@(private = "file")
paster_build :: proc(s: ^session.Session) {
	p := (^Paster)(s.user)
	ui.next({width = ui.px(EDITOR_SIZE.x), height = ui.px(EDITOR_SIZE.y)})
	res := ui.text_edit("###rich", &p.rich, {paste = ui.PASTE_KINDS_ALL})
	// (after the editor: it took the text, if it was text)
	if a, ok := ui.paste_answer(res.box.key, {.Files, .Image}); ok { paster_keep(p, a) }
	ui.next({width = ui.px(EDITOR_SIZE.x), height = ui.px(EDITOR_SIZE.y)})
	ui.text_edit("###plain", &p.plain)
	if p.ask_view {
		p.ask_view = false
		ui.paste_request(VIEWER, {.Image}, decode = true)
	}
	if a, ok := ui.paste_answer(VIEWER); ok { paster_keep(p, a) }
}

@(private = "file")
paster_keep :: proc(p: ^Paster, a: ui.Paste_Answer) {
	taken_free(&p.last)
	p.taken += 1
	p.last.kind, p.last.cut, p.last.size, p.last.data = a.kind, a.cut, a.image.size, len(a.image.data)
	p.last.mime = strings.clone(a.image.mime)
	for f in a.files { append(&p.last.files, strings.clone(f)) }
	append(&p.last.rgba, ..a.image.rgba)
}

@(private = "file")
taken_free :: proc(k: ^Taken) {
	for f in k.files { delete(f) }
	delete(k.files)
	delete(k.mime)
	delete(k.rgba)
	k^ = {}
}

@(private = "file")
paster_start :: proc(t: ^testing.T, loc := #caller_location) -> (^session.Session, ^Paster) {
	p := new(Paster)   // (a cleanup runs after the test's procedure has returned)
	testing.cleanup(t, proc(d: rawptr) {
		p := (^Paster)(d)
		ui.text_edit_destroy(&p.rich)
		ui.text_edit_destroy(&p.plain)
		taken_free(&p.last)
		free(p)
	}, p)
	return session.start(t, {build = paster_build, user = p, no_renderer = true}, loc), p
}

// Ctrl+V in one frame: the key, and nothing after it (the build that sees it asks the clipboard).
@(private = "file")
ctrl_v :: proc(s: ^session.Session) {
	session.event(s, {kind = .Key_Press, key = .V, mods = {.Ctrl}})
	session.event(s, {kind = .Key_Release, key = .V, mods = {.Ctrl}})
	session.frame(s)
}

@(private = "file")
taken_one :: proc(s: ^session.Session, p: ^Paster) -> bool { return p.taken == 1 }

// A file manager's Cut puts the files and their paths as text: the files win, cut, and the editor gets no text.
@(test)
files_win_over_their_paths_as_text :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, p := paster_start(t)
	paths := []string{"/tmp/a b.txt", "/tmp/c"}
	testing.expect(t, platform.clipboard_set(s.win, {files = paths, files_cut = true, text = "/tmp/a b.txt\n/tmp/c"}), "cut")
	session.click(s, "rich")
	ctrl_v(s)
	testing.expect_value(t, p.taken, 0)   // (nothing in the build of Ctrl+V)
	session.wait_until(s, p, taken_one, "the files")
	testing.expect_value(t, p.last.kind, ui.Paste_Kind.Files)
	testing.expect(t, slice.equal(p.last.files[:], paths), "the paths")
	testing.expect(t, p.last.cut, "cut: a paste moves them")
	session.frames(s, QUIET_FRAMES)
	testing.expect_value(t, p.taken, 1)
	testing.expect_value(t, ui.text_edit_string(&p.rich), "")
}) }

// A spreadsheet's cells come as text and as a picture of them: the text wins, the editor inserts it, the image is not
// given to the program.
@(test)
text_wins_over_an_image :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, p := paster_start(t)
	px := PIXELS
	testing.expect(t, platform.clipboard_set(s.win, {text = "cells", image = platform.Clipboard_Image{rgba = px[:], size = {2, 1}}}), "cells")
	session.click(s, "rich")
	ctrl_v(s)
	session.wait_until(s, p, proc(s: ^session.Session, p: ^Paster) -> bool { return ui.text_edit_string(&p.rich) == "cells" }, "the text")
	session.frames(s, QUIET_FRAMES)
	testing.expect_value(t, p.taken, 0)
}) }

// An image alone, pasted into an editor: the editor gets nothing, the program that asked for images on its key takes it,
// still encoded. An editor that asks for text gets nothing, and nothing else comes.
@(test)
an_image_alone_is_the_program_s_not_the_field_s :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, p := paster_start(t)
	px := PIXELS
	testing.expect(t, platform.clipboard_set(s.win, {image = platform.Clipboard_Image{rgba = px[:], size = {2, 1}}}), "an image")
	session.click(s, "rich")
	ctrl_v(s)
	session.wait_until(s, p, taken_one, "the image")
	testing.expect_value(t, p.last.kind, ui.Paste_Kind.Image)
	testing.expect_value(t, p.last.mime, "image/png")
	testing.expect(t, p.last.data > 0, "its file")
	testing.expect(t, len(p.last.rgba) == 0, "not decoded: not asked")
	testing.expect_value(t, ui.text_edit_string(&p.rich), "")
	session.click(s, "plain")
	ctrl_v(s)
	session.frames(s, QUIET_FRAMES)
	testing.expect_value(t, ui.text_edit_string(&p.plain), "")
	testing.expect_value(t, p.taken, 1)
}) }

// A picture asked with its pixels: decoded on the chores, it comes in a later build with its file. A request made again
// while the first decodes drops the first: one answer.
@(test)
an_image_is_decoded_on_the_chores :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, p := paster_start(t)
	px := PIXELS
	testing.expect(t, platform.clipboard_set(s.win, {image = platform.Clipboard_Image{rgba = px[:], size = {2, 1}}}), "an image")
	p.ask_view = true
	session.frame(s)
	session.frame(s)   // (the image came: its decode runs)
	p.ask_view = true   // (asked again: the first decode is stale)
	session.wait_until(s, p, taken_one, "the pixels")
	testing.expect_value(t, p.last.kind, ui.Paste_Kind.Image)
	testing.expect_value(t, p.last.size, [2]int{2, 1})
	testing.expect(t, slice.equal(p.last.rgba[:], px[:]), "its pixels")
	testing.expect(t, p.last.data > 0, "and its file")
	session.frames(s, QUIET_FRAMES)
	testing.expect_value(t, p.taken, 1)
}) }
