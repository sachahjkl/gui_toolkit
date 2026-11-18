package film_tool

import "core:math"
import "core:strings"
import "core:unicode/utf8"
import host "gt:host"
import "gt:film"
import "gt:platform"
import "gt:render"
import syntax "gt:syntax"
import "gt:ui"

// An editor in a window of the film's own: a file's path and its state above, its text with line numbers and its
// language's colours, a terminal under it. What it shows is the film's: the text grows by `reveal` as the script asks, as
// if typed (the editor's own Enter would indent each line again: the film writes the buffer, the caret at its end), so
// the code shown is exactly the file that runs after.
Editor :: struct {
	shared:    host.Shared,
	host:      host.Host,
	shown:     ui.Theme_Shown,
	edit:      ui.Text_Edit,
	language:  syntax.Language,   // (ui.code_highlight's colouring is made at each build: it lives in the frame's memory)
	path:      string,
	saved:     bool,
	// the text to type, put at `at` in the buffer one character at a time from the clock `from`, `per_second`
	typing:    string,
	at:        int,
	typed:     int,
	from:      f64,
	per_second: f64,
	// the terminal's command, typed the same way, and what it said after
	command:   string,
	command_typed: int,
	command_from: f64,
	ran:       bool,
}

editor_open :: proc(path, text: string) -> ^Editor {
	e := new(Editor)
	e.path = path
	e.saved = true
	if !host.host_open(&e.host, &e.shared, {title = "film editor", size = WINDOW_LOGICAL, headless = true, headless_gpu = true}, editor_build, e) {
		free(e)
		return nil
	}
	platform.set_offscreen_dpi(e.host.win, DPI_STAGED)
	e.host.params = proc(h: ^host.Host, p: ^ui.Build_Params) {
		e := (^Editor)(h.user)
		sh := (^host.Shared)(&e.shared)
		if ui.theme_show(&sh.theme, ui.THEMES[:], {name = "Midnight", mode = .Dark, finish = .Machined, glow = 1}, &e.shown, render.blend_space(&sh.r)) {
			h.background = ui.theme_lookup(&sh.theme, {}, "background")
		}
		p.base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = sh.font, font_size = 15, text_pad = 6, cursor = .Arrow}
	}
	e.language, _ = syntax.language("js")
	ui.text_edit_set(&e.edit, shown_text(text, context.temp_allocator))
	e.edit.cursor, e.edit.mark = 0, 0
	return e
}

editor_close :: proc(e: ^Editor) {
	ui.text_edit_destroy(&e.edit)
	host.host_close(&e.host)
	free(e)
}

editor_app :: proc(e: ^Editor) -> film.App {
	return {win = e.host.win, state = &e.host.state, renderer = &e.shared.r, user = &e.host,
		frame = proc(user: rawptr) { host.host_frame((^host.Host)(user)) }}
}

// From the next frame, `text` comes in at byte `at` of the buffer, `per_second` characters a second.
editor_type :: proc(e: ^Editor, at: int, text: string, per_second := 40.0) {
	e.typing, e.at, e.typed, e.from, e.per_second = shown_text(text, context.allocator), at, 0, -1, per_second
	e.saved = false
}

// The terminal's command, typed at a person's pace from the next frame.
editor_command :: proc(e: ^Editor, command: string) {
	e.command, e.command_typed, e.command_from = command, 0, -1
}

// The bytes the editor shows before `marker` in the file (where the typing goes).
editor_offset :: proc(text, marker: string) -> int {
	i := strings.index(text, marker)
	return i < 0 ? len(text) : len(shown_text(text[:i], context.temp_allocator))
}

// A tab as two spaces: the editor's width for it, and the film's.
@(private = "file")
shown_text :: proc(text: string, allocator := context.allocator) -> string {
	s, _ := strings.replace_all(text, "\t", "  ", allocator)
	return s
}

@(private = "file")
editor_build :: proc(h: ^host.Host, size: host.Vec2) {
	e := (^Editor)(h.user)
	em := ui.font_size()
	now := ui.now_ms() / 1000
	// the typing: each character at its time, the caret after it
	if e.typed < len(e.typing) {
		if e.from < 0 { e.from = now }
		want := min(int(math.floor((now - e.from) * e.per_second)) + 1, len(e.typing))
		for e.typed < want {
			_, w := utf8.decode_rune_in_string(e.typing[e.typed:])
			inject_at_elems(&e.edit.buf, e.at + e.typed, ..transmute([]u8)e.typing[e.typed:][:w])
			e.typed += w
		}
		e.edit.cursor, e.edit.mark = e.at + e.typed, e.at + e.typed
		h.state.anim_busy = true
	}
	if e.command_typed < len(e.command) {
		if e.command_from < 0 { e.command_from = now }
		e.command_typed = min(int(math.floor((now - e.command_from) * 16)) + 1, len(e.command))
		h.state.anim_busy = true
	}
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(flags = {.Draw_Background}, id = "###editor_window") {
		// the file's path, its language, its state
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.4)), axis = .X, cross = .Center})
		if ui.row(id = "###editor_bar") {
			ui.space(ui.PAGE_MARGIN)
			ui.label(strings.concatenate({e.path, "###editor_path"}, context.temp_allocator))
			ui.space(ui.CONTROL_GAP)
			if ui.tags("weak") { ui.label(strings.concatenate({e.saved ? "saved" : "edited", "###editor_state"}, context.temp_allocator)) }
			ui.spacer(ui.fill())
			if ui.tags("weak") { ui.label("JavaScript###editor_language") }
			ui.space(ui.PAGE_MARGIN)
		}
		ui.next({width = ui.fill(), height = ui.fill(), font = ui.mono_font(), font_size = math.round(em * 0.95)})
		_ = ui.text_edit("###editor_text", &e.edit, {line_numbers = true, highlight = ui.code_highlight(e.language)})
		// the terminal: a prompt and the command
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 3.2)), axis = .X, cross = .Center, font = ui.mono_font()})
		if ui.row(id = "###editor_terminal") {
			ui.space(ui.PAGE_MARGIN)
			if ui.tags("weak") { ui.label("$###editor_prompt") }
			ui.space(ui.CONTROL_GAP)
			ui.label(strings.concatenate({e.command[:e.command_typed], "###editor_command"}, context.temp_allocator))
			if e.command_typed < len(e.command) || int(now * 2) % 2 == 0 {
				ui.next({width = ui.px(math.round(em * 0.55)), height = ui.px(math.round(em * 1.1)), bg = ui.color("accent")})
				ui.build_box({.Draw_Background}, "###editor_cursor")
			}
			h.state.anim_busy = true   // (the cursor blinks)
		}
	}
}
