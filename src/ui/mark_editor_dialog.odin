package ui

// ui.mark_editor_dialog: the mark editor in a dialog, in one call, as ui.file_dialog shows the file picker. The editor
// is in a view (MARK_DIALOG_VIEW, one instance per owner window): the views build it while it is open, the program
// calls nothing per frame. Its answer comes once, to the program's procedure: the flattened picture, or nothing.

import "base:runtime"
import "core:fmt"
import "core:strings"
import lucide "../lucide"

// The dialog's size at first and its least, in ems.
MARK_DIALOG_WIDTH_EM :: 72
MARK_DIALOG_HEIGHT_EM :: 46
MARK_DIALOG_MIN_WIDTH_EM :: 36
MARK_DIALOG_MIN_HEIGHT_EM :: 24

MARK_DIALOG_VIEW :: "mark_editor_dialog"

// The dialog's answer, on the interface's thread. ok: Done, and rgba is the flattened picture of size (taken: the
// procedure frees it with delete(rgba, runtime.heap_allocator())); false: cancelled or failed, rgba nil.
Mark_Editor_Dialog_Done :: #type proc(rgba: []u8, size: [2]int, ok: bool, user: rawptr)

// The dialog of a State: its editor, and what its answer goes to.
@(private)
Mark_Dialog_Host :: struct {
	editor:   Mark_Editor,
	open:     bool,
	done:     Mark_Editor_Dialog_Done,
	user:     rawptr,
	views:    ^Views,
	instance: string,   // its view's instance: its owner window's (heap)
	title:    string,   // heap
}

// Shows rgba (straight RGBA8, w x h, copied) in the mark editor in a dialog over the window of s. done(rgba, size, ok,
// user) comes once, at a next build of s. A dialog asked while another shows answers that one first, with nothing.
// title: the dialog's ("": "Draw on the picture"). False: no picture (done is not called).
mark_editor_dialog :: proc(s: ^State, rgba: []u8, w, h: int, o: Mark_Editor_Options, done: Mark_Editor_Dialog_Done, user: rawptr = nil, title := "") -> bool {
	heap := runtime.heap_allocator()
	if s.mark_dialog == nil {
		s.mark_dialog = new(Mark_Dialog_Host, heap)
	}
	dh := s.mark_dialog
	if dh.open { mark_dialog_answer(dh, false) }
	if !mark_editor_init(&dh.editor, rgba, w, h, o) { return false }
	dh.open, dh.done, dh.user = true, done, user
	delete(dh.title, heap)
	dh.title = strings.clone(title != "" ? title : "Draw on the picture", heap)
	vs := state_views(s)
	views_ready(vs)
	if !view_registered(vs, MARK_DIALOG_VIEW) {
		view_register(vs, MARK_DIALOG_VIEW, mark_dialog_view, View_Options{
			title = "Draw on the picture", width_em = MARK_DIALOG_WIDTH_EM, height_em = MARK_DIALOG_HEIGHT_EM,
			min_width_em = MARK_DIALOG_MIN_WIDTH_EM, min_height_em = MARK_DIALOG_MIN_HEIGHT_EM, resizable = true,
		})
		// (the person's close, the close cross or Escape, is Cancel: done is called once)
		vs.kinds[MARK_DIALOG_VIEW].on_end = proc(data: rawptr, code: int) {
			dh := (^Mark_Dialog_Host)(data)
			if dh.open { mark_dialog_answer(dh, false, close = false) }
		}
	}
	if dh.instance == "" { dh.instance = fmt.aprintf("%x", uintptr(s), allocator = heap) }
	dh.views = vs
	r := view_open_raw(vs, MARK_DIALOG_VIEW, dh, typeid_of(Mark_Dialog_Host), dh.instance, s)
	delete(r.title, r.allocator)
	r.title = strings.clone(dh.title, r.allocator)
	r.icon, r.icon_set = lucide.PENCIL, false
	return true
}

// Whether the mark editor's dialog of s is open.
mark_editor_dialog_shown :: proc(s: ^State) -> bool { return s.mark_dialog != nil && s.mark_dialog.open }

// The view's build: the editor; its Done or Cancel answers.
@(private = "file")
mark_dialog_view :: proc(v: ^View, dh: ^Mark_Dialog_Host) {
	if !dh.open { return }
	next({width = fill(), height = fill()})
	events := mark_editor("mark_dialog", &dh.editor)
	if .Done in events {
		mark_dialog_answer(dh, true)
	} else if .Cancelled in events || .Failed in events {
		mark_dialog_answer(dh, false)
	}
}

// The answer: the view closes (close: the program's close; false when the person closed it), the editor goes, then
// done gets the picture, once (it may ask for another dialog).
@(private)
mark_dialog_answer :: proc(dh: ^Mark_Dialog_Host, ok: bool, close := true) {
	if !dh.open { return }
	dh.open = false
	rgba, size, got := mark_editor_result(&dh.editor)
	mark_editor_destroy(&dh.editor)
	if close && dh.views != nil { view_close(dh.views, MARK_DIALOG_VIEW, dh.instance) }
	done, user := dh.done, dh.user
	dh.done, dh.user = nil, nil
	if !(ok && got) {
		delete(rgba, runtime.heap_allocator())
		rgba, size = nil, {}
	}
	if done != nil { done(rgba, size, ok && got, user) } else { delete(rgba, runtime.heap_allocator()) }
}

// ui.destroy: the dialog is given up (its done not called), its editor freed.
@(private)
mark_dialog_destroy :: proc(s: ^State) {
	dh := s.mark_dialog
	if dh == nil { return }
	heap := runtime.heap_allocator()
	if dh.open {
		dh.open = false
		mark_editor_destroy(&dh.editor)
		if dh.views != nil { view_close(dh.views, MARK_DIALOG_VIEW, dh.instance) }
	}
	delete(dh.instance, heap)
	delete(dh.title, heap)
	free(dh, heap)
	s.mark_dialog = nil
}
