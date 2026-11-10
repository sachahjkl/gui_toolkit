// Package svg: a drawing in SVG, read into shapes and texts (svg.odin) and drawn with the toolkit's paths and fonts (draw.odin).
// It reads what diagrams and icons use, not the whole of SVG: svg, g, path, rect, circle, ellipse, line, polyline, polygon, text
// and tspan, markers (drawn where a line starts or ends), transforms, fill, stroke, stroke-width, stroke-dasharray, opacity,
// font-size, font-weight, text-anchor, and the style attribute. A linear gradient is its first colour; what it does not know
// (style sheets, filters, images, clips) is left out, and the rest is drawn.
//
//	doc, ok := svg.parse(text)
//	defer svg.destroy(&doc)
//	svg.draw(dc, &doc, at, scale, {regular = ui_font, bold = ui_bold})
package tk_svg

import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"

Vec2 :: [2]f32
Color :: [4]f32   // straight RGBA, 0..1

// A drawing: what it shows of its plane (`view`: its viewBox, x y width height), its shapes and texts in the order drawn.
Document :: struct {
	view:   [4]f32,
	items:  [dynamic]Item,
	arena:  virtual.Arena,
}

Item :: union { Shape, Text }

// A path in the drawing's coordinates (the transforms of its element and its groups applied).
Shape :: struct {
	segs:         []Seg,
	fill:         Maybe(Color),
	stroke:       Maybe(Color),
	stroke_width: f32,      // in the drawing's coordinates
	dash:         []f32,    // stroke-dasharray (empty: solid)
	evenodd:      bool,
}

Seg_Kind :: enum u8 { Move, Line, Quad, Cubic, Close }

// One step of a path: to `p`, by `c1` (Quad, Cubic) and `c2` (Cubic).
Seg :: struct {
	kind:      Seg_Kind,
	c1, c2, p: Vec2,
}

Anchor :: enum u8 { Start, Middle, End }

// A line of text: its pen at `at` (x, baseline) in the drawing's coordinates, `size` its font size there.
Text :: struct {
	at:     Vec2,
	anchor: Anchor,
	size:   f32,
	bold:   bool,
	color:  Color,
	text:   string,
}

// Reads `src`. ok false: no <svg> element. The document's memory is its own: destroy frees it.
parse :: proc(src: string) -> (doc: Document, ok: bool) {
	if virtual.arena_init_growing(&doc.arena) != nil { return }
	a := virtual.arena_allocator(&doc.arena)
	doc.items = make([dynamic]Item, a)
	p := Parser{src = src, doc = &doc, a = a}
	p.markers = make(map[string]^Node, allocator = context.temp_allocator)
	root := read_tree(&p)
	p.tree = root
	svg := find_svg(root)
	if svg == nil { virtual.arena_destroy(&doc.arena); doc = {}; return }
	doc.view = view_of(svg)
	collect_markers(&p, svg)
	walk(&p, svg, IDENTITY, Style{fill = Color{0, 0, 0, 1}, stroke_width = 1, font_size = 16, opacity = 1})
	return doc, true
}

destroy :: proc(doc: ^Document) {
	virtual.arena_destroy(&doc.arena)
	doc^ = {}
}

////////////////////////////////
// The tree

@(private)
Node :: struct {
	name:     string,
	attrs:    [dynamic][2]string,
	children: [dynamic]^Node,
	text:     string,   // the characters directly in it (text, tspan)
}

@(private)
Parser :: struct {
	src:     string,
	at:      int,
	doc:     ^Document,
	a:       mem.Allocator,          // the document's
	markers: map[string]^Node,
	tree:    ^Node,
}

// The elements of `p.src` under one root (temp memory).
@(private)
read_tree :: proc(p: ^Parser) -> ^Node {
	root := new(Node, context.temp_allocator)
	root.children = make([dynamic]^Node, context.temp_allocator)
	stack := make([dynamic]^Node, context.temp_allocator)
	append(&stack, root)
	s := p.src
	for p.at < len(s) {
		top := stack[len(stack) - 1]
		lt := strings.index_byte(s[p.at:], '<')
		if lt < 0 { break }
		if lt > 0 { text_add(top, s[p.at:][:lt]) }
		p.at += lt
		rest := s[p.at:]
		switch {
		case strings.has_prefix(rest, "<!--"):
			end := strings.index(rest, "-->")
			p.at = end < 0 ? len(s) : p.at + end + 3
		case strings.has_prefix(rest, "<![CDATA["):
			end := strings.index(rest, "]]>")
			if end < 0 { p.at = len(s); break }
			text_add(top, rest[len("<![CDATA["):end])
			p.at += end + 3
		case strings.has_prefix(rest, "<?") || strings.has_prefix(rest, "<!"):
			end := strings.index_byte(rest, '>')
			p.at = end < 0 ? len(s) : p.at + end + 1
		case strings.has_prefix(rest, "</"):
			end := strings.index_byte(rest, '>')
			p.at = end < 0 ? len(s) : p.at + end + 1
			if len(stack) > 1 { pop(&stack) }
		case:
			n, closed := read_tag(p)
			if n == nil { return root }
			append(&top.children, n)
			if !closed { append(&stack, n) }
		}
	}
	return root
}

// An opening tag at p.at: its node, and whether it closes itself.
@(private)
read_tag :: proc(p: ^Parser) -> (n: ^Node, closed: bool) {
	s := p.src
	i := p.at + 1
	start := i
	for i < len(s) && !is_space(s[i]) && s[i] != '>' && s[i] != '/' { i += 1 }
	n = new(Node, context.temp_allocator)
	n.name = s[start:i]
	n.attrs = make([dynamic][2]string, context.temp_allocator)
	n.children = make([dynamic]^Node, context.temp_allocator)
	for i < len(s) {
		for i < len(s) && is_space(s[i]) { i += 1 }
		if i >= len(s) { return nil, false }
		if s[i] == '>' { p.at = i + 1; return n, false }
		if s[i] == '/' && i + 1 < len(s) && s[i + 1] == '>' { p.at = i + 2; return n, true }
		k := i
		for i < len(s) && s[i] != '=' && !is_space(s[i]) && s[i] != '>' && s[i] != '/' { i += 1 }
		key := s[k:i]
		for i < len(s) && is_space(s[i]) { i += 1 }
		value := ""
		if i < len(s) && s[i] == '=' {
			i += 1
			for i < len(s) && is_space(s[i]) { i += 1 }
			if i < len(s) && (s[i] == '"' || s[i] == '\'') {
				q := s[i]
				end := strings.index_byte(s[i + 1:], q)
				if end < 0 { return nil, false }
				value = entities(s[i + 1:][:end])
				i += end + 2
			}
		}
		if key != "" { append(&n.attrs, [2]string{key, value}) } else { i += 1 }
	}
	return nil, false
}

@(private)
text_add :: proc(n: ^Node, raw: string) {
	t := entities(raw)
	n.text = n.text == "" ? t : strings.concatenate({n.text, t}, context.temp_allocator)
	// (a text's characters between its tspans go to it as a tspan of its own: their order is kept)
	if n.name == "text" && len(n.children) > 0 && strings.trim_space(t) != "" {
		c := new(Node, context.temp_allocator)
		c.name, c.text = "tspan", t
		append(&n.children, c)
	}
}

@(private)
is_space :: proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }

// XML's entities and character references (temp memory when there are any).
@(private)
entities :: proc(s: string) -> string {
	if strings.index_byte(s, '&') < 0 { return s }
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		if s[i] != '&' { strings.write_byte(&b, s[i]); i += 1; continue }
		end := strings.index_byte(s[i:], ';')
		if end < 0 { strings.write_byte(&b, s[i]); i += 1; continue }
		name := s[i + 1:][:end - 1]
		switch {
		case name == "lt":   strings.write_byte(&b, '<')
		case name == "gt":   strings.write_byte(&b, '>')
		case name == "amp":  strings.write_byte(&b, '&')
		case name == "quot": strings.write_byte(&b, '"')
		case name == "apos": strings.write_byte(&b, '\'')
		case name == "nbsp": strings.write_rune(&b, 0xA0)
		case strings.has_prefix(name, "#x") || strings.has_prefix(name, "#X"):
			if n, ok := strconv.parse_int(name[2:], 16); ok { strings.write_rune(&b, rune(n)) }
		case strings.has_prefix(name, "#"):
			if n, ok := strconv.parse_int(name[1:], 10); ok { strings.write_rune(&b, rune(n)) }
		case:
			strings.write_string(&b, s[i:][:end + 1])
		}
		i += end + 1
	}
	return strings.to_string(b)
}

@(private)
attr :: proc(n: ^Node, key: string) -> (string, bool) {
	for a in n.attrs { if a[0] == key { return a[1], true } }
	return "", false
}

@(private)
find_svg :: proc(n: ^Node) -> ^Node {
	if n.name == "svg" { return n }
	for c in n.children { if s := find_svg(c); s != nil { return s } }
	return nil
}

// The viewBox, else 0 0 width height.
@(private)
view_of :: proc(svg: ^Node) -> [4]f32 {
	if vb, ok := attr(svg, "viewBox"); ok {
		nums := numbers(vb)
		if len(nums) == 4 && nums[2] > 0 && nums[3] > 0 { return {nums[0], nums[1], nums[2], nums[3]} }
	}
	w, _ := length(attr(svg, "width"))
	h, _ := length(attr(svg, "height"))
	return {0, 0, w, h}
}

@(private)
collect_markers :: proc(p: ^Parser, n: ^Node) {
	if n.name == "marker" {
		if id, ok := attr(n, "id"); ok { p.markers[id] = n }
		return
	}
	for c in n.children { collect_markers(p, c) }
}

////////////////////////////////
// Style and transforms

// What an element inherits from its group, and what it says itself.
@(private)
Style :: struct {
	fill, stroke:  Maybe(Color),
	stroke_width:  f32,
	dash:          []f32,
	font_size:     f32,
	bold:          bool,
	anchor:        Anchor,
	opacity:       f32,   // the product of the groups' and its own
	fill_opacity:  f32,
	stroke_opacity: f32,
	evenodd:       bool,
}

// x' = a x + c y + e, y' = b x + d y + f (SVG's matrix(a b c d e f))
@(private)
Affine :: [6]f32

@(private)
IDENTITY :: Affine{1, 0, 0, 1, 0, 0}

@(private)
mul :: proc(m, n: Affine) -> Affine {   // m then n applied first: m · n
	return {
		m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1],
		m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3],
		m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5],
	}
}

@(private)
apply :: proc(m: Affine, v: Vec2) -> Vec2 { return {m[0] * v.x + m[2] * v.y + m[4], m[1] * v.x + m[3] * v.y + m[5]} }

// How much a length grows under `m` (the mean of its axes' scales).
@(private)
scale_of :: proc(m: Affine) -> f32 {
	return (math.sqrt(m[0] * m[0] + m[1] * m[1]) + math.sqrt(m[2] * m[2] + m[3] * m[3])) * 0.5
}

// A transform attribute: translate, scale, rotate, skewX, skewY, matrix, in order.
@(private)
transform_of :: proc(s: string) -> Affine {
	m := IDENTITY
	rest := s
	for {
		open := strings.index_byte(rest, '(')
		close := strings.index_byte(rest, ')')
		if open < 0 || close < open { break }
		name := strings.trim_space(strings.trim_left(rest[:open], ", \t\n"))
		v := numbers(rest[open + 1:close])
		t := IDENTITY
		switch name {
		case "translate":
			if len(v) >= 1 { t[4] = v[0] }
			if len(v) >= 2 { t[5] = v[1] }
		case "scale":
			if len(v) >= 1 { t[0], t[3] = v[0], v[0] }
			if len(v) >= 2 { t[3] = v[1] }
		case "rotate":
			if len(v) >= 1 {
				r := v[0] * math.PI / 180
				cs, sn := math.cos(r), math.sin(r)
				t = {cs, sn, -sn, cs, 0, 0}
				if len(v) >= 3 { t = mul(mul({1, 0, 0, 1, v[1], v[2]}, t), {1, 0, 0, 1, -v[1], -v[2]}) }
			}
		case "skewX": if len(v) >= 1 { t[2] = math.tan(v[0] * math.PI / 180) }
		case "skewY": if len(v) >= 1 { t[1] = math.tan(v[0] * math.PI / 180) }
		case "matrix": if len(v) >= 6 { t = {v[0], v[1], v[2], v[3], v[4], v[5]} }
		}
		m = mul(m, t)
		rest = rest[close + 1:]
	}
	return m
}

// The element's own style over what it inherits: its attributes, then its style attribute (which wins).
@(private)
style_of :: proc(n: ^Node, parent: Style) -> Style {
	st := parent
	st.opacity = 1   // (the group's opacity is multiplied in by walk)
	set :: proc(st: ^Style, key, value: string) {
		v := strings.trim_space(value)
		switch key {
		case "fill":             st.fill = paint(v, st.fill)
		case "stroke":           st.stroke = paint(v, st.stroke)
		case "stroke-width":     if w, ok := length(v, true); ok { st.stroke_width = w }
		case "stroke-dasharray": st.dash = v == "none" ? nil : numbers(v)
		case "font-size":        if w, ok := length(v, true); ok { st.font_size = w }
		case "font-weight":      st.bold = v == "bold" || v == "bolder" || (len(v) > 0 && v[0] >= '6' && v[0] <= '9')
		case "text-anchor":      st.anchor = v == "middle" ? .Middle : v == "end" ? .End : .Start
		case "opacity":          if o, ok := strconv.parse_f32(v); ok { st.opacity = clamp(o, 0, 1) }
		case "fill-opacity":     if o, ok := strconv.parse_f32(v); ok { st.fill_opacity = clamp(o, 0, 1) }
		case "stroke-opacity":   if o, ok := strconv.parse_f32(v); ok { st.stroke_opacity = clamp(o, 0, 1) }
		case "fill-rule":        st.evenodd = v == "evenodd"
		}
	}
	for a in n.attrs { set(&st, a[0], a[1]) }
	if css, ok := attr(n, "style"); ok {
		for decl in strings.split(css, ";", context.temp_allocator) {
			colon := strings.index_byte(decl, ':')
			if colon > 0 { set(&st, strings.trim_space(decl[:colon]), decl[colon + 1:]) }
		}
	}
	return st
}

// A fill or a stroke: none, a colour, or what it was (currentColor, a gradient: its first colour is read by walk).
@(private)
paint :: proc(v: string, was: Maybe(Color)) -> Maybe(Color) {
	if v == "none" || v == "transparent" { return nil }
	if c, ok := color_of(v); ok { return c }
	return was
}

// #rgb, #rgba, #rrggbb, #rrggbbaa, rgb(), rgba() and the common names.
color_of :: proc(v: string) -> (Color, bool) {
	s := strings.trim_space(v)
	hex :: proc(c: u8) -> (int, bool) {
		switch c {
		case '0' ..= '9': return int(c - '0'), true
		case 'a' ..= 'f': return int(c - 'a' + 10), true
		case 'A' ..= 'F': return int(c - 'A' + 10), true
		}
		return 0, false
	}
	if strings.has_prefix(s, "#") {
		h := s[1:]
		digits := make([]int, len(h), context.temp_allocator)
		for i in 0 ..< len(h) {
			d, ok := hex(h[i])
			if !ok { return {}, false }
			digits[i] = d
		}
		switch len(h) {
		case 3, 4:
			c := Color{f32(digits[0] * 17) / 255, f32(digits[1] * 17) / 255, f32(digits[2] * 17) / 255, 1}
			if len(h) == 4 { c.a = f32(digits[3] * 17) / 255 }
			return c, true
		case 6, 8:
			c := Color{f32(digits[0] * 16 + digits[1]) / 255, f32(digits[2] * 16 + digits[3]) / 255, f32(digits[4] * 16 + digits[5]) / 255, 1}
			if len(h) == 8 { c.a = f32(digits[6] * 16 + digits[7]) / 255 }
			return c, true
		}
		return {}, false
	}
	if strings.has_prefix(s, "rgb") {
		open := strings.index_byte(s, '(')
		close := strings.last_index_byte(s, ')')
		if open < 0 || close < open { return {}, false }
		parts := strings.split(s[open + 1:close], ",", context.temp_allocator)
		if len(parts) < 3 { return {}, false }
		c := Color{0, 0, 0, 1}
		for i in 0 ..< min(len(parts), 4) {
			t := strings.trim_space(parts[i])
			pct := strings.has_suffix(t, "%")
			n, ok := strconv.parse_f32(strings.trim_suffix(t, "%"))
			if !ok { return {}, false }
			c[i] = i == 3 ? (pct ? n / 100 : n) : (pct ? n / 100 : n / 255)
		}
		return c, true
	}
	switch strings.to_lower(s, context.temp_allocator) {
	case "black":  return {0, 0, 0, 1}, true
	case "white":  return {1, 1, 1, 1}, true
	case "red":    return {1, 0, 0, 1}, true
	case "green":  return {0, 0.5, 0, 1}, true
	case "blue":   return {0, 0, 1, 1}, true
	case "gray", "grey": return {0.5, 0.5, 0.5, 1}, true
	case "yellow": return {1, 1, 0, 1}, true
	case "orange": return {1, 0.647, 0, 1}, true
	case "purple": return {0.5, 0, 0.5, 1}, true
	}
	return {}, false
}

// The numbers of a list ("0 0 10 10", "1,2.5-3e2"), temp memory.
@(private)
numbers :: proc(s: string) -> []f32 {
	out := make([dynamic]f32, context.temp_allocator)
	i := 0
	for i < len(s) {
		for i < len(s) && !starts_number(s, i) { i += 1 }
		if i >= len(s) { break }
		n, used := number_at(s, i)
		if used == 0 { i += 1; continue }
		append(&out, n)
		i += used
	}
	return out[:]
}

@(private)
starts_number :: proc(s: string, i: int) -> bool {
	c := s[i]
	return (c >= '0' && c <= '9') || c == '-' || c == '+' || (c == '.' && i + 1 < len(s) && s[i + 1] >= '0' && s[i + 1] <= '9')
}

// A number at s[i:]: its value and its length (0: none). "1.5.5" is two numbers, as SVG reads it.
@(private)
number_at :: proc(s: string, i: int) -> (f32, int) {
	j := i
	if j < len(s) && (s[j] == '-' || s[j] == '+') { j += 1 }
	digits, dot := false, false
	for j < len(s) {
		c := s[j]
		if c >= '0' && c <= '9' { digits = true; j += 1; continue }
		if c == '.' && !dot { dot = true; j += 1; continue }
		break
	}
	if !digits { return 0, 0 }
	if j < len(s) && (s[j] == 'e' || s[j] == 'E') {
		k := j + 1
		if k < len(s) && (s[k] == '-' || s[k] == '+') { k += 1 }
		if k < len(s) && s[k] >= '0' && s[k] <= '9' {
			for k < len(s) && s[k] >= '0' && s[k] <= '9' { k += 1 }
			j = k
		}
	}
	n, _ := strconv.parse_f32(s[i:j])
	return n, j - i
}

// A length ("12", "12px", "1.5"): its number. Percentages and other units are none (`plain`: units are dropped).
@(private)
length :: proc(s: string, found := true, plain := false) -> (f32, bool) {
	if !found { return 0, false }
	t := strings.trim_space(s)
	if len(t) == 0 { return 0, false }
	n, used := number_at(t, 0)
	if used == 0 { return 0, false }
	unit := t[used:]
	if unit == "" || unit == "px" || plain { return n, true }
	if unit == "pt" { return n * 4 / 3, true }
	if unit == "em" { return n * 16, true }
	return 0, false
}

////////////////////////////////
// Elements to items

@(private)
walk :: proc(p: ^Parser, n: ^Node, m: Affine, parent: Style) {
	switch n.name {
	case "defs", "marker", "title", "desc", "style", "script", "clipPath", "mask", "pattern", "filter", "symbol", "linearGradient", "radialGradient", "metadata":
		return
	}
	st := style_of(n, parent)
	st.opacity *= parent.opacity
	gradient_colors(p, n, &st)
	mm := m
	if t, ok := attr(n, "transform"); ok { mm = mul(m, transform_of(t)) }
	switch n.name {
	case "svg", "g", "a", "switch":
		for c in n.children { walk(p, c, mm, st) }
	case "path":
		d, _ := attr(n, "d")
		shape_add(p, n, path_of(d), mm, st)
	case "rect":
		x, _ := length(attr(n, "x"))
		y, _ := length(attr(n, "y"))
		w, _ := length(attr(n, "width"))
		h, _ := length(attr(n, "height"))
		rx, hx := length(attr(n, "rx"))
		ry, hy := length(attr(n, "ry"))
		if !hx { rx = ry }
		if !hy { ry = rx }
		if w > 0 && h > 0 { shape_add(p, n, rect_path(x, y, w, h, min(rx, w / 2), min(ry, h / 2)), mm, st) }
	case "circle", "ellipse":
		cx, _ := length(attr(n, "cx"))
		cy, _ := length(attr(n, "cy"))
		rx, ry: f32
		if n.name == "circle" {
			r, _ := length(attr(n, "r"))
			rx, ry = r, r
		} else {
			rx, _ = length(attr(n, "rx"))
			ry, _ = length(attr(n, "ry"))
		}
		if rx > 0 && ry > 0 { shape_add(p, n, ellipse_path(cx, cy, rx, ry), mm, st) }
	case "line":
		x1, _ := length(attr(n, "x1"))
		y1, _ := length(attr(n, "y1"))
		x2, _ := length(attr(n, "x2"))
		y2, _ := length(attr(n, "y2"))
		st.fill = nil
		shape_add(p, n, []Seg{{kind = .Move, p = {x1, y1}}, {kind = .Line, p = {x2, y2}}}, mm, st)
	case "polyline", "polygon":
		pts, _ := attr(n, "points")
		v := numbers(pts)
		segs := make([dynamic]Seg, context.temp_allocator)
		for i := 0; i + 1 < len(v); i += 2 { append(&segs, Seg{kind = i == 0 ? .Move : .Line, p = {v[i], v[i + 1]}}) }
		if n.name == "polygon" && len(segs) > 0 { append(&segs, Seg{kind = .Close}) }
		shape_add(p, n, segs[:], mm, st)
	case "text":
		text_items(p, n, mm, st)
	}
}

// fill="url(#g)": a gradient's first stop colour (the diagram's colours, without the blend).
@(private)
gradient_colors :: proc(p: ^Parser, n: ^Node, st: ^Style) {
	first_stop :: proc(p: ^Parser, ref: string) -> Maybe(Color) {
		if !strings.has_prefix(ref, "url(#") { return nil }
		id := strings.trim_suffix(strings.trim_prefix(ref, "url(#"), ")")
		g := find_id(find_svg_root(p), id)
		if g == nil { return nil }
		for c in g.children {
			if c.name != "stop" { continue }
			if col, ok := attr(c, "stop-color"); ok { if v, is := color_of(col); is { return v } }
		}
		return nil
	}
	for key in ([]string{"fill", "stroke"}) {
		v, ok := attr(n, key)
		if !ok || !strings.has_prefix(v, "url(") { continue }
		c := first_stop(p, v)
		if key == "fill" { st.fill = c } else { st.stroke = c }
	}
}

@(private)
find_svg_root :: proc(p: ^Parser) -> ^Node { return p.tree }

@(private)
find_id :: proc(n: ^Node, id: string) -> ^Node {
	if n == nil { return nil }
	if v, ok := attr(n, "id"); ok && v == id { return n }
	for c in n.children { if f := find_id(c, id); f != nil { return f } }
	return nil
}

// The shape of an element, then its markers.
@(private)
shape_add :: proc(p: ^Parser, n: ^Node, segs: []Seg, m: Affine, st: Style) {
	if len(segs) == 0 { return }
	sw := st.stroke_width * scale_of(m)
	out := make([]Seg, len(segs), p.a)
	for s, i in segs { out[i] = {s.kind, apply(m, s.c1), apply(m, s.c2), apply(m, s.p)} }
	fill := alpha(st.fill, st.opacity * (st.fill_opacity == 0 ? 1 : st.fill_opacity))
	stroke := alpha(st.stroke, st.opacity * (st.stroke_opacity == 0 ? 1 : st.stroke_opacity))
	dash: []f32
	if len(st.dash) > 0 {
		dash = make([]f32, len(st.dash), p.a)
		for d, i in st.dash { dash[i] = d * scale_of(m) }
	}
	append(&p.doc.items, Shape{segs = out, fill = fill, stroke = stroke, stroke_width = sw, dash = dash, evenodd = st.evenodd})
	markers_add(p, n, segs, m, st)
}

@(private)
alpha :: proc(c: Maybe(Color), a: f32) -> Maybe(Color) {
	v, ok := c.?
	if !ok { return nil }
	v.a *= a
	return v
}

// marker-start and marker-end: the marker's content at the line's end, turned to the line (orient="auto"), scaled by the
// stroke's width (markerUnits="strokeWidth"), its viewBox fitted in markerWidth x markerHeight.
@(private)
markers_add :: proc(p: ^Parser, n: ^Node, segs: []Seg, m: Affine, st: Style) {
	for key in ([]string{"marker-start", "marker-end"}) {
		ref, ok := attr(n, key)
		if !ok {
			// (in the style attribute)
			css, has := attr(n, "style")
			if !has { continue }
			i := strings.index(css, key)
			if i < 0 { continue }
			rest := css[i + len(key):]
			end := strings.index_byte(rest, ';')
			ref = strings.trim_space(strings.trim_left(rest[:end < 0 ? len(rest) : end], ": "))
		}
		if !strings.has_prefix(ref, "url(#") { continue }
		id := strings.trim_suffix(strings.trim_prefix(ref, "url(#"), ")")
		mk := p.markers[id]
		if mk == nil { continue }
		start := key == "marker-start"
		at, dir := ends_of(segs, start)
		angle: f32 = 0
		orient, _ := attr(mk, "orient")
		switch orient {
		case "auto":               angle = math.atan2(dir.y, dir.x)
		case "auto-start-reverse": angle = math.atan2(dir.y, dir.x) + (start ? math.PI : 0)
		case:                      if a, is := strconv.parse_f32(orient); is { angle = a * math.PI / 180 }
		}
		mw, hw := length(attr(mk, "markerWidth"))
		mh, hh := length(attr(mk, "markerHeight"))
		if !hw { mw = 3 }
		if !hh { mh = 3 }
		rx, _ := length(attr(mk, "refX"))
		ry, _ := length(attr(mk, "refY"))
		vb := view_of(mk)
		sx, sy: f32 = 1, 1
		if vb[2] > 0 && vb[3] > 0 { sx, sy = mw / vb[2], mh / vb[3]; s := min(sx, sy); sx, sy = s, s }
		units, _ := attr(mk, "markerUnits")
		k: f32 = units == "userSpaceOnUse" ? 1 : st.stroke_width
		cs, sn := math.cos(angle), math.sin(angle)
		t := mul(m, Affine{1, 0, 0, 1, at.x, at.y})
		t = mul(t, Affine{cs, sn, -sn, cs, 0, 0})
		t = mul(t, Affine{k * sx, 0, 0, k * sy, 0, 0})
		t = mul(t, Affine{1, 0, 0, 1, -rx, -ry})   // (refX, refY: in the marker's own coordinates, its viewBox's)
		inner := Style{fill = Color{0, 0, 0, 1}, stroke_width = 1, font_size = st.font_size, opacity = st.opacity}
		for c in mk.children { walk(p, c, t, inner) }
	}
}

// Where a path starts or ends, and the way it goes there (the tangent of its first or last segment).
@(private)
ends_of :: proc(segs: []Seg, start: bool) -> (at, dir: Vec2) {
	if start {
		at = segs[0].p
		for s in segs[1:] {
			to := s.kind == .Cubic || s.kind == .Quad ? s.c1 : s.p
			if to != at { return at, to - at }
		}
		return at, {1, 0}
	}
	last := len(segs) - 1
	for last > 0 && segs[last].kind == .Close { last -= 1 }
	at = segs[last].p
	prev := last > 0 ? segs[last - 1].p : at
	from := prev
	switch segs[last].kind {
	case .Cubic: from = segs[last].c2
	case .Quad:  from = segs[last].c1
	case .Move, .Line, .Close:
	}
	if from == at { from = prev }
	return at, at - from
}

@(private)
rect_path :: proc(x, y, w, h, rx, ry: f32) -> []Seg {
	segs := make([dynamic]Seg, context.temp_allocator)
	if rx <= 0 || ry <= 0 {
		append(&segs, Seg{kind = .Move, p = {x, y}}, Seg{kind = .Line, p = {x + w, y}}, Seg{kind = .Line, p = {x + w, y + h}}, Seg{kind = .Line, p = {x, y + h}}, Seg{kind = .Close})
		return segs[:]
	}
	K :: 0.5522848   // a quarter of a circle as one cubic
	append(&segs, Seg{kind = .Move, p = {x + rx, y}}, Seg{kind = .Line, p = {x + w - rx, y}})
	append(&segs, Seg{.Cubic, {x + w - rx + rx * K, y}, {x + w, y + ry - ry * K}, {x + w, y + ry}}, Seg{kind = .Line, p = {x + w, y + h - ry}})
	append(&segs, Seg{.Cubic, {x + w, y + h - ry + ry * K}, {x + w - rx + rx * K, y + h}, {x + w - rx, y + h}}, Seg{kind = .Line, p = {x + rx, y + h}})
	append(&segs, Seg{.Cubic, {x + rx - rx * K, y + h}, {x, y + h - ry + ry * K}, {x, y + h - ry}}, Seg{kind = .Line, p = {x, y + ry}})
	append(&segs, Seg{.Cubic, {x, y + ry - ry * K}, {x + rx - rx * K, y}, {x + rx, y}}, Seg{kind = .Close})
	return segs[:]
}

@(private)
ellipse_path :: proc(cx, cy, rx, ry: f32) -> []Seg {
	K :: 0.5522848
	segs := make([dynamic]Seg, context.temp_allocator)
	append(&segs, Seg{kind = .Move, p = {cx + rx, cy}})
	append(&segs, Seg{.Cubic, {cx + rx, cy + ry * K}, {cx + rx * K, cy + ry}, {cx, cy + ry}})
	append(&segs, Seg{.Cubic, {cx - rx * K, cy + ry}, {cx - rx, cy + ry * K}, {cx - rx, cy}})
	append(&segs, Seg{.Cubic, {cx - rx, cy - ry * K}, {cx - rx * K, cy - ry}, {cx, cy - ry}})
	append(&segs, Seg{.Cubic, {cx + rx * K, cy - ry}, {cx + rx, cy - ry * K}, {cx + rx, cy}}, Seg{kind = .Close})
	return segs[:]
}

// A path's d: M L H V C S Q T A Z, absolute and relative, as segments in absolute coordinates (temp memory). Arcs become cubics.
path_of :: proc(d: string) -> []Seg {
	segs := make([dynamic]Seg, context.temp_allocator)
	cur, start, last_ctrl: Vec2
	last_cmd: u8
	i := 0
	cmd: u8 = 0
	for i < len(d) {
		c := d[i]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
			cmd = c
			i += 1
			if c == 'Z' || c == 'z' {
				append(&segs, Seg{kind = .Close})
				cur = start
				last_cmd = c
				continue
			}
		}
		if cmd == 0 { i += 1; continue }
		// the numbers of one step
		want := 0
		switch cmd | 0x20 {
		case 'm', 'l', 't': want = 2
		case 'h', 'v':      want = 1
		case 'c':           want = 6
		case 's', 'q':      want = 4
		case 'a':           want = 7
		case:               i += 1; continue
		}
		v: [7]f32
		got := 0
		for got < want && i < len(d) {
			for i < len(d) && (is_space(d[i]) || d[i] == ',') { i += 1 }
			if i >= len(d) { break }
			if (cmd | 0x20) == 'a' && (got == 3 || got == 4) && (d[i] == '0' || d[i] == '1') {   // (flags may touch: "a1 1 0 01 2 3")
				v[got] = f32(d[i] - '0')
				got += 1
				i += 1
				continue
			}
			if !starts_number(d, i) { break }
			n, used := number_at(d, i)
			if used == 0 { break }
			v[got] = n
			got += 1
			i += used
		}
		if got < want {
			for i < len(d) && !((d[i] >= 'A' && d[i] <= 'Z') || (d[i] >= 'a' && d[i] <= 'z')) { i += 1 }
			continue
		}
		rel := cmd >= 'a'
		base := rel ? cur : Vec2{}
		switch cmd | 0x20 {
		case 'm':
			cur = base + {v[0], v[1]}
			start = cur
			append(&segs, Seg{kind = .Move, p = cur})
			cmd = rel ? 'l' : 'L'   // (more pairs after M are lines)
		case 'l':
			cur = base + {v[0], v[1]}
			append(&segs, Seg{kind = .Line, p = cur})
		case 'h':
			cur = {(rel ? cur.x : 0) + v[0], cur.y}
			append(&segs, Seg{kind = .Line, p = cur})
		case 'v':
			cur = {cur.x, (rel ? cur.y : 0) + v[0]}
			append(&segs, Seg{kind = .Line, p = cur})
		case 'c':
			c1, c2, p := base + {v[0], v[1]}, base + {v[2], v[3]}, base + {v[4], v[5]}
			append(&segs, Seg{.Cubic, c1, c2, p})
			last_ctrl, cur = c2, p
		case 's':
			c1 := (last_cmd | 0x20) == 'c' || (last_cmd | 0x20) == 's' ? 2 * cur - last_ctrl : cur
			c2, p := base + {v[0], v[1]}, base + {v[2], v[3]}
			append(&segs, Seg{.Cubic, c1, c2, p})
			last_ctrl, cur = c2, p
		case 'q':
			c1, p := base + {v[0], v[1]}, base + {v[2], v[3]}
			append(&segs, Seg{.Quad, c1, {}, p})
			last_ctrl, cur = c1, p
		case 't':
			c1 := (last_cmd | 0x20) == 'q' || (last_cmd | 0x20) == 't' ? 2 * cur - last_ctrl : cur
			p := base + {v[0], v[1]}
			append(&segs, Seg{.Quad, c1, {}, p})
			last_ctrl, cur = c1, p
		case 'a':
			p := base + {v[5], v[6]}
			arc_add(&segs, cur, abs(v[0]), abs(v[1]), v[2], v[3] != 0, v[4] != 0, p)
			cur = p
		}
		last_cmd = cmd
	}
	return segs[:]
}

// SVG's arc from `from` to `to` (radii, x-axis rotation in degrees, flags) as cubics: the endpoint form to the centre form
// (SVG 1.1, F.6.5), then quarter turns or less.
@(private)
arc_add :: proc(segs: ^[dynamic]Seg, from: Vec2, rx_, ry_, rot_deg: f32, large, sweep: bool, to: Vec2) {
	rx, ry := rx_, ry_
	if rx == 0 || ry == 0 || from == to { append(segs, Seg{kind = .Line, p = to}); return }
	phi := rot_deg * math.PI / 180
	cs, sn := math.cos(phi), math.sin(phi)
	d := (from - to) * 0.5
	x1 := cs * d.x + sn * d.y
	y1 := -sn * d.x + cs * d.y
	lambda := (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
	if lambda > 1 { s := math.sqrt(lambda); rx *= s; ry *= s }
	num := rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
	den := rx * rx * y1 * y1 + ry * ry * x1 * x1
	k := math.sqrt(max(num / den, 0))
	if large == sweep { k = -k }
	cxp, cyp := k * rx * y1 / ry, -k * ry * x1 / rx
	mid := (from + to) * 0.5
	c := Vec2{cs * cxp - sn * cyp + mid.x, sn * cxp + cs * cyp + mid.y}
	angle :: proc(u, v: Vec2) -> f32 {
		a := math.atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y)
		return a
	}
	t1 := angle({1, 0}, {(x1 - cxp) / rx, (y1 - cyp) / ry})
	dt := angle({(x1 - cxp) / rx, (y1 - cyp) / ry}, {(-x1 - cxp) / rx, (-y1 - cyp) / ry})
	if !sweep && dt > 0 { dt -= 2 * math.PI }
	if sweep && dt < 0 { dt += 2 * math.PI }
	n := max(int(math.ceil(abs(dt) / (math.PI / 2))), 1)
	step := dt / f32(n)
	kk := 4.0 / 3.0 * math.tan(step / 4)
	point :: proc(c: Vec2, rx, ry, cs, sn, t: f32) -> Vec2 {
		x, y := rx * math.cos(t), ry * math.sin(t)
		return {c.x + cs * x - sn * y, c.y + sn * x + cs * y}
	}
	deriv :: proc(rx, ry, cs, sn, t: f32) -> Vec2 {
		x, y := -rx * math.sin(t), ry * math.cos(t)
		return {cs * x - sn * y, sn * x + cs * y}
	}
	t := t1
	for i in 0 ..< n {
		a, b := t, t + step
		p0, p1 := point(c, rx, ry, cs, sn, a), point(c, rx, ry, cs, sn, b)
		c1 := p0 + kk * deriv(rx, ry, cs, sn, a)
		c2 := p1 - kk * deriv(rx, ry, cs, sn, b)
		append(segs, Seg{.Cubic, c1, c2, i == n - 1 ? to : p1})
		t = b
	}
}

// A coordinate of a text (its unit, if any, dropped: "1.2em" is read by the caller).
@(private)
coord :: proc(n: ^Node, key: string) -> (f32, bool) {
	v, ok := attr(n, key)
	if !ok { return 0, false }
	return length(v, true, true)
}

// A text element and its tspans: a line each where they say where (x, y, dy), else following.
@(private)
text_items :: proc(p: ^Parser, n: ^Node, m: Affine, st: Style) {
	x, _ := coord(n, "x")
	y, _ := coord(n, "y")
	if dy, ok := coord(n, "dy"); ok { y += dy }
	if len(n.children) == 0 {
		item_text(p, n.text, {x, y}, m, st)
		return
	}
	at := Vec2{x, y}
	for c in n.children {
		if c.name != "tspan" { continue }
		cs := style_of(c, st)
		cs.opacity *= st.opacity
		if tx, ok := coord(c, "x"); ok { at.x = tx }
		if ty, ok := coord(c, "y"); ok { at.y = ty }
		if dy, ok := coord(c, "dy"); ok {
			// ("1.2em": a line down)
			raw, _ := attr(c, "dy")
			at.y += strings.has_suffix(raw, "em") ? dy / 16 * cs.font_size : dy
		}
		item_text(p, c.text, at, m, cs)
	}
}

@(private)
item_text :: proc(p: ^Parser, s: string, at: Vec2, m: Affine, st: Style) {
	t := strings.trim_space(s)
	if t == "" { return }
	col := st.fill.? or_else Color{0, 0, 0, 1}
	col.a *= st.opacity * (st.fill_opacity == 0 ? 1 : st.fill_opacity)
	append(&p.doc.items, Text{at = apply(m, at), anchor = st.anchor, size = st.font_size * scale_of(m), bold = st.bold, color = col, text = strings.clone(t, p.a)})
}
