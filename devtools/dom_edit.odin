package devtools

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "../render"
import "../ui"

// What Chrome's DevTools edits, live: a box's style as inline CSS and its text (ui.Box_Edit, applied at each build). An edit
// lasts as long as the client: when it goes the window is as its program builds it. Only what differs from what the box had when
// first edited is imposed, so what was left alone goes on following the program (a hover's colour).

@(private)
Dom_Style :: struct {
	text: string,   // the style as the client wrote it (comments are the properties it unticked)
	base: string,   // as it was before the first edit
}

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
		depth, j := 0, i
		for j < len(text) {
			if text[j] == '(' { depth += 1 } else if text[j] == ')' { depth -= 1 } else if text[j] == ';' && depth <= 0 { break }
			j += 1
		}
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

// A CSS colour as the toolkit's: linear light from sRGB. #rgb #rgba #rrggbb #rrggbbaa rgb() rgba() hsl() hsla() and a few names.
@(private)
css_color :: proc(value: string) -> (c: ui.Color, ok: bool) {
	v := strings.to_lower(strings.trim_space(value), context.temp_allocator)
	linear :: proc(r, g, b, a: f32) -> ui.Color { return {render.srgb_to_linear(r), render.srgb_to_linear(g), render.srgb_to_linear(b), clamp(a, 0, 1)} }
	switch v {
	case "transparent": return {}, true
	case "black":       return linear(0, 0, 0, 1), true
	case "white":       return linear(1, 1, 1, 1), true
	case "red":         return linear(1, 0, 0, 1), true
	case "green":       return linear(0, 0.502, 0, 1), true
	case "blue":        return linear(0, 0, 1, 1), true
	case "yellow":      return linear(1, 1, 0, 1), true
	case "gray", "grey": return linear(0.502, 0.502, 0.502, 1), true
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
			f, f_ok := strconv.parse_f32(t)
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
	return strconv.parse_f32(strings.trim_space(strings.trim_suffix(strings.trim_space(value), "px")))
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
		if v, ok := strconv.parse_f32(strings.trim_space(value)); ok { e.opacity = clamp(v, 0, 1); e.set += {.Opacity} }
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
		srv.dom.styles[id] = Dom_Style{base = base}
		st = &srv.dom.styles[id]
	} else {
		delete(st.text)
	}
	st.text = strings.clone(text)
	e := ui.box_edit(s, b.key)
	e.set &~= {.Background, .Border, .Text_Color, .Opacity, .Radius, .Font_Size, .Padding, .Width, .Height}
	base := css_parse(st.base)
	for p in css_parse(st.text) {
		if p.disabled { continue }
		same := false
		for q in base { if q.name == p.name && q.value == p.value { same = true; break } }
		if !same { css_impose(e, p.name, p.value, f32(dpi(srv))) }
	}
}
