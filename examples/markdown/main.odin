// gui_toolkit example: a small Markdown viewer on rich_paragraph (headings, paragraphs, lists, **bold**, *italic*,
// `code`, ~~strike~~, [links](url)), the way a chat app shows a reply. Links show a toast; the text is selectable.
package markdown

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"
import "../../ui"

SAMPLE :: `# Rich text in gui_toolkit

A **rich paragraph** mixes *styles*, ` + "`inline code`" + `, ~~mistakes~~ and [links](https://example.org) in one block of text that wraps as **one** paragraph: the line breaks come from the font backend (UAX #14) on the *whole* text, so a word made of **two**runs is never cut between them.

## Lists

- Bold and italic take the family's faces, or simulated ones.
- Inline code takes the mono font and a tinted background.
- Links answer the pointer and the keyboard: press Tab, then Enter.

## Long text

The layout of a paragraph is kept by content: this one, built every frame, is laid out once. Narrow the window to see it wrap, and select text with the mouse to copy it.
`

App :: struct {
	win:      ^platform.Window,
	r:        render.Renderer,
	fonts:    font.State,
	dc:       draw.Context,
	ui_state: ui.State,
	theme:    ui.Theme,
	ui_font, mono, bold: font.Font_Id,
	frames:   int,
	last:     time.Tick,
}

the_app: ^App

// Inline Markdown of one block into runs (temp memory): **bold**, *italic*, `code`, ~~strike~~, [text](url).
inline_runs :: proc(text: string, base: ui.Rich_Style, out: ^[dynamic]ui.Rich_Run) {
	st := base
	i, start := 0, 0
	flush :: proc(out: ^[dynamic]ui.Rich_Run, s: string, st: ui.Rich_Style) { if s != "" { append(out, ui.Rich_Run{text = s, style = st}) } }
	for i < len(text) {
		switch {
		case strings.has_prefix(text[i:], "**"):
			flush(out, text[start:i], st); st.bold = !st.bold; i += 2; start = i
		case strings.has_prefix(text[i:], "~~"):
			flush(out, text[start:i], st); st.strike = !st.strike; i += 2; start = i
		case text[i] == '*':
			flush(out, text[start:i], st); st.italic = !st.italic; i += 1; start = i
		case text[i] == '`':
			flush(out, text[start:i], st)
			e := strings.index_byte(text[i + 1:], '`')
			if e < 0 { e = len(text) - i - 1 }
			c := st
			c.code = true
			flush(out, text[i + 1:i + 1 + e], c)
			i += e + 2; start = min(i, len(text)); i = start
		case text[i] == '[':
			close_b := strings.index(text[i:], "](")
			close_p := close_b >= 0 ? strings.index_byte(text[i + close_b:], ')') : -1
			if close_b < 0 || close_p < 0 { i += 1; continue }
			flush(out, text[start:i], st)
			l := st
			l.link = text[i + close_b + 2:i + close_b + close_p]
			flush(out, text[i + 1:i + close_b], l)
			i += close_b + close_p + 1; start = i
		case:
			i += 1
		}
	}
	flush(out, text[start:], st)
}

build_ui :: proc(app: ^App) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	page := ui.build_box({.Draw_Background}, "###page")
	if !ui.parent(page) { return }
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###doc") {
		ui.spacer(ui.px(em))
		text := SAMPLE
		n := 0
		for block in strings.split_iterator(&text, "\n\n") {
			b := strings.trim_space(block)
			if b == "" { continue }
			runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
			size := em
			style := ui.Rich_Style{}
			if strings.has_prefix(b, "## ") { b = b[3:]; size = math.round(em * 1.3); style.bold = true }
			else if strings.has_prefix(b, "# ") { b = b[2:]; size = math.round(em * 1.7); style.bold = true }
			lines := b
			first := true
			for line in strings.split_lines_iterator(&lines) {
				l := line
				if !first { append(&runs, ui.Rich_Run{text = "\n"}) }
				first = false
				if strings.has_prefix(l, "- ") { append(&runs, ui.Rich_Run{text = "•  "}); l = l[2:] }
				inline_runs(l, style, &runs)
			}
			// selectable: a drag selects across the blocks, Ctrl+C copies, double / triple click: a word / a block
			ui.next({width = ui.fill(), font_size = size, flags = {.Selectable}})
			res := ui.rich_paragraph(fmt.tprintf("###b%d", n), runs[:])
			if res.link_clicked >= 0 { ui.toast(.Info, "Link: %s", res.link) }
			ui.spacer(ui.px(em * 0.6))
			n += 1
		}
		// what an app reads of the selection (a chat's "quote" or "copy" action)
		if ui.has_selection(&app.ui_state) {
			sel := ui.selected_text(&app.ui_state, context.temp_allocator)
			if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.px(em * 2)})
				ui.label(fmt.tprintf("Selected: %d characters (Ctrl+C copies)", strings.rune_count(sel)))
			}
		}
	}
}

clip_get :: proc() -> string { return platform.get_clipboard(the_app.win, context.temp_allocator) }
clip_set :: proc(text: string) { platform.set_clipboard(the_app.win, text) }

frame :: proc(app: ^App) {
	render.wait_for_frame(&app.r)
	events := platform.poll_events(app.win, false)
	if len(events) > 0 { app.frames = max(app.frames, 4) }
	render.resize(&app.r, app.win.size)
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}
	now := time.tick_now()
	dt := clamp(f32(time.duration_seconds(time.tick_diff(app.last, now))), 0.0005, 0.1)
	app.last = now
	ui.apply_palette(&app.theme, ui.PALETTE_MIDNIGHT)
	ui.begin_build(&app.ui_state, {
		window_size = size, events = events, dt = dt, animations = true, dpi_scale = app.win.dpi_scale,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(34)}, font = app.ui_font, font_size = 16, text_pad = 8},
		clipboard_get = clip_get, clipboard_set = clip_set,
	})
	build_ui(app)
	ui.end_build()
	platform.set_cursor(app.win, ui.cursor(&app.ui_state))
	if ui.needs_frame(&app.ui_state) { app.frames = max(app.frames, 2) }
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, {0, 0, 0, 1})
	ui.draw_tree(&app.ui_state, &app.dc)
	draw.end_frame(&app.dc)
	render.frame_end(&app.r)
	free_all(context.temp_allocator)
}

main :: proc() {
	app := new(App)
	the_app = app
	font.init(&app.fonts)
	app.win = platform.open_window("gui_toolkit markdown", {720, 800})
	if !render.init(&app.r, app.win.hwnd, app.win.size) { fmt.eprintln("renderer init failed"); return }
	ok: bool
	app.ui_font, ok, _ = font.load_system_or_embedded(&app.fonts, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	if !ok { fmt.eprintln("cannot load a UI font"); return }
	app.mono, _, _ = font.load_system_or_embedded(&app.fonts, platform.system_font_path("consola.ttf"), font.FALLBACK_MONO_DATA)
	draw.init(&app.dc, &app.r, &app.fonts)
	ui.init(&app.ui_state, &app.fonts, &app.theme)
	app.ui_state.mono_font = app.mono
	// the family's real bold and italic faces (else they are simulated)
	if bold, bok := font.load_system(&app.fonts, "Segoe UI", 700); bok {
		italic, _ := font.load_system(&app.fonts, "Segoe UI", 400, .Italic)
		bi, _ := font.load_system(&app.fonts, "Segoe UI", 700, .Italic)
		ui.rich_set_faces(&app.ui_state, app.ui_font, bold, italic, bi)
	}
	app.last = time.tick_now()
	app.frames = 4
	app.win.user = app
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user)) }
	platform.show_window(app.win)
	for !platform.is_closed(app.win) {
		if app.frames == 0 && !ui.needs_frame(&app.ui_state) { platform.wait_event(app.win, ui.wake_ms(&app.ui_state)) }
		frame(app)
		if app.frames > 0 { app.frames -= 1 }
	}
}
