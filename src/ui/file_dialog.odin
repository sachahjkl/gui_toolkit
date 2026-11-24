package ui

// ui.file_dialog: a file dialog in one call. The toolkit's picker (file_picker.odin) in a view, "file_dialog" (one
// instance per owner window): the views build it while it is open, a program calls nothing per frame; or, when the person
// prefers it, the system's dialog on the chores. Its picker is the State's (File_Pickers.dialog), kept from one dialog
// to the next: its thumbnails serve the next one.

import "base:runtime"
import "core:fmt"
import "core:strings"
import lucide "../lucide"
import "../platform"

// The dialog's size at first and its least, in ems.
FILE_DIALOG_WIDTH_EM :: 76
FILE_DIALOG_HEIGHT_EM :: 42
FILE_DIALOG_MIN_WIDTH_EM :: 32
FILE_DIALOG_MIN_HEIGHT_EM :: 20

// The id of the dialog's view; its instance is its owner window's (one dialog per State).
FILE_DIALOG_VIEW :: "file_dialog"

// What comes back of a file dialog, on the interface's thread: the result (its paths are freed after the call: copy
// what is kept) and the `user` given.
File_Dialog_Done :: #type proc(r: platform.Dialog_Result, user: rawptr)

// Which file dialogs ui.file_dialog shows: the toolkit's own picker (the same in every program and every theme, the
// program's sources too), or the system's (a preference of the person: general.file_dialog).
File_Dialogs :: enum u8 { Toolkit, System }

set_file_dialogs :: proc(s: ^State, d: File_Dialogs) { s.file_dialogs = d }
file_dialogs :: proc(s: ^State) -> File_Dialogs { return s.file_dialogs }

// The dialog of a State: its picker, and what its answer goes to.
@(private)
File_Dialog_Host :: struct {
	picker:   File_Picker,   // set up at the first dialog (picker.state), kept
	open:     bool,
	done:     File_Dialog_Done,
	user:     rawptr,
	views:    ^Views,        // where its view is: its owner window's
	instance: string,        // its view's instance: its owner window's (heap)
}

// Shows a file dialog with no wait here; `done(result, user)` comes at a next build of `s`, on its thread. The strings
// of `d` are copied. It is the toolkit's picker (docs/file-browser.md), built by the toolkit at each build until it
// answers, reading `source` (nil: the computer's files, local_files). With set_file_dialogs(.System) and no source, it
// is the system's: the system's dialogs are modal loops (Windows) or another process (zenity, kdialog, the portal) that
// this thread would wait for, the window frozen meanwhile, so it runs on the chores. A dialog asked while the picker
// shows another one cancels that one. With platform.dialog_test_hook set (a program's end-to-end test), the hook
// answers for the computer's files, whichever dialog is chosen.
file_dialog :: proc(s: ^State, kind: platform.File_Dialog_Kind, d: platform.File_Dialog, done: File_Dialog_Done, user: rawptr = nil, source: ^File_Source = nil) {
	if source != nil || (s.file_dialogs == .Toolkit && platform.dialog_test_hook == nil) {
		file_dialog_open(s, kind, d, done, user, source)
		return
	}
	a := runtime.heap_allocator()
	j := new(File_Dialog_Job, a)
	j^ = {kind = kind, d = platform.file_dialog_clone(d, a), done = done, user = user}
	work :: proc(data: rawptr) {
		j := (^File_Dialog_Job)(data)
		switch j.kind {
		case .Open:   j.result = platform.open_file_dialog(j.d, runtime.heap_allocator())
		case .Save:   j.result = platform.save_file_dialog(j.d, runtime.heap_allocator())
		case .Folder: j.result = platform.pick_folder_dialog(j.d, runtime.heap_allocator())
		}
	}
	back :: proc(data: rawptr, word: u64) {
		j := (^File_Dialog_Job)(data)
		if j.done != nil { j.done(j.result, j.user) }
		file_dialog_job_free(data)
	}
	task(s, work, back, j, file_dialog_job_free)
}

// The system's dialog, on the chores.
@(private = "file")
File_Dialog_Job :: struct {
	kind:   platform.File_Dialog_Kind,
	d:      platform.File_Dialog,
	result: platform.Dialog_Result,
	done:   File_Dialog_Done,
	user:   rawptr,
}

@(private = "file")
file_dialog_job_free :: proc(data: rawptr) {
	a := runtime.heap_allocator()
	j := (^File_Dialog_Job)(data)
	platform.dialog_result_destroy(&j.result, a)
	platform.file_dialog_free(&j.d, a)
	free(j, a)
}

// Whether the toolkit's file dialog is open (ui.file_dialog shows it until it answers): a program that counts what is
// over its window, or waits for its keys.
file_dialog_shown :: proc(s: ^State) -> bool { return s.files != nil && s.files.dialog.open }

// The picker of the toolkit's file dialog of `s` (nil before the first): a test reads it (file_picker_counts).
file_dialog_picker :: proc(s: ^State) -> ^File_Picker {
	if s.files == nil || s.files.dialog.picker.state == nil { return nil }
	return &s.files.dialog.picker
}

@(private = "file")
file_dialog_open :: proc(s: ^State, kind: platform.File_Dialog_Kind, d: platform.File_Dialog, done: File_Dialog_Done, user: rawptr, source: ^File_Source) {
	dh := &file_pickers_of(s).dialog
	fp := &dh.picker
	if fp.state == nil {
		file_picker_setup(fp, s)
		fp.dialog = true
	}
	// (one dialog at a time: the one shown gives way, its `done` called)
	if dh.open { file_picker_answer(fp, .Cancelled) }
	dh.open = true
	dh.done, dh.user = done, user
	file_picker_start(fp, kind, d, source)
	file_picker_focus(fp)
	file_dialog_view_open(dh, s)
}

// The picker answered (file_picker_answer): the dialog closes, then `done` gets the answer, once (`done` may ask for
// another dialog).
@(private)
file_dialog_answered :: proc(fp: ^File_Picker) {
	dh := &fp.state.files.dialog
	if !dh.open || fp != &dh.picker { return }
	a := runtime.heap_allocator()
	r := fp.answer
	fp.answer, fp.answered = {}, false
	done, user := dh.done, dh.user
	file_dialog_close(dh)
	if done != nil { done(r, user) }
	platform.dialog_result_destroy(&r, a)
}

// Closes the dialog with no answer: its picker stops, its view goes (the program's close of it: no on_end).
@(private = "file")
file_dialog_close :: proc(dh: ^File_Dialog_Host) {
	if !dh.open { return }
	dh.open = false
	file_picker_stop(&dh.picker)
	if dh.views != nil { view_close(dh.views, FILE_DIALOG_VIEW, dh.instance) }
}

// ui.destroy: the dialog goes before the views end (no answer), then its picker.
@(private)
file_dialog_destroy :: proc(h: ^File_Pickers) {
	dh := &h.dialog
	file_dialog_close(dh)
	if dh.picker.state != nil { file_picker_destroy(&dh.picker) }
	delete(dh.instance, runtime.heap_allocator())
	dh^ = {}
}

// The dialog's view in the Views of `s`, registered the first time, opened (or brought forward) with the request's
// title and icon, and the size its remember_id keeps.
@(private = "file")
file_dialog_view_open :: proc(dh: ^File_Dialog_Host, s: ^State) {
	vs := state_views(s)
	views_ready(vs)
	if !view_registered(vs, FILE_DIALOG_VIEW) {
		view_register(vs, FILE_DIALOG_VIEW, file_dialog_view, View_Options{
			title = "Open", width_em = FILE_DIALOG_WIDTH_EM, height_em = FILE_DIALOG_HEIGHT_EM,
			min_width_em = FILE_DIALOG_MIN_WIDTH_EM, min_height_em = FILE_DIALOG_MIN_HEIGHT_EM, resizable = true,
			quick = true,   // (summoned by a key, Ctrl+P, every time: views.md 3.4)
		})
		// (the person's close, the close cross or a press outside, is the picker's Cancel: `done` is called once)
		vs.kinds[FILE_DIALOG_VIEW].on_end = proc(data: rawptr, code: int) {
			dh := (^File_Dialog_Host)(data)
			if dh.open { file_picker_answer(&dh.picker, .Cancelled) }
		}
	}
	a := runtime.heap_allocator()
	if dh.instance == "" { dh.instance = fmt.aprintf("%x", uintptr(s), allocator = a) }
	dh.views = vs
	fp := &dh.picker
	r := view_open_raw(vs, FILE_DIALOG_VIEW, dh, typeid_of(File_Dialog_Host), dh.instance, s)
	title, _ := file_picker_words(fp.kind)
	if fp.d.title != "" { title = fp.d.title }
	delete(r.title, r.allocator)
	r.title = strings.clone(title, r.allocator)
	r.icon, r.icon_set = fp.kind == .Save ? lucide.SAVE : (fp.kind == .Folder ? lucide.FOLDER_OPEN : lucide.FOLDER), false
	if fp.size != {} { r.size = fp.size }   // (what this remember_id was left at)
}

// Whether the dialog of `s` holds its window's keys before the program's code (overlay_capture_keys): open as a dialog
// of that window. A floating window, a panel, a window of its own take keys as views do.
@(private)
file_dialog_holds_keys :: proc(s: ^State) -> bool {
	if s.files == nil { return false }
	dh := &s.files.dialog
	if !dh.open || dh.views == nil { return false }
	r := view_record_find(dh.views, FILE_DIALOG_VIEW, dh.instance)
	return r != nil && r.owner == s && r.machine.state != .Closed && view_shown_in(r.machine) == .Dialog
}

// The view's build: the keys held for it (as a dialog), then its picker. Its answer reaches file_dialog_answered.
@(private = "file")
file_dialog_view :: proc(v: ^View, dh: ^File_Dialog_Host) {
	// (the keys held from the program since begin_build: the dialog's own)
	overlay_release_keys(gs(), .File_Dialog)
	if !dh.open { return }
	fp := &dh.picker
	// (its size as the person leaves it, remembered with its remember_id when it answers)
	if r := view_record_find(dh.views, FILE_DIALOG_VIEW, dh.instance); r != nil && r.size != {} { fp.size = r.size }
	next({width = fill(), height = fill()})
	_ = file_picker("###fb_body", fp)
}
