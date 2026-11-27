package ui

// ui.mark_editor_dialog: the mark editor in a dialog, in one call, as ui.file_dialog shows the file picker. The editor
// is in a view (MARK_DIALOG_VIEW, one instance per owner window): the views build it while it is open, the program
// calls nothing per frame. Its answer comes once, to the program's procedure: the flattened picture, or nothing.

import "base:runtime"
import "core:fmt"
import "core:strings"
import lucide "../lucide"
import marks "../marks"

// The dialog's least size, in ems.
MARK_DIALOG_MIN_WIDTH_EM :: 36
MARK_DIALOG_MIN_HEIGHT_EM :: 24
// Its largest first size: this share of the owner window (the person may make it larger).
MARK_DIALOG_MOST :: 0.9
// What the bars, the header and the edges take around the canvas, in ems, until a layout measured them.
@(private = "file") MARK_DIALOG_AROUND_EM :: Vec2{1, 9}
// The unseen builds that size the dialog: an estimate, then the bars measured (a size asked shows a build later, and
// the bars wrap by the width).
@(private = "file") MARK_DIALOG_MEASURES :: 4

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
	size_em:  Vec2,     // the program's first size ({}: the picture's)
	measures: int,      // the unseen builds left that size the dialog (0: the size is set, or the person's)
}

// Shows rgba (straight RGBA8, w x h, copied) in the mark editor in a dialog over the window of s. done(rgba, size, ok,
// user) comes once, at a next build of s. A dialog asked while another shows answers that one first, with nothing.
// title: the dialog's ("": "Draw on the picture"). size_em: its first size in ems ({}: the picture at 100 % with the
// bars, at most MARK_DIALOG_MOST of the window); the size the person gave it before wins over both. False: no picture
// (done is not called).
mark_editor_dialog :: proc(s: ^State, rgba: []u8, w, h: int, o: Mark_Editor_Options, done: Mark_Editor_Dialog_Done, user: rawptr = nil, title := "", size_em := Vec2{}) -> bool {
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
		// (its least size until its first build asks for the picture's: view_size)
		view_register(vs, MARK_DIALOG_VIEW, mark_dialog_view, View_Options{
			title = "Draw on the picture", width_em = MARK_DIALOG_MIN_WIDTH_EM, height_em = MARK_DIALOG_MIN_HEIGHT_EM,
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
	// (the size the person gave it, from the views' memory: it is kept as it is)
	dh.size_em = size_em
	dh.measures = r.size == {} ? MARK_DIALOG_MEASURES : 0
	return true
}

// Whether the mark editor's dialog of s is open.
mark_editor_dialog_shown :: proc(s: ^State) -> bool { return s.mark_dialog != nil && s.mark_dialog.open }

// The view's build: the editor; its Done or Cancel answers.
@(private = "file")
mark_dialog_view :: proc(v: ^View, dh: ^Mark_Dialog_Host) {
	if !dh.open { return }
	mark_dialog_fit(v, dh)
	next({width = fill(), height = fill()})
	events := mark_editor("mark_dialog", &dh.editor)
	if .Done in events {
		mark_dialog_answer(dh, true)
	} else if .Cancelled in events || .Failed in events {
		mark_dialog_answer(dh, false)
	}
}

// While the dialog opens unseen: its size, the program's, else the picture at 100 % with what the last layout put
// around the canvas (the bars, the header, the edges), held between its least and MARK_DIALOG_MOST of the window.
@(private = "file")
mark_dialog_fit :: proc(v: ^View, dh: ^Mark_Dialog_Host) {
	if dh.measures <= 0 { return }
	// (shown, moved to a panel or a window, or resized by the person: the size is theirs)
	if v.shown || v.presentation != .Dialog || v.record.size != {} {
		dh.measures = 0
		return
	}
	if dh.size_em != {} {
		view_size(v, dh.size_em.x, dh.size_em.y)
		dh.measures = 0
		return
	}
	dh.measures -= 1
	s := gs()
	em := font_size()
	around := MARK_DIALOG_AROUND_EM * em
	panel, canvas := box_from_key(v.record.panel), box_from_key(dh.editor.canvas_key)
	if panel != nil && canvas != nil && canvas.last_build + 1 >= s.build_index {
		c := canvas.rect.max - canvas.rect.min
		if c.x > 0 && c.y > 0 { around = (panel.rect.max - panel.rect.min) - c }
	}
	// (a fitted picture takes FIT_MARGIN of its canvas: a canvas that much larger shows it at 100 %; a pixel for rounding)
	want := Vec2{f32(dh.editor.size.x), f32(dh.editor.size.y)} / marks.FIT_MARGIN + around + 1
	most := s.window_size * MARK_DIALOG_MOST
	least := Vec2{MARK_DIALOG_MIN_WIDTH_EM, MARK_DIALOG_MIN_HEIGHT_EM} * em
	size := Vec2{max(min(want.x, most.x), least.x), max(min(want.y, most.y), least.y)}
	view_size(v, size.x / em, size.y / em)
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
