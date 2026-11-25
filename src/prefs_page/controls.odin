package tk_prefs_page

// The one table that gives a preference's control from its value: its storage, its value kind (config.Value_Kind), its
// choices; never its name. The page draws every line with it (setting, setting_line); the palette's run mode reads it
// too (palette_run.odin).
// src/md/features/everything-palette.md, "The control comes from the value, in one table".

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "../ascii"
import config "../config"
import "../draw"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"
import "../ui"

// A preference's control.
Control :: enum u8 {
	Custom,        // the program's own (Page_Options.custom), under the words
	Switch,        // a Bool
	Segments,      // a closed list of at most SEGMENTS_MAX: a row of buttons
	List,          // a closed list of more: a drop-down list
	Font_Family,   // the font picker, each family in its face
	Theme,         // the program's themes as cards, under the words
	Color,         // a swatch and the value; a click opens the colour picker in a popover under it
	Keys,          // the shortcut recorder
	Number,        // a bounded number (not a Size): a slider, its field, − and +, its unit
	Field,         // a field; a number's unit after it
}

// The most choices a row of buttons shows; more is a list.
SEGMENTS_MAX :: 6

// The control of a preference `d` that has `choices` (its own or the program's), `themes` themes to show, and that the
// program draws itself or not (`custom`). Kinds with a control of their own first, then the closed lists, then numbers.
control_of :: proc(d: config.Def, choices, themes: int, custom: bool) -> Control {
	if custom { return .Custom }
	if d.kind == .Bool { return .Switch }
	#partial switch d.value_kind {
	case .Font_Family: return .Font_Family
	case .Theme:       if themes > 0 { return .Theme }
	case .Color:       return .Color
	case .Keys:        return .Keys
	}
	if choices > 0 { return choices <= SEGMENTS_MAX ? .Segments : .List }
	if (d.kind == .Int || d.kind == .Float) && d.value_kind != .Size {
		if _, _, ok := number_range(d); ok { return .Number }
	}
	return .Field
}

// control_of with the page's facts: the choices, the themes and the program's own controls of `o`.
@(private)
control_for :: proc(o: Page_Options, e: ^config.Entry) -> Control {
	custom := o.custom != nil && slice.contains(o.custom_names, e.def.name)
	choices := 0
	if e.def.kind == .String && !custom {
		_, values := choices_of(o, e)
		choices = len(values)
	}
	return control_of(e.def, choices, len(o.themes), custom)
}

// The range of a number's slider in the stored unit: its bounds, or a share's whole (0 to 1). ok false: it has none.
@(private)
number_range :: proc(d: config.Def) -> (lo, hi: f64, ok: bool) {
	if d.bounded && d.max > d.min { return d.min, d.max, true }
	if d.value_kind == .Fraction { return 0, 1, true }
	return
}

// The width a preference's control asks on its line, and the share of the line it may take at most (a segmented
// choice: WIDE_SHARE); 0: it goes under the words (the themes' cards, the program's own).
@(private)
control_width :: proc(o: Page_Options, e: ^config.Entry, c: Control, em: f32) -> (w: f32, share: f32) {
	share = 1
	switch c {
	case .Custom, .Theme: return 0, share
	case .Switch:         return em * SWITCH_EM, share
	case .Segments:
		labels, _ := choices_of(o, e)
		return ui.segmented_width(labels), WIDE_SHARE
	case .List, .Keys, .Color: return em * LIST_EM, share
	case .Font_Family:    return em * FIELD_EM, share
	case .Number:         return em * NUMBER_EM, share
	case .Field:
		if e.def.kind == .String { return em * FIELD_EM, share }
		sym := field_unit(e.def)
		unit: f32 = sym != "" ? math.round(em * ui.CONTROL_GAP) + ui.text_width(ui.top_style().font, math.round(em * 0.86), sym) : 0
		return em * NUMBER_FIELD_EM + unit, share
	}
	return
}

// The control of a preference, `width` wide: on its line, or under its words when the line has no room.
@(private)
control :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, r: config.Ref, e: ^config.Entry, c: Control, em: f32, width: ui.Size) {
	name := e.def.name
	h := ui.px(math.round(em * ui.CONTROL_HEIGHT_EM))
	opening := p.opening != "" && p.opening == name
	if opening { delete(p.opening); p.opening = "" }
	switch c {
	case .Custom, .Theme:   // (under the words: control_under)
	case .Switch:
		v := e.value.b
		ui.next({width = width, height = h})
		ui.a11y({name = config.title_of(e.def)})
		if ui.toggle("###sw", "", &v) { apply(p, prefs, o, name, v ? "true" : "false") }
	case .Segments, .List:
		labels, values := choices_of(o, e)
		sel := -1
		for v, i in values { if v == e.value.s { sel = i } }
		ui.next({width = width, height = h})
		if c == .Segments {
			if ui.segmented("###seg", labels, &sel) && sel >= 0 { apply(p, prefs, o, name, values[sel]) }
		} else {
			if sel < 0 { sel = 0 }
			if ui.dropdown("###dd", labels, &sel) { apply(p, prefs, o, name, values[sel]) }
		}
	case .Font_Family:
		font_control(p, prefs, o, e, width, h, opening)
	case .Color:
		color_control(p, prefs, o, e, width, h, opening)
	case .Keys:
		hk, _ := platform.hotkey_parse(e.value.s)
		ui.next({width = width, height = h})
		if ui.hotkey_field("###keys", &hk) { apply(p, prefs, o, name, platform.hotkey_text(hk)) }
	case .Number:
		number(p, prefs, o, e, em, width)
	case .Field:
		field(p, prefs, o, r, e, em, width)
	}
}

// A control under the words: the themes' cards (and the line of the user's themes file), or the program's own
// (Page_Options.custom).
@(private)
control_under :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, e: ^config.Entry, c: Control, em: f32) {
	#partial switch c {
	case .Theme:
		// (the cards in the version the look shows: appearance.mode's, or the one the program shows for the system's)
		light := o.themes_light
		if config.ref_of(prefs, MODE_PREF) != config.NO_REF {
			#partial switch ui.theme_mode_of(config.string_of(prefs, MODE_PREF)) {
			case .Dark:  light = false
			case .Light: light = true
			}
		}
		if at := theme_cards(o.themes, e.value.s, light, em); at >= 0 {
			apply(p, prefs, o, e.def.name, o.themes[at].name)
		}
		if o.themes_file != nil { themes_file_line(p, o.themes_file, em) }
	case .Custom:
		o.custom(o.user, e.def.name, em)
	}
}

// A family: a font picker (ui.font_picker) that shows the family in use, its default named: the program's face that the
// preference replaces (standard_face_of), whatever was chosen before. Its list is read at its first opening, on a chore,
// from the program's source (ui.text_font_source: Standard_Targets.font_source); a choice is set at once, and
// standard_watch applies a standard one. `opening`: control_open asked for it.
@(private = "file")
font_control :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, e: ^config.Entry, width, height: ui.Size, opening: bool) {
	fam := &p.font_families
	// (taken at each build, a copy: a source given after the page's first build is the one read)
	fam.source = ui.text_font_source(ui.current_state())
	fp, ok := p.font_pickers[e.def.name]
	if !ok {
		fp = new(ui.Font_Picker)
		p.font_pickers[strings.clone(e.def.name)] = fp
	}
	if opening && !fp.open { ui.font_picker_open(fp, fam) }
	face := standard_face_of(e.def.name)
	value := strings.trim_space(e.value.s)
	def := ui.program_text_face(ui.current_state(), face)
	ui.next({width = width, height = height})
	if v, chosen := ui.font_picker("###font", fp, fam, value, {default_face = def, monospace = face == .Mono, name = config.title_of(e.def)}).?; chosen {
		apply(p, prefs, o, e.def.name, v)
	}
}

// A colour: its swatch and its value on a button; a click opens the colour picker in a popover under the button, as
// the font picker's list opens. Each change is set at once, in hex (what the value kind takes). The button again,
// Escape or a press outside closes it.
@(private = "file")
color_control :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, e: ^config.Entry, width, height: ui.Size, opening: bool) {
	name := e.def.name
	// (a picker whose line was not built at the last build was left: shown again, the line starts closed)
	if p.color_open != "" && p.color_build + 1 < ui.current_state().build_index { color_close(p) }
	open := p.color_open == name
	c, _, parsed := ui.color_parse(e.value.s)
	btn: ui.Signal
	ui.next({width = width, height = height, axis = .X, cross = .Center})
	if ui.row(.Center, id = "###color_row") {
		if parsed {
			// (the text's colour is sRGB; a box's background is the renderer's linear colour)
			ui.swatch(draw.srgb(c.r, c.g, c.b, c.a), "###swatch")
			ui.space(ui.CONTROL_GAP)
		}
		ui.next({width = ui.fill(), height = height, font = ui.mono_font()})
		label := e.value.s != "" ? e.value.s : i18n.tr("Default")
		btn = ui.button("###color", label, lucide.PALETTE, {icon_font = ui.lucide_icons(), selected = open, left = true})
	}
	pop := fmt.tprintf("###color_pop_%s", name)
	if btn.clicked || (opening && !open) {
		color_close(p)
		if !open || opening {
			open = true
			p.color_open = strings.clone(name)
			ui.color_pick_set(&p.color, parsed ? c : ui.Srgba{0.5, 0.5, 0.5, 1}, {format = .Hex})
		}
	} else if open {
		// (a press outside the popover and its button, or Escape: closed, as a menu closes)
		at := ui.mouse_pos()
		inside :: proc(r: ui.Rect, at: [2]f32) -> bool { return at.x >= r.min.x && at.x < r.max.x && at.y >= r.min.y && at.y < r.max.y }
		pr, shown := ui.popover_rect(pop)
		outside := ui.mouse_pressed(.Left) && shown && !inside(pr, at) && !inside(btn.box.rect, at)
		if outside || ui.key_press(.Escape) { color_close(p); open = false }
	}
	if !open { return }
	p.color_build = ui.current_state().build_index
	em := ui.font_size()
	if ui.popover(pop, btn.box.rect, ui.color_picker_width() + 2 * math.round(em * ui.INNER_PAD), .Below) {
		ui.space(ui.INNER_PAD)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###color_pad") {
			ui.space(ui.INNER_PAD)
			if ui.color_picker("###picker", &p.color) {
				apply(p, prefs, o, name, ui.color_text(ui.color_pick_rgba(&p.color), {format = .Hex}))
			}
			ui.space(ui.INNER_PAD)
		}
		ui.space(ui.INNER_PAD)
	}
}

@(private = "file")
color_close :: proc(p: ^Page) {
	delete(p.color_open)
	p.color_open = ""
}

// Under the themes' cards: that one can make one's own, and the file (a click makes it when needed and opens it).
@(private = "file")
themes_file_line :: proc(p: ^Page, tf: ^Themes_File, em: f32) {
	// (the cards end with their gap: the words follow at once)
	if ui.tags("weak") {
		ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
		ui.paragraph(fmt.tprintf("%s###themes_own", i18n.tr("Make themes of your own: each is a few lines in this file, which explains how. They show here as soon as it is saved.")))
	}
	ui.space(ui.LINE_GAP)
	shown := home_short(tf.path, context.temp_allocator)
	if link("###themes_file", shown, i18n.tr("Open the themes file in the system's editor (made at the first click)"), em, mono = true) && p.state != nil {
		themes_file_open(tf, p.state)
	}
	if tf.error != "" {
		if ui.tags("bad") {
			ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
			ui.paragraph(fmt.tprintf("%s###themes_error", tf.error))
		}
	}
}

// A String preference's choices: its own (their labels, else the values capitalised, in the language in use), or the
// program's.
@(private)
choices_of :: proc(o: Page_Options, e: ^config.Entry) -> (labels, values: []string) {
	if len(e.def.choices) > 0 {
		own := len(e.def.choice_labels) == len(e.def.choices)
		out := make([]string, len(e.def.choices), context.temp_allocator)
		for c, i in e.def.choices { out[i] = i18n.tr(own ? e.def.choice_labels[i] : capitalised(c)) }
		return out, e.def.choices
	}
	if o.choices != nil {
		// (the program's labels are its English, i18n.later: translated here, where they show)
		labels, values = o.choices(o.user, e.def.name)
		out := make([]string, len(labels), context.temp_allocator)
		for l, i in labels { out[i] = i18n.tr(l) }
		return out, values
	}
	return
}

// A value as a label: its first letter upper case, its underscores spaces ("top_right": "Top right").
@(private = "file")
capitalised :: proc(s: string) -> string {
	if s == "" { return s }
	t, _ := strings.replace_all(s, "_", " ", context.temp_allocator)
	if t[0] < 'a' || t[0] > 'z' { return t }
	return strings.concatenate({ascii.upper(t[:1]), t[1:]}, context.temp_allocator)   // (a value: ASCII)
}

// The unit written after a number's field ("": none): a Size writes its own in its text ("4 MiB").
@(private = "file")
field_unit :: proc(d: config.Def) -> string {
	if d.kind == .String || d.value_kind == .Size { return "" }
	return config.unit_symbol(d)
}

// A float's step: round, and cutting its range in at most a few hundred (0.1, 1, 10...).
@(private)
float_step :: proc(span: f64) -> f64 {
	return math.pow(10, math.ceil(math.log10(span / FLOAT_STEPS_MAX)))
}
@(private = "file") FLOAT_STEPS_MAX :: 200

// What a number's field reads (ui.Number_Parse): the value kind's suffixes ("1.5 s", "45%"), as the field shows it.
@(private = "file")
number_typed :: proc(user: rawptr, text: string) -> (f64, bool) {
	d := (^config.Entry)(user).def
	v, ok := config.measure_parse(d, text, shown = true)
	return v * config.shown_scale(d), ok
}

// A bounded number: ui.number with its slider, in the unit it is shown in (a share in percent). A drag is written when
// it is let go (the file is not rewritten at the pointer's rate; while held, the page keeps the value and
// Page_Options.preview shows it); a key, a click, the wheel, a button or what is typed, at once.
@(private = "file")
number :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, e: ^config.Entry, em: f32, width: ui.Size) {
	d := e.def
	name := d.name
	held := p.held != "" && p.held == name
	scale := config.shown_scale(d)
	lo, hi, _ := number_range(d)
	parse: ui.Number_Parse
	if config.is_measure(d.value_kind) { parse = {fn = number_typed, user = e} }
	nk := ui.key_from_string(ui.parent_box().key, "###num")
	ui.next({width = width, height = ui.px(math.round(em * ui.CONTROL_HEIGHT_EM))})
	ui.a11y({name = config.title_of(d)})
	stored := d.kind == .Int ? f64(e.value.i) : e.value.f
	value: f64
	changed: bool
	if d.kind == .Int && scale == 1 {
		v := held ? int(math.round(p.held_value)) : int(e.value.i)
		changed = ui.number("###num", &v, lo = int(lo), hi = int(hi), unit = config.unit_symbol(d), slider = true, parse = parse)
		value = f64(v)
	} else {
		v := held ? p.held_value * scale : stored * scale
		changed = ui.number("###num", &v, lo = lo * scale, hi = hi * scale, step = float_step((hi - lo) * scale), unit = config.unit_symbol(d), slider = true, parse = parse)
		value = v / scale
	}
	if ui.focus_key() == ui.key_from_string(nk, "###value") { p.number_typed = true }
	if ui.active_key() == ui.key_from_string(nk, "###slider") {
		moved := !held || value != p.held_value
		if !held { delete(p.held); p.held = strings.clone(name) }
		p.held_value = value
		if moved && o.preview != nil { o.preview(o.user, name, value) }
		return
	}
	if held { delete(p.held); p.held = "" }
	// (only what moved it is written: a share shown in percent and back leaves a binary tail that is no change)
	if !changed && !held { return }
	if d.kind == .Int {
		if i64(math.round(value)) != e.value.i { apply(p, prefs, o, name, fmt.tprintf("%d", i64(math.round(value)))) }
	} else if value != stored {
		apply(p, prefs, o, name, fmt.tprintf("%v", value))
	}
}

// The stored value formatted for a free field (temp allocator): a size in its largest exact unit, a number with the
// language's decimal mark, a string as it is.
@(private)
field_current_text :: proc(prefs: ^config.Prefs, r: config.Ref, e: ^config.Entry) -> string {
	current := config.value_string(prefs, r)
	if e.def.value_kind == .Size {
		return config.shown_text(e.def, e.value)
	}
	if e.def.kind != .String {
		return i18n.decimal_marks(current)
	}
	return current
}

// Loads `shown` into `f` and marks it clean and synced (even when `shown` is "").
@(private)
field_sync :: proc(f: ^Field, shown: string) {
	if ui.line_edit_string(&f.text) != shown { ui.line_edit_set(&f.text, shown) }
	delete(f.synced)
	f.synced = strings.clone(shown)
	f.synced_valid = true
	f.dirty = false
}

// Discards any pending edit and forces the next build to reload the field from the registry.
@(private)
field_invalidate :: proc(f: ^Field) {
	delete(f.synced)
	f.synced = ""
	f.synced_valid = false
	f.was_focused = false
	f.dirty = false
	delete(f.error)
	f.error = ""
}

// Applies the text in `f` to the registry; on success, resyncs `f` to the normalized display text.
@(private)
field_commit :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, r: config.Ref, e: ^config.Entry, f: ^Field) {
	err := apply(p, prefs, o, e.def.name, ui.line_edit_string(&f.text))
	delete(f.error)
	f.error = err
	f.dirty = false
	if err == "" { field_sync(f, field_current_text(prefs, r, e)) }
}

// Commits `f` when it holds a pending edit and clears its prior-frame focus flag.
@(private)
flush_field :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, name: string, f: ^Field) {
	if !f.dirty {
		f.was_focused = false
		return
	}
	r := config.ref_of(prefs, name)
	if r == config.NO_REF {
		f.dirty = false
		f.was_focused = false
		return
	}
	e := config.entry(prefs, r)
	if e.source == .Policy || e.source == .Command_Line {
		field_sync(f, field_current_text(prefs, r, e))
		f.was_focused = false
		return
	}
	current := field_current_text(prefs, r, e)
	if ui.line_edit_string(&f.text) != current {
		field_commit(p, prefs, o, r, e, f)
	} else {
		f.dirty = false
		delete(f.error)
		f.error = ""
	}
	f.was_focused = false
}

// Commits every free field with a pending edit.
@(private)
flush_all :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options) {
	if prefs == nil { return }
	for name, f in p.fields { flush_field(p, prefs, o, name, f) }
}

// Commits any free field that was not built in `build_index` (hidden by a page switch, search filter or folded section).
@(private)
flush_unseen :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, build_index: u64) {
	if prefs == nil { return }
	for name, f in p.fields {
		if f.seen_build != build_index && (f.dirty || f.was_focused) {
			flush_field(p, prefs, o, name, f)
		}
	}
}

// A free field, its unit after it: Enter or leaving it applies the text; a refused one says why under the line. A
// size shows in its largest exact unit ("4 MiB"); a path and an address in the monospace face.
@(private = "file")
field :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, r: config.Ref, e: ^config.Entry, em: f32, width: ui.Size) {
	name := e.def.name
	f, ok := p.fields[name]
	if !ok {
		f = new(Field)
		p.fields[strings.clone(name)] = f
	}
	numeric := e.def.kind != .String
	// (a number as the language writes it: "1,5" in French; apply reads either mark)
	current := field_current_text(prefs, r, e)
	focused_now := f.box != 0 && ui.focus_key() == f.box
	if !f.synced_valid || (f.synced != current && !focused_now && !f.was_focused && !f.dirty) {
		field_sync(f, current)
		delete(f.error)
		f.error = ""
	}
	// (a number's field: its width less its unit's, which follows it)
	sym := field_unit(e.def)
	fw := width
	if sym != "" && width.kind == .Pixels { fw = ui.px(math.round(em * NUMBER_FIELD_EM)) }
	mono := e.def.value_kind == .Path || e.def.value_kind == .Address
	ui.next({width = fw, height = ui.px(math.round(em * ui.CONTROL_HEIGHT_EM)), font = mono ? ui.mono_font() : ui.top_style().font})
	ui.a11y({name = config.title_of(e.def)})
	before_edit := strings.clone(ui.line_edit_string(&f.text), context.temp_allocator)
	res := ui.line_edit("###field", &f.text)
	f.box = res.box.key
	f.seen_build = ui.current_state().build_index
	if res.changed || ui.line_edit_string(&f.text) != before_edit { f.dirty = true }
	// (a numeric field — Size like "4 MiB", unbounded Int or Float — steps on the wheel and Up/Down/Page keys, as
	// ui.number does: wheel_steps requires focus inside the scrolling settings page)
	if numeric {
		delta := f64(ui.wheel_steps(res.box, res.focused))
		if res.focused && delta == 0 {
			feel := ui.feel(ui.current_state())
			if ui.key_press(.Up) { delta = 1 } else if ui.key_press(.Down) { delta = -1 }
			if ui.key_press(.Page_Up) { delta = feel.step_page } else if ui.key_press(.Page_Down) { delta = -feel.step_page }
		}
		if delta != 0 {
			s := ui.current_state()
			mult: f64 = .Shift in s.mods ? f64(s.feel.step_shift) : 1
			base := e.def.kind == .Int ? f64(e.value.i) : e.value.f
			// (start from what the person typed if it parses, so typing "8 MiB" then scrolling up gives "9 MiB")
			if parsed, perr := config.parse_shown(e.def, ui.line_edit_string(&f.text)); perr == .None {
				base = e.def.kind == .Int ? f64(parsed.i) : parsed.f
			}
			next := field_step(e.def, base, delta * mult)
			raw := e.def.kind == .Int ? fmt.tprintf("%d", i64(math.round(next))) : fmt.tprintf("%v", next)
			err := apply(p, prefs, o, name, raw)
			delete(f.error)
			f.error = err
			if err == "" {
				current = field_current_text(prefs, r, e)
				field_sync(f, current)
			}
		}
	}
	left := !res.focused && f.was_focused   // (the keyboard went elsewhere since the last build)
	if res.cancelled {
		field_sync(f, current)
		delete(f.error)
		f.error = ""
		f.was_focused = false
	} else if res.committed {
		field_commit(p, prefs, o, r, e, f)
		f.was_focused = res.focused
	} else if left {
		if f.dirty && ui.line_edit_string(&f.text) != current {
			field_commit(p, prefs, o, r, e, f)
		} else {
			f.dirty = false
			if f.synced != current {
				field_sync(f, current)
				delete(f.error)
				f.error = ""
			} else if ui.line_edit_string(&f.text) == current {
				delete(f.error)
				f.error = ""
			}
		}
		f.was_focused = false
	} else {
		f.was_focused = res.focused
	}
	if sym != "" {
		ui.space(ui.CONTROL_GAP)
		if ui.tags("weak") {
			ui.next({width = ui.text_size(0), height = ui.px(math.round(em * ui.CONTROL_HEIGHT_EM)), text_pad = 0, font_size = math.round(em * 0.86)})
			ui.label(fmt.tprintf("%s###unit", sym))
		}
	}
}

// Next value of a numeric preference field after `steps` notches/keys (in the preference's stored unit). For a Size
// ("4 MiB"), steps by 1 of the binary unit shown (5 MiB, 3 MiB), stepping down into the next smaller binary unit at
// 1 MiB (down to the stored unit) so going down from 1 MiB to 1023 KiB and back up is reversible.
@(private)
field_step :: proc(d: config.Def, current, steps: f64) -> f64 {
	next: f64
	if d.value_kind == .Size {
		unit_scale := config.UNITS[config.unit_of(d)].scale
		if unit_scale <= 0 { unit_scale = 1 }
		bytes := current * unit_scale
		shown_u := size_shown_unit(bytes, unit_scale)
		if steps < 0 && abs(bytes) <= shown_u && shown_u >= 1024 && shown_u > unit_scale { shown_u /= 1024 }
		step_bytes := max(shown_u, unit_scale)
		next = (bytes + steps * step_bytes) / unit_scale
	} else if d.kind == .Int {
		next = current + steps
	} else {
		k: f64 = d.value_kind == .Fraction || d.value_kind == .Factor ? 0.1 : 1
		next = current + steps * k
	}
	if d.kind == .Int { next = math.round(next) }
	if d.bounded { next = clamp(next, d.min, d.max) }
	return next
}

// The binary unit (bytes: 1, 1024, 1024^2...) at which `bytes` is displayed by config.shown_text, or `fallback` at 0.
@(private = "file")
size_shown_unit :: proc(bytes, fallback: f64) -> f64 {
	if bytes == 0 { return fallback }
	CENTS :: 100
	for k := 4; k > 0; k -= 1 {
		u := math.pow(1024, f64(k))
		if abs(bytes) < u { continue }
		x := bytes / u
		if math.round(x * CENTS) / CENTS * u == bytes { return u }
	}
	return 1
}

// Opens the control of preference `name` at its next build, as a click would: a family's list, a colour's picker. A
// control with nothing to open is drawn as it is.
control_open :: proc(p: ^Page, name: string) {
	delete(p.opening)
	p.opening = strings.clone(name)
}
