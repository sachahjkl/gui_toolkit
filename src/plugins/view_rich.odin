package tk_plugins

// The rich parts of a plugin's view (plugins.md, "As built: rich views", API level 6): icons by name, a text's tone,
// face and highlights, the badge. Each is a call of the toolkit's (ui.icon, ui.rich_paragraph, ui.pill); nothing here
// draws.

import "core:fmt"
import "core:math"
import "core:strings"
import ascii "../ascii"
import lucide "../lucide"
import plugin_api "../plugin_api"
import "../ui"

// The glyph of an icon's name ("": none, or a name the font does not have: the plugin's log said it).
@(private)
icon_glyph :: proc(name: plugin_api.Icon_Name) -> string {
	if name == "" { return "" }
	g, _ := lucide.glyph_of(string(name))
	return g
}

// An icon `glyph` in the box being built, a line of text high (not a share of a row as tall as what is in it). Its box's
// text is the glyph: what a test finds.
@(private)
icon_cell :: proc(glyph: string, fg: Maybe(ui.Color) = nil) {
	em := ui.font_size()
	ui.next({width = ui.px(math.round(em * 1.3)), height = ui.px(ui.dense(em * 2)), font = ui.lucide_icons(), text_align = .Center, text_pad = 0, fg = fg})
	ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###pv_icon", glyph))
}

// The colour of a tone, by the theme (false: plain, the box's own).
@(private)
tone_color :: proc(t: plugin_api.Tone) -> (ui.Color, bool) {
	switch t {
	case .plain: return {}, false
	case .info:  return ui.color("accent"), true
	case .good:  return ui.color("good text"), true
	case .warn:  return ui.color("warn text"), true
	case .bad:   return ui.color("bad text"), true
	case .weak:  return ui.color("weak text"), true
	}
	return {}, false
}

// A text node: its icon, its tone, its face, its highlights. `in_row`: as wide as its words, on one line.
@(private)
text_replay :: proc(r: ^View_Record, n: plugin_api.List_Node, t: ^plugin_api.Text_Node, box: string, in_row: bool) {
	tone := t.tone == .plain && t.weak ? plugin_api.Tone.weak : t.tone
	fg, toned := tone_color(tone)
	glyph := icon_glyph(t.icon)
	if glyph == "" {
		text_body(t, box, in_row, fg, toned)
		return
	}
	icon_fg: Maybe(ui.Color)
	if toned { icon_fg = fg }
	ui.next({width = in_row ? ui.children_sum() : ui.fill(), height = ui.children_sum()})
	if ui.row(.Center, id = fmt.tprintf("###pv_icon_row:%s", n.key)) {
		icon_cell(glyph, icon_fg)
		ui.space(ui.CONTROL_GAP)
		text_body(t, box, true, fg, toned)
	}
}

@(private)
text_body :: proc(t: ^plugin_api.Text_Node, box: string, in_row: bool, fg: ui.Color, toned: bool) {
	em := ui.font_size()
	m := ui.Style_Mod{}
	if toned { m.fg = fg }
	if t.mono { m.font = ui.mono_font() }
	if t.highlight != "" {
		m.width = in_row ? ui.text_size(0) : ui.fill()
		ui.next(m)
		_ = ui.rich_paragraph(box, highlight_runs(t.text, string(t.highlight), t.mono, fg, toned))
		return
	}
	if in_row {
		m.width, m.height = ui.text_size(0), ui.px(ui.dense(em * 2))
		ui.next(m)
		ui.label(fmt.tprintf("%s%s", t.text, box))
	} else {
		m.width = ui.fill()
		ui.next(m)
		ui.paragraph(fmt.tprintf("%s%s", t.text, box))
	}
}

// `text` as runs, each occurrence of one of `words` (joined by WORDS_SEPARATOR) a run in the find bar's colours: its
// background "find_match background", its letters "find_text". Case aside by an ASCII fold, as the find bar matches.
// Overlapping words: the earliest match wins, then the longest. Temp memory.
@(private)
highlight_runs :: proc(text, words: string, mono: bool, fg: ui.Color, toned: bool) -> []ui.Rich_Run {
	plain := ui.Rich_Style{}
	if mono { plain.font = ui.mono_font() }
	if toned { plain.color = fg }
	found := plain
	found.background = ui.color("find_match background")
	found.color = ui.color("find_text")
	runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
	folded := ascii.lower(text, context.temp_allocator)
	needles := make([dynamic]string, context.temp_allocator)
	for w in strings.split(words, plugin_api.WORDS_SEPARATOR, context.temp_allocator) {
		if w != "" { append(&needles, ascii.lower(w, context.temp_allocator)) }
	}
	start, i := 0, 0
	for i < len(folded) {
		best := 0
		for nd in needles {
			if len(nd) > best && strings.has_prefix(folded[i:], nd) { best = len(nd) }
		}
		if best == 0 { i += 1; continue }
		if i > start { append(&runs, ui.Rich_Run{text = text[start:i], style = plain}) }
		append(&runs, ui.Rich_Run{text = text[i:i + best], style = found})
		i += best
		start = i
	}
	if start < len(text) || len(runs) == 0 { append(&runs, ui.Rich_Run{text = text[start:], style = plain}) }
	return runs[:]
}

// A badge: the toolkit's pill in its tone's colour (plain: the weak text's).
@(private)
badge_replay :: proc(n: plugin_api.List_Node, b: ^plugin_api.Badge_Node) {
	c, toned := tone_color(b.tone)
	if !toned { c = ui.color("weak text") }
	ui.pill(fmt.tprintf("pv:%s", n.key), b.text, icon_glyph(b.icon), c)
}

// A field with a glyph at its start: the find bar's way, a well with the glyph and a bare field in it.
@(private)
field_with_icon :: proc(box, glyph: string, edit: ^ui.Line_Edit, o: ui.Line_Edit_Options, width: ui.Size) -> (res: ui.Edit_Result) {
	em := ui.font_size()
	ui.next({width = width, height = ui.px(ui.dense(em * 2.2)), cross = .Center})
	if ui.well(fmt.tprintf("%s_well", box), .X, flags = {.Focus_Within, .Draw_Focus_Ring}) {
		ui.space(ui.SPACE_2)
		if ui.tags("weak") { icon_cell(glyph) }
		ui.push_tags("bare")
		ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.3})
		res = ui.line_edit(box, edit, o)
		ui.pop_tags()
	}
	return
}
