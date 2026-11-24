package markdown

// Mermaid diagrams in Markdown (src/md/features/markdown-diagrams.md): a closed ```mermaid block drawn as its diagram,
// laid out on a chore by the procedure the program gives (mermaid.layout), kept by its text and the theme's lightness.
//
//	app.diagrams = markdown.Diagrams{layout = mermaid.layout}     // the program keeps it: it does not move once used
//	markdown.view(&doc, "note", text, {diagrams = &app.diagrams})
//	markdown.diagrams_destroy(&app.diagrams)                      // layouts still running are dropped when they answer
//
// The package does not import gt:mermaid: a program that shows Markdown links the native library only when it gives a
// layout.

import "base:runtime"
import "core:hash"
import "core:math"
import "core:strings"
import "core:sync"
import "../ascii"
import "../draw"
import "../font"
import svg "../svg"
import "../ui"

// The diagrams kept when Diagrams.kept is 0: the one drawn least recently goes first.
DIAGRAMS_KEPT :: 32
// Mermaid draws its text at 14 px: at the text's size divided by this, a diagram's text is as large as the text around it.
DIAGRAM_FONT_PX :: 14

// A diagram's text to a drawing, on a chore (never the interface's thread). why: "" for a diagram, else why it is none
// (the caller copies it: it may be in the chore's temporary memory).
Diagram_Layout :: #type proc(text: string, dark: bool) -> (doc: svg.Document, why: string)

// A diagram laid out, or being laid out.
Diagram :: struct {
	doc:     svg.Document,
	why:     string,   // not a diagram: why (owned; "": it is one)
	pending: bool,     // its layout runs: no drawing yet
	used:    u64,      // the build that last asked for it
}

Diagrams :: struct {
	layout:  Diagram_Layout,   // nil: no diagram is drawn, every block shows its text
	kept:    int,              // the most kept (0: DIAGRAMS_KEPT)
	// (each on the heap: a box draws its drawing after the build, and the map moves its values when it grows)
	entries: map[u64]^Diagram,
	link:    ^Diagrams_Link,   // what the layouts running answer to
}

// What a layout's answer finds: the cache, or nil once it is destroyed. The tasks and the cache each hold a reference;
// the last one frees it.
@(private)
Diagrams_Link :: struct {
	owner: ^Diagrams,   // (the interface's thread)
	refs:  int,         // (atomic)
}

@(private = "file")
Diagram_Job :: struct {
	link:   ^Diagrams_Link,
	key:    u64,
	text:   string,   // (owned)
	dark:   bool,
	layout: Diagram_Layout,
	doc:    svg.Document,
	why:    string,   // (owned)
}

// Frees the diagrams. A layout that answers later frees its drawing and does nothing else.
diagrams_destroy :: proc(ds: ^Diagrams) {
	for _, d in ds.entries { diagram_free(d) }
	delete(ds.entries)
	if ds.link != nil {
		ds.link.owner = nil
		link_release(ds.link)
	}
	ds^ = {layout = ds.layout, kept = ds.kept}
}

// "mermaid" after a fence, in any case, with or without words after it.
is_mermaid :: proc(lang: string) -> bool {
	word := lang
	if i := strings.index_any(word, " \t{"); i >= 0 { word = word[:i] }
	return ascii.equal_fold(word, "mermaid")
}

// The diagram of `text` in the lightness of the theme being built: laid out (its doc, or its `why`), or pending, its
// layout asked of the chores. nil: no layout, or outside a build. On the interface's thread, during a build.
diagram_of :: proc(ds: ^Diagrams, text: string) -> ^Diagram {
	s := ui.current_state()
	if ds.layout == nil || s == nil { return nil }
	dark := s.theme == nil || s.theme.dark
	key := hash.fnv64a(transmute([]u8)text) ~ (dark ? HASH_MIX_A : 0)
	if d, ok := ds.entries[key]; ok {
		d.used = s.build_index
		return d
	}
	kept := ds.kept > 0 ? ds.kept : DIAGRAMS_KEPT
	for len(ds.entries) >= kept && diagrams_trim(ds, s.build_index) {}
	if ds.link == nil {
		ds.link = new(Diagrams_Link, runtime.heap_allocator())
		ds.link^ = {owner = ds, refs = 1}
	}
	heap := runtime.heap_allocator()
	if ds.entries == nil { ds.entries = make(map[u64]^Diagram, heap) }
	d := new(Diagram, heap)
	d^ = {pending = true, used = s.build_index}
	ds.entries[key] = d
	sync.atomic_add(&ds.link.refs, 1)
	job := new(Diagram_Job, heap)
	job^ = {link = ds.link, key = key, text = strings.clone(text, heap), dark = dark, layout = ds.layout}
	ui.task(s, job_work, job_done, job, job_lost)
	return d
}

// A fenced block of language mermaid: its diagram once laid out, else its text (code_block). For a program's own
// View_Options.code; view calls it when View_Options.diagrams is set and View_Options.code is nil.
diagram_block :: proc(id: string, c: Code, o: View_Options) {
	d: ^Diagram
	if o.diagrams != nil && c.closed { d = diagram_of(o.diagrams, c.text) }
	if d == nil || d.pending || d.why != "" {
		code_block(id, c, o)
		return
	}
	em := ui.font_size()
	// (the column's width as laid out last frame: the box keeps its key; at the first frame, the text's size alone)
	col := ui.parent_box()
	avail := col.rect.max.x - col.rect.min.x - 2 * col.text_pad
	scale := em / DIAGRAM_FONT_PX
	if avail > 0 { scale = min(scale, max(avail, em * 8) / max(d.doc.view[2], 1)) }
	sz := svg.size(&d.doc, scale)
	ui.next({width = ui.fill(), height = ui.px(math.ceil(sz.y)), axis = .X})
	if ui.row(id = strings.concatenate({id, "_row"}, context.temp_allocator)) {
		ui.spacer(ui.fill())
		dd := ui.frame_new(Diagram_Draw)
		face := o.prose != 0 ? o.prose : ui.text_face(.Prose)
		if face == 0 { face = ui.top_style().font }
		dd^ = {doc = &d.doc, scale = scale, regular = face, bold = ui.styled_face(face, true, false)}
		ui.a11y({role = .Image, name = "diagram"})
		ui.next({width = ui.px(math.ceil(sz.x)), height = ui.px(math.ceil(sz.y))})
		ui.custom(strings.concatenate({id, "_diagram"}, context.temp_allocator), diagram_draw, dd)
		ui.spacer(ui.fill())
	}
}

// A diagram in a preview: fitted to the box, then zoomed and moved (ui.preview). `face` 0: the prose face. The diagram's
// unit at the zoom 100 % is its size beside the text (DIAGRAM_FONT_PX).
diagram_view :: proc(id: string, p: ^ui.Preview, d: ^Diagram, face: font.Font_Id = 0, o := ui.Preview_Options{}) -> ui.Preview_Result {
	f := face != 0 ? face : ui.text_face(.Prose)
	if f == 0 { f = ui.top_style().font }
	dd := ui.frame_new(Diagram_Draw)
	dd^ = {doc = &d.doc, regular = f, bold = ui.styled_face(f, true, false)}
	content := [2]f32{d.doc.view[2], d.doc.view[3]} * (ui.font_size() / DIAGRAM_FONT_PX)
	return ui.preview(id, p, content, proc(dc: ^draw.Context, dst: ui.Rect, user: rawptr) {
		dd := (^Diagram_Draw)(user)
		svg.draw_doc(dc, dd.doc, dst.min, (dst.max.x - dst.min.x) / max(dd.doc.view[2], 1), {regular = dd.regular, bold = dd.bold})
	}, dd, o)
}

@(private = "file")
Diagram_Draw :: struct {
	doc:           ^svg.Document,
	scale:         f32,
	regular, bold: font.Font_Id,
}

@(private = "file")
diagram_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	dd := (^Diagram_Draw)(user)
	svg.draw_doc(dc, dd.doc, b.rect.min, dd.scale, {regular = dd.regular, bold = dd.bold})
}

@(private = "file")
diagram_free :: proc(d: ^Diagram) {
	svg.destroy(&d.doc)
	delete(d.why, runtime.heap_allocator())
	free(d, runtime.heap_allocator())
}

// The entry drawn least recently goes. A pending one stays (its task writes it), and so does one this build asked for
// (its box draws it after the build): more than the bound are then kept for a while. false: none can go.
@(private = "file")
diagrams_trim :: proc(ds: ^Diagrams, build: u64) -> bool {
	oldest: ^Diagram
	oldest_key: u64
	for k, d in ds.entries {
		if d.pending || d.used == build { continue }
		if oldest == nil || d.used < oldest.used { oldest, oldest_key = d, k }
	}
	if oldest == nil { return false }
	diagram_free(oldest)
	delete_key(&ds.entries, oldest_key)
	return true
}

@(private = "file")
link_release :: proc(l: ^Diagrams_Link) {
	if sync.atomic_sub(&l.refs, 1) == 1 { free(l, runtime.heap_allocator()) }
}

// (a chore)
@(private = "file")
job_work :: proc(data: rawptr) {
	job := (^Diagram_Job)(data)
	doc, why := job.layout(job.text, job.dark)
	job.doc, job.why = doc, strings.clone(why, runtime.heap_allocator())
}

// (the interface's thread, at a build)
@(private = "file")
job_done :: proc(data: rawptr, _: u64) {
	job := (^Diagram_Job)(data)
	heap := runtime.heap_allocator()
	ds := job.link.owner
	d: ^Diagram
	if ds != nil { d = ds.entries[job.key] or_else nil }
	if d != nil && d.pending {
		d.doc, d.why, d.pending = job.doc, job.why, false
	} else {
		svg.destroy(&job.doc)
		delete(job.why, heap)
	}
	link_release(job.link)
	delete(job.text, heap)
	free(job, heap)
}

// (whichever thread found that the answer will never run)
@(private = "file")
job_lost :: proc(data: rawptr) {
	job := (^Diagram_Job)(data)
	heap := runtime.heap_allocator()
	svg.destroy(&job.doc)
	delete(job.why, heap)
	link_release(job.link)
	delete(job.text, heap)
	free(job, heap)
}
