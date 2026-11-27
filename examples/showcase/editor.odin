package showcase

// The editor's scene: a dock (ui.dock_begin) split in stacks of tabs, the files at the left, two files of code and an
// outline at the right, the find open over the code shown: its matches lit over the code's own colours. What the dock's
// tabs and the find's matches look like in a program's own layout (tk screenshots, the before and after of a look).

import "core:fmt"
import "core:math"
import "gt:syntax"
import "gt:ui"

@(private = "file") EDITOR_FILES :: 1
@(private = "file") EDITOR_WORDS :: 2
@(private = "file") EDITOR_NOTES :: 3
@(private = "file") EDITOR_OUTLINE :: 4
@(private = "file", rodata) EDITOR_TITLES := [?]string{"", "Files", "words.odin", "notes.md", "Outline"}

@(private = "file")
EDITOR_CODE :: `package words

import "core:strings"

// A word and how many times it came.
Count :: struct {
	word:  string,
	times: int,
}

// The words of a text, counted (letters only, small).
count_words :: proc(text: string) -> map[string]int {
	counts := make(map[string]int)
	for field in strings.fields(text) {
		word := strings.to_lower(field)
		if len(word) == 0 { continue }
		counts[word] += 1   // one more of this word
	}
	return counts
}

// The words counted most, at most "n" of them.
top :: proc(counts: map[string]int, n: int) -> []Count {
	list := make([dynamic]Count)
	for word, times in counts { append(&list, Count{word, times}) }
	return list[:min(n, len(list))]
}`

@(private = "file")
EDITOR_NOTES_TEXT :: "Count the words of a text, then keep the most frequent."

// The scene's dock: made at its first build.
Editor :: struct {
	dock:  ui.Dock,
	ready: bool,
	found: bool,   // the find was opened over the code (once)
}

editor_build :: proc(app: ^App, em: f32) {
	e := &app.editor
	if !e.ready {
		e.ready = true
		d := &e.dock
		ui.dock_init(d)
		ui.dock_add(d, EDITOR_FILES, ui.dock_with(d, EDITOR_FILES))
		ui.dock_add(d, EDITOR_WORDS, ui.dock_beside(d, EDITOR_FILES, .Right))
		ui.dock_add(d, EDITOR_NOTES, ui.dock_with(d, EDITOR_WORDS))
		ui.dock_add(d, EDITOR_OUTLINE, ui.dock_beside(d, EDITOR_WORDS, .Right))
		ui.dock_activate(d, EDITOR_WORDS)
		// (the files a sidebar's width, the outline a narrow column)
		if leaf := ui.dock_leaf_of(d, EDITOR_FILES); leaf != ui.DOCK_NONE { ui.dock_set_split(d, d.nodes[leaf].parent, 0.22, false) }
		if leaf := ui.dock_leaf_of(d, EDITOR_OUTLINE); leaf != ui.DOCK_NONE { ui.dock_set_split(d, d.nodes[leaf].parent, 0.7, false) }
	}
	ui.dock_begin(&e.dock, "###editor_dock", {
		title = proc(user: rawptr, id: u32) -> string { return EDITOR_TITLES[id] },
		user = app, close_buttons = true,
	})
	if ui.dock_panel(&e.dock, EDITOR_FILES) {
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###files") {
			for name, i in EDITOR_TITLES[EDITOR_WORDS:EDITOR_OUTLINE] {
				ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.8)), text_pad = editor_pad(em)})
				ui.label(fmt.tprintf("%s###file_%d", name, i))
			}
		}
	}
	if ui.dock_panel(&e.dock, EDITOR_WORDS) { editor_code(e, em) }
	if ui.dock_panel(&e.dock, EDITOR_NOTES) {
		ui.next({width = ui.fill(), text_pad = editor_pad(em)})
		ui.paragraph(EDITOR_NOTES_TEXT)
	}
	if ui.dock_panel(&e.dock, EDITOR_OUTLINE) {
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###outline") {
			for name, i in ([?]string{"Count", "count_words", "top"}) {
				ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.8)), text_pad = editor_pad(em)})
				ui.label(fmt.tprintf("%s###sym_%d", name, i))
			}
		}
	}
	ui.dock_end(&e.dock)
}

// The panels' content starts where their tab's words start.
@(private = "file")
editor_pad :: proc(em: f32) -> f32 { return ui.dock_content_inset() }

// The code, coloured by its language, in a view the find searches (box mode: all of it is built).
@(private = "file")
editor_code :: proc(e: ^Editor, em: f32) {
	runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
	lang, _ := syntax.language("odin")
	ui.code_runs(EDITOR_CODE, lang, {font = ui.mono_font()}, &runs)
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###code_view") {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###code") {
			ui.spacer(ui.px(math.round(em * 3)))   // (room for the find's bar over the first lines)
			ui.next({width = ui.fill(), text_pad = editor_pad(em)})
			ui.rich_paragraph("###code_text", runs[:], version = 1)
		}
	}
	view := ui.prev_box("###code_view")
	if view != nil && !e.found { ui.find_open(ui.current_state(), view.key, "count"); e.found = true }
	ui.find_bar(view)
}
