// Package file_request: a file picker's request and answer as text (src/md/features/file-picker.md). The request is a
// platform.File_Request, the answer a platform.Dialog_Result: plain values. This package reads and writes their texts:
// a command line as zenity's ("open --multiple --filter Images:*.png;*.jpg"), JSON, and the XDG desktop portal's
// FileChooser calls (portal.odin). Every procedure is pure: no file, no process, no bus. A host reads a request with
// it, serves it with the toolkit's picker (ui.file_picker_init) and writes the answer with it.
package file_request

import "core:encoding/json"
import "core:strconv"
import "core:strings"
import gjson "../json"
import "../platform"

// The exit codes of a picker's command line: what a caller acts on.
EXIT_CHOSEN :: 0
EXIT_CANCELLED :: 1
EXIT_ERROR :: 2

// What a command line asks.
Mode :: enum u8 {
	Pick,     // a request served once (its kind as a word, or --json with the request on stdin)
	Portal,   // the XDG portal's FileChooser backend (Linux)
	Help,
}

Command :: struct {
	mode:    Mode,
	request: platform.File_Request,   // Pick: what the words gave (stdin: none yet)
	stdin:   bool,                    // Pick: the request is JSON on stdin (--json with no kind)
	json:    bool,                    // Pick: the answer as JSON
	theme:   string,                  // --theme: "NAME" or "NAME:light|dark|system" ("": the program's default)
}

// The usage, as --help prints it.
USAGE :: `gt-file-picker: asks the person for files, and prints what they chose.

  gt-file-picker open [--multiple] [options]     files to open
  gt-file-picker save [--name NAME] [options]    a file to save
  gt-file-picker folder [options]                a folder
  gt-file-picker --json < request.json           the request as JSON, the answer as JSON
  gt-file-picker --portal                        the XDG portal's FileChooser backend (Linux)

Options:
  --title TEXT            the window's title
  --folder PATH           the folder shown first
  --filter NAME:PATTERNS  a line of the type list ("Images:*.png;*.jpg"); one per --filter
  --all-files             a last line "All files"
  --accept WORD           the act button's word
  --remember ID           where it starts next time: the folder left with this ID
  --theme NAME[:MODE]     the look: a theme of the toolkit (Ember by default) and light, dark or system
                          (system by default: it follows the desktop's light or dark setting)
  --json                  the answer as JSON

The chosen paths go to stdout, one per line. Exit code: 0 chosen, 1 cancelled, 2 an error.
`

// Reads a command line (the arguments after the program's name). `why` says what does not read ("": it reads). The
// request's strings are in `allocator` (an arena: platform.file_dialog_free frees the request's options too).
parse_args :: proc(args: []string, allocator := context.allocator) -> (c: Command, why: string) {
	context.allocator = allocator
	filters := make([dynamic]platform.File_Filter)
	kind_set := false
	i := 0
	// (an option's value: "--title=T" or "--title T")
	value :: proc(args: []string, i: ^int, inline: Maybe(string)) -> (string, bool) {
		if v, ok := inline.?; ok { return v, true }
		if i^ + 1 >= len(args) { return "", false }
		i^ += 1
		return args[i^], true
	}
	for ; i < len(args); i += 1 {
		a := args[i]
		name := a
		inline: Maybe(string)
		if strings.has_prefix(a, "--") {
			if eq := strings.index_byte(a, '='); eq >= 0 { name, inline = a[:eq], a[eq + 1:] }
		}
		switch name {
		case "open", "save", "folder":
			if kind_set { return c, "one kind only: open, save or folder" }
			kind_set = true
			c.request.kind = name == "open" ? .Open : (name == "save" ? .Save : .Folder)
		case "--multiple":  c.request.dialog.multiple = true
		case "--all-files": c.request.dialog.all_files = true
		case "--json":      c.json = true
		case "--portal":    c.mode = .Portal
		case "--help", "-h": c.mode = .Help
		case "--theme":
			v, ok := value(args, &i, inline)
			if !ok { return c, "--theme needs a value" }
			if _, _, tok := parse_theme(v); !tok { return c, strings.concatenate({"a theme is NAME or NAME:light, NAME:dark, NAME:system (", v, ")"}) }
			c.theme = strings.clone(v)
		case "--title", "--folder", "--filter", "--name", "--accept", "--remember":
			v, ok := value(args, &i, inline)
			if !ok { return c, strings.concatenate({name, " needs a value"}) }
			switch name {
			case "--title":    c.request.dialog.title = strings.clone(v)
			case "--folder":   c.request.dialog.start_dir = strings.clone(v)
			case "--name":     c.request.dialog.suggested_name = strings.clone(v)
			case "--accept":   c.request.dialog.act = strings.clone(v)
			case "--remember": c.request.dialog.remember_id = strings.clone(v)
			case "--filter":
				f, fok := parse_filter(v)
				if !fok { return c, strings.concatenate({"a filter is NAME:PATTERNS or PATTERNS (", v, ")"}) }
				append(&filters, f)
			}
		case:
			return c, strings.concatenate({"unknown argument: ", a})
		}
	}
	c.request.dialog.filters = filters[:]
	switch c.mode {
	case .Help, .Portal: return c, ""
	case .Pick:
	}
	if !kind_set {
		if !c.json { return c, "say open, save or folder (or --json with the request on stdin)" }
		c.stdin = true
	}
	if c.request.dialog.multiple && c.request.kind != .Open { return c, "--multiple is for open" }
	c.request.dialog.overwrite_prompt = c.request.kind == .Save
	return c, ""
}

// A theme as --theme writes it: "Ember", "Ember:dark". mode is "" (the default), "light", "dark" or "system" (ASCII case
// ignored). Whether NAME is a theme is the program's to check: this package knows no themes.
parse_theme :: proc(text: string) -> (name, mode: string, ok: bool) {
	name = text
	if colon := strings.index_byte(text, ':'); colon >= 0 { name, mode = text[:colon], text[colon + 1:] }
	if name == "" { return "", "", false }
	switch strings.to_lower(mode, context.temp_allocator) {
	case "", "light", "dark", "system": return name, mode, true
	}
	return "", "", false
}

// A filter as a command line writes it: "Images:*.png;*.jpg", or the patterns alone (then they are its name). In the
// context's allocator.
parse_filter :: proc(text: string) -> (f: platform.File_Filter, ok: bool) {
	name, list := "", text
	if colon := strings.index_byte(text, ':'); colon >= 0 { name, list = text[:colon], text[colon + 1:] }
	patterns := make([dynamic]string)
	rest := list
	for p in strings.split_iterator(&rest, ";") {
		q := strings.trim_space(p)
		if q != "" { append(&patterns, strings.clone(q)) }
	}
	if len(patterns) == 0 { return {}, false }
	return {name = strings.clone(strings.trim_space(name)), patterns = patterns[:]}, true
}

// The words of a kind in a request's JSON and on a command line.
kind_word :: proc(k: platform.File_Dialog_Kind) -> string {
	switch k {
	case .Open:   return "open"
	case .Save:   return "save"
	case .Folder: return "folder"
	}
	return "open"
}

// Reads a request's JSON:
//
//	{"kind": "open", "title": "...", "folder": "/start", "filters": [{"name": "Images", "patterns": ["*.png"]}],
//	 "filter": 0, "all_files": true, "multiple": true, "name": "a.txt", "accept": "Open", "remember": "id",
//	 "choices": [{"id": "enc", "label": "Encoding", "options": [{"id": "utf8", "label": "UTF-8"}], "initial": "utf8"}]}
//
// Every field but "kind" may be absent. In `allocator`.
parse_request_json :: proc(text: string, allocator := context.allocator) -> (r: platform.File_Request, why: string) {
	context.allocator = allocator
	v, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil { return r, "the request is no JSON" }
	switch gjson.text(v, "kind") {
	case "open":   r.kind = .Open
	case "save":   r.kind = .Save
	case "folder": r.kind = .Folder
	case:          return r, "the request's kind is open, save or folder"
	}
	d := &r.dialog
	d.title = strings.clone(gjson.text(v, "title"))
	d.start_dir = strings.clone(gjson.text(v, "folder"))
	d.suggested_name = strings.clone(gjson.text(v, "name"))
	d.act = strings.clone(gjson.text(v, "accept"))
	d.remember_id = strings.clone(gjson.text(v, "remember"))
	d.multiple = gjson.boolean(v, "multiple") && r.kind == .Open
	d.all_files = gjson.boolean(v, "all_files")
	d.filter_index = int(gjson.integer(v, "filter"))
	d.overwrite_prompt = r.kind == .Save && gjson.boolean(v, "overwrite_prompt", default = true)
	filters := make([dynamic]platform.File_Filter)
	for f in gjson.array(v, "filters") {
		patterns := make([dynamic]string)
		for p in gjson.array(f, "patterns") { if s := gjson.text(p); s != "" { append(&patterns, strings.clone(s)) } }
		if len(patterns) > 0 { append(&filters, platform.File_Filter{name = strings.clone(gjson.text(f, "name")), patterns = patterns[:]}) }
	}
	d.filters = filters[:]
	choices := make([dynamic]platform.File_Choice)
	for ch in gjson.array(v, "choices") {
		options := make([dynamic]platform.File_Choice_Option)
		for o in gjson.array(ch, "options") { append(&options, platform.File_Choice_Option{id = strings.clone(gjson.text(o, "id")), label = strings.clone(gjson.text(o, "label"))}) }
		append(&choices, platform.File_Choice{id = strings.clone(gjson.text(ch, "id")), label = strings.clone(gjson.text(ch, "label")), options = options[:], initial = strings.clone(gjson.text(ch, "initial"))})
	}
	d.choices = choices[:]
	return r, ""
}

// A request as JSON (parse_request_json reads it back), in `allocator`.
request_json :: proc(r: platform.File_Request, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	w := gjson.writer_make(&b)
	d := r.dialog
	gjson.begin_object(&w)
	gjson.key(&w, "kind"); gjson.write_text(&w, kind_word(r.kind))
	if d.title != "" { gjson.key(&w, "title"); gjson.write_text(&w, d.title) }
	if d.start_dir != "" { gjson.key(&w, "folder"); gjson.write_text(&w, d.start_dir) }
	if d.suggested_name != "" { gjson.key(&w, "name"); gjson.write_text(&w, d.suggested_name) }
	if d.act != "" { gjson.key(&w, "accept"); gjson.write_text(&w, d.act) }
	if d.remember_id != "" { gjson.key(&w, "remember"); gjson.write_text(&w, d.remember_id) }
	if d.multiple { gjson.key(&w, "multiple"); gjson.write_boolean(&w, true) }
	if d.all_files { gjson.key(&w, "all_files"); gjson.write_boolean(&w, true) }
	if r.kind == .Save && !d.overwrite_prompt { gjson.key(&w, "overwrite_prompt"); gjson.write_boolean(&w, false) }
	if d.filter_index != 0 { gjson.key(&w, "filter"); gjson.write_integer(&w, i64(d.filter_index)) }
	if len(d.filters) > 0 {
		gjson.key(&w, "filters")
		gjson.begin_array(&w)
		for f in d.filters {
			gjson.begin_object(&w)
			gjson.key(&w, "name"); gjson.write_text(&w, f.name)
			gjson.key(&w, "patterns")
			gjson.begin_array(&w)
			for p in f.patterns { gjson.write_text(&w, p) }
			gjson.end_array(&w)
			gjson.end_object(&w)
		}
		gjson.end_array(&w)
	}
	if len(d.choices) > 0 {
		gjson.key(&w, "choices")
		gjson.begin_array(&w)
		for ch in d.choices {
			gjson.begin_object(&w)
			gjson.key(&w, "id"); gjson.write_text(&w, ch.id)
			gjson.key(&w, "label"); gjson.write_text(&w, ch.label)
			gjson.key(&w, "initial"); gjson.write_text(&w, ch.initial)
			gjson.key(&w, "options")
			gjson.begin_array(&w)
			for o in ch.options {
				gjson.begin_object(&w)
				gjson.key(&w, "id"); gjson.write_text(&w, o.id)
				gjson.key(&w, "label"); gjson.write_text(&w, o.label)
				gjson.end_object(&w)
			}
			gjson.end_array(&w)
			gjson.end_object(&w)
		}
		gjson.end_array(&w)
	}
	gjson.end_object(&w)
	return strings.to_string(b)
}

// The exit code of an answer: EXIT_CHOSEN, EXIT_CANCELLED, else EXIT_ERROR.
exit_code :: proc(r: platform.Dialog_Result) -> int {
	#partial switch r.status {
	case .Chosen:    return EXIT_CHOSEN
	case .Cancelled: return EXIT_CANCELLED
	}
	return EXIT_ERROR
}

// An answer as the command line prints it: the paths chosen, one per line (nothing when cancelled), in `allocator`.
answer_text :: proc(r: platform.Dialog_Result, allocator := context.allocator) -> string {
	if r.status != .Chosen { return "" }
	b := strings.builder_make(allocator)
	for p in r.paths {
		strings.write_string(&b, p)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// The word of a status in an answer's JSON.
status_word :: proc(s: platform.Dialog_Status) -> string {
	switch s {
	case .Chosen:      return "chosen"
	case .Cancelled:   return "cancelled"
	case .Unsupported: return "unsupported"
	case .Failed:      return "failed"
	}
	return "failed"
}

// An answer as JSON, in `allocator`: {"status": "chosen", "paths": [...], "filter": 0, "choices": [{"id", "value"}]},
// and "error" with `why` when it is not "".
answer_json :: proc(r: platform.Dialog_Result, why := "", allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	w := gjson.writer_make(&b)
	gjson.begin_object(&w)
	gjson.key(&w, "status"); gjson.write_text(&w, status_word(r.status))
	gjson.key(&w, "paths")
	gjson.begin_array(&w)
	for p in r.paths { gjson.write_text(&w, p) }
	gjson.end_array(&w)
	gjson.key(&w, "filter"); gjson.write_integer(&w, i64(r.filter))
	if len(r.choices) > 0 {
		gjson.key(&w, "choices")
		gjson.begin_array(&w)
		for c in r.choices {
			gjson.begin_object(&w)
			gjson.key(&w, "id"); gjson.write_text(&w, c.id)
			gjson.key(&w, "value"); gjson.write_text(&w, c.value)
			gjson.end_object(&w)
		}
		gjson.end_array(&w)
	}
	if why != "" { gjson.key(&w, "error"); gjson.write_text(&w, why) }
	gjson.end_object(&w)
	strings.write_byte(&b, '\n')
	return strings.to_string(b)
}

// Reads an answer's JSON (answer_json's), in `allocator` (platform.dialog_result_destroy frees it). A text that does
// not read is a Failed answer.
parse_answer_json :: proc(text: string, allocator := context.allocator) -> (r: platform.Dialog_Result) {
	context.allocator = allocator
	v, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil { return {status = .Failed} }
	switch gjson.text(v, "status") {
	case "chosen":      r.status = .Chosen
	case "cancelled":   r.status = .Cancelled
	case "unsupported": r.status = .Unsupported
	case:               r.status = .Failed
	}
	paths := make([dynamic]string)
	for p in gjson.array(v, "paths") { append(&paths, strings.clone(gjson.text(p))) }
	r.paths = paths[:]
	r.filter = int(gjson.integer(v, "filter"))
	choices := make([dynamic]platform.File_Choice_Answer)
	for c in gjson.array(v, "choices") { append(&choices, platform.File_Choice_Answer{id = strings.clone(gjson.text(c, "id")), value = strings.clone(gjson.text(c, "value"))}) }
	r.choices = choices[:]
	return
}

_ :: strconv
