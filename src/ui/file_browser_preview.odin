package ui

// The file browser's preview (docs/file-browser.md): the selected file's start, read through the source
// (File_Source.read) and made ready on the chores: a picture decoded (gt:image: PNG, JPEG, BMP, WebP), a text cut at
// its last whole character and coloured by its kind (syntax). Only the latest selection counts: a reading has a ticket
// (remote), and an older one answers nothing. A picture's texture is made at the first draw that shows it (the draw
// has the renderer) and freed when another file is selected or the dialog closes.

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"
import "../draw"
import i18n "../i18n"
import img "../image"
import "../render"
import remote "../remote"
import syntax "../syntax"
import timefmt "../timefmt"

// The preview's width at first, its least, and the room the list and the preview need for it to show, in ems.
FILE_PREVIEW_DEFAULT_EM :: 18
FILE_PREVIEW_MIN_EM :: 10
FILE_PREVIEW_SHOWN_EM :: 44
// The lines of a text shown at most (a long file's start is what tells it).
FILE_PREVIEW_LINES :: 300
// A file with a zero byte in its first bytes is no text.
@(private = "file") FILE_PREVIEW_BINARY_PROBE :: 8000

@(private)
File_Preview :: struct {
	reading:  remote.Remote,
	path:     string,     // the file previewed ("": none)
	name:     string,
	look:     File_Look,
	size:     i64,
	modified: i64,
	// what was read
	text:     string,
	spans:    [dynamic]syntax.Span,
	coloured: bool,       // its kind is known: the spans colour it
	version:  u64,        // counts the texts (rich_paragraph's version: laid out once)
	binary:   bool,       // neither a picture nor a text: its icon, its size, its date
	pixels:   []u8,       // RGBA8
	width:    int,
	height:   int,
	texture:  render.Texture,
	renderer: ^render.Renderer,   // the texture's (texture 0: none)
	refused:  bool,       // the texture could not be made (too large): the picture is not shown
	zoom:     Preview,
}

@(private)
file_preview_clear :: proc(fb: ^File_Browser) {
	p := &fb.preview
	a := runtime.heap_allocator()
	if p.texture != 0 && p.renderer != nil { render.destroy_texture(p.renderer, p.texture) }
	delete(p.path, a); delete(p.name, a); delete(p.text, a); delete(p.pixels, a)
	clear(&p.spans)
	p.path, p.name, p.text, p.pixels = "", "", "", nil
	p.texture, p.renderer, p.refused, p.binary, p.coloured = 0, nil, false, false, false
	p.width, p.height, p.size, p.modified = 0, 0, -1, 0
	remote.reset(&p.reading)
	preview_reset(&p.zoom)
}

@(private)
file_preview_destroy :: proc(fb: ^File_Browser) {
	file_preview_clear(fb)
	delete(fb.preview.spans)
	remote.destroy(&fb.preview.reading)
}

// The preview follows the selection: a single file selected is read (`shown`: the preview is on screen and the source
// reads), anything else shows nothing. Compared at each build, read only when it changed.
@(private)
file_preview_follow :: proc(fb: ^File_Browser, shown: bool) {
	want := ""
	e: ^File_Entry
	if shown && .Read in fb.source.caps && fb.source.read != nil && list_mark_count(&fb.table.vl) <= 1 {
		e = file_row_entry(fb, table_selected(&fb.table))
		if e != nil && e.kind == .File { want = file_path_join(fb.folder, e.name, fb.sep) }
	}
	if want == fb.preview.path { return }
	file_preview_clear(fb)
	if want == "" { return }
	p := &fb.preview
	a := runtime.heap_allocator()
	p.path, p.name = strings.clone(want, a), strings.clone(e.name, a)
	p.look, p.size, p.modified = file_entry_look(e^), e.size, e.modified
	if p.look == .Image && e.size > FILE_PREVIEW_IMAGE_BYTES {
		p.binary = true   // (too large to read for a glance: its size and its date)
		return
	}
	most := p.look == .Image ? FILE_PREVIEW_IMAGE_BYTES : FILE_PREVIEW_BYTES
	ticket := remote.begin(&p.reading)
	fb.source.read(&fb.source, strings.clone(want, context.temp_allocator), most, {state = fb.state, dialog = fb.serial, ticket = ticket, kind = .Read})
}

// What a preview's bytes become, on the chores.
@(private = "file")
Preview_Job :: struct {
	state:    ^State,
	serial:   u64,
	ticket:   u64,
	name:     string,
	image:    bool,
	bytes:    []u8,
	// made
	text:     string,
	spans:    [dynamic]syntax.Span,
	coloured: bool,
	binary:   bool,
	pixels:   []u8,
	width:    int,
	height:   int,
}

@(private)
file_browser_read :: proc(fb: ^File_Browser, ticket: u64, bytes: []u8, size: i64) {
	p := &fb.preview
	if !remote.current(&p.reading, ticket) { return }
	if size >= 0 { p.size = size }
	a := runtime.heap_allocator()
	j := new(Preview_Job, a)
	j^ = {state = fb.state, serial = fb.serial, ticket = ticket, name = strings.clone(p.name, a), image = p.look == .Image, bytes = make([]u8, len(bytes), a)}
	copy(j.bytes, bytes)
	j.spans = make([dynamic]syntax.Span, a)
	task(fb.state, preview_job_work, preview_job_done, j, preview_job_lost)
}

@(private = "file")
preview_job_work :: proc(d: rawptr) {
	j := (^Preview_Job)(d)
	a := runtime.heap_allocator()
	if j.image {
		if im, _, ok := img.decode(j.bytes, a); ok {
			j.pixels, j.width, j.height = im.pixels, im.width, im.height
			return
		}
	}
	probe := j.bytes[:min(len(j.bytes), FILE_PREVIEW_BINARY_PROBE)]
	for b in probe { if b == 0 { j.binary = true; return } }
	// (cut at its last whole character: the read stopped where it stopped)
	n := len(j.bytes)
	for k := 1; k <= min(utf8.UTF_MAX, n); k += 1 {
		b := j.bytes[n - k]
		if b < 0x80 { break }
		if b >= 0xC0 {
			if !utf8.full_rune(j.bytes[n - k:n]) { n -= k }
			break
		}
	}
	text := string(j.bytes[:n])
	lines := 0
	for c, i in text {
		if c != '\n' { continue }
		lines += 1
		if lines == FILE_PREVIEW_LINES { text = text[:i]; break }
	}
	j.text = strings.clone(text, a)
	if l, ok := syntax.language_of_file(j.name); ok {
		syntax.spans(j.text, l, &j.spans)
		j.coloured = true
	}
}

@(private = "file")
preview_job_done :: proc(d: rawptr, _: u64) {
	j := (^Preview_Job)(d)
	defer preview_job_free(j)
	fb := j.state.files
	if fb == nil || !fb.open || fb.serial != j.serial { return }
	p := &fb.preview
	context.allocator = runtime.heap_allocator()
	if !remote.answer(&p.reading, j.ticket, .Ready) { return }
	// (taken over: the job frees what is left, the preview's old spans with it)
	p.text, j.text = j.text, ""
	p.spans, j.spans = j.spans, p.spans
	p.pixels, j.pixels = j.pixels, nil
	p.width, p.height, p.coloured = j.width, j.height, j.coloured
	p.binary = j.binary || (p.pixels == nil && p.text == "")
	p.version += 1
}

@(private = "file")
preview_job_lost :: proc(d: rawptr) { preview_job_free((^Preview_Job)(d)) }

@(private = "file")
preview_job_free :: proc(j: ^Preview_Job) {
	a := runtime.heap_allocator()
	delete(j.name, a); delete(j.bytes, a); delete(j.text, a); delete(j.pixels, a)
	delete(j.spans)
	free(j, a)
}

@(private)
file_preview_failed :: proc(fb: ^File_Browser, ticket: u64, message: string) {
	_ = remote.answer(&fb.preview.reading, ticket, .Failed, message)
}

// The preview's pane: the picture (zoomed and moved as ui.preview does), the text, or what is known of the file.
@(private)
file_preview_build :: proc(fb: ^File_Browser) {
	p := &fb.preview
	em := font_size()
	if p.path == "" {
		next({width = fill(), height = fill()})
		empty_state("fb_preview_none", {icon = file_look_icon(.File), title = i18n.tr("No preview"), note = i18n.tr("Select a file to see it here.")})
		return
	}
	if p.reading.state == .Ready && p.pixels != nil && !p.refused {
		d := frame_new(File_Image_Draw)
		d.fb = fb
		next({width = fill(), height = fill()})
		_ = preview("###fb_preview_image", &p.zoom, {f32(p.width), f32(p.height)}, file_image_draw, d, {buttons = true})
		return
	}
	if p.reading.state == .Ready && p.text != "" && !p.binary {
		next({width = fill(), height = fill()})
		if scroll_y("###fb_preview_text") {
			runs := make([dynamic]Rich_Run, context.temp_allocator)
			style := Rich_Style{font = mono_font(), size = em * 0.9}
			if p.coloured {
				code_runs_of(p.text, p.spans[:], style, &runs)
			} else {
				append(&runs, Rich_Run{text = p.text, style = style})
			}
			next({width = fill(), text_pad = em * 0.6})
			_ = rich_paragraph("###fb_preview_lines", runs[:], version = p.version)
		}
		return
	}
	// what is known of it: its size and its date (a file that is no picture nor text, a reading that failed or is on
	// its way)
	details := make([dynamic]string, context.temp_allocator)
	if p.size >= 0 { append(&details, timefmt.size(p.size)) }
	if p.modified > 0 { append(&details, timefmt.moment(f64(p.modified), f64(choice_now()), fb.local.offset_minutes)) }
	switch {
	case p.reading.state == .Loading: append(&details, i18n.tr("Reading…"))
	case remote.failed(&p.reading):   append(&details, p.reading.message)
	}
	next({width = fill(), height = fill()})
	empty_state("fb_preview_info", {icon = file_look_icon(p.look), title = p.name, note = strings.join(details[:], " · ", context.temp_allocator)})
}

@(private = "file")
File_Image_Draw :: struct { fb: ^File_Browser }

// (the texture made at the first draw: the draw has the renderer, the build has not)
@(private = "file")
file_image_draw :: proc(dc: ^draw.Context, dst: Rect, user: rawptr) {
	d := (^File_Image_Draw)(user)
	p := &d.fb.preview
	if p.texture == 0 && !p.refused && p.pixels != nil && dc.renderer != nil {
		most := render.max_texture_size(dc.renderer)
		if p.width <= 0 || p.height <= 0 || p.width > most || p.height > most {
			p.refused = true
			return
		}
		p.texture = render.create_texture_rgba(dc.renderer, p.width, p.height)
		if p.texture == 0 { p.refused = true; return }
		p.renderer = dc.renderer
		render.update_texture_rgba(dc.renderer, p.texture, 0, 0, p.width, p.height, p.pixels)
	}
	if p.texture != 0 { draw.image(dc, p.texture, dst) }
}
