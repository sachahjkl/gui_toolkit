// gt:file_request: a picker's request and answer as text. A command line, JSON both ways, and the XDG portal's
// FileChooser calls marshalled as a portal frontend sends them, read back; the reply written and read as a caller reads
// it. What breaks first: a filter with no name, a value after "=", a MIME filter, a GTK mnemonic, SaveFiles' names in
// the folder chosen, a path with a space in its URI.
package file_request_test

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "gt:dbus"
import req "gt:file_request"
import "gt:platform"

@(private = "file")
arena_of :: proc(a: ^virtual.Arena) -> runtime.Allocator { return virtual.arena_allocator(a) }

@(test)
a_command_line_reads :: proc(t: ^testing.T) {
	a: virtual.Arena
	defer virtual.arena_destroy(&a)
	args := []string{"open", "--multiple", "--title", "Pick images", "--folder=/home/me", "--filter", "Images:*.png; *.jpg", "--filter", "*.gif", "--all-files", "--json"}
	c, why := req.parse_args(args, arena_of(&a))
	testing.expect_value(t, why, "")
	testing.expect_value(t, c.mode, req.Mode.Pick)
	testing.expect_value(t, c.request.kind, platform.File_Dialog_Kind.Open)
	testing.expect(t, c.request.dialog.multiple)
	testing.expect(t, c.json && !c.stdin)
	testing.expect_value(t, c.request.dialog.title, "Pick images")
	testing.expect_value(t, c.request.dialog.start_dir, "/home/me")
	testing.expect(t, c.request.dialog.all_files)
	if testing.expect_value(t, len(c.request.dialog.filters), 2) {
		testing.expect_value(t, c.request.dialog.filters[0].name, "Images")
		testing.expect_value(t, len(c.request.dialog.filters[0].patterns), 2)
		testing.expect_value(t, c.request.dialog.filters[0].patterns[1], "*.jpg")
		testing.expect_value(t, c.request.dialog.filters[1].name, "")
		testing.expect_value(t, c.request.dialog.filters[1].patterns[0], "*.gif")
	}
}

// --theme takes a name and, after a colon, light, dark or system; parse_theme splits it.
@(test)
a_theme_reads :: proc(t: ^testing.T) {
	name, mode, ok := req.parse_theme("Ember")
	testing.expect(t, ok && name == "Ember" && mode == "")
	name, mode, ok = req.parse_theme("Nord:Dark")
	testing.expect(t, ok && name == "Nord" && mode == "Dark")
	_, _, ok = req.parse_theme("Nord:dim")
	testing.expect(t, !ok, "a mode that is none of the three")
	_, _, ok = req.parse_theme(":dark")
	testing.expect(t, !ok, "no name")
	a: virtual.Arena
	defer virtual.arena_destroy(&a)
	c, why := req.parse_args({"open", "--theme", "Ember:light"}, virtual.arena_allocator(&a))
	testing.expect(t, why == "" && c.theme == "Ember:light", why)
	_, why = req.parse_args({"open", "--theme=Ember:dim"}, virtual.arena_allocator(&a))
	testing.expect(t, why != "", "a theme that does not read is said")
}

@(test)
a_command_line_that_does_not_read :: proc(t: ^testing.T) {
	a: virtual.Arena
	defer virtual.arena_destroy(&a)
	cases := [?][]string{
		{},                              // no kind, no --json
		{"open", "save"},                // two kinds
		{"save", "--multiple"},          // several files to save
		{"open", "--title"},             // a value missing
		{"open", "--filter", ":"},       // a filter of no pattern
		{"open", "--colour", "red"},     // an unknown option
	}
	for args in cases {
		_, why := req.parse_args(args, arena_of(&a))
		testing.expectf(t, why != "", "%v must not read", args)
	}
	c, why := req.parse_args({"--json"}, arena_of(&a))
	testing.expect_value(t, why, "")
	testing.expect(t, c.stdin, "--json alone: the request on stdin")
	c, why = req.parse_args({"--portal"}, arena_of(&a))
	testing.expect_value(t, c.mode, req.Mode.Portal)
	c, why = req.parse_args({"save", "--name", "report.txt"}, arena_of(&a))
	testing.expect_value(t, c.request.dialog.suggested_name, "report.txt")
	testing.expect(t, c.request.dialog.overwrite_prompt, "save asks before it replaces")
}

@(test)
a_request_goes_through_json :: proc(t: ^testing.T) {
	a: virtual.Arena
	defer virtual.arena_destroy(&a)
	context.allocator = arena_of(&a)
	options := []platform.File_Choice_Option{{id = "utf8", label = "UTF-8"}, {id = "latin1", label = "Latin-1"}}
	choices := []platform.File_Choice{{id = "enc", label = "Encoding", options = options, initial = "latin1"}, {id = "ro", label = "Read only", initial = "true"}}
	patterns := []string{"*.txt", "*.md"}
	filters := []platform.File_Filter{{name = "Text \"files\"", patterns = patterns}}
	r := platform.File_Request{kind = .Save, dialog = {title = "Save the notes", start_dir = "/tmp/a b", suggested_name = "notes.md",
		filters = filters, filter_index = 0, choices = choices, overwrite_prompt = true, remember_id = "notes"}}
	text := req.request_json(r)
	back, why := req.parse_request_json(text)
	testing.expect_value(t, why, "")
	testing.expect_value(t, back.kind, platform.File_Dialog_Kind.Save)
	testing.expect_value(t, back.dialog.title, "Save the notes")
	testing.expect_value(t, back.dialog.start_dir, "/tmp/a b")
	testing.expect_value(t, back.dialog.suggested_name, "notes.md")
	testing.expect_value(t, back.dialog.remember_id, "notes")
	testing.expect(t, back.dialog.overwrite_prompt)
	if testing.expect_value(t, len(back.dialog.filters), 1) {
		testing.expect_value(t, back.dialog.filters[0].name, "Text \"files\"")
		testing.expect_value(t, back.dialog.filters[0].patterns[1], "*.md")
	}
	if testing.expect_value(t, len(back.dialog.choices), 2) {
		testing.expect_value(t, back.dialog.choices[0].initial, "latin1")
		testing.expect_value(t, back.dialog.choices[0].options[1].label, "Latin-1")
		testing.expect_value(t, len(back.dialog.choices[1].options), 0)
	}
	_, why = req.parse_request_json(`{"kind": "delete"}`)
	testing.expect(t, why != "", "a kind of no picker")
	_, why = req.parse_request_json("not json")
	testing.expect(t, why != "")
}

@(test)
an_answer_as_text_json_and_exit_code :: proc(t: ^testing.T) {
	a: virtual.Arena
	defer virtual.arena_destroy(&a)
	context.allocator = arena_of(&a)
	chosen := platform.Dialog_Result{status = .Chosen, paths = {"/a/one.png", "/a/two words.png"}, filter = 1, choices = {{id = "enc", value = "utf8"}}}
	testing.expect_value(t, req.answer_text(chosen), "/a/one.png\n/a/two words.png\n")
	testing.expect_value(t, req.exit_code(chosen), req.EXIT_CHOSEN)
	back := req.parse_answer_json(req.answer_json(chosen))
	testing.expect_value(t, back.status, platform.Dialog_Status.Chosen)
	testing.expect_value(t, len(back.paths), 2)
	testing.expect_value(t, back.paths[1], "/a/two words.png")
	testing.expect_value(t, back.filter, 1)
	testing.expect_value(t, back.choices[0].value, "utf8")
	cancelled := platform.Dialog_Result{status = .Cancelled}
	testing.expect_value(t, req.answer_text(cancelled), "")
	testing.expect_value(t, req.exit_code(cancelled), req.EXIT_CANCELLED)
	failed := platform.Dialog_Result{status = .Failed}
	testing.expect_value(t, req.exit_code(failed), req.EXIT_ERROR)
	testing.expect(t, strings.contains(req.answer_json(failed, "no window"), `"error":"no window"`))
	testing.expect_value(t, req.parse_answer_json("garbage").status, platform.Dialog_Status.Failed)
}

////////////////////////////////
// The portal

// The body of a call as a portal frontend writes it: handle, app id, parent, title, then the options.
@(private = "file")
call_body :: proc(title: string, options: proc(w: ^dbus.Writer)) -> []u8 {
	w := dbus.body_writer()
	dbus.w_string(&w, "/org/freedesktop/portal/desktop/request/1_42/t")
	dbus.w_string(&w, "org.example.App")
	dbus.w_string(&w, "x11:3a00004")
	dbus.w_string(&w, title)
	l, c := dbus.arg_dict_begin(&w)
	options(&w)
	dbus.arg_dict_end(&w, l, c)
	return w.buf[:]
}

@(private = "file")
path_bytes :: proc(w: ^dbus.Writer, path: string) {
	l, c := dbus.w_array_begin(w, 1)
	for i in 0 ..< len(path) { dbus.w_u8(w, path[i]) }
	dbus.w_u8(w, 0)
	dbus.w_array_end(w, l, c)
}

// A filter (sa(us)) with a glob and a MIME type.
@(private = "file")
filter :: proc(w: ^dbus.Writer, name: string, glob, mime: string) {
	dbus.w_struct(w)
	dbus.w_string(w, name)
	l, c := dbus.w_array_begin(w, 8)
	if glob != "" { dbus.w_struct(w); dbus.w_u32(w, 0); dbus.w_string(w, glob) }
	if mime != "" { dbus.w_struct(w); dbus.w_u32(w, 1); dbus.w_string(w, mime) }
	dbus.w_array_end(w, l, c)
}

@(test)
an_open_file_call_reads :: proc(t: ^testing.T) {
	a: virtual.Arena
	defer virtual.arena_destroy(&a)
	context.allocator = arena_of(&a)
	body := call_body("Open a picture", proc(w: ^dbus.Writer) {
		dbus.arg_dict_entry(w, "accept_label"); dbus.arg_variant_string(w, "_Open")
		dbus.arg_dict_entry(w, "multiple"); dbus.arg_variant_bool(w, true)
		dbus.arg_dict_entry(w, "filters"); dbus.w_signature(w, "a(sa(us))")
		l, c := dbus.w_array_begin(w, 8)
		filter(w, "Text", "*.txt", "")
		filter(w, "Pictures", "", "image/png")
		dbus.w_array_end(w, l, c)
		dbus.arg_dict_entry(w, "current_filter"); dbus.w_signature(w, "(sa(us))")
		filter(w, "Pictures", "", "image/png")
		dbus.arg_dict_entry(w, "current_folder"); dbus.w_signature(w, "ay"); path_bytes(w, "/home/me/Pictures")
		dbus.arg_dict_entry(w, "unknown"); dbus.arg_variant_i32(w, 7)   // (skipped)
		dbus.arg_dict_entry(w, "choices"); dbus.w_signature(w, "a(ssa(ss)s)")
		cl, cc := dbus.w_array_begin(w, 8)
		dbus.w_struct(w); dbus.w_string(w, "ro"); dbus.w_string(w, "Read only")
		ol, oc := dbus.w_array_begin(w, 8); dbus.w_array_end(w, ol, oc)
		dbus.w_string(w, "true")
		dbus.w_array_end(w, cl, cc)
	})
	r := dbus.reader_make(body)
	call, ok := req.portal_read_call("OpenFile", &r)
	testing.expect(t, ok)
	testing.expect_value(t, call.method, req.Portal_Method.Open_File)
	testing.expect_value(t, call.parent, "x11:3a00004")
	d := call.request.dialog
	testing.expect_value(t, call.request.kind, platform.File_Dialog_Kind.Open)
	testing.expect_value(t, d.title, "Open a picture")
	testing.expect_value(t, d.act, "Open")
	testing.expect(t, d.multiple)
	testing.expect_value(t, d.start_dir, "/home/me/Pictures")
	testing.expect_value(t, d.filter_index, 1)
	if testing.expect_value(t, len(d.filters), 2) {
		testing.expect_value(t, d.filters[1].patterns[0], "*.png")
		testing.expect(t, call.mime_filters[1] && !call.mime_filters[0])
	}
	if testing.expect_value(t, len(d.choices), 1) { testing.expect_value(t, d.choices[0].initial, "true") }
	_, ok = req.portal_read_call("DeleteFile", &r)
	testing.expect(t, !ok)
}

@(test)
a_save_files_reply_names_each_file :: proc(t: ^testing.T) {
	a: virtual.Arena
	defer virtual.arena_destroy(&a)
	context.allocator = arena_of(&a)
	body := call_body("Save the attachments", proc(w: ^dbus.Writer) {
		dbus.arg_dict_entry(w, "files"); dbus.w_signature(w, "aay")
		l, c := dbus.w_array_begin(w, 4)
		path_bytes(w, "a.pdf")
		path_bytes(w, "b c.txt")
		dbus.w_array_end(w, l, c)
	})
	r := dbus.reader_make(body)
	call, ok := req.portal_read_call("SaveFiles", &r)
	testing.expect(t, ok)
	testing.expect_value(t, call.request.kind, platform.File_Dialog_Kind.Folder)
	testing.expect_value(t, len(call.files), 2)
	w := dbus.body_writer()
	req.portal_write_reply(&w, call, {status = .Chosen, paths = {"/home/me/Mail"}})
	back := dbus.reader_make(w.buf[:])
	testing.expect_value(t, dbus.r_u32(&back), u32(req.PORTAL_RESPONSE_SUCCESS))
	uris := make([dynamic]string)
	end := dbus.r_array_begin(&back, "{sv}")
	for back.pos < end && !back.err {
		dbus.r_align_entry(&back)
		key := dbus.r_string(&back)
		sig := dbus.r_variant_sig(&back)
		if key != "uris" { dbus.r_skip(&back, sig); continue }
		uend := dbus.r_array_begin(&back, "s")
		for back.pos < uend && !back.err { append(&uris, dbus.r_string(&back)) }
	}
	if testing.expect_value(t, len(uris), 2) {
		testing.expect_value(t, uris[0], "file:///home/me/Mail/a.pdf")
		testing.expect_value(t, uris[1], "file:///home/me/Mail/b%20c.txt")
	}
	w2 := dbus.body_writer()
	req.portal_write_reply(&w2, call, {status = .Cancelled})
	back2 := dbus.reader_make(w2.buf[:])
	testing.expect_value(t, dbus.r_u32(&back2), u32(req.PORTAL_RESPONSE_CANCELLED))
}

@(test)
a_save_file_over_a_file :: proc(t: ^testing.T) {
	a: virtual.Arena
	defer virtual.arena_destroy(&a)
	context.allocator = arena_of(&a)
	body := call_body("Save", proc(w: ^dbus.Writer) {
		dbus.arg_dict_entry(w, "current_file"); dbus.w_signature(w, "ay"); path_bytes(w, "/home/me/report.odt")
	})
	r := dbus.reader_make(body)
	call, ok := req.portal_read_call("SaveFile", &r)
	testing.expect(t, ok)
	testing.expect_value(t, call.request.kind, platform.File_Dialog_Kind.Save)
	testing.expect_value(t, call.request.dialog.start_dir, "/home/me")
	testing.expect_value(t, call.request.dialog.suggested_name, "report.odt")
	testing.expect_value(t, req.portal_mnemonic_off("Save __as_"), "Save _as")
}
