package tk_prefs_page

// The palette's run mode, prefs_page's part (src/md/features/everything-palette.md, "Layer 2, as built" and "Layer 4"):
// the runners of the settings source and of the commands' forms (ui.Palette_Runner). Both draw a value's control from
// the one table (control_of) and write through `apply`, as the page does; the palette owns the levels and the keys.
//
//   a setting:   open notes the value of before (and whether it was the default); Escape puts it back, unless another
//                path wrote since the run mode's last write
//   a form:      its arguments registered in a registry of their own, each checked as a setting; their values given with
//                the choice (ui.Palette_Choice.arguments)
//
// The field of the palette is the control's filter (a closed list, a family, a theme) or the value's text (a number, a
// colour, keys, a field). A filter typed selects the best row; a move writes at once.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "../ascii"
import config "../config"
import "../draw"
import "../font"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"
import "../ui"

// The run of one item: what it writes in, its rows, its controls' state. Made by open, freed by close.
@(private = "file")
Run_State :: struct {
	settings:  ^Palette_Settings,   // a setting's (nil: a command's form)
	prefs:     ^config.Prefs,       // the program's registry, or `form`
	form:      config.Prefs,        // a form's arguments, registered
	names:     [dynamic]string,     // the values of the steps, in order (owned)
	command:   int,                 // a form's command, in the commands table
	palette:   ^ui.Command_Palette,
	before:    string,              // (owned) a setting's value when it opened
	was_default: bool,
	written:   string,              // (owned) the last value the run mode wrote ("": none)
	// the step's sub-list: the rows the filter keeps (indexes in its choices), what they were made for
	sub:       ui.Palette_Sublist,
	rows:      [dynamic]int,
	rows_query: string,             // (owned)
	rows_step: int,
	rows_version: u64,              // the families' version they were made for
	rows_made: bool,
	color:     ui.Color_Pick,
	color_step: int,                // the step the picker was set for (-1: none)
	held:      bool,                // the number's slider is held
	held_value: f32,
	path:      Path_Completion,     // a path's: the folder typed, read on a chore (palette_path.odin)
}

// The commands' forms of a palette: the forms runner, prefs_page's (it has the control table). palette_settings_add
// installs it; a program without the settings source calls this once, before its palette opens.
palette_forms_use :: proc(p: ^ui.Command_Palette) {
	p.forms = {open = form_open, text = run_text, build = run_build, write = run_write, undo = run_undo, values = form_values, close = run_close}
}

// (palette_settings_add) The settings source's runner.
@(private)
settings_runner :: proc(s: ^Palette_Settings) -> ui.Palette_Runner {
	return {open = settings_open, text = run_text, build = run_build, write = run_write, undo = run_undo, close = run_close, user = s}
}

@(private = "file")
settings_open :: proc(p: ^ui.Command_Palette, run: ^ui.Palette_Run) -> int {
	s := (^Palette_Settings)(run.runner.user)
	r, ok := s.prefs.index[run.id]
	if !ok { return 0 }
	e := &s.prefs.entries[r]
	if e.def.kind == .Bool || e.source == .Policy || e.source == .Command_Line { return 0 }
	st := new(Run_State)
	st.settings, st.prefs, st.palette, st.color_step = s, s.prefs, p, -1
	append(&st.names, strings.clone(run.id))
	st.before = strings.clone(config.value_string(s.prefs, config.Ref(r)))
	st.was_default = e.source == .Default
	run.state = st
	return 1
}

@(private = "file")
form_open :: proc(p: ^ui.Command_Palette, run: ^ui.Palette_Run) -> int {
	index, args := ui.palette_command_arguments(p, run.id)
	if index < 0 || len(args) == 0 { return 0 }
	st := new(Run_State)
	st.command, st.palette, st.color_step = index, p, -1
	st.form = config.prefs_make()
	config.register(&st.form, args)
	st.prefs = &st.form
	for a in args { append(&st.names, strings.clone(a.name)) }
	run.state = st
	return len(args)
}

@(private = "file")
run_close :: proc(p: ^ui.Command_Palette, run: ^ui.Palette_Run) {
	st := (^Run_State)(run.state)
	if st == nil { return }
	if st.settings == nil { config.prefs_destroy(&st.form) }
	for n in st.names { delete(n) }
	delete(st.names)
	delete(st.before)
	delete(st.written)
	delete(st.rows)
	delete(st.rows_query)
	ui.color_pick_destroy(&st.color)
	path_completion_end(&st.path)
	free(st)
	run.state = nil
}

// The options a step's control reads: the program's (a setting), or the form's (its choices the program's for the
// command).
@(private = "file")
run_options :: proc(st: ^Run_State) -> Page_Options {
	if st.settings != nil { return st.settings.options(st.settings.user) }
	return {user = st, choices = proc(user: rawptr, name: string) -> (labels, values: []string) {
		st := (^Run_State)(user)
		return ui.palette_command_choices(st.palette, st.command, name)
	}}
}

@(private = "file")
run_entry :: proc(st: ^Run_State, run: ^ui.Palette_Run) -> (^config.Entry, config.Ref) {
	r := config.ref_of(st.prefs, st.names[run.arg])
	if r == config.NO_REF { return nil, r }
	return config.entry(st.prefs, r), r
}

// Whether a control is a list of choices in the palette: its field is the list's filter.
@(private = "file")
is_list :: proc(c: Control) -> bool { return c == .Switch || c == .Segments || c == .List || c == .Font_Family || c == .Theme }

@(private = "file")
run_text :: proc(p: ^ui.Command_Palette, run: ^ui.Palette_Run) -> (text: string, value: bool) {
	st := (^Run_State)(run.state)
	e, _ := run_entry(st, run)
	if e == nil { return "", false }
	c := control_for(run_options(st), e)
	if is_list(c) || c == .Custom { return "", false }
	return value_shown(e), true
}

// A value as its field shows it: a number with its unit ("300 ms", "45 %", "4 MiB"), a text as it is.
@(private = "file")
value_shown :: proc(e: ^config.Entry) -> string {
	if e.def.kind == .String { return e.value.s }
	return i18n.decimal_marks(config.shown_text(e.def, e.value))
}

// Writes a step's value from text as its field shows it; "" done, else why not (temp).
@(private = "file")
run_write :: proc(p: ^ui.Command_Palette, run: ^ui.Palette_Run, text: string) -> string {
	st := (^Run_State)(run.state)
	e, r := run_entry(st, run)
	if e == nil { return "" }
	d := e.def
	stored := text
	// (a share is typed in percent, as shown; the file and the registry take the share)
	if d.value_kind == .Fraction {
		if v, err := config.parse_shown(d, text); err == .None { stored = fmt.tprintf("%v", v.f) }
	}
	o := run_options(st)
	err := apply(nil, st.prefs, o, d.name, stored)
	if err != "" {
		out := strings.clone(err, context.temp_allocator)
		delete(err)
		return out
	}
	delete(st.written)
	st.written = strings.clone(config.value_string(st.prefs, r))
	return ""
}

// Escape: the value of before, when the value now is the run mode's last write (another path that wrote since wins); a
// value that was the default is reset, so the file gains no line.
@(private = "file")
run_undo :: proc(p: ^ui.Command_Palette, run: ^ui.Palette_Run) {
	st := (^Run_State)(run.state)
	if st == nil || st.settings == nil || st.written == "" { return }
	r := config.ref_of(st.prefs, st.names[0])
	if r == config.NO_REF || config.value_string(st.prefs, r) != st.written { return }
	o := run_options(st)
	if st.was_default {
		config.reset(st.prefs, st.names[0])
		if o.changed != nil { o.changed(o.user, st.names[0]) }
	} else {
		delete(apply(nil, st.prefs, o, st.names[0], st.before))
	}
}

@(private = "file")
form_values :: proc(p: ^ui.Command_Palette, run: ^ui.Palette_Run, allocator: runtime.Allocator) -> []string {
	st := (^Run_State)(run.state)
	out := make([]string, len(st.names), allocator)
	for name, i in st.names {
		r := config.ref_of(st.prefs, name)
		out[i] = r != config.NO_REF ? config.value_string(st.prefs, r, allocator) : strings.clone("", allocator)
	}
	return out
}

////////////////////////////////
// The controls

// What a sub-list's rows build from (user of ui.palette_sublist).
@(private = "file")
Sub_Rows :: struct {
	st:      ^Run_State,
	control: Control,
	labels:  []string,
	values:  []string,
	current: string,
	themes:  []ui.Theme_Def,
	light:   bool,
	fam:     ^ui.Font_Families,
	default_label: string,
	default_face:  font.Font_Id,
}

@(private = "file")
run_build :: proc(p: ^ui.Command_Palette, run: ^ui.Palette_Run, query: string, keys: ui.Palette_Run_Keys, height: f32) -> (write: Maybe(string)) {
	st := (^Run_State)(run.state)
	e, _ := run_entry(st, run)
	if e == nil { return }
	em := ui.font_size()
	o := run_options(st)
	c := control_for(o, e)
	used: f32 = 0
	// (a form's argument says its title; a setting's is its run row's. The description of either, once, weak)
	if st.settings == nil {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.5)), font_size = math.round(em * 0.92), text_pad = em * 0.7})
		ui.label(fmt.tprintf("%s###arg_title", i18n.tr(config.title_of(e.def))))
		used += math.round(em * 1.5)
	}
	if note := config.description_of(e.def); note != "" {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = em * 0.7})
			ui.paragraph(fmt.tprintf("%s###arg_note", note))
		}
		used += math.round(em * 1.6)
	}
	ui.space(ui.LINE_GAP)
	used += math.round(em * ui.LINE_GAP)
	room := max(height - used, em * 2)
	switch c {
	case .Switch, .Segments, .List, .Font_Family, .Theme:
		write = sub_build(st, run, o, e, c, query, keys, room)
	case .Color:
		write = color_build(st, run, e, keys)
	case .Keys:
		hk, _ := platform.hotkey_parse(e.value.s)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###keys_row") {
			ui.space(ui.INNER_PAD)
			ui.next({width = ui.px(math.round(em * LIST_EM)), height = ui.px(math.round(em * CONTROL_H_EM))})
			if ui.hotkey_field("###keys", &hk) { write = strings.clone(platform.hotkey_text(hk), context.temp_allocator) }
		}
	case .Number:
		write = number_build(st, o, e, keys)
	case .Field:
		if e.def.value_kind == .Path { path_build(st.palette, &st.path, query, keys, room) }
	case .Custom:
		o.custom(o.user, e.def.name, em)
	}
	return
}

// The sub-list of a closed list, a family or a theme: filtered by the field, the value in use marked; a move writes at
// once, Enter writes the row selected.
@(private = "file")
sub_build :: proc(st: ^Run_State, run: ^ui.Palette_Run, o: Page_Options, e: ^config.Entry, c: Control, query: string, keys: ui.Palette_Run_Keys, height: f32) -> (write: Maybe(string)) {
	em := ui.font_size()
	rows := Sub_Rows{st = st, control = c, current = e.def.kind == .Bool ? (e.value.b ? "true" : "false") : e.value.s}
	switch c {
	case .Switch:
		rows.labels = {i18n.tr("Off"), i18n.tr("On")}
		rows.values = {"false", "true"}
	case .Segments, .List:
		rows.labels, rows.values = choices_of(o, e)
	case .Theme:
		rows.themes = o.themes
		rows.light = o.themes_light
		if config.ref_of(st.prefs, MODE_PREF) != config.NO_REF {
			#partial switch ui.theme_mode_of(config.string_of(st.prefs, MODE_PREF)) {
			case .Dark:  rows.light = false
			case .Light: rows.light = true
			}
		}
		labels := make([]string, len(o.themes), context.temp_allocator)
		for t, i in o.themes { labels[i] = t.name }
		rows.labels, rows.values = labels, labels
	case .Font_Family:
		// (a setting's are the page's, shared with its pickers; a form's the palette's: both outlive the run and its chore)
		fam := st.settings != nil ? &st.settings.page.font_families : &st.palette.families
		fam.source = ui.text_font_source(ui.current_state())
		ui.font_families_read(fam)
		rows.fam = fam
		rows.default_face = ui.program_text_face(ui.current_state(), standard_face_of(e.def.name))
		rows.default_label = ui.font_default_label(font.family_of(ui.current_state().fonts, rows.default_face))
		labels := make([]string, len(fam.list) + 1, context.temp_allocator)
		values := make([]string, len(fam.list) + 1, context.temp_allocator)
		labels[0], values[0] = rows.default_label, ""
		for f, i in fam.list { labels[i + 1], values[i + 1] = f.name, f.name }
		rows.labels, rows.values = labels, values
		if fam.reading == .Reading {
			if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), text_pad = em * 0.9})
				ui.label(fmt.tprintf("%s###reading", i18n.tr("Reading the fonts…")))
			}
		}
	case .Color, .Keys, .Number, .Field, .Custom:
	}
	// (the rows the filter keeps, made when the filter, the step or the families change: never at each build)
	version := rows.fam != nil ? rows.fam.version : 0
	if !st.rows_made || st.rows_query != query || st.rows_step != run.arg || st.rows_version != version {
		first := !st.rows_made || st.rows_step != run.arg || (st.rows_version != version && query == "")
		delete(st.rows_query)
		st.rows_query, st.rows_step, st.rows_version, st.rows_made = strings.clone(query), run.arg, version, true
		clear(&st.rows)
		best, best_score := -1, min(int)
		for l, i in rows.labels {
			if query == "" { append(&st.rows, i); continue }
			score, _, ok := ui.fuzzy_score(query, l)
			if !ok { continue }
			if score > best_score { best, best_score = len(st.rows), score }
			append(&st.rows, i)
		}
		// (opening: the value in use selected; a filter: its best row, written only by a move or Enter)
		st.sub.sel, st.sub.reveal = 0, true
		if first || query == "" {
			for row, k in st.rows { if ascii.equal_fold(rows.values[row], rows.current) { st.sub.sel = k } }
		} else if best >= 0 {
			st.sub.sel = best
		}
	}
	if len(st.rows) == 0 {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), text_align = .Center})
			ui.label(fmt.tprintf("%s###none", i18n.tr("Nothing matches")))
		}
		return
	}
	moved, clicked := ui.palette_sublist("###sub", &st.sub, len(st.rows), keys.step, height, sub_row, &rows)
	if rows.fam != nil { ui.font_families_ask(rows.fam) }
	if moved || clicked >= 0 || keys.enter {
		if st.sub.sel >= 0 && st.sub.sel < len(st.rows) {
			v := rows.values[st.rows[st.sub.sel]]
			// (a value: what programs store; a family's name and a theme's are found whatever their case)
			if !ascii.equal_fold(v, rows.current) { write = strings.clone(v, context.temp_allocator) }
		}
	}
	return
}

// One row of a sub-list: a family in its own face, a theme with its hues, a choice; the value in use marked.
@(private = "file")
sub_row :: proc(user: rawptr, k: int, selected: bool) {
	rows := (^Sub_Rows)(user)
	st := rows.st
	em := ui.font_size()
	i := st.rows[k]
	label := rows.labels[i]
	// (the palette's rows' inset: the names start where the list's titles do)
	ui.spacer(ui.px(math.round(em * 0.9)))
	ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
	face: font.Font_Id
	if rows.fam != nil { face = i == 0 ? rows.default_face : ui.font_families_face(rows.fam, label) }
	if face != 0 {
		ui.next_merge({font = face})
	}
	ranges: []ui.Fuzzy_Range
	if st.rows_query != "" { _, ranges, _ = ui.fuzzy_score(st.rows_query, label) }
	ui.matched_label("###t", label, ranges)
	if rows.control == .Theme && i < len(rows.themes) {
		d := ui.frame_new(Dots)
		d.colors, _ = ui.theme_version(rows.themes[i], rows.light)
		ui.next({width = ui.px(math.round(em * 5)), height = ui.pct(1)})
		b := ui.build_box({}, "###dots")
		b.custom, b.custom_user = dots_draw, d
		ui.space(ui.SPACE_2)
	}
	if ascii.equal_fold(rows.values[i], rows.current) {
		ui.next({width = ui.px(em * 1.4), height = ui.pct(1), font = ui.lucide_icons(), font_size = em * 0.9, text_align = .Center, text_pad = 0})
		ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###m", lucide.CHECK))
	}
	ui.spacer(ui.px(math.round(em * 0.9)))
}

@(private = "file")
Dots :: struct { colors: ui.Theme_Colors }

// A theme's hues as dots, on its own surface: what the cards show of it, on one row.
@(private = "file")
dots_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Dots)(user)
	r := b.rect
	h := r.max.y - r.min.y
	dot := math.round(h * 0.32)
	pad := math.round(h * 0.18)
	draw.rect(dc, {{r.min.x, r.min.y + pad}, {r.max.x, r.max.y - pad}}, draw.hex(d.colors.steps[3] | 0xff), (h - 2 * pad) * 0.5)
	prev := draw.set_circular_corners(dc, true)
	defer draw.set_circular_corners(dc, prev)
	x := r.min.x + pad * 1.5
	cy := (r.min.y + r.max.y) * 0.5
	for c in d.colors.hues {
		if x + dot > r.max.x - pad { break }
		draw.rect(dc, {{x, cy - dot * 0.5}, {x + dot, cy + dot * 0.5}}, draw.hex(c | 0xff), dot * 0.5)
		x += dot + math.round(dot * 0.4)
	}
}

// A colour: the picker without its text (the palette's field is that text); a change writes at once.
@(private = "file")
color_build :: proc(st: ^Run_State, run: ^ui.Palette_Run, e: ^config.Entry, keys: ui.Palette_Run_Keys) -> (write: Maybe(string)) {
	c, _, parsed := ui.color_parse(e.value.s)
	// (set at the step's opening, and when another path changed the value: the picker follows the registry)
	if st.color_step != run.arg || (parsed && ui.active_key() == 0 && ui.color_text(ui.color_pick_rgba(&st.color), {format = .Hex}) != ui.color_text(c, {format = .Hex})) {
		ui.color_pick_set(&st.color, parsed ? c : ui.Srgba{0.5, 0.5, 0.5, 1}, {format = .Hex})
		st.color_step = run.arg
	}
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###color_row") {
		ui.space(ui.INNER_PAD)
		if ui.color_picker("###picker", &st.color, text = false) {
			write = strings.clone(ui.color_text(ui.color_pick_rgba(&st.color), {format = .Hex}), context.temp_allocator)
		}
	}
	return
}

// A bounded number: its slider (written when it is let go, previewed while held, as on the page), Up and Down step it.
@(private = "file")
number_build :: proc(st: ^Run_State, o: Page_Options, e: ^config.Entry, keys: ui.Palette_Run_Keys) -> (write: Maybe(string)) {
	d := e.def
	em := ui.font_size()
	scale := config.shown_scale(d)
	lo, hi, _ := number_range(d)
	stored := d.kind == .Int ? f64(e.value.i) : e.value.f
	step := d.kind == .Int && scale == 1 ? 1.0 : float_step((hi - lo) * scale)
	text :: proc(d: config.Def, v: f64) -> string {
		if d.kind == .Int { return fmt.tprintf("%d", i64(math.round(v))) }
		return fmt.tprintf("%v", v)
	}
	if keys.step != 0 && !keys.page {
		// (Up raises a number, as a spinner's arrow: the list's step is the other way)
		v := clamp(stored * scale - f64(keys.step) * step, lo * scale, hi * scale) / scale
		if v != stored { return text(d, v) }
	}
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###number_row") {
		ui.space(ui.INNER_PAD)
		v := st.held ? st.held_value : f32(stored * scale)
		ui.next({width = ui.fill(), height = ui.px(math.round(em * CONTROL_H_EM))})
		sk := ui.key_from_string(ui.parent_box().key, "###slider")
		_ = ui.slider("###slider", &v, f32(lo * scale), f32(hi * scale), f32(step), format = "")
		held := ui.active_key() == sk
		if held {
			if !st.held || v != st.held_value {
				if o.preview != nil { o.preview(o.user, d.name, f64(v) / scale) }
			}
			st.held, st.held_value = true, v
		} else if st.held {
			st.held = false
			if f64(st.held_value) / scale != stored { write = text(d, f64(st.held_value) / scale) }
		}
		ui.space(ui.INNER_PAD)
	}
	return
}
