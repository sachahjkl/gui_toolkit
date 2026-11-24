package ui

// ui.Mark_Editor: marks drawn on a picture (boxes, arrows, ink, text, hidden parts, a crop) before it is sent, in the
// box a program gives (docs/mark-editor.md; the design: src/md/features/mark-editor.md). The model is gt:marks: this
// file turns the pointer and the keys into its events, builds the bars and the text field, and runs on the chores what
// reads every pixel: the mosaics and the blurred copies the screen shows, and the flattening at Done.
//
//   flattening   Idle --Done--> Flattening (a chore) --pixels--> Idle (.Done; the result held until taken)
//   a filter     asked (a chore) --pixels--> made (a texture at its first draw); asked again when the shapes change
//
// The picture is copied once into a counted buffer (Mark_Pixels): each chore takes a count and the last one out frees
// it, so the editor never waits for a chore. Destroyed while one runs, it lets go of its count, and the chore's answer
// finds no editor (its job's editor is nil).

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "../draw"
import "../font"
import i18n "../i18n"
import ink "../ink"
import lucide "../lucide"
import marks "../marks"
import paint "../paint"
import "../platform"
import "../render"

// What a program chooses. A zero field takes the toolkit's choice.
Mark_Editor_Options :: struct {
	tools:  marks.Tools,               // the tools offered ({}: every one)
	tool:   Maybe(marks.Tool),         // the tool chosen first (nil: Arrow, or the first offered)
	styles: [marks.Tool]marks.Style,   // each tool's first style (a zero style: the toolkit's)
	colors: []u32,                     // the swatches, 0xRRGGBB (nil: marks.COLORS); copied
	scale:  f32,                       // the picture's pixels per logical pixel (0: 1)
	pen:    Maybe(ink.Pen),            // the pen's ink (nil: marks.PEN_DEFAULT); its width is the style's
	// the program has its own Done and Cancel (mark_editor_done, mark_editor_cancel): the editor shows none
	hide_end_buttons: bool,
}

Mark_Editor_Event :: enum u8 {
	Changed,     // the shapes or the crop changed (a kept change: an undo step, an undo, a redo)
	Done,        // the flattened picture is ready: mark_editor_result takes it
	Cancelled,   // the person gave up (Cancel, Escape with nothing selected)
	Failed,      // the picture could not be flattened
}
Mark_Editor_Events :: bit_set[Mark_Editor_Event; u8]

// The picture, shared by the editor and its chores; the last one out frees it.
@(private)
Mark_Pixels :: struct {
	rgba: []u8,   // heap
	refs: int,    // atomic
}

// A mosaic or a blurred copy of the picture for the screen.
@(private)
Mark_Filter :: struct {
	blur:    bool,
	amount:  int,                // picture pixels: a mosaic's cell, a blur's radius
	job:     ^Mark_Filter_Job,   // asked; nil once made
	mosaic:  marks.Mosaic,       // heap
	blurred: marks.Blurred,      // heap
	texture: render.Texture,     // Blur: made at its first draw
}

@(private)
Mark_Filter_Job :: struct {
	editor:  ^Mark_Editor,   // nil once the editor went
	pixels:  ^Mark_Pixels,
	size:    [2]int,
	blur:    bool,
	amount:  int,
	mosaic:  marks.Mosaic,
	blurred: marks.Blurred,
	cancel:  bool,           // atomic: the editor went, the work stops early
}

@(private)
Mark_Flatten_Job :: struct {
	editor:   ^Mark_Editor,   // nil once the editor went
	pixels:   ^Mark_Pixels,
	input:    marks.Flatten_Input,
	out:      []u8,           // heap
	out_size: [2]int,
	cancel:   bool,           // atomic
}

// The editor: kept by the program between builds. Zero, then mark_editor_init; mark_editor_destroy at the end.
Mark_Editor :: struct {
	model:   marks.Model,      // the program may read it, set its tool and styles (a saved choice)
	tools:   marks.Tools,
	colors:  [dynamic]u32,
	hide_end_buttons: bool,
	picture: ^Mark_Pixels,
	size:    [2]int,

	// the screen: the picture's texture, the filters, the figures of the shapes (made again when the model changes)
	texture:     render.Texture,
	renderer:    ^render.Renderer,   // the textures'
	refused:     bool,               // no texture of the picture could be made (too large): it shows grey
	filters:     [dynamic]Mark_Filter,
	filters_changes: u64,
	figures:     [dynamic]marks.Figure,
	ranges:      [dynamic][2]int,    // each shape's figures in `figures`
	figure_arena: virtual.Arena,
	figures_changes: u64,
	figures_made: bool,

	// the build: its State, the fonts and faces the texts are measured and drawn with, the colours the draw needs
	state:     ^State,
	fonts:     ^font.State,
	face:      font.Font_Id,
	face_bold: font.Font_Id,
	accent:    Color,
	ui_scale:  f32,
	hover:     platform.Cursor,
	focus_due: bool,          // the canvas takes the keyboard at the first build
	canvas_key: Key,
	root_key:  Key,

	field:        Text_Edit,  // the text being typed
	field_typing: u32,        // the model's Typing count the field was filled for
	field_rect:   marks.Box,  // where the field was last built, window pixels
	field_shown:  bool,
	menu_due:     bool,       // a right press on a shape: its menu opens at menu_at in the next build
	menu_at:      Vec2,

	flat:        ^Mark_Flatten_Job,   // the flattening under way
	result:      []u8,                // heap: the flattened picture, until mark_editor_result takes it
	result_size: [2]int,
	pending:     Mark_Editor_Events,  // what the next build returns
	edits_seen:  u64,
}

// The editor shows rgba (straight RGBA8, w x h, copied) with nothing drawn on it. False: no picture (a size of 0, too
// few bytes).
mark_editor_init :: proc(e: ^Mark_Editor, rgba: []u8, w, h: int, o := Mark_Editor_Options{}) -> bool {
	e^ = {}
	if w <= 0 || h <= 0 || len(rgba) < w * h * 4 { return false }
	heap := runtime.heap_allocator()
	e.picture = new(Mark_Pixels, heap)
	e.picture^ = {rgba = make([]u8, w * h * 4, heap), refs = 1}
	copy(e.picture.rgba, rgba[:w * h * 4])
	e.size = {w, h}
	e.tools = o.tools != {} ? o.tools : marks.TOOLS_ALL
	tool := o.tool.? or_else .Arrow
	if tool not_in e.tools {
		for t in marks.Tool { if t in e.tools { tool = t; break } }
	}
	marks.init(&e.model, {w, h}, {scale = o.scale, tool = tool, styles = o.styles, pen = o.pen, measure = mark_measure, user = e})
	defaults := marks.COLORS
	append(&e.colors, ..(o.colors != nil ? o.colors : defaults[:]))
	e.hide_end_buttons = o.hide_end_buttons
	e.focus_due = true
	e.hover = .Crosshair
	return true
}

// Everything freed. A chore still running finishes on its own and frees what it holds.
mark_editor_destroy :: proc(e: ^Mark_Editor) {
	if j := e.flat; j != nil {
		j.editor = nil
		sync.atomic_store(&j.cancel, true)
	}
	for &f in e.filters {
		if f.job != nil {
			f.job.editor = nil
			sync.atomic_store(&f.job.cancel, true)
		}
		mark_filter_free(e, &f)
	}
	delete(e.filters)
	if e.texture != 0 && e.renderer != nil { render.destroy_texture(e.renderer, e.texture) }
	delete(e.figures)
	delete(e.ranges)
	virtual.arena_destroy(&e.figure_arena)
	marks.destroy(&e.model)
	delete(e.colors)
	text_edit_destroy(&e.field)
	delete(e.result, runtime.heap_allocator())
	if e.picture != nil { mark_pixels_release(e.picture) }
	e^ = {}
}

// Flattens the picture (a text being typed is kept first); the build that has it returns .Done. Nothing while a
// flattening is under way or a gesture goes on.
mark_editor_done :: proc(e: ^Mark_Editor) {
	m := &e.model
	if e.flat != nil || e.state == nil || e.picture == nil { return }
	if _, typing := m.mode.(marks.Typing); typing { marks.step(m, marks.Type_End{keep = true}) }
	if !marks.idle(m) { return }
	heap := runtime.heap_allocator()
	job := new(Mark_Flatten_Job, heap)
	job.editor = e
	job.pixels = e.picture
	sync.atomic_add(&e.picture.refs, 1)
	job.input = marks.flatten_input_make(m, e.picture.rgba, e.size, heap)
	// (the texts' outlines here: the fonts are this thread's)
	for &s, i in job.input.shapes {
		if s.kind != .Text { continue }
		append(&job.input.texts, marks.Flatten_Text{shape = i, glyphs = mark_text_path(e, &s, heap)})
	}
	work :: proc(data: rawptr) {
		job := (^Mark_Flatten_Job)(data)
		job.out, job.out_size = marks.flatten(&job.input, &job.cancel, runtime.heap_allocator())
	}
	done :: proc(data: rawptr, _: u64) {
		job := (^Mark_Flatten_Job)(data)
		if e := job.editor; e != nil {
			e.flat = nil
			if job.out != nil {
				delete(e.result, runtime.heap_allocator())
				e.result, e.result_size = job.out, job.out_size
				job.out = nil
				e.pending += {.Done}
			} else {
				e.pending += {.Failed}
			}
		}
		mark_flatten_free(job)
	}
	lost :: proc(data: rawptr) {
		job := (^Mark_Flatten_Job)(data)
		if e := job.editor; e != nil {
			e.flat = nil
			e.pending += {.Failed}
		}
		mark_flatten_free(job)
	}
	e.flat = job
	task(e.state, work, done, job, lost)
}

// The person gave up: the next build returns .Cancelled.
mark_editor_cancel :: proc(e: ^Mark_Editor) { e.pending += {.Cancelled} }

// Whether a flattening is under way (Done waits for it).
mark_editor_busy :: proc(e: ^Mark_Editor) -> bool { return e.flat != nil }

// The flattened picture of the last .Done, taken: straight RGBA8 of size, in the heap allocator (the caller frees it
// with delete(rgba, runtime.heap_allocator())). ok false: none.
mark_editor_result :: proc(e: ^Mark_Editor) -> (rgba: []u8, size: [2]int, ok: bool) {
	if e.result == nil { return }
	rgba, size, ok = e.result, e.result_size, true
	e.result, e.result_size = nil, {}
	return
}

@(private)
mark_pixels_release :: proc(p: ^Mark_Pixels) {
	if sync.atomic_sub(&p.refs, 1) != 1 { return }
	heap := runtime.heap_allocator()
	delete(p.rgba, heap)
	free(p, heap)
}

@(private)
mark_flatten_free :: proc(job: ^Mark_Flatten_Job) {
	heap := runtime.heap_allocator()
	marks.flatten_input_destroy(&job.input)
	delete(job.out, heap)
	mark_pixels_release(job.pixels)
	free(job, heap)
}

// The size of a line of text in the interface's face (the model's measure).
@(private)
mark_measure :: proc(user: rawptr, text: string, size: f32, bold: bool) -> marks.Vec {
	e := (^Mark_Editor)(user)
	if e.fonts == nil || e.face == 0 { return {f32(len(text)) * size * 0.5, size * 1.2} }
	face := mark_face(e, bold)
	m := font.metrics(e.fonts, face, size)
	return {font.text_width(e.fonts, face, size, text), m.line_height}
}

@(private)
mark_face :: proc(e: ^Mark_Editor, bold: bool) -> font.Font_Id {
	return bold && e.face_bold != 0 ? e.face_bold : e.face
}

// (glyph outlines are read within this part of an em, as draw's are)
@(private = "file")
MARK_OUTLINE_EM :: 1.0 / 1024

// A text's letters as a path in the picture's pixels, line by line from its top left, as the canvas draws them.
@(private)
mark_text_path :: proc(e: ^Mark_Editor, s: ^marks.Shape, allocator: runtime.Allocator) -> paint.Path {
	path := paint.Path{verbs = make([dynamic]paint.Verb, allocator), points = make([dynamic][2]f32, allocator)}
	if e.fonts == nil || e.face == 0 { return path }
	face := mark_face(e, s.style.bold)
	size := marks.text_px(&e.model.doc, s)
	m := font.metrics(e.fonts, face, size)
	y := s.a.y + m.ascent
	rest := s.text
	for {
		nl := strings.index_byte(rest, '\n')
		line := nl < 0 ? rest : rest[:nl]
		shaped := font.shape(e.fonts, face, size, line, {}, context.temp_allocator)
		for g in shaped.glyphs {
			o := font.Outline{quads = make([dynamic]font.Quad, context.temp_allocator), ends = make([dynamic]int, context.temp_allocator)}
			if !font.glyph_outline(e.fonts, g.face, g.id, MARK_OUTLINE_EM, &o) { continue }
			at := [2]f32{s.a.x + g.x, y + g.y}
			first := 0
			for last in o.ends {
				for q, k in o.quads[first:last] {
					// (outlines are in ems, y up; the picture is in pixels, y down)
					a := at + [2]f32{q.p[0].x, -q.p[0].y} * size
					b := at + [2]f32{q.p[1].x, -q.p[1].y} * size
					c := at + [2]f32{q.p[2].x, -q.p[2].y} * size
					if k == 0 { paint.move_to(&path, a.x, a.y) }
					if q.p[1] == q.p[2] { paint.line_to(&path, c.x, c.y) } else { paint.quad_to(&path, b.x, b.y, c.x, c.y) }
				}
				paint.close(&path)
				first = last
			}
		}
		if nl < 0 { break }
		rest = rest[nl + 1:]
		y += m.line_height
	}
	return path
}

////////////////////////////////
// The filters of the screen

// The mosaics and blurred copies the shapes need, asked when the shapes changed (not at each build).
@(private = "file")
mark_filters_want :: proc(e: ^Mark_Editor) {
	m := &e.model
	if m.changes == e.filters_changes { return }
	e.filters_changes = m.changes
	for &s in m.doc.shapes {
		#partial switch s.kind {
		case .Pixelate: mark_filter_ask(e, false, marks.pixel_cell(&m.doc, s.style))
		case .Blur:     mark_filter_ask(e, true, marks.blur_px(&m.doc, s.style))
		}
	}
}

@(private = "file")
mark_filter_ask :: proc(e: ^Mark_Editor, blur: bool, amount: int) {
	for f in e.filters { if f.blur == blur && f.amount == amount { return } }
	heap := runtime.heap_allocator()
	job := new(Mark_Filter_Job, heap)
	job^ = {editor = e, pixels = e.picture, size = e.size, blur = blur, amount = amount}
	sync.atomic_add(&e.picture.refs, 1)
	work :: proc(data: rawptr) {
		job := (^Mark_Filter_Job)(data)
		heap := runtime.heap_allocator()
		if job.blur {
			job.blurred = marks.blur_make(job.pixels.rgba, job.size, job.amount, &job.cancel, heap)
		} else {
			job.mosaic = marks.mosaic_make(job.pixels.rgba, job.size, job.amount, &job.cancel, heap)
		}
	}
	done :: proc(data: rawptr, _: u64) {
		job := (^Mark_Filter_Job)(data)
		if e := job.editor; e != nil {
			for &f in e.filters {
				if f.job != job { continue }
				f.job = nil
				f.mosaic, f.blurred = job.mosaic, job.blurred
				job.mosaic, job.blurred = {}, {}
			}
		}
		mark_filter_job_free(job)
	}
	lost :: proc(data: rawptr) {
		job := (^Mark_Filter_Job)(data)
		if e := job.editor; e != nil {
			for &f in e.filters { if f.job == job { f.job = nil } }
		}
		mark_filter_job_free(job)
	}
	append(&e.filters, Mark_Filter{blur = blur, amount = amount, job = job})
	task(e.state, work, done, job, lost)
}

@(private = "file")
mark_filter_job_free :: proc(job: ^Mark_Filter_Job) {
	heap := runtime.heap_allocator()
	marks.mosaic_destroy(&job.mosaic, heap)
	marks.blur_destroy(&job.blurred, heap)
	mark_pixels_release(job.pixels)
	free(job, heap)
}

@(private = "file")
mark_filter_free :: proc(e: ^Mark_Editor, f: ^Mark_Filter) {
	heap := runtime.heap_allocator()
	marks.mosaic_destroy(&f.mosaic, heap)
	marks.blur_destroy(&f.blurred, heap)
	if f.texture != 0 && e.renderer != nil { render.destroy_texture(e.renderer, f.texture) }
	f^ = {}
}

////////////////////////////////
// The build

// The tools' keys, labels and icons.
@(private)
mark_tool_command :: proc(t: marks.Tool) -> Command {
	// (static: a command's keys outlive the call)
	@(static, rodata) keys := [marks.Tool]Chord{
		.Select = {.V, {}}, .Rectangle = {.R, {}}, .Ellipse = {.E, {}}, .Arrow = {.A, {}}, .Line = {.L, {}}, .Pen = {.P, {}},
		.Highlighter = {.H, {}}, .Text = {.T, {}}, .Pixelate = {.B, {}}, .Blur = {.G, {}}, .Crop = {.C, {}},
	}
	c := Command{group = i18n.later("Tools"), keys = ([^]Chord)(&keys[t])[:1]}
	switch t {
	case .Select:      c.id, c.label, c.icon = "tool_select", i18n.later("Select and move"), lucide.MOUSE_POINTER_2
	case .Rectangle:   c.id, c.label, c.icon = "tool_rectangle", i18n.later("Rectangle"), lucide.SQUARE
	case .Ellipse:     c.id, c.label, c.icon = "tool_ellipse", i18n.later("Ellipse"), lucide.CIRCLE
	case .Arrow:       c.id, c.label, c.icon = "tool_arrow", i18n.later("Arrow"), lucide.ARROW_UP_RIGHT
	case .Line:        c.id, c.label, c.icon = "tool_line", i18n.later("Line"), lucide.SLASH
	case .Pen:         c.id, c.label, c.icon = "tool_pen", i18n.later("Pen"), lucide.PENCIL
	case .Highlighter: c.id, c.label, c.icon = "tool_highlighter", i18n.later("Highlighter"), lucide.HIGHLIGHTER
	case .Text:        c.id, c.label, c.icon = "tool_text", i18n.later("Text"), lucide.TYPE
	case .Pixelate:    c.id, c.label, c.icon = "tool_pixelate", i18n.later("Pixelate"), lucide.LAYOUT_GRID
	case .Blur:        c.id, c.label, c.icon = "tool_blur", i18n.later("Blur"), lucide.DROPLETS
	case .Crop:        c.id, c.label, c.icon = "tool_crop", i18n.later("Crop"), lucide.CROP
	}
	return c
}

// What the editor's keys and buttons do besides choosing a tool.
@(private)
Mark_Action :: enum u8 { Undo, Redo, Delete, Select_All, Duplicate, Front, Forward, Backward, Back, Remove_Crop, Zoom_In, Zoom_Out, Zoom_Fit, Zoom_Actual, Done, Cancel }

@(private)
mark_command :: proc(a: Mark_Action) -> Command {
	// (static: a command's keys outlive the call)
	@(static, rodata) keys := [13]Chord{
		{.Z, {.Ctrl}},                                   // 0: undo
		{.Z, {.Ctrl, .Shift}}, {.Y, {.Ctrl}},            // 1, 2: redo
		{.Delete, {}}, {.Backspace, {}},                 // 3, 4: delete
		{.A, {.Ctrl}}, {.D, {.Ctrl}},                    // 5: select all; 6: duplicate
		{.Home, {}}, {.Page_Up, {}}, {.Page_Down, {}}, {.End, {}},   // 7 to 10: the order
		{.N1, {.Ctrl}}, {.Return, {.Ctrl}},              // 11: actual size; 12: done
	}
	undo_keys, redo_keys, delete_keys, all_keys, duplicate_keys := keys[0:1], keys[1:3], keys[3:5], keys[5:6], keys[6:7]
	front_keys, forward_keys, backward_keys, back_keys := keys[7:8], keys[8:9], keys[9:10], keys[10:11]
	actual_keys, done_keys := keys[11:12], keys[12:13]
	edit, view := i18n.later("Edit"), i18n.later("View")
	switch a {
	case .Undo:        return {id = "undo", label = i18n.later("Undo"), group = edit, keys = undo_keys, icon = lucide.UNDO_2}
	case .Redo:        return {id = "redo", label = i18n.later("Redo"), group = edit, keys = redo_keys, icon = lucide.REDO_2}
	case .Delete:      return {id = "delete", label = i18n.later("Delete the selection"), group = edit, keys = delete_keys, icon = lucide.TRASH_2}
	case .Select_All:  return {id = "select_all", label = i18n.later("Select every mark"), group = edit, keys = all_keys, icon = lucide.BOX_SELECT}
	case .Duplicate:   return {id = "duplicate", label = i18n.later("Duplicate the selection"), group = edit, keys = duplicate_keys, icon = lucide.COPY}
	case .Front:       return {id = "bring_to_front", label = i18n.later("Bring to front"), group = edit, keys = front_keys, icon = lucide.BRING_TO_FRONT}
	case .Forward:     return {id = "bring_forward", label = i18n.later("Bring forward"), group = edit, keys = forward_keys, icon = lucide.ARROW_UP}
	case .Backward:    return {id = "send_backward", label = i18n.later("Send backward"), group = edit, keys = backward_keys, icon = lucide.ARROW_DOWN}
	case .Back:        return {id = "send_to_back", label = i18n.later("Send to back"), group = edit, keys = back_keys, icon = lucide.SEND_TO_BACK}
	case .Remove_Crop: return {id = "remove_crop", label = i18n.later("Remove the crop"), group = edit, icon = lucide.CROP}
	case .Zoom_In:     return {id = "zoom_in", label = i18n.later("Zoom in"), group = view, icon = lucide.ZOOM_IN}
	case .Zoom_Out:    return {id = "zoom_out", label = i18n.later("Zoom out"), group = view, icon = lucide.ZOOM_OUT}
	case .Zoom_Fit:    return {id = "zoom_fit", label = i18n.later("Fit the picture"), group = view, icon = lucide.MAXIMIZE}
	case .Zoom_Actual: return {id = "zoom_actual", label = i18n.later("Actual size"), group = view, keys = actual_keys, icon = lucide.SCAN}
	case .Done:        return {id = "done", label = i18n.later("Done"), group = edit, keys = done_keys, icon = lucide.CHECK}
	case .Cancel:      return {id = "cancel", label = i18n.later("Cancel"), group = edit, icon = lucide.X}
	}
	return {}
}

@(private)
mark_action_enabled :: proc(e: ^Mark_Editor, a: Mark_Action) -> bool {
	m := &e.model
	if e.flat != nil { return a == .Cancel }
	switch a {
	case .Undo:        return marks.can_undo(m)
	case .Redo:        return marks.can_redo(m)
	case .Delete, .Duplicate: return marks.idle(m) && marks.has_selection(m)
	case .Select_All:  return marks.idle(m) && len(m.doc.shapes) > 0
	case .Front:       return marks.can_order(m, .Front)
	case .Forward:     return marks.can_order(m, .Forward)
	case .Backward:    return marks.can_order(m, .Backward)
	case .Back:        return marks.can_order(m, .Back)
	case .Remove_Crop: return marks.idle(m) && m.doc.has_crop
	case .Zoom_In, .Zoom_Out, .Zoom_Fit, .Zoom_Actual, .Done, .Cancel: return true
	}
	return false
}

@(private)
mark_action :: proc(e: ^Mark_Editor, a: Mark_Action) {
	m := &e.model
	switch a {
	case .Undo:        marks.undo(m)
	case .Redo:        marks.redo(m)
	case .Delete:      marks.delete_selection(m)
	case .Select_All:  marks.select_all(m)
	case .Duplicate:   marks.duplicate(m)
	case .Front:       marks.order(m, .Front)
	case .Forward:     marks.order(m, .Forward)
	case .Backward:    marks.order(m, .Backward)
	case .Back:        marks.order(m, .Back)
	case .Remove_Crop: marks.crop_clear(m)
	case .Zoom_In:     marks.view_zoom_centre(m, marks.ZOOM_STEP)
	case .Zoom_Out:    marks.view_zoom_centre(m, 1 / marks.ZOOM_STEP)
	case .Zoom_Fit:    marks.view_fit(m); m.changes += 1
	case .Zoom_Actual: marks.view_zoom_to(m, 1)
	case .Done:        mark_editor_done(e)
	case .Cancel:      mark_editor_cancel(e)
	}
}

// A tool's side in the bars (ems).
@(private = "file") MARK_BAR_SIDE_EM :: 2.2
@(private = "file") MARK_MENU :: "mark_editor_menu"

// The editor in the box `next` gives (else it fills its parent): its tool bar, the canvas, its end bar. id: a name of
// the program's ("marks"), its boxes' ids under it. Returns what happened since the last build.
mark_editor :: proc(id: string, e: ^Mark_Editor) -> (events: Mark_Editor_Events) {
	s := gs()
	m := &e.model
	e.state = s
	events, e.pending = e.pending, {}
	if e.picture == nil { return }
	if e.fonts != s.fonts || e.face != text_face(.Interface) {
		// (the bold face of the interface's: warmed on a chore with the family, so no read of the disk here)
		e.fonts, e.face = s.fonts, text_face(.Interface)
		e.face_bold = e.fonts != nil && e.face != 0 ? font.styled_face(e.fonts, e.face, true, false) : 0
	}
	e.accent, e.ui_scale = color("accent"), scale()
	em := font_size()

	if !s.has_next || s.next_mod.width == nil { next_merge({width = fill()}) }
	if s.next_mod.height == nil { next_merge({height = fill()}) }
	if column(id = fmt.tprintf("###%s", id)) {
		e.root_key = parent_box().key
		mark_editor_keys(e, s)
		mark_tools_bar(e, id, em)
		next({width = fill(), height = fill(), cursor = e.hover, bg = color("well")})
		b := build_box({.Clickable, .Focusable, .Clip, .Draw_Background, .Scroll_Self, .Ctrl_Wheel, .Middle_Click}, "###mark_canvas")
		b.custom, b.custom_user = mark_editor_draw, e
		e.canvas_key = b.key
		if e.focus_due {
			set_focus(b.key)
			e.focus_due = false
		}
		sig := signal(b)
		marks.view_place(m, {b.rect.min, b.rect.max})   // (last build's layout: where the pointer was)
		mark_editor_input(e, s, b, sig)
		mark_end_bar(e, id, em)
	}
	mark_text_field(e, em)
	mark_shape_menu(e)
	mark_filters_want(e)
	if m.doc.edits != e.edits_seen {
		e.edits_seen = m.doc.edits
		events += {.Changed}
	}
	return
}

// The canvas's pointer: this build's presses, moves and releases in their order (a pen's every sample), and the wheel.
@(private = "file")
mark_editor_input :: proc(e: ^Mark_Editor, s: ^State, canvas: ^Box, sig: Signal) {
	m := &e.model
	if e.flat != nil { return }
	for p in s.pointer_samples {
		ev := p.event
		ms := ev.stamp._nsec != 0 ? f64(ev.stamp._nsec) / 1e6 : s.time_ms
		_, typing := m.mode.(marks.Typing)
		#partial switch ev.kind {
		case .Mouse_Press:
			if hit_test(s, ev.pos) != canvas.key { continue }
			button: marks.Button
			#partial switch ev.button {
			case .Left:   button = .Left
			case .Middle: button = .Middle
			case .Right:  button = .Right
			case:         continue
			}
			was_idle := marks.idle(m)
			took := marks.step(m, marks.Press{at = ev.pos, button = button, shift = .Shift in ev.mods, pan = key_held(.Space), double = button == .Left && s.press_double, time = ms, pressure = p.pressure, tilt = p.tilt})
			// (a right press that took a shape: its menu, in the next build)
			if took && button == .Right && was_idle && marks.has_selection(m) { e.menu_due, e.menu_at = true, ev.pos }
		case .Mouse_Move:
			if marks.idle(m) || typing { continue }
			marks.step(m, marks.Move{at = ev.pos, shift = .Shift in ev.mods, time = ms, pressure = p.pressure, tilt = p.tilt})
		case .Mouse_Release:
			if marks.idle(m) || typing { continue }
			button := marks.Button.Left
			if ev.button == .Middle { button = .Middle } else if ev.button == .Right { button = .Right }
			marks.step(m, marks.Release{at = ev.pos, button = button, shift = .Shift in ev.mods})
		}
	}
	if sig.scrolled != {} {
		marks.step(m, marks.Wheel{at = s.mouse, delta = sig.scrolled, zoom = .Ctrl in sig.mods, sideways = .Shift in sig.mods})
	}
	e.hover = mark_hover(e, s)
}

// The canvas's cursor where the pointer is: what a press there would do.
@(private = "file")
mark_hover :: proc(e: ^Mark_Editor, s: ^State) -> platform.Cursor {
	m := &e.model
	switch st in m.mode {
	case marks.Panning:  return .Grabbing
	case marks.Moving:   return .Move
	case marks.Resizing: return mark_handle_cursor(st.handle)
	case marks.Drawing, marks.Cropping, marks.Selecting: return .Crosshair
	case marks.Typing:   return .Text
	case marks.Idle:
	}
	if key_held(.Space) { return .Grab }
	p := marks.to_picture(m.view, s.mouse)
	tolerance := marks.HANDLE_PX / m.view.zoom
	if m.tool == .Crop {
		if h := marks.crop_handle_hit(&m.doc, p, tolerance); h != .None { return mark_handle_cursor(h) }
		return .Crosshair
	}
	if h := marks.handle_hit(&m.doc, p, tolerance); h != .None { return mark_handle_cursor(h) }
	hit := marks.hit(&m.doc, p, marks.HIT_PX / m.view.zoom)
	if hit >= 0 && (m.tool == .Select || m.doc.shapes[hit].picked) { return .Move }
	if hit >= 0 && m.doc.shapes[hit].kind == .Text && m.tool == .Text { return .Text }
	#partial switch m.tool {
	case .Select: return .Arrow
	case .Text:   return .Text
	}
	return .Crosshair
}

@(private = "file")
mark_handle_cursor :: proc(h: marks.Handle) -> platform.Cursor {
	switch h {
	case .Top_Left, .Bottom_Right, .Scale: return .Resize_NWSE
	case .Top_Right, .Bottom_Left:         return .Resize_NESW
	case .Top, .Bottom:                    return .Resize_V
	case .Left, .Right:                    return .Resize_H
	case .Start, .End:                     return .Crosshair
	case .None:
	}
	return .Arrow
}

// Whether the keyboard is the editor's: its focus is on the canvas or on a box inside the editor.
@(private = "file")
mark_keys_ours :: proc(e: ^Mark_Editor, s: ^State) -> bool {
	if s.focus_key == 0 { return false }
	for b := s.boxes[s.focus_key] or_else nil; b != nil; b = b.parent {
		if b.key == e.root_key { return true }
	}
	return false
}

// The editor's keys: the tools, the actions, the arrows that nudge, Escape. Not while a text is typed (its field has
// the keys), nor while a menu is open, nor when the keyboard is elsewhere in the program.
@(private = "file")
mark_editor_keys :: proc(e: ^Mark_Editor, s: ^State) {
	m := &e.model
	if !mark_keys_ours(e, s) || menu_any_open() || e.flat != nil { return }
	if _, typing := m.mode.(marks.Typing); typing { return }
	if key_press(.Escape) {
		if !marks.deselect(m) { mark_editor_cancel(e) }
		return
	}
	for t in marks.Tool {
		if t in e.tools && command_pressed(mark_tool_command(t)) { marks.tool_set(m, t); return }
	}
	for a in Mark_Action {
		if command_pressed(mark_command(a), !mark_action_enabled(e, a)) { mark_action(e, a); return }
	}
	if marks.idle(m) && marks.has_selection(m) {
		dirs := [4]platform.Key{.Left, .Right, .Up, .Down}
		steps := [4]marks.Vec{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}
		for k, i in dirs {
			if key_press(k) { marks.nudge(m, steps[i]) }
			if key_press(k, {.Shift}) { marks.nudge(m, steps[i] * marks.NUDGE_FAST) }
		}
	}
}

// The bar above the picture: the tools, then the properties of the tool or of the selection. It wraps onto more
// lines: nothing folds away.
@(private = "file")
mark_tools_bar :: proc(e: ^Mark_Editor, id: string, em: f32) {
	m := &e.model
	side := math.round(em * MARK_BAR_SIDE_EM)
	next({width = fill(), height = children_sum(), axis = .X})
	if row(id = "###mark_tools_row") {
		next({width = fill()})
		if toolbar(fmt.tprintf("%s_tools", id), {overflow = .Wrap, align = .Center}) {
			if toolbar_group("tools", {title = i18n.tr("Tools")}) {
				for t in marks.Tool {
					if t not_in e.tools { continue }
					if toolbar_tool(fmt.tprintf("mark_tool_%d", int(t)), {command = mark_tool_command(t), on = m.tool == t}) { marks.tool_set(m, t) }
				}
			}
			mark_properties(e, side)
		}
	}
}

// The properties a tool or the selection has: a change goes to the selection (one undo step) and to the tool.
@(private = "file")
mark_properties :: proc(e: ^Mark_Editor, side: f32) {
	m := &e.model
	style, props := marks.style_shown(m)
	if props == {} { return }
	was := style
	if toolbar_group("style", {title = i18n.tr("Style"), separator = true}) {
		if .Color in props {
			if toolbar_control("mark_color", {label = i18n.tr("Colour")}) {
				if row(cross = .Center, id = "###mark_colors") {
					for rgb, i in e.colors {
						if mark_swatch(fmt.tprintf("###mark_color_%d", i), rgb, style.color == rgb, side) { style.color = rgb }
					}
				}
			}
		}
		if .Fill in props {
			if toolbar_control("mark_fill", {label = i18n.tr("Fill"), labelled = true}) {
				if row(cross = .Center, id = "###mark_fills") {
					_, filled := marks.fill_of(style)
					next({width = px(side * 0.7), height = px(side * 0.7)})
					if button("mark_fill_none", icon = lucide.BAN, o = {tip = i18n.tr("No fill"), face = !filled ? .Toggled : .Ghost}).clicked { style.fill_color = 0 }
					for rgb, i in e.colors {
						if mark_swatch(fmt.tprintf("###mark_fill_%d", i), rgb, filled && style.fill_color & 0xFFFFFF == rgb, side) { style.fill_color = marks.OPAQUE | rgb }
					}
				}
			}
		}
		if .Width in props {
			if toolbar_control("mark_width", {label = i18n.tr("Width"), labelled = true}) {
				next({width = px(side * 4)})
				slider("###mark_width", &style.width, marks.WIDTH_MIN, marks.WIDTH_MAX, 1, "%.0f")
			}
		}
		if .Radius in props {
			if toolbar_control("mark_radius", {label = i18n.tr("Corners"), labelled = true}) {
				next({width = px(side * 4)})
				slider("###mark_radius", &style.radius, 0, marks.RADIUS_MAX, 1, "%.0f")
			}
		}
		if .Dash in props {
			if toolbar_control("mark_dash", {label = i18n.tr("Line")}) {
				i := int(style.dash)
				if segmented("###mark_dash", {i18n.tr("Solid"), i18n.tr("Dashed"), i18n.tr("Dotted")}, &i) { style.dash = marks.Dash(i) }
			}
		}
		if .Heads in props {
			if toolbar_control("mark_heads", {label = i18n.tr("Heads")}) {
				i := int(style.heads)
				if segmented("###mark_heads", {i18n.tr("None"), i18n.tr("End"), i18n.tr("Start"), i18n.tr("Both")}, &i) { style.heads = marks.Heads(i) }
			}
		}
		if .Text_Size in props {
			if toolbar_control("mark_text_size", {label = i18n.tr("Size")}) {
				sizes := marks.TEXT_SIZES
				mark_choices("###mark_text_size", sizes[:], &style.text_size)
			}
		}
		if .Bold in props {
			if toolbar_control("mark_bold", {label = i18n.tr("Bold")}) {
				next({width = px(side), height = px(side)})
				if button("mark_bold", icon = lucide.BOLD, o = {tip = i18n.tr("Bold"), face = style.bold ? .Toggled : .Ghost}).clicked { style.bold = !style.bold }
			}
		}
		if .Text_Look in props {
			if toolbar_control("mark_text_look", {label = i18n.tr("Look")}) {
				i := int(style.text_look)
				if segmented("###mark_text_look", {i18n.tr("Plain"), i18n.tr("Outline"), i18n.tr("Box")}, &i) { style.text_look = marks.Text_Look(i) }
			}
		}
		if .Pixel_Size in props {
			if toolbar_control("mark_pixel_size", {label = i18n.tr("Cells")}) {
				sizes := marks.PIXEL_SIZES
				mark_choices("###mark_pixel_size", sizes[:], &style.pixel_size)
			}
		}
		if .Blur_Radius in props {
			if toolbar_control("mark_blur_radius", {label = i18n.tr("Blur")}) {
				radii := marks.BLUR_RADII
				mark_choices("###mark_blur_radius", radii[:], &style.blur_radius)
			}
		}
	}
	if style != was { marks.style_set(m, style) }
}

// A choice among a few lengths, as a segmented control of their numbers.
@(private = "file")
mark_choices :: proc(id: string, values: []f32, value: ^f32) {
	labels := make([]string, len(values), context.temp_allocator)
	i := -1
	for v, k in values {
		labels[k] = fmt.tprintf("%.0f", v)
		if abs(v - value^) < 0.01 { i = k }
	}
	if segmented(id, labels, &i) && i >= 0 { value^ = values[i] }
}

// A colour to choose: a disc of it, ringed when it is the one chosen.
@(private = "file")
mark_swatch :: proc(id: string, rgb: u32, chosen: bool, side: f32) -> bool {
	d := math.round(side * 0.7)
	c := draw.hex(rgb << 8 | 0xFF)
	next({width = px(d), height = px(d), radius = d * 0.5, bg = c, border = chosen ? color("accent") : color("border")})
	b := build_box({.Clickable, .Draw_Background, .Draw_Border, .Fixed_Radius, .Draw_Hot_Effects}, id)
	return signal(b).clicked
}

// The bar under the picture: undo, redo, delete, the zoom, then Cancel and Done at its end.
@(private = "file")
mark_end_bar :: proc(e: ^Mark_Editor, id: string, em: f32) {
	next({width = fill(), height = children_sum(), axis = .X})
	if row(id = "###mark_end_row") {
		next({width = fill()})
		if toolbar(fmt.tprintf("%s_end", id), {overflow = .Wrap, align = .Center}) {
			if toolbar_group("edit", {title = i18n.tr("Edit")}) {
				for a in ([?]Mark_Action{.Undo, .Redo, .Delete, .Remove_Crop}) {
					if toolbar_tool(fmt.tprintf("mark_act_%d", int(a)), {command = mark_command(a), disabled = !mark_action_enabled(e, a)}) { mark_action(e, a) }
				}
			}
			if toolbar_group("zoom", {title = i18n.tr("Zoom"), separator = true}) {
				if toolbar_tool("mark_zoom_out", {command = mark_command(.Zoom_Out)}) { mark_action(e, .Zoom_Out) }
				if toolbar_tool("mark_zoom_actual", {label = fmt.tprintf("%d %%", int(math.round(e.model.view.zoom * 100))), words = true, tip = i18n.tr("Actual size"), command = mark_command(.Zoom_Actual)}) { mark_action(e, .Zoom_Actual) }
				if toolbar_tool("mark_zoom_in", {command = mark_command(.Zoom_In)}) { mark_action(e, .Zoom_In) }
				if toolbar_tool("mark_zoom_fit", {command = mark_command(.Zoom_Fit)}) { mark_action(e, .Zoom_Fit) }
			}
			if !e.hide_end_buttons {
				if toolbar_group("end", {pinned = true}) {
					if toolbar_tool("mark_cancel", {label = i18n.tr("Cancel"), words = true, command = mark_command(.Cancel), disabled = e.flat != nil}) { mark_action(e, .Cancel) }
					if toolbar_tool("mark_done", {label = i18n.tr("Done"), words = true, intent = .Primary, command = mark_command(.Done), disabled = e.flat != nil}) { mark_action(e, .Done) }
				}
			}
		}
	}
}

// The field of the text being typed, over the canvas where the text is.
@(private = "file")
mark_text_field :: proc(e: ^Mark_Editor, em: f32) {
	m := &e.model
	st, typing := m.mode.(marks.Typing)
	if !typing {
		if e.field_shown { set_focus(e.canvas_key) }
		e.field_shown = false
		return
	}
	sh := &m.doc.shapes[st.index]
	fresh := e.field_typing != m.typing
	if fresh {
		e.field_typing = m.typing
		text_edit_set(&e.field, sh.text)
		text_edit_select_all(&e.field)
	}
	size := max(marks.text_px(&m.doc, sh) * m.view.zoom, em * 0.8)
	face := mark_face(e, sh.style.bold)
	at := marks.to_window(m.view, sh.a)
	pad := math.round(em * SPACE_1)
	// (as wide as its longest line, as tall as its lines: the field grows with what is typed; a pass over the text
	// typed, not over the document)
	text := text_edit_string(&e.field)
	text_w: f32
	lines := 1
	rest := text
	for {
		nl := strings.index_byte(rest, '\n')
		if e.fonts != nil { text_w = max(text_w, font.text_width(e.fonts, face, size, nl < 0 ? rest : rest[:nl])) }
		if nl < 0 { break }
		rest = rest[nl + 1:]
		lines += 1
	}
	w := max(text_w + 2 * pad + size, em * 8)
	lh := e.fonts != nil ? math.round(font.metrics(e.fonts, face, size).line_height * 1.15) : size * 1.3
	hgt := f32(lines) * lh + 2 * pad
	e.field_rect = {at - pad, at - pad + {w, hgt}}
	next({fixed_x = at.x - pad, fixed_y = at.y - pad, width = px(w), height = px(hgt), font = face, font_size = size, text_pad = pad, fg = draw.hex(sh.style.color << 8 | 0xFF)})
	res := text_edit("###mark_text", &e.field, {placeholder = i18n.tr("Text"), own_menu = true, enter_commits = true, auto_height = true})
	if fresh || !e.field_shown { set_focus(res.box.key) }
	e.field_shown = true
	// (what was typed in the frame of Enter is kept with it)
	if res.changed { marks.step(m, marks.Typed{text = text_edit_string(&e.field)}) }
	if res.committed {
		marks.step(m, marks.Type_End{keep = true})
	} else if res.cancelled {
		marks.step(m, marks.Type_End{keep = false})
	}
}

// The menu of a shape (a right press on it): delete, duplicate, its place among the others.
@(private = "file")
mark_shape_menu :: proc(e: ^Mark_Editor) {
	if e.menu_due {
		e.menu_due = false
		menu_open(MARK_MENU, e.menu_at)
	}
	if menu(MARK_MENU) {
		for a in ([?]Mark_Action{.Duplicate, .Delete, .Front, .Forward, .Backward, .Back}) {
			c := mark_command(a)
			if menu_item(i18n.tr(c.label), command_shortcut(c), icon = c.icon, disabled = !mark_action_enabled(e, a)).clicked { mark_action(e, a) }
		}
	}
}