// gt-file-picker: one file picker for any program (apps/file-picker/README.md, src/md/features/file-picker.md). It
// serves one request with the toolkit's picker in a window of its own, prints the answer and exits; or, with --portal
// (Linux), it serves the XDG desktop portal's FileChooser backend.
//
//   gt-file-picker open --multiple --filter "Images:*.png;*.jpg"     the paths chosen, one per line
//   gt-file-picker --json < request.json                             the answer as JSON
//   gt-file-picker --portal                                          org.freedesktop.impl.portal.FileChooser
package gt_file_picker

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import req "gt:file_request"
import host "gt:host"
import "gt:platform"
import "gt:process"
import "gt:ui"

// The window's size at first, in pixels at a scale of 1.
WINDOW_SIZE :: [2]int{1000, 640}

main :: proc() { os.exit(run()) }

// The program; its exit code (os.exit runs no defer: what is freed is freed before it).
run :: proc() -> int {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	cmd, why := req.parse_args(process.command_line_args(a), a)
	if why != "" {
		process.console_error(strings.concatenate({"gt-file-picker: ", why, "\n\n", req.USAGE}, a))
		return req.EXIT_ERROR
	}
	switch cmd.mode {
	case .Help:
		process.console_write(req.USAGE)
		return 0
	case .Portal:
		return portal_serve()
	case .Pick:
	}
	request := cmd.request
	if cmd.stdin {
		text, ok := read_stdin(a)
		if !ok { return answer_error(cmd, "the request could not be read on stdin", a) }
		request, why = req.parse_request_json(text, a)
		if why != "" { return answer_error(cmd, why, a) }
	}
	answer, failure := pick(request)
	defer platform.dialog_result_destroy(&answer, runtime.heap_allocator())
	if failure != "" { return answer_error(cmd, failure, a) }
	process.console_write(cmd.json ? req.answer_json(answer, allocator = a) : req.answer_text(answer, a))
	return req.exit_code(answer)
}

// The request's error, said as the caller reads answers (JSON, or a line on stderr); the exit code of an error.
answer_error :: proc(cmd: req.Command, why: string, a: runtime.Allocator) -> int {
	if cmd.json {
		process.console_write(req.answer_json({status = .Failed}, why, a))
	} else {
		process.console_error(strings.concatenate({"gt-file-picker: ", why, "\n"}, a))
	}
	return req.EXIT_ERROR
}

read_stdin :: proc(a: runtime.Allocator) -> (string, bool) {
	data, err := os.read_entire_file(os.stdin, a)
	return string(data), err == nil
}

App :: struct {
	shared: host.Shared,
	main:   host.Host,
	picker: ui.File_Picker,
	answer: platform.Dialog_Result,   // (heap)
	done:   bool,
}

// The picker fills the window; its answer ends the loop.
build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	ui.next({width = ui.fill(), height = ui.fill()})
	ev := ui.file_picker("###picker", &app.picker)
	if ev.answered && !app.done {
		app.answer = platform.dialog_result_clone(ev.result, runtime.heap_allocator())
		app.done = true
	}
}

// Serves `r` in a window of its own: the person's answer, or Cancelled when they close the window. `failure`: no
// window could open (no display, no graphics device).
pick :: proc(r: platform.File_Request) -> (answer: platform.Dialog_Result, failure: string) {
	app := new(App)
	defer free(app)
	title := r.dialog.title
	if title == "" {
		switch r.kind {
		case .Open:   title = r.dialog.multiple ? "Open files" : "Open a file"
		case .Save:   title = "Save as"
		case .Folder: title = "Choose a folder"
		}
	}
	if !host.host_open(&app.main, &app.shared, {title = title, size = WINDOW_SIZE}, build, app) {
		return {status = .Failed}, host.open_error(&app.main)
	}
	defer host.host_close(&app.main)
	app.main.background = ui.theme_lookup(&app.shared.theme, {}, "background")
	ui.file_picker_init(&app.picker, &app.main.state, r.kind, r.dialog)
	ui.file_picker_focus(&app.picker)
	defer ui.file_picker_destroy(&app.picker)
	platform.show_window(app.main.win)
	for !app.done && !platform.is_closed(app.main.win) {
		host.hosts_wait({&app.main})
		host.host_frame(&app.main)
	}
	if !app.done { return {status = .Cancelled}, "" }
	return app.answer, ""
}
