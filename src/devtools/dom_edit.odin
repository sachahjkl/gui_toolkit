package devtools

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "../render"
import "../ui"
import "../ascii"

// What Chrome's DevTools edits, live: a box's style as inline CSS and its text (ui.Box_Edit, applied at each build). An edit
// lasts as long as the client: when it goes the window is as its program builds it. Only what differs from what the box had when
// first edited is imposed, so what was left alone goes on following the program (a hover's colour).

// 128 / 255: the channel of CSS's named colours "green" and "gray".
@(private)
CSS_CHANNEL_128 :: 0.502

@(private)
Dom_Style :: struct {
	text: string,   // the style as the client wrote it (comments are the properties it unticked)
	base: string,   // as it was before the first edit
}

// An edit, for DOM.undo and DOM.redo: what it was, what it made it (owned). had, has: whether the edit stood.
@(private)
Dom_Edit_Kind :: enum { Style, Text, Removed, Aria_Label }
@(private)
Dom_Edit :: struct {
	kind:          Dom_Edit_Kind,
	id:            int,
	mark:          int,
	had, has:      bool,
	before, after: string,
}

// The one attribute that can be edited: what a reader gets.
@(private)
ATTR_LABEL :: "aria-label"

@(private)
Css_Prop :: struct {
	name, value: string,
	start, end:  int,    // in the style's text, what the client sees as this property
	disabled:    bool,
}

// "a: b; /* c: d; */ e: f" as properties.
@(private)
css_parse :: proc(text: string) -> [dynamic]Css_Prop {
	out := make([dynamic]Css_Prop, context.temp_allocator)
	one :: proc(out: ^[dynamic]Css_Prop, body: string, start, end: int, disabled: bool) {
		colon := strings.index_byte(body, ':')
		if colon <= 0 { return }
		name := strings.trim_space(body[:colon])
		value := strings.trim_right(strings.trim_space(body[colon + 1:]), ";")
		value = strings.trim_space(value)
		if name != "" { append(out, Css_Prop{name = name, value = value, start = start, end = end, disabled = disabled}) }
	}
	i := 0
	for i < len(text) {
		c := text[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ';' { i += 1; continue }
		if strings.has_prefix(text[i:], "/*") {
			close := strings.index(text[i + 2:], "*/")
			end := close < 0 ? len(text) : i + 2 + close + 2
			one(&out, text[i + 2:close < 0 ? len(text) : i + 2 + close], i, end, true)
			i = end
			continue
		}
		// (a ';' in parentheses, a string or a comment does not end the declaration)
		depth, j, quote := 0, i, u8(0)
		scan: for j < len(text) {
			ch := text[j]
			switch {
			case quote != 0:
				if ch == '\\' { j += 1 } else if ch == quote { quote = 0 }
			case ch == '"' || ch == '\'':
				quote = ch
			case strings.has_prefix(text[j:], "/*"):
				close := strings.index(text[j + 2:], "*/")
				j = close < 0 ? len(text) : j + 2 + close + 1
			case ch == '(':
				depth += 1
			case ch == ')':
				depth -= 1
			case ch == ';' && depth <= 0:
				break scan
			}
			j += 1
		}
		j = min(j, len(text))
		end := j < len(text) ? j + 1 : j
		one(&out, text[i:j], i, end, false)
		i = end
	}
	return out
}

// An offset of the text as the protocol says it.
@(private)
css_pos :: proc(text: string, at: int) -> (line, column: int) {
	for k in 0 ..< min(at, len(text)) {
		if text[k] == '\n' { line += 1; column = 0 } else { column += 1 }
	}
	return
}

@(private)
css_write_range :: proc(sb: ^strings.Builder, text: string, start, end: int) {
	l0, c0 := css_pos(text, start)
	l1, c1 := css_pos(text, end)
	fmt.sbprintf(sb, `{{"startLine":%d,"startColumn":%d,"endLine":%d,"endColumn":%d}}`, l0, c0, l1, c1)
}

// The inline style of a node: its text, with where each property is in it (what makes it editable).
@(private)
css_write_style :: proc(sb: ^strings.Builder, id: int, text: string) {
	fmt.sbprintf(sb, `{{"styleSheetId":"toolkit-%d","cssProperties":[`, id)
	for p, i in css_parse(text) {
		if i > 0 { strings.write_byte(sb, ',') }
		fmt.sbprintf(sb, `{{"name":%s,"value":%s,"text":%s,"implicit":false,"disabled":%v,"range":`, json_quote(p.name), json_quote(p.value), json_quote(text[p.start:p.end]), p.disabled)
		css_write_range(sb, text, p.start, p.end)
		strings.write_byte(sb, '}')
	}
	fmt.sbprintf(sb, `],"shorthandEntries":[],"cssText":%s,"range":`, json_quote(text))
	css_write_range(sb, text, 0, len(text))
	strings.write_byte(sb, '}')
}

// A number of CSS: finite (strconv also reads "inf" and "nan", and a layout is not to get them).
@(private)
css_number :: proc(text: string) -> (v: f32, ok: bool) {
	v, ok = strconv.parse_f32(text)
	if !ok || math.is_nan(v) || math.is_inf(v) { return 0, false }
	return
}

// A CSS colour as the toolkit's: linear light from sRGB. #rgb #rgba #rrggbb #rrggbbaa rgb() rgba() hsl() hsla() and a few names.
@(private)
css_color :: proc(value: string) -> (c: ui.Color, ok: bool) {
	v := ascii.lower(strings.trim_space(value))
	linear :: proc(r, g, b, a: f32) -> ui.Color { return {render.srgb_to_linear(r), render.srgb_to_linear(g), render.srgb_to_linear(b), clamp(a, 0, 1)} }
	switch v {
	case "transparent": return {}, true
	case "black":       return linear(0, 0, 0, 1), true
	case "white":       return linear(1, 1, 1, 1), true
	case "red":         return linear(1, 0, 0, 1), true
	case "green":       return linear(0, CSS_CHANNEL_128, 0, 1), true
	case "blue":        return linear(0, 0, 1, 1), true
	case "yellow":      return linear(1, 1, 0, 1), true
	case "gray", "grey": return linear(CSS_CHANNEL_128, CSS_CHANNEL_128, CSS_CHANNEL_128, 1), true
	}
	if strings.has_prefix(v, "#") {
		h := v[1:]
		n, hex_ok := strconv.parse_u64_of_base(h, 16)
		if !hex_ok { return }
		byte_of :: proc(n: u64, shift: uint) -> f32 { return f32((n >> shift) & 255) / 255 }
		nib :: proc(n: u64, shift: uint) -> f32 { return f32((n >> shift) & 15) / 15 }
		switch len(h) {
		case 3: return linear(nib(n, 8), nib(n, 4), nib(n, 0), 1), true
		case 4: return linear(nib(n, 12), nib(n, 8), nib(n, 4), nib(n, 0)), true
		case 6: return linear(byte_of(n, 16), byte_of(n, 8), byte_of(n, 0), 1), true
		case 8: return linear(byte_of(n, 24), byte_of(n, 16), byte_of(n, 8), byte_of(n, 0)), true
		}
		return
	}
	open := strings.index_byte(v, '(')
	if open < 0 || !strings.has_suffix(v, ")") { return }
	fn := v[:open]
	nums: [4]f32
	count := 0
	percent: [4]bool
	rest := v[open + 1:len(v) - 1]
	for part in strings.fields_iterator(&rest) {
		for piece in strings.split_multi(part, {",", "/"}, context.temp_allocator) {
			t := strings.trim_right(piece, "deg")
			if t == "" { continue }
			if count == 4 { return }
			if strings.has_suffix(t, "%") { percent[count] = true; t = t[:len(t) - 1] }
			f, f_ok := css_number(t)
			if !f_ok { return }
			nums[count] = f
			count += 1
		}
	}
	if count < 3 { return }
	a := f32(1)
	if count == 4 { a = percent[3] ? nums[3] / 100 : nums[3] }
	switch fn {
	case "rgb", "rgba":
		ch :: proc(v: f32, pct: bool) -> f32 { return clamp(pct ? v / 100 : v / 255, 0, 1) }
		return linear(ch(nums[0], percent[0]), ch(nums[1], percent[1]), ch(nums[2], percent[2]), a), true
	case "hsl", "hsla":
		h := math.mod(math.mod(nums[0], 360) + 360, 360) / 60
		s, l := clamp(nums[1] / 100, 0, 1), clamp(nums[2] / 100, 0, 1)
		k := (1 - abs(2 * l - 1)) * s
		x := k * (1 - abs(math.mod(h, 2) - 1))
		m := l - k / 2
		rgb: [3]f32
		switch int(h) {
		case 0: rgb = {k, x, 0}
		case 1: rgb = {x, k, 0}
		case 2: rgb = {0, k, x}
		case 3: rgb = {0, x, k}
		case 4: rgb = {x, 0, k}
		case:   rgb = {k, 0, x}
		}
		return linear(rgb[0] + m, rgb[1] + m, rgb[2] + m, a), true
	}
	return
}

// A length in CSS pixels: "12px", "12".
@(private)
css_length :: proc(value: string) -> (v: f32, ok: bool) {
	return css_number(strings.trim_space(strings.trim_suffix(strings.trim_space(value), "px")))
}

@(private)
css_impose :: proc(e: ^ui.Box_Edit, name, value: string, d: f32) {
	switch name {
	case "background-color", "background":
		if c, ok := css_color(value); ok { e.bg = c; e.set += {.Background} }
	case "border-color":
		if c, ok := css_color(value); ok { e.border = c; e.set += {.Border} }
	case "color":
		if c, ok := css_color(value); ok { e.text_color = c; e.set += {.Text_Color} }
	case "opacity":
		if v, ok := css_number(strings.trim_space(value)); ok { e.opacity = clamp(v, 0, 1); e.set += {.Opacity} }
	case "border-radius":
		if v, ok := css_length(value); ok { e.radius = max(v, 0) * d; e.set += {.Radius} }
	case "font-size":
		if v, ok := css_length(value); ok && v > 0 { e.font_size = v * d; e.set += {.Font_Size} }
	case "padding":
		if v, ok := css_length(value); ok { e.padding = max(v, 0) * d; e.set += {.Padding} }
	case "width":
		if v, ok := css_length(value); ok { e.width = max(v, 0) * d; e.set += {.Width} }
	case "height":
		if v, ok := css_length(value); ok { e.height = max(v, 0) * d; e.set += {.Height} }
	}
}

// The style text of a node as the client knows it: what it wrote, else what the box has.
@(private)
dom_style_text :: proc(srv: ^Server, id: int, b: ^ui.Box) -> string {
	if st, ok := srv.dom.styles[id]; ok { return st.text }
	sb := strings.builder_make(context.temp_allocator)
	for kv, i in dom_style_editable(srv, b) { fmt.sbprintf(&sb, "%s%s: %s;", i > 0 ? " " : "", kv[0], kv[1]) }
	return strings.to_string(sb)
}

// A style edited: what it says that differs from where it started is imposed on the box.
@(private)
dom_style_set :: proc(srv: ^Server, s: ^ui.State, id: int, b: ^ui.Box, text: string) {
	st, known := &srv.dom.styles[id]
	if !known {
		base := strings.clone(dom_style_text(srv, id, b))
		srv.dom.styles[id] = Dom_Style{base = base, text = strings.clone(base)}
		st = &srv.dom.styles[id]
	}
	dom_history_add(srv, Dom_Edit{kind = .Style, id = id, had = true, before = strings.clone(st.text), has = true, after = strings.clone(text)})
	dom_style_impose(srv, s, id, b.key, text)
}

@(private)
dom_style_impose :: proc(srv: ^Server, s: ^ui.State, id: int, key: ui.Key, text: string) {
	st := &srv.dom.styles[id]
	copied := strings.clone(text)   // (text may be the entry's own)
	delete(st.text)
	st.text = copied
	e := ui.box_edit(s, key)
	e.set &~= {.Background, .Border, .Text_Color, .Opacity, .Radius, .Font_Size, .Padding, .Width, .Height}
	base := css_parse(st.base)
	for p in css_parse(st.text) {
		if p.disabled { continue }
		same := false
		for q in base { if q.name == p.name && q.value == p.value { same = true; break } }
		if !same { css_impose(e, p.name, p.value, f32(dpi(srv))) }
	}
}

// A text edited (DOM.setNodeValue).
@(private)
dom_text_edit :: proc(srv: ^Server, s: ^ui.State, id: int, key: ui.Key, value: string) {
	e := ui.box_edit(s, key)
	dom_history_add(srv, Dom_Edit{kind = .Text, id = id, had = .Text in e.set, before = strings.clone(e.text), has = true, after = strings.clone(value)})
	dom_edit_text(s, key, true, value)
}

@(private)
dom_edit_text :: proc(s: ^ui.State, key: ui.Key, has: bool, value: string) {
	e := ui.box_edit(s, key)
	copied := strings.clone(value)
	delete(e.text)
	e.text = copied
	if has { e.set += {.Text} } else { e.set -= {.Text} }
}

// A box removed (DOM.removeNode).
@(private)
dom_remove_edit :: proc(srv: ^Server, s: ^ui.State, id: int, key: ui.Key) {
	dom_history_add(srv, Dom_Edit{kind = .Removed, id = id, had = false, has = true})
	ui.box_edit(s, key).set += {.Removed}
}

// The name a reader gets, edited: what `aria-label` is here.
@(private)
dom_aria_edit :: proc(srv: ^Server, s: ^ui.State, id: int, b: ^ui.Box, value: string) {
	e := ui.box_edit(s, b.key)
	had := .Aria_Label in e.set
	before := had ? e.aria_label : (b.a11y != nil ? b.a11y.name : "")   // (what the program gives, for the undo to say)
	dom_history_add(srv, Dom_Edit{kind = .Aria_Label, id = id, had = had, before = strings.clone(before), has = true, after = strings.clone(value)})
	dom_edit_aria(srv, s, id, b.key, true, value)
}

// (Without an edit, what the program gives comes back at the next build: the client hears of what it shows now.)
@(private)
dom_edit_aria :: proc(srv: ^Server, s: ^ui.State, id: int, key: ui.Key, has: bool, value: string) {
	e := ui.box_edit(s, key)
	copied := strings.clone(value)
	delete(e.aria_label)
	e.aria_label = copied
	if has { e.set += {.Aria_Label} } else { e.set -= {.Aria_Label} }
	to := srv.dom.to
	if to.conn == nil { return }
	if value != "" {
		event(to.conn, to.session, "DOM.attributeModified", fmt.tprintf(`{{"nodeId":%d,"name":"aria-label","value":%s}}`, id, json_quote(value)))
	} else {
		event(to.conn, to.session, "DOM.attributeRemoved", fmt.tprintf(`{{"nodeId":%d,"name":"aria-label"}}`, id))
	}
}

// `name="value"` pairs, as an attribute is typed in Elements.
@(private)
attrs_parse :: proc(text: string) -> [dynamic][2]string {
	out := make([dynamic][2]string, context.temp_allocator)
	space :: proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }
	i := 0
	for i < len(text) {
		if space(text[i]) { i += 1; continue }
		start := i
		for i < len(text) && !space(text[i]) && text[i] != '=' { i += 1 }
		name := text[start:i]
		value := ""
		for i < len(text) && space(text[i]) { i += 1 }
		if i < len(text) && text[i] == '=' {
			i += 1
			for i < len(text) && space(text[i]) { i += 1 }
			if i < len(text) && (text[i] == '"' || text[i] == '\'') {
				q := text[i]
				i += 1
				start = i
				for i < len(text) && text[i] != q { i += 1 }
				value = text[start:i]
				if i < len(text) { i += 1 }
			} else {
				start = i
				for i < len(text) && !space(text[i]) { i += 1 }
				value = text[start:i]
			}
		}
		if name != "" { append(&out, [2]string{name, value}) }
	}
	return out
}

// Attributes as asked: `pairs` to set, `name` the attribute they replace ("": they replace nothing). Only `aria-label` is the
// client's to change: the others say what the box is in the program, and stay. An error's text, else "".
@(private)
dom_attr_edit :: proc(srv: ^Server, s: ^ui.State, to: Reply_To, id: int, pairs: [][2]string, name: string) -> string {
	b := dom_box(srv, s, id)
	if b == nil || id % 2 == 1 { return "not a box in the window" }
	current :: proc(b: ^ui.Box, name: string) -> (string, bool) {
		for kv in dom_attrs(b) { if kv[0] == name { return kv[1], true } }
		return "", false
	}
	refused :: proc(name: string) -> string { return fmt.tprintf("'%s' comes from the program: only aria-label can be edited", name) }
	label, has_label := "", false
	for kv in pairs {
		if kv[0] == ATTR_LABEL { label, has_label = kv[1], true; continue }
		// (Elements sends what it did not change along)
		if v, ok := current(b, kv[0]); !ok || v != kv[1] { return refused(kv[0]) }
	}
	if name != "" && name != ATTR_LABEL {
		v, ok := current(b, name)
		kept := false
		for kv in pairs { if kv[0] == name && ok && kv[1] == v { kept = true } }
		if !kept { return refused(name) }
	}
	if !has_label && name != ATTR_LABEL { return "" }
	if srv.dom.to.conn != to.conn { dom_take(srv, s, to) }
	dom_aria_edit(srv, s, id, b, label)
	return ""
}

// One step of the history, one way or the other.
@(private)
dom_history_apply :: proc(srv: ^Server, s: ^ui.State, h: Dom_Edit, forward: bool) {
	has, value := forward ? h.has : h.had, forward ? h.after : h.before
	key := srv.dom.keys[h.id / 2 - 1]
	to := srv.dom.to
	switch h.kind {
	case .Style:
		dom_style_impose(srv, s, h.id, key, value)
		// (what makes the Styles panel read it again)
		if to.conn != nil { event(to.conn, to.session, "CSS.styleSheetChanged", fmt.tprintf(`{{"styleSheetId":"toolkit-%d"}}`, h.id)) }
	case .Text:
		dom_edit_text(s, key, has, value)
	case .Removed:
		e := ui.box_edit(s, key)
		if has { e.set += {.Removed} } else { e.set -= {.Removed} }
	case .Aria_Label:
		dom_edit_aria(srv, s, h.id, key, has, value)
	}
}

// DOM.undo: back over the edits since the last mark (DOM.markUndoableState).
@(private)
dom_undo :: proc(srv: ^Server, s: ^ui.State) {
	d := &srv.dom
	if d.done == 0 { return }
	mark := d.history[d.done - 1].mark
	for d.done > 0 && d.history[d.done - 1].mark == mark {
		d.done -= 1
		dom_history_apply(srv, s, d.history[d.done], false)
	}
}

// DOM.redo: what the last undo took back.
@(private)
dom_redo :: proc(srv: ^Server, s: ^ui.State) {
	d := &srv.dom
	if d.done == len(d.history) { return }
	mark := d.history[d.done].mark
	for d.done < len(d.history) && d.history[d.done].mark == mark {
		dom_history_apply(srv, s, d.history[d.done], true)
		d.done += 1
	}
}

// An edit done: it replaces what had been undone.
@(private)
dom_history_add :: proc(srv: ^Server, h: Dom_Edit) {
	d := &srv.dom
	for len(d.history) > d.done { dom_edit_free(pop(&d.history)) }
	h := h
	h.mark = d.mark
	append(&d.history, h)
	d.done = len(d.history)
}

@(private)
dom_edit_free :: proc(h: Dom_Edit) { delete(h.before); delete(h.after) }

@(private)
dom_history_clear :: proc(d: ^Dom) {
	for h in d.history { dom_edit_free(h) }
	clear(&d.history)
	d.done = 0
}
