package debug

// What a panel's procedure calls: each one a row in the window (the Build pass), an entry of a tool's list (List), or
// the target of a tool's set or press (Apply). Debug-panel.md, "A panel is a procedure the toolkit runs".

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "../ascii"
import tk_json "../json"
import i18n "../i18n"
import "../ui"

// Who runs a panel's procedure, and so what each call does.
@(private)
Pass_Kind :: enum u8 { Build, List, Apply }

// The sections a path holds at most; deeper ones are not entered.
SECTIONS_MAX :: 8

@(private)
Pass :: struct {
	kind:    Pass_Kind,
	surface: ^Surface,
	depth:   int,                       // the sections entered
	keys:    [SECTIONS_MAX + 1]u64,     // the hash of the path at each depth; [0] the panel's
	names:   [SECTIONS_MAX + 1]string,  // the path's parts (the List's paths, the filter's labels)
	filter:  string,                    // Build: what a row's label holds to show ("": all)
	target:  u64,                       // Apply: the hash of the path asked
	text:    string,                    // Apply: the value to set
	press:   bool,                      // Apply: an act is pressed (else a value is set)
	found:   bool,
	err:     string,                    // Apply: why the item asked refused (temp)
	sb:      ^strings.Builder,          // List
	items:   int,
	panel:   ^Panel,                    // the panel run
	acts:    bool,                      // Build: a row of acts is open, the next act goes on it
	acts_used, acts_room: f32,          // its width taken so far, and its whole width (by the last layout; 0: unknown)
}

// The pass this thread runs: its procedure's calls find it here.
@(private, thread_local) current: ^Pass

// Runs `p`'s procedure in the pass.
@(private)
pass_run :: proc(pass: ^Pass, p: ^Panel) {
	pass.depth = 0
	pass.keys[0], pass.names[0] = p.key, p.name
	pass.panel = p
	was := current
	current = pass
	defer current = was
	if pass.kind == .Build { ui.dense_labels_begin(&p.labels) }
	p.build(p.data)
	if pass.kind == .Build {
		acts_close(pass)
		ui.dense_labels_end(&p.labels)
	}
}

////////////////////////////////
// Values

// A number shown and dragged (T: any integer or float). lo, hi: its bounds (nil: none on that side); step: what it is
// rounded to and what a key or a notch adds (0: an integer's 1, a float's as it comes). True when it changed (by the
// person or a tool).
number :: proc(label: string, value: ^$T, lo: Maybe(f64) = nil, hi: Maybe(f64) = nil, step: f64 = 0) -> (changed: bool) where intrinsics.type_is_numeric(T) {
	when ENABLED { return number_any(label, value, type_info_of(T), lo, hi, step, false) } else { return false }
}

// A vector of N numbers on one row, each dragged (N from 1 to 4); the bounds and the step are each component's.
vector :: proc(label: string, value: ^[$N]$T, lo: Maybe(f64) = nil, hi: Maybe(f64) = nil, step: f64 = 0) -> (changed: bool) where intrinsics.type_is_numeric(T) && N >= 1 && N <= 4 {
	when ENABLED { return vector_any(label, value, type_info_of(T), N, lo, hi, step, false) } else { return false }
}

// A bool, as a check box.
toggle :: proc(label: string, value: ^bool) -> (changed: bool) {
	when ENABLED { return bool_any(label, value, type_info_of(bool), false) } else { return false }
}

// An enum, its names (by reflection) in a list.
choice :: proc(label: string, value: ^$E) -> (changed: bool) where intrinsics.type_is_enum(E) {
	when ENABLED { return enum_any(label, value, type_info_of(E), false) } else { return false }
}

// A string, edited in a field. What the surface writes is its own (debug-panel.md, "Values"): the program's string is
// never freed, and the surface's goes when it writes again or ends.
text :: proc(label: string, value: ^string) -> (changed: bool) {
	when ENABLED { return string_any(label, value, false) } else { return false }
}

// A colour: a swatch and its four channels (0..1).
color :: proc(label: string, value: ^ui.Color) -> (changed: bool) {
	when ENABLED { return color_any(label, value, false) } else { return false }
}

// A value shown, never edited (a count, a time, a state's name): its text as fmt's %v.
watch :: proc(label: string, value: any) {
	when ENABLED { watch_text(label, fmt.tprint(value)) }
}

// The program's history of a value, as a small graph and its last value. The program pushes into it each frame
// (ui.value_history_push): the panel only reads it. top: the graph's top (0: its largest value).
plot :: proc(label: string, history: ^ui.Value_History($N), top: f32 = 0) {
	when ENABLED {
		p, key, here := item(label)
		if !here { return }
		last := ui.value_history_last(history)
		switch p.kind {
		case .Build:
			if row_start(p, label, key, math.round(ui.dense_row_height() * PLOT_ROWS)) {
				values := ui.value_history_values(history)
				// (the graph spans what it shows, lowest to highest; top > 0: zero to top, a fixed scale)
				lo, hi := plot_range(values, top)
				// (a margin over and under the line: its lowest and highest points are not cut by the graph's edges)
				pad := (hi - lo) * PLOT_MARGIN
				for &v in values { v -= lo - pad }
				ui.next({width = ui.fill(), height = ui.pct(1)})
				g := ui.sparkline(widget_id(key, "graph"), {{values, ui.color("accent")}}, hi - lo + 2 * pad, N)
				g.flags += {.Draw_Border}
				ui.spacer(ui.px(ui.dense_gap()))
				plot_numbers(key, lo, last, hi)
			}
		case .List:
			list_open(p, label, "plot")
			fmt.sbprintf(p.sb, `,"value":%s,"count":%d,"readOnly":true}`, json_number(f64(last), type_info_of(f32)), history.count)
		case .Apply:
			p.err = "a plot is read only"
		}
	}
}

// A plot's height, in dense rows.
@(private) PLOT_ROWS :: 2.4
// The room over the highest value and under the lowest, a share of the range.
@(private) PLOT_MARGIN :: 0.12

// The scale of a plot: the lowest and the highest of its values (a flat line: around it); top > 0: zero to top.
@(private)
plot_range :: proc(values: []f32, top: f32) -> (lo, hi: f32) {
	if top > 0 { return 0, top }
	if len(values) == 0 { return 0, 1 }
	lo, hi = values[0], values[0]
	for v in values { lo, hi = min(lo, v), max(hi, v) }
	if hi - lo < 1e-6 * max(1, abs(hi)) { lo, hi = lo - 1, hi + 1 }
	return
}

// A plot's numbers at the right of its graph: its highest at the top, its last, its lowest at the bottom.
@(private)
plot_numbers :: proc(key: u64, lo, last, hi: f32) {
	em := ui.font_size()
	ui.next({width = ui.px(math.round(em * 4)), height = ui.pct(1), axis = .Y})
	if ui.column(id = widget_id(key, "numbers")) {
		line :: proc(key: u64, part: string, v: f32, weak: bool) {
			ui.next({width = ui.fill(), height = ui.pct(1.0 / 3), font = ui.mono_font(), text_align = .Right})
			if weak { ui.push_tags("weak") }
			ui.build_box({.Draw_Text}, fmt.tprintf("%.2f%s", v, widget_id(key, part)))
			if weak { ui.pop_tags() }
		}
		line(key, "max", hi, true)
		line(key, "last", last, false)
		line(key, "min", lo, true)
	}
}

// A button that runs the program's code: true when pressed (by the person, or a tool's press). Its arguments are
// values shown before it (debug-panel.md, "Acts take no arguments").
act :: proc(label: string) -> (pressed: bool) {
	when ENABLED {
		p, key, here := item(label, act = true)
		if !here { return }
		switch p.kind {
		case .Build:
			// (acts one after another share a row, as many as it holds, then the next row: Print and Reset side by side,
			// not a row each for a short button)
			gap := ui.dense_gap()
			em := ui.font_size()
			words := shown_label(p, label)
			w := ui.text_width(ui.top_style().font, em, words) + 2 * em + 2 * gap
			if p.acts && p.acts_room > 0 && p.acts_used + gap + w > p.acts_room { acts_close(p) }
			if !p.acts {
				ui.spacer(ui.px(gap))
				ui.next({width = ui.fill(), height = ui.px(ui.dense_row_height()), axis = .X, cross = .Center})
				row := ui.build_box({}, widget_id(key, "acts"))
				ui.push_parent(row)
				p.acts, p.acts_used, p.acts_room = true, 0, row.rect.max.x - row.rect.min.x
			} else {
				ui.spacer(ui.px(gap))
				p.acts_used += gap
			}
			ui.next({width = ui.text_size(em), height = ui.pct(1)})
			pressed = ui.button(widget_id(key, "act"), words).clicked
			p.acts_used += w
		case .List:
			list_open(p, label, "act")
			strings.write_string(p.sb, "}")
		case .Apply:
			if !p.press { p.err = "an act: press it"; return }
			pressed = true
		}
		return
	} else {
		return false
	}
}

// Ends the row of acts open, if one is.
@(private)
acts_close :: proc(p: ^Pass) {
	if !p.acts { return }
	ui.pop_parent()
	p.acts = false
}

// A line of words in the panel (what a group of values is for). Not in a tool's list.
note :: proc(words: string) {
	when ENABLED {
		p := current
		if p == nil || p.kind != .Build || p.filter != "" { return }
		acts_close(p)
		ui.spacer(ui.px(ui.dense_gap()))
		ui.next({width = ui.fill(), height = ui.text_size()})
		if ui.tags("weak") { ui.build_box({.Draw_Text, .Text_Wrap, .No_Text_Trunc}, fmt.tprintf("%s###note", ui.text_shown(words))) }
	}
}

// `if debug.section("Transform") { ... }`: a group of values under a header that opens and closes (its state the
// person's, kept while the program runs; `open`: its first). Its label is a part of the paths inside. A tool's list
// and set see every section open.
@(deferred_out = section_end)
section :: proc(label: string, open := true) -> bool {
	when ENABLED {
		p := current
		if p == nil || p.depth >= SECTIONS_MAX { return false }
		key := path_child(p.keys[p.depth], label)
		if p.kind == .Build { acts_close(p) }
		if p.kind == .Build && p.filter == "" {
			sf := p.surface
			on := sf.opened[key] or_else open
			was := on
			ui.spacer(ui.px(ui.dense_gap()))
			ui.tree_header(widget_id(key, "section"), label, &on)
			if on != was { sf.opened[key] = on }
			if !on { return false }
			// (what it holds, moved in under its header)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			ui.push_parent(ui.build_box({}, widget_id(key, "body")))
			ui.spacer(ui.px(math.round(ui.font_size() * ui.DENSE_INDENT_EM)))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			ui.push_parent(ui.build_box({}, "###column"))
		}
		p.depth += 1
		p.keys[p.depth], p.names[p.depth] = key, label
		return true
	} else {
		return false
	}
}

@(private)
section_end :: proc(entered: bool) {
	when ENABLED {
		if !entered { return }
		p := current
		p.depth -= 1
		if p.kind == .Build { acts_close(p) }
		if p.kind == .Build && p.filter == "" { ui.pop_parent(); ui.pop_parent() }
	}
}

////////////////////////////////
// The values' bodies, by their type's information (the typed calls and reflection share them)

@(private)
number_any :: proc(label: string, ptr: rawptr, ti: ^runtime.Type_Info, lo, hi: Maybe(f64), step: f64, read_only: bool) -> (changed: bool) {
	p, key, here := item(label)
	if !here { return }
	switch p.kind {
	case .Build:
		if read_only { watch_row(p, label, key, number_text(scalar_get(ptr, ti), ti, step)); return }
		if row_start(p, label, key) {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			changed = drag_scalar(widget_id(key, "value"), ptr, ti, lo, hi, step, {})
		}
	case .List:
		list_open(p, label, "number")
		fmt.sbprintf(p.sb, `,"value":%s`, json_number(scalar_get(ptr, ti), ti))
		list_bounds(p, lo, hi, step, read_only, scalar_integer(ti))
	case .Apply:
		if p.press { p.err = "a value: set it"; return }
		if read_only { p.err = "read only"; return }
		v, ok := parse_number(p.text)
		if !ok { p.err = fmt.tprintf("not a number: %q", p.text); return }
		scalar_set(ptr, ti, bounded(v, lo, hi, step, scalar_integer(ti)))
		changed = true
	}
	return
}

@(private)
vector_any :: proc(label: string, ptr: rawptr, elem: ^runtime.Type_Info, n: int, lo, hi: Maybe(f64), step: f64, read_only: bool) -> (changed: bool) {
	p, key, here := item(label)
	if !here { return }
	at :: proc(ptr: rawptr, elem: ^runtime.Type_Info, i: int) -> rawptr { return rawptr(uintptr(ptr) + uintptr(i * elem.size)) }
	switch p.kind {
	case .Build:
		if read_only {
			parts := make([]string, n, context.temp_allocator)
			for i in 0 ..< n { parts[i] = number_text(scalar_get(at(ptr, elem, i), elem), elem, step) }
			watch_row(p, label, key, strings.join(parts, "  ", context.temp_allocator))
			return
		}
		if row_start(p, label, key) {
			AXES :: [3]ui.Hue{.Red, .Green, .Blue}
			axes := AXES
			for i in 0 ..< n {
				if i > 0 { ui.spacer(ui.px(ui.dense_gap())) }
				ui.next({width = ui.fill(), height = ui.pct(1)})
				o: ui.Drag_Options
				if i < 3 { o.mark = ui.hue(axes[i]) }
				if drag_scalar(widget_id(key, fmt.tprintf("c%d", i)), at(ptr, elem, i), elem, lo, hi, step, o) { changed = true }
			}
		}
	case .List:
		list_open(p, label, "vector")
		strings.write_string(p.sb, `,"value":[`)
		for i in 0 ..< n {
			if i > 0 { strings.write_byte(p.sb, ',') }
			strings.write_string(p.sb, json_number(scalar_get(at(ptr, elem, i), elem), elem))
		}
		strings.write_byte(p.sb, ']')
		list_bounds(p, lo, hi, step, read_only, scalar_integer(elem))
	case .Apply:
		if p.press { p.err = "a value: set it"; return }
		if read_only { p.err = "read only"; return }
		parts := numbers_of(p.text)
		if len(parts) != n { p.err = fmt.tprintf("%d numbers, not %q", n, p.text); return }
		for v, i in parts { scalar_set(at(ptr, elem, i), elem, bounded(v, lo, hi, step, scalar_integer(elem))) }
		changed = true
	}
	return
}

@(private)
bool_any :: proc(label: string, ptr: rawptr, ti: ^runtime.Type_Info, read_only: bool) -> (changed: bool) {
	p, key, here := item(label)
	if !here { return }
	on := scalar_bool(ptr, ti)
	switch p.kind {
	case .Build:
		if read_only { watch_row(p, label, key, on ? "true" : "false"); return }
		if row_start(p, label, key) {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			if ui.checkbox(widget_id(key, "check"), "", &on) { bool_set(ptr, ti, on); changed = true }
		}
	case .List:
		list_open(p, label, "bool")
		fmt.sbprintf(p.sb, `,"value":%v`, on)
		if read_only { strings.write_string(p.sb, `,"readOnly":true`) }
		strings.write_byte(p.sb, '}')
	case .Apply:
		if p.press { p.err = "a value: set it"; return }
		if read_only { p.err = "read only"; return }
		switch ascii.lower(strings.trim_space(p.text)) {
		case "true", "1", "on", "yes":  on = true
		case "false", "0", "off", "no": on = false
		case: p.err = fmt.tprintf("not a bool: %q", p.text); return
		}
		bool_set(ptr, ti, on)
		changed = true
	}
	return
}

@(private)
enum_any :: proc(label: string, ptr: rawptr, ti: ^runtime.Type_Info, read_only: bool) -> (changed: bool) {
	p, key, here := item(label)
	if !here { return }
	e := runtime.type_info_base(ti).variant.(runtime.Type_Info_Enum)
	v := i64(scalar_get(ptr, e.base))
	chosen := -1
	for x, i in e.values { if i64(x) == v { chosen = i; break } }
	name := chosen >= 0 ? e.names[chosen] : fmt.tprintf("%d", v)
	switch p.kind {
	case .Build:
		if read_only || len(e.names) == 0 { watch_row(p, label, key, name); return }
		if row_start(p, label, key) {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			i := max(chosen, 0)
			if ui.dropdown(widget_id(key, "choice"), e.names, &i) && i != chosen {
				scalar_set(ptr, e.base, f64(e.values[i]))
				changed = true
			}
		}
	case .List:
		list_open(p, label, "choice")
		fmt.sbprintf(p.sb, `,"value":%s,"choices":[`, tk_json.quote(name))
		for n, i in e.names {
			if i > 0 { strings.write_byte(p.sb, ',') }
			strings.write_string(p.sb, tk_json.quote(n))
		}
		strings.write_byte(p.sb, ']')
		if read_only { strings.write_string(p.sb, `,"readOnly":true`) }
		strings.write_byte(p.sb, '}')
	case .Apply:
		if p.press { p.err = "a value: set it"; return }
		if read_only { p.err = "read only"; return }
		want := strings.trim_space(p.text)
		want = strings.trim_prefix(want, ".")
		for n, i in e.names {
			if ascii.equal_fold(n, want) { scalar_set(ptr, e.base, f64(e.values[i])); return true }
		}
		p.err = fmt.tprintf("no %q among %s", want, strings.join(e.names, ", ", context.temp_allocator))
	}
	return
}

// A string's field, kept by the surface while it shows.
@(private)
Text_Field :: struct {
	edit:    ui.Line_Edit,
	focused: bool,   // it had the keyboard at its last build: what is typed is not replaced by the value
}

@(private)
string_any :: proc(label: string, ptr: ^string, read_only: bool) -> (changed: bool) {
	p, key, here := item(label)
	if !here { return }
	switch p.kind {
	case .Build:
		if read_only { watch_row(p, label, key, ptr^); return }
		if row_start(p, label, key) {
			sf := p.surface
			f := sf.fields[key] or_else nil
			if f == nil {
				f = new(Text_Field, sf.allocator)
				sf.fields[key] = f
			}
			if !f.focused && ui.line_edit_string(&f.edit) != ptr^ { ui.line_edit_set(&f.edit, ptr^) }
			ui.next({width = ui.fill(), height = ui.pct(1)})
			res := ui.line_edit(widget_id(key, "text"), &f.edit)
			f.focused = res.focused
			if res.changed { string_write(sf, key, ptr, ui.line_edit_string(&f.edit)); changed = true }
		}
	case .List:
		list_open(p, label, "text")
		fmt.sbprintf(p.sb, `,"value":%s`, tk_json.quote(ptr^))
		if read_only { strings.write_string(p.sb, `,"readOnly":true`) }
		strings.write_byte(p.sb, '}')
	case .Apply:
		if p.press { p.err = "a value: set it"; return }
		if read_only { p.err = "read only"; return }
		string_write(p.surface, key, ptr, p.text)
		changed = true
	}
	return
}

// The program's string replaced by the surface's copy of `text`; the copy the surface wrote before at this path goes.
@(private)
string_write :: proc(sf: ^Surface, key: u64, ptr: ^string, text: string) {
	old, had := sf.written[key]
	copy := clone(sf, text)
	ptr^ = copy
	sf.written[key] = copy
	if had { delete(old, sf.allocator) }
}

@(private)
color_any :: proc(label: string, c: ^ui.Color, read_only: bool) -> (changed: bool) {
	p, key, here := item(label)
	if !here { return }
	f32_info := type_info_of(f32)
	switch p.kind {
	case .Build:
		if row_start(p, label, key) {
			h := ui.dense_row_height()
			ui.next({width = ui.px(h), height = ui.pct(1), bg = c^, radius = math.round(h * 0.2)})
			ui.build_box({.Draw_Background, .Draw_Border}, widget_id(key, "swatch"))
			if read_only {
				ui.spacer(ui.px(ui.dense_gap()))
				value_text(key, color_hex(c^), 0)
				return
			}
			for i in 0 ..< 4 {
				ui.spacer(ui.px(ui.dense_gap()))
				ui.next({width = ui.fill(), height = ui.pct(1)})
				if drag_scalar(widget_id(key, fmt.tprintf("c%d", i)), &c[i], f32_info, 0, 1, 0.001, {}) { changed = true }
			}
		}
	case .List:
		list_open(p, label, "color")
		fmt.sbprintf(p.sb, `,"value":[%s,%s,%s,%s],"hex":%s`, json_number(f64(c.r), f32_info), json_number(f64(c.g), f32_info), json_number(f64(c.b), f32_info), json_number(f64(c.a), f32_info), tk_json.quote(color_hex(c^)))
		if read_only { strings.write_string(p.sb, `,"readOnly":true`) }
		strings.write_byte(p.sb, '}')
	case .Apply:
		if p.press { p.err = "a value: set it"; return }
		if read_only { p.err = "read only"; return }
		v, ok := parse_color(p.text)
		if !ok { p.err = fmt.tprintf("not a colour (#rrggbb, #rrggbbaa or four numbers): %q", p.text); return }
		c^ = v
		changed = true
	}
	return
}

@(private)
watch_text :: proc(label, words: string) {
	p, key, here := item(label)
	if !here { return }
	switch p.kind {
	case .Build: watch_row(p, label, key, words)
	case .List:
		list_open(p, label, "watch")
		fmt.sbprintf(p.sb, `,"value":%s,"readOnly":true}`, tk_json.quote(words))
	case .Apply: p.err = "a watch is read only"
	}
}

@(private)
watch_row :: proc(p: ^Pass, label: string, key: u64, words: string) {
	if row_start(p, label, key) { value_text(key, words, 0) }
}

// A value's words at the right of its row, in the mono face; width 0: the rest of the row.
@(private)
value_text :: proc(key: u64, words: string, width: f32) {
	ui.next({width = width > 0 ? ui.px(width) : ui.fill(), height = ui.pct(1), font = ui.mono_font(), text_align = .Right})
	ui.build_box({.Draw_Text}, fmt.tprintf("%s%s", ui.text_shown(words), widget_id(key, "watch")))
}

////////////////////////////////
// The pass's items

// An item's start: the pass, its path's hash, and whether this pass deals with it (Build: its label holds the filter;
// Apply: it is the target).
@(private)
item :: proc(label: string, act := false) -> (p: ^Pass, key: u64, here: bool) {
	p = current
	if p == nil { return }
	key = path_child(p.keys[p.depth], label)
	switch p.kind {
	case .Build:
		here = p.filter == "" || filter_matches(shown_label(p, label), p.filter)
		// (what is not an act ends a row of acts)
		if here && !act { acts_close(p) }
	case .List:  here = true
	case .Apply:
		here = !p.found && key == p.target
		if here { p.found = true }
	}
	return
}

// A row's start in the window: the gap over it, its label (with a filter, its sections before it).
@(private, require_results, deferred_out = row_end)
row_start :: proc(p: ^Pass, label: string, key: u64, height: f32 = 0) -> bool {
	ui.spacer(ui.px(ui.dense_gap()))
	shown := shown_label(p, label)
	ranges := p.filter != "" ? ui.word_ranges(shown, p.filter) : nil
	ui.dense_row_open(shown, widget_id(key, "row"), row_label_width(p, shown), ranges, height)
	return true
}

// The labels' column of a row at the pass's depth: the panel's longest label's width (ui.Dense_Labels), less the
// sections' indent, so the fields of every depth line up on one edge; with a filter, a label says its sections too and
// is not indented.
@(private)
row_label_width :: proc(p: ^Pass, label: string) -> f32 {
	indent := p.filter == "" ? f32(p.depth) * math.round(ui.font_size() * ui.DENSE_INDENT_EM) : 0
	return ui.dense_label_column(&p.panel.labels, label, indent)
}

// Whether a row's words (its sections and its label) hold each word of the filter, in any case: as a settings page
// filters (ui.word_ranges lights the same words).
@(private)
filter_matches :: proc(words, filter: string) -> bool {
	f := filter
	for w in strings.fields_iterator(&f) { if !ascii.contains_fold(words, w) { return false } }
	return true
}


@(private)
row_end :: proc(ok: bool) { if ok { ui.pop_parent() } }

// A row's words: its label; with a filter (the sections are not drawn), its sections first.
@(private)
shown_label :: proc(p: ^Pass, label: string) -> string {
	if p.filter == "" || p.depth == 0 { return label }
	b := strings.builder_make(context.temp_allocator)
	for i in 1 ..= p.depth {
		strings.write_string(&b, p.names[i])
		strings.write_string(&b, " › ")
	}
	strings.write_string(&b, label)
	return strings.to_string(b)
}

// The name of a box of the item at `path` in the window, for a tool's click (Toolkit.click {name}) or a test's: part
// "value" a number's field, "c0" to "c3" a vector's or a colour's components, "check" a bool's, "choice" an enum's,
// "text" a string's field, "act" an act's button, "section" a section's header, "row" an item's row.
box_name :: proc(path: string, part := "value") -> string { return fmt.tprintf("%s_%x", part, path_root(path)) }

// A box's id for an item's part: its path's hash, so the same value keeps its boxes (its focus, its drag) whatever is
// shown around it.
@(private)
widget_id :: proc(key: u64, part: string) -> string { return fmt.tprintf("###%s_%x", part, key) }

// The List's entry of an item: its path and its kind; the caller writes the rest and its "}".
@(private)
list_open :: proc(p: ^Pass, label, kind: string) {
	if p.items > 0 { strings.write_byte(p.sb, ',') }
	p.items += 1
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..= p.depth {
		strings.write_string(&b, p.names[i])
		strings.write_byte(&b, '/')
	}
	strings.write_string(&b, label)
	fmt.sbprintf(p.sb, `{{"path":%s,"kind":%q`, tk_json.quote(strings.to_string(b)), kind)
}

@(private)
quoted :: proc(s: string) -> string { return tk_json.quote(s) }

@(private)
list_bounds :: proc(p: ^Pass, lo, hi: Maybe(f64), step: f64, read_only, integer: bool) {
	if l, ok := lo.?; ok { fmt.sbprintf(p.sb, `,"min":%s`, json_number(l)) }
	if h, ok := hi.?; ok { fmt.sbprintf(p.sb, `,"max":%s`, json_number(h)) }
	if step > 0 { fmt.sbprintf(p.sb, `,"step":%s`, json_number(step)) }
	if integer { strings.write_string(p.sb, `,"integer":true`) }
	if read_only { strings.write_string(p.sb, `,"readOnly":true`) }
	strings.write_byte(p.sb, '}')
}

////////////////////////////////
// Paths: FNV-1a over the parts joined by "/", fed part by part

@(private) FNV_OFFSET :: u64(0xcbf29ce484222325)
@(private) FNV_PRIME :: u64(0x100000001b3)

@(private)
path_feed :: proc(h: u64, s: string) -> u64 {
	h := h
	for i in 0 ..< len(s) { h = (h ~ u64(s[i])) * FNV_PRIME }
	return h
}

@(private)
path_root :: proc(name: string) -> u64 { return path_feed(FNV_OFFSET, name) }

@(private)
path_child :: proc(h: u64, label: string) -> u64 { return path_feed(path_feed(h, "/"), label) }

////////////////////////////////
// Scalars by their type's information

@(private)
scalar_integer :: proc(ti: ^runtime.Type_Info) -> bool {
	_, ok := runtime.type_info_base(ti).variant.(runtime.Type_Info_Integer)
	return ok
}

@(private)
scalar_get :: proc(ptr: rawptr, ti: ^runtime.Type_Info) -> f64 {
	b := runtime.type_info_base(ti)
	#partial switch v in b.variant {
	case runtime.Type_Info_Integer:
		switch b.size {
		case 1: return v.signed ? f64((^i8)(ptr)^) : f64((^u8)(ptr)^)
		case 2: return v.signed ? f64((^i16)(ptr)^) : f64((^u16)(ptr)^)
		case 4: return v.signed ? f64((^i32)(ptr)^) : f64((^u32)(ptr)^)
		case 8: return v.signed ? f64((^i64)(ptr)^) : f64((^u64)(ptr)^)
		}
	case runtime.Type_Info_Float:
		switch b.size {
		case 2: return f64((^f16)(ptr)^)
		case 4: return f64((^f32)(ptr)^)
		case 8: return (^f64)(ptr)^
		}
	case runtime.Type_Info_Enum:
		return scalar_get(ptr, v.base)
	}
	return 0
}

@(private)
scalar_set :: proc(ptr: rawptr, ti: ^runtime.Type_Info, x: f64) {
	b := runtime.type_info_base(ti)
	#partial switch v in b.variant {
	case runtime.Type_Info_Integer:
		r := math.round(x)
		switch b.size {
		case 1: if v.signed { (^i8)(ptr)^ = i8(clamp(r, f64(min(i8)), f64(max(i8)))) } else { (^u8)(ptr)^ = u8(clamp(r, 0, f64(max(u8)))) }
		case 2: if v.signed { (^i16)(ptr)^ = i16(clamp(r, f64(min(i16)), f64(max(i16)))) } else { (^u16)(ptr)^ = u16(clamp(r, 0, f64(max(u16)))) }
		case 4: if v.signed { (^i32)(ptr)^ = i32(clamp(r, f64(min(i32)), f64(max(i32)))) } else { (^u32)(ptr)^ = u32(clamp(r, 0, f64(max(u32)))) }
		case 8: if v.signed { (^i64)(ptr)^ = i64(clamp(r, f64(min(i64)), f64(max(i64)))) } else { (^u64)(ptr)^ = u64(clamp(r, 0, f64(max(u64)))) }
		}
	case runtime.Type_Info_Float:
		switch b.size {
		case 2: (^f16)(ptr)^ = f16(x)
		case 4: (^f32)(ptr)^ = f32(x)
		case 8: (^f64)(ptr)^ = x
		}
	case runtime.Type_Info_Enum:
		scalar_set(ptr, v.base, x)
	}
}

@(private)
scalar_bool :: proc(ptr: rawptr, ti: ^runtime.Type_Info) -> bool {
	bytes := ([^]u8)(ptr)[:ti.size]
	for x in bytes { if x != 0 { return true } }
	return false
}

@(private)
bool_set :: proc(ptr: rawptr, ti: ^runtime.Type_Info, on: bool) {
	bytes := ([^]u8)(ptr)[:ti.size]
	for &x in bytes { x = 0 }
	if on { bytes[0] = 1 }   // (little endian: a b16 or b32 of 1)
}

// A number of any type dragged as the widget's integer or f64, written back in its type.
@(private)
drag_scalar :: proc(id: string, ptr: rawptr, ti: ^runtime.Type_Info, lo, hi: Maybe(f64), step: f64, o: ui.Drag_Options) -> (changed: bool) {
	if scalar_integer(ti) {
		v := int(scalar_get(ptr, ti))
		l, h: Maybe(int)
		if x, ok := lo.?; ok { l = int(x) }
		if x, ok := hi.?; ok { h = int(x) }
		if ui.drag_number(id, &v, l, h, int(step), o) { scalar_set(ptr, ti, f64(v)); changed = true }
	} else {
		v := scalar_get(ptr, ti)
		if ui.drag_number(id, &v, lo, hi, step, o) { scalar_set(ptr, ti, v); changed = true }
	}
	return
}

// A value set by a tool, held to its bounds and its step (an integer: whole).
@(private)
bounded :: proc(v: f64, lo, hi: Maybe(f64), step: f64, integer: bool) -> f64 {
	v := v
	if step > 0 { v = math.round(v / step) * step }
	if integer { v = math.round(v) }
	if l, ok := lo.?; ok { v = max(v, l) }
	if h, ok := hi.?; ok { v = min(v, h) }
	return v
}

@(private)
number_text :: proc(v: f64, ti: ^runtime.Type_Info, step: f64) -> string {
	if scalar_integer(ti) { return fmt.tprintf("%d", i64(v)) }
	return ui.drag_text(v, step)
}

// A number for JSON: what is not finite is null; an f32's digits as an f32 has them (0.92, not 0.9200000166893005).
@(private)
json_number :: proc(v: f64, ti: ^runtime.Type_Info = nil) -> string {
	if math.is_nan(v) || math.is_inf(v) { return "null" }
	if v == math.trunc(v) && abs(v) < 1e15 { return fmt.tprintf("%d", i64(v)) }
	if ti != nil && ti.size == 4 { if _, ok := runtime.type_info_base(ti).variant.(runtime.Type_Info_Float); ok { return fmt.tprintf("%v", f32(v)) } }
	return fmt.tprintf("%v", v)
}

// What a tool sets: a number with a point (as JSON writes it) or the language's mark.
@(private)
parse_number :: proc(text: string) -> (f64, bool) {
	t := strings.trim_space(text)
	v, ok := strconv.parse_f64(t)
	if !ok { v, ok = i18n.parse_decimal(t) }
	// (an infinity or a NaN set by a tool would reach the program's variable: refused)
	return v, ok && !math.is_nan(v) && !math.is_inf(v)
}

// Numbers in a text: "1, 2, 3", "[1,2,3]", "1 2 3".
@(private)
numbers_of :: proc(text: string) -> []f64 {
	out := make([dynamic]f64, context.temp_allocator)
	t := strings.trim(strings.trim_space(text), "[]{}()")
	for part in strings.fields_iterator(&t) {
		for piece in strings.split(part, ",", context.temp_allocator) {
			if piece == "" { continue }
			v, ok := strconv.parse_f64(piece)
			if !ok || math.is_nan(v) || math.is_inf(v) { return nil }
			append(&out, v)
		}
	}
	return out[:]
}

@(private)
parse_color :: proc(text: string) -> (c: ui.Color, ok: bool) {
	t := strings.trim_space(text)
	if strings.has_prefix(t, "#") && (len(t) == 7 || len(t) == 9) {
		c.a = 1
		for i in 0 ..< (len(t) - 1) / 2 {
			x, xok := strconv.parse_uint(t[1 + 2 * i:][:2], 16)
			if !xok { return }
			c[i] = f32(x) / 255
		}
		return c, true
	}
	n := numbers_of(t)
	if len(n) != 4 && len(n) != 3 { return }
	c.a = 1
	for v, i in n { c[i] = f32(v) }
	return c, true
}

@(private)
color_hex :: proc(c: ui.Color) -> string {
	b :: proc(x: f32) -> u8 { return u8(math.round(clamp(x, 0, 1) * 255)) }
	return fmt.tprintf("#%02x%02x%02x%02x", b(c.r), b(c.g), b(c.b), b(c.a))
}

