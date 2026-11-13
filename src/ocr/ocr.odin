// Package tk_ocr: the text in a picture, read with what the system has (Windows: Windows.Media.Ocr; Linux: Tesseract,
// loaded at run time). It blocks: a program calls it on a thread of its own. (Named tk_ocr: a program may have an `ocr`
// package of its own.)
//
//	r, err := ocr.recognize(pixels, width, height, stride, .RGBA)
//	if err != .None { ... }                      // No_Engine, No_Language...
//	defer ocr.result_destroy(&r)
//	fmt.println(r.text)                          // the lines in reading order
//
// Before an engine sees the picture it becomes grey, dark text on a light ground (inverted when the ground is dark), its
// contrast stretched, and scaled up when its text is small (prepare.odin). See docs/ocr.md.
package tk_ocr

import "core:slice"
import "core:strings"
import "../ascii"
import i18n "../i18n"

Format :: enum u8 { RGBA, BGRA }

Engine :: enum u8 {
	None,
	Tesseract,   // Linux: libtesseract.so.5
	Windows,     // Windows.Media.Ocr
}

Recognize_Options :: struct {
	// The languages to read, in the engine's own codes as `languages` lists them: Tesseract's ("eng", "fra", "chi_sim"),
	// all of them at once; Windows' BCP-47 tags ("en-US", "fr-FR"), the first one installed (its engine reads one
	// language). Empty: the user's (default_languages; Windows: the languages of the user's profile).
	languages: []string,
}

// A rectangle in the pixels of the picture given to recognize.
Rect :: struct {
	x, y, width, height: int,
}

Word :: struct {
	text: string,
	rect: Rect,
}

Line :: struct {
	text:  string,
	rect:  Rect,
	words: []Word,
}

Result :: struct {
	text:     string,   // the lines in reading order (reading_order): a row's lines joined by a tab, the rows by "\n"
	lines:    []Line,   // in the same order
	engine:   Engine,
	language: string,   // what the engine read with: "eng+fra", "en-US"
}

Error :: enum u8 {
	None,
	No_Engine,     // this system has no OCR engine (Linux: no libtesseract)
	No_Language,   // none of the languages asked is installed, or none is at all
	Bad_Picture,   // a size, a stride or a length that do not match
	Too_Large,     // larger than the engine takes (Windows: OcrEngine.MaxImageDimension)
	Failed,        // the engine stopped with an error
}

error_text :: proc(e: Error) -> string {
	switch e {
	case .None:        return i18n.tr("no error")
	case .No_Engine:   return i18n.tr("this system has no text recognition (OCR) engine")
	case .No_Language: return i18n.tr("no text recognition language is installed for the languages asked")
	case .Bad_Picture: return i18n.tr("the picture's size does not match its pixels")
	case .Too_Large:   return i18n.tr("the picture is too large for text recognition")
	case .Failed:      return i18n.tr("text recognition failed")
	}
	return i18n.tr("unknown error")
}

// Which engine this system has, and whether it can read: its library is there and at least one language is installed.
// Blocks (it may load a library, list files, start the Windows Runtime).
available :: proc() -> (engine: Engine, ok: bool) { return system_available() }

// The languages installed, in the engine's own codes (Recognize_Options.languages). Blocks.
languages :: proc(allocator := context.allocator) -> []string { return system_languages(allocator) }

// The text in `pixels` (`width` x `height`, `stride` bytes a row, 4 bytes a pixel in `format`; alpha is not read).
// Blocks: a second or more on a large picture. A picture with no text is no Error: its Result has no lines. The
// rectangles are in the pixels given.
recognize :: proc(pixels: []u8, width, height, stride: int, format: Format, o := Recognize_Options{}, allocator := context.allocator) -> (r: Result, err: Error) {
	if width <= 0 || height <= 0 || stride < width * 4 || len(pixels) < stride * (height - 1) + width * 4 { return {}, .Bad_Picture }
	max_side := system_max_side()
	if max_side > 0 && max(width, height) > max_side { return {}, .Too_Large }
	p := prepare(pixels, width, height, stride, format, max_side, context.allocator)
	defer prepared_destroy(&p)
	lines: [dynamic]Line
	lines.allocator = allocator
	r.engine, r.language, err = system_recognize(p, o, &lines, allocator)
	if err != .None {
		lines_destroy(lines[:], allocator)
		delete(lines)
		delete(r.language, allocator)
		return {}, err
	}
	for &l in lines {
		l.rect = unscale(l.rect, p.scale, width, height)
		for &w in l.words { w.rect = unscale(w.rect, p.scale, width, height) }
	}
	r.lines = lines[:]
	r.text = reading_order(r.lines, allocator)
	return r, .None
}

result_destroy :: proc(r: ^Result, allocator := context.allocator) {
	lines_destroy(r.lines, allocator)
	delete(r.lines, allocator)
	delete(r.text, allocator)
	delete(r.language, allocator)
	r^ = {}
}

@(private)
lines_destroy :: proc(lines: []Line, allocator := context.allocator) {
	for l in lines {
		for w in l.words { delete(w.text, allocator) }
		delete(l.words, allocator)
		delete(l.text, allocator)
	}
}

// A rectangle of the prepared picture in the pixels of the one given (the engine read it `scale` times as large).
@(private)
unscale :: proc(r: Rect, scale, width, height: int) -> Rect {
	x0 := clamp(r.x / scale, 0, width)
	y0 := clamp(r.y / scale, 0, height)
	x1 := clamp((r.x + r.width + scale - 1) / scale, 0, width)
	y1 := clamp((r.y + r.height + scale - 1) / scale, 0, height)
	return {x0, y0, x1 - x0, y1 - y0}
}

////////////////////////////////
// Reading order

// Puts `lines` in reading order and returns their text (owned). Lines whose heights overlap by half the shorter one are
// on one row: a row is read left to right, the rows top to bottom. A row's lines are joined by a tab (the cells of a
// table, a label and its value), the rows by "\n". Engines give lines in the order of their blocks: a column at a time;
// a region of a screen is read a row at a time.
reading_order :: proc(lines: []Line, allocator := context.allocator) -> string {
	if len(lines) == 0 { return strings.clone("", allocator) }
	rows := make([]int, len(lines), context.temp_allocator)
	slice.stable_sort_by(lines, proc(a, b: Line) -> bool { return a.rect.y < b.rect.y })
	// (sorted by their tops, a line can only share a row with the row last opened)
	row := 0
	top, bottom := lines[0].rect.y, lines[0].rect.y + lines[0].rect.height
	for l, i in lines[1:] {
		if !same_row(top, bottom, l.rect) {
			row += 1
			top, bottom = l.rect.y, l.rect.y + l.rect.height
		} else {
			top, bottom = min(top, l.rect.y), max(bottom, l.rect.y + l.rect.height)
		}
		rows[i + 1] = row
	}
	ordered := make([]Ordered, len(lines), context.temp_allocator)
	for l, i in lines { ordered[i] = {l, rows[i]} }
	slice.stable_sort_by(ordered, proc(a, b: Ordered) -> bool {
		if a.row != b.row { return a.row < b.row }
		return a.line.rect.x < b.line.rect.x
	})
	b := strings.builder_make(allocator)
	for o, i in ordered {
		lines[i] = o.line
		if i > 0 { strings.write_byte(&b, ordered[i - 1].row == o.row ? '\t' : '\n') }
		strings.write_string(&b, o.line.text)
	}
	return strings.to_string(b)
}

@(private = "file")
Ordered :: struct { line: Line, row: int }

// Whether a line belongs to the row that spans [top, bottom): they overlap by half the shorter of the two.
@(private)
same_row :: proc(top, bottom: int, r: Rect) -> bool {
	overlap := min(bottom, r.y + r.height) - max(top, r.y)
	shorter := min(bottom - top, r.height)
	return overlap > 0 && 2 * overlap >= shorter
}

////////////////////////////////
// Languages

// Tesseract's languages for a locale ("fr_FR.UTF-8", as LANG says), among those `installed`: the locale's language and
// English, the ones installed; else the first installed that is a language ("osd" and "equ" are not). Owned slice; its
// strings are `installed`'s.
default_languages :: proc(locale: string, installed: []string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	wanted := [2]string{tesseract_code(locale), "eng"}
	for w in wanted {
		if w == "" || slice.contains(out[:], w) { continue }
		for i in installed { if i == w { append(&out, i); break } }
	}
	if len(out) == 0 {
		for i in installed { if i != "osd" && i != "equ" { append(&out, i); break } }
	}
	return out[:]
}

// Tesseract's code of a locale's language ("fr_FR.UTF-8": "fra"; "zh_TW": "chi_tra"); "" for one it has no line for.
tesseract_code :: proc(locale: string) -> string {
	lang := locale
	if i := strings.index_any(lang, "_.@-"); i >= 0 { lang = lang[:i] }
	if lang == "zh" {
		region := locale[len(lang):]
		traditional := ascii.contains_fold(region, "tw") || ascii.contains_fold(region, "hk") || ascii.contains_fold(region, "hant")
		return traditional ? "chi_tra" : "chi_sim"
	}
	for c in LANGUAGE_CODES { if c[0] == lang { return c[1] } }
	return ""
}

// ISO 639-1 to Tesseract's codes (ISO 639-2/T, with its own names for a few), for the languages most desktops run in.
@(private, rodata)
LANGUAGE_CODES := [?][2]string{
	{"en", "eng"}, {"fr", "fra"}, {"de", "deu"}, {"es", "spa"}, {"it", "ita"}, {"pt", "por"}, {"nl", "nld"},
	{"sv", "swe"}, {"da", "dan"}, {"nb", "nor"}, {"nn", "nor"}, {"no", "nor"}, {"fi", "fin"}, {"pl", "pol"},
	{"cs", "ces"}, {"sk", "slk"}, {"hu", "hun"}, {"ro", "ron"}, {"ru", "rus"}, {"uk", "ukr"}, {"el", "ell"},
	{"tr", "tur"}, {"ar", "ara"}, {"he", "heb"}, {"ja", "jpn"}, {"ko", "kor"}, {"hi", "hin"}, {"vi", "vie"},
	{"th", "tha"}, {"id", "ind"}, {"ca", "cat"}, {"bg", "bul"}, {"hr", "hrv"}, {"sr", "srp"}, {"sl", "slv"},
	{"lt", "lit"}, {"lv", "lav"}, {"et", "est"},
}
