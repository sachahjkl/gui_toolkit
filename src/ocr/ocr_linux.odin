#+build linux
package tk_ocr

// Tesseract 5's C API (capi.h), by dlopen: a program that never reads text starts on a system without it. Its language
// data (<code>.traineddata) is in the first of tessdata_folders that has some.

import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"

@(private = "file")
Tesseract :: struct {
	create:            proc "c" () -> rawptr,
	destroy:           proc "c" (api: rawptr),
	init3:             proc "c" (api: rawptr, datapath: cstring, language: cstring) -> i32,
	end:               proc "c" (api: rawptr),
	set_variable:      proc "c" (api: rawptr, name: cstring, value: cstring) -> i32,
	set_page_seg_mode: proc "c" (api: rawptr, mode: i32),
	set_image:         proc "c" (api: rawptr, data: [^]u8, width, height, bytes_per_pixel, bytes_per_line: i32),
	recognize:         proc "c" (api: rawptr, monitor: rawptr) -> i32,
	get_iterator:      proc "c" (api: rawptr) -> rawptr,
	iterator_delete:   proc "c" (it: rawptr),
	iterator_next:     proc "c" (it: rawptr, level: i32) -> i32,
	iterator_text:     proc "c" (it: rawptr, level: i32) -> cstring,
	iterator_page:     proc "c" (it: rawptr) -> rawptr,
	page_box:          proc "c" (page: rawptr, level: i32, left, top, right, bottom: ^i32) -> i32,
	page_begins:       proc "c" (page: rawptr, level: i32) -> i32,
	delete_text:       proc "c" (text: cstring),
}

@(private = "file") tess: Tesseract
@(private = "file") tess_once: sync.Once
@(private = "file") tess_found: bool

// TessPageSegMode: PSM_AUTO finds blocks and columns; PSM_SINGLE_BLOCK reads the picture as one block, which finds
// text PSM_AUTO misses in a small region (one word, one short line).
@(private = "file") PSM_AUTO         :: 3
@(private = "file") PSM_SINGLE_BLOCK :: 6
// TessPageIteratorLevel.
@(private = "file") RIL_TEXTLINE :: 2
@(private = "file") RIL_WORD     :: 3

@(private = "file")
tess_load :: proc() {
	for name in ([]cstring{"libtesseract.so.5", "libtesseract.so"}) {
		h := posix.dlopen(name, posix.RTLD_LOCAL + {.NOW})
		if h == nil { continue }
		t := &tess
		t.create = auto_cast posix.dlsym(h, "TessBaseAPICreate")
		t.destroy = auto_cast posix.dlsym(h, "TessBaseAPIDelete")
		t.init3 = auto_cast posix.dlsym(h, "TessBaseAPIInit3")
		t.end = auto_cast posix.dlsym(h, "TessBaseAPIEnd")
		t.set_variable = auto_cast posix.dlsym(h, "TessBaseAPISetVariable")
		t.set_page_seg_mode = auto_cast posix.dlsym(h, "TessBaseAPISetPageSegMode")
		t.set_image = auto_cast posix.dlsym(h, "TessBaseAPISetImage")
		t.recognize = auto_cast posix.dlsym(h, "TessBaseAPIRecognize")
		t.get_iterator = auto_cast posix.dlsym(h, "TessBaseAPIGetIterator")
		t.iterator_delete = auto_cast posix.dlsym(h, "TessResultIteratorDelete")
		t.iterator_next = auto_cast posix.dlsym(h, "TessResultIteratorNext")
		t.iterator_text = auto_cast posix.dlsym(h, "TessResultIteratorGetUTF8Text")
		t.iterator_page = auto_cast posix.dlsym(h, "TessResultIteratorGetPageIterator")
		t.page_box = auto_cast posix.dlsym(h, "TessPageIteratorBoundingBox")
		t.page_begins = auto_cast posix.dlsym(h, "TessPageIteratorIsAtBeginningOf")
		t.delete_text = auto_cast posix.dlsym(h, "TessDeleteText")
		if t.create == nil || t.destroy == nil || t.init3 == nil || t.end == nil || t.set_variable == nil ||
		   t.set_page_seg_mode == nil || t.set_image == nil || t.recognize == nil || t.get_iterator == nil ||
		   t.iterator_delete == nil || t.iterator_next == nil || t.iterator_text == nil || t.iterator_page == nil ||
		   t.page_box == nil || t.page_begins == nil || t.delete_text == nil {
			posix.dlclose(h)
			tess = {}
			continue
		}
		tess_found = true
		return
	}
}

// Where the language data may be, in this order: $TESSDATA_PREFIX (Tesseract 4 and 5 read the files there; Tesseract 3
// read its tessdata subfolder), then the folders of the distributions' packages, then the Nix profiles'.
@(private = "file")
tessdata_folders :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	if prefix := os.get_env("TESSDATA_PREFIX", allocator); prefix != "" {
		append(&out, prefix, strings.concatenate({prefix, "/tessdata"}, allocator))
	}
	append(&out,
		"/usr/share/tesseract-ocr/5/tessdata",     // Debian, Ubuntu
		"/usr/share/tessdata",                     // Arch, Fedora, openSUSE
		"/usr/share/tesseract/tessdata",
		"/usr/local/share/tessdata",               // a build of one's own
		"/run/current-system/sw/share/tessdata",   // NixOS, the system's packages
	)
	if home := os.get_env("HOME", allocator); home != "" { append(&out, strings.concatenate({home, "/.nix-profile/share/tessdata"}, allocator)) }
	if user := os.get_env("USER", allocator); user != "" { append(&out, strings.concatenate({"/etc/profiles/per-user/", user, "/share/tessdata"}, allocator)) }
	return out[:]
}

// The first folder with language data, and its languages (sorted).
@(private = "file")
tessdata :: proc(allocator := context.temp_allocator) -> (folder: string, installed: []string) {
	for f in tessdata_folders(context.temp_allocator) {
		entries, err := os.read_all_directory_by_path(f, context.temp_allocator)
		if err != nil { continue }
		names := make([dynamic]string, allocator)
		for e in entries {
			if e.type == .Directory || !strings.has_suffix(e.name, ".traineddata") { continue }
			append(&names, strings.clone(strings.trim_suffix(e.name, ".traineddata"), allocator))
		}
		if len(names) == 0 { delete(names); continue }
		slice.sort(names[:])
		return strings.clone(f, allocator), names[:]
	}
	return "", nil
}

// The locale messages are read in, as the C library takes it from the environment.
@(private = "file")
messages_locale :: proc() -> string {
	for name in ([]string{"LC_ALL", "LC_MESSAGES", "LANG"}) {
		v := os.get_env(name, context.temp_allocator)
		if v != "" && v != "C" && v != "POSIX" { return v }
	}
	return ""
}

@(private)
system_available :: proc() -> (engine: Engine, ok: bool) {
	sync.once_do(&tess_once, tess_load)
	if !tess_found { return .None, false }
	_, installed := tessdata()
	return .Tesseract, len(installed) > 0
}

// Tesseract has no limit of its own: MAX_PIXELS bounds the picture.
@(private) system_max_side :: proc() -> int { return 0 }

@(private)
system_languages :: proc(allocator := context.allocator) -> []string {
	sync.once_do(&tess_once, tess_load)
	if !tess_found { return nil }
	folder, installed := tessdata(allocator)
	delete(folder, allocator)
	return installed
}

@(private)
system_recognize :: proc(p: Prepared, options: Options, lines: ^[dynamic]Line, allocator := context.allocator) -> (engine: Engine, language: string, err: Error) {
	sync.once_do(&tess_once, tess_load)
	if !tess_found { return .None, "", .No_Engine }
	folder, installed := tessdata()
	asked := options.languages
	if len(asked) == 0 { asked = default_languages(messages_locale(), installed, context.temp_allocator) }
	use := make([dynamic]string, context.temp_allocator)
	for a in asked { if slice.contains(installed, a) && !slice.contains(use[:], a) { append(&use, a) } }
	if len(use) == 0 { return .Tesseract, "", .No_Language }
	language = strings.join(use[:], "+", allocator)

	t := &tess
	api := t.create()
	if api == nil { return .Tesseract, language, .Failed }
	defer t.destroy(api)
	if t.init3(api, strings.clone_to_cstring(folder, context.temp_allocator), strings.clone_to_cstring(language, context.temp_allocator)) != 0 {
		return .Tesseract, language, .Failed
	}
	defer t.end(api)
	// (its notes, "Estimating resolution as 142", go to stderr otherwise: the program's own log)
	t.set_variable(api, "debug_file", "/dev/null")
	for mode in ([]i32{PSM_AUTO, PSM_SINGLE_BLOCK}) {
		t.set_page_seg_mode(api, mode)
		// (SetImage again: it drops the previous mode's results)
		t.set_image(api, raw_data(p.gray), i32(p.width), i32(p.height), 1, i32(p.width))
		if t.recognize(api, nil) != 0 { return .Tesseract, language, .Failed }
		read_lines(api, lines, allocator)
		if len(lines) > 0 { break }
	}
	return .Tesseract, language, .None
}

// The lines and words of the last recognition, with their boxes (in the prepared picture's pixels).
@(private = "file")
read_lines :: proc(api: rawptr, lines: ^[dynamic]Line, allocator := context.allocator) {
	t := &tess
	it := t.get_iterator(api)
	if it == nil { return }
	defer t.iterator_delete(it)
	page := t.iterator_page(it)   // (the same object seen as its base: not deleted on its own)

	line: Line
	words := make([dynamic]Word, allocator)
	open := false
	for {
		if t.page_begins(page, RIL_TEXTLINE) != 0 {
			if open { close_line(lines, &line, &words, allocator) }
			open = true
			line.text = text_at(it, RIL_TEXTLINE, allocator)
			line.rect = box_at(page, RIL_TEXTLINE)
		}
		if w := text_at(it, RIL_WORD, allocator); w != "" {
			append(&words, Word{text = w, rect = box_at(page, RIL_WORD)})
		}
		if t.iterator_next(it, RIL_WORD) == 0 { break }
	}
	if open { close_line(lines, &line, &words, allocator) }
	delete(words)
}

// Ends the line being read: kept with its words, or dropped when it has no text (an empty page's first position).
@(private = "file")
close_line :: proc(lines: ^[dynamic]Line, line: ^Line, words: ^[dynamic]Word, allocator := context.allocator) {
	if line.text == "" && len(words) == 0 {
		line^ = {}
		return
	}
	line.words = words[:]
	append(lines, line^)
	words^ = make([dynamic]Word, allocator)
	line^ = {}
}

// The text of the element the iterator is at, without the spaces and newline Tesseract ends a line with (owned; "" is
// not allocated).
@(private = "file")
text_at :: proc(it: rawptr, level: i32, allocator := context.allocator) -> string {
	c := tess.iterator_text(it, level)
	if c == nil { return "" }
	defer tess.delete_text(c)
	s := strings.trim_space(string(c))
	if s == "" { return "" }
	return strings.clone(s, allocator)
}

@(private = "file")
box_at :: proc(page: rawptr, level: i32) -> Rect {
	left, top, right, bottom: i32
	if tess.page_box(page, level, &left, &top, &right, &bottom) == 0 { return {} }
	return {int(left), int(top), int(right - left), int(bottom - top)}
}
