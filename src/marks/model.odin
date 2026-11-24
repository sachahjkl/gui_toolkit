package tk_marks

// The document's changes: the undo steps, the operations on the selection, the styles, and the interaction (step).

import "core:math"
import "core:slice"
import "core:strings"
import ink "../ink"
import tk_undo "../undo"

////////////////////////////////
// Shapes

@(private)
shape_clone :: proc(s: Shape) -> Shape {
	out := s
	out.samples = nil
	if len(s.samples) > 0 {
		out.samples = make([dynamic]ink.Sample, len(s.samples))
		copy(out.samples[:], s.samples[:])
	}
	out.text = strings.clone(s.text)
	out.polygon = slice.clone(s.polygon)
	out.triangles = slice.clone(s.triangles)
	return out
}

@(private)
shape_free :: proc(s: ^Shape) {
	delete(s.samples)
	delete(s.text)
	delete(s.polygon)
	delete(s.triangles)
	s.samples, s.text, s.polygon, s.triangles = nil, "", nil, nil
}

@(private)
shapes_free :: proc(list: []Shape) { for &s in list { shape_free(&s) } }

@(private)
shapes_equal :: proc(x, y: []Shape) -> bool {
	if len(x) != len(y) { return false }
	for i in 0 ..< len(x) {
		p, q := x[i], y[i]
		if p.kind != q.kind || p.a != q.a || p.b != q.b || p.style != q.style || p.text != q.text { return false }
		if len(p.samples) != len(q.samples) { return false }
		for k in 0 ..< len(p.samples) { if p.samples[k].at != q.samples[k].at { return false } }
	}
	return true
}

// A pen's ink made again from its samples and its width: the polygon the flattening fills, the triangles the screen
// draws. A Text's box measured again from its text. Other kinds: nothing.
@(private)
shape_refresh :: proc(doc: ^Doc, s: ^Shape) {
	#partial switch s.kind {
	case .Text:
		s.b = s.a + text_size_of(doc, s)
	case .Pen:
		pen_trace(doc, s)
	}
}

// The pen's ink of a shape: doc.pen at the style's width (its tapers in proportion), through gt:ink.
pen_of :: proc(doc: ^Doc, s: ^Shape) -> ink.Pen {
	w := max(stroke_px(doc, s), 0.1)
	return doc.pen.width > 0 ? ink.scaled(doc.pen, w / doc.pen.width) : ink.Pen{nib = .Round, width = w}
}

@(private)
pen_trace :: proc(doc: ^Doc, s: ^Shape) {
	delete(s.polygon)
	delete(s.triangles)
	o := ink.outline(s.samples[:], pen_of(doc, s))
	defer ink.outline_destroy(&o)
	s.polygon = ink.polygon(o)
	s.triangles = ink.triangles(o)
	r := shape_box(doc, s)
	s.a, s.b = r.min, r.max
}

@(private)
shape_translate :: proc(s: ^Shape, d: Vec) {
	s.a += d
	s.b += d
	for &p in s.samples { p.at += d }
	for &p in s.polygon { p += d }
	for &t in s.triangles { for &p in t { p += d } }
}

// The shape as it was (a, b) with handle moved by d. Shift keeps a line or an arrow straight or diagonal.
@(private)
shape_resize :: proc(s: ^Shape, handle: Handle, a, b, d: Vec, shift: bool) {
	if handle == .Start || handle == .End {
		s.a, s.b = a, b
		if handle == .Start { s.a = shift ? snap_45(b, a + d) : a + d } else { s.b = shift ? snap_45(a, b + d) : b + d }
		return
	}
	r := box_of(a, b)
	#partial switch handle {
	case .Top_Left:     r.min += d
	case .Top:          r.min.y += d.y
	case .Top_Right:    r.min.y += d.y; r.max.x += d.x
	case .Right:        r.max.x += d.x
	case .Bottom_Right: r.max += d
	case .Bottom:       r.max.y += d.y
	case .Bottom_Left:  r.max.y += d.y; r.min.x += d.x
	case .Left:         r.min.x += d.x
	}
	// (dragged past the other side: the box turns over, as it does in every editor)
	s.a, s.b = r.min, r.max
}

// The scale handle moved by d from where it was: the shape as it was when the gesture began (was), scaled from its
// anchor (a text's top left, a drawing's top left) by how far the handle went along its diagonal.
@(private)
shape_scale :: proc(doc: ^Doc, s: ^Shape, was: ^Shape, d: Vec) {
	box := shape_box(doc, was)
	anchor := was.kind == .Pen ? box.min : was.a
	diag := box.max - anchor
	l2 := diag.x * diag.x + diag.y * diag.y
	if l2 <= 0 { return }
	q := box.max + d - anchor
	f := (q.x * diag.x + q.y * diag.y) / l2
	#partial switch s.kind {
	case .Text:
		s.style.text_size = clamp(was.style.text_size * f, TEXT_SIZE_MIN, TEXT_SIZE_MAX)
		shape_refresh(doc, s)
	case .Pen:
		f = max(f, SCALE_MIN)
		for p, i in was.samples { if i < len(s.samples) { s.samples[i].at = anchor + (p.at - anchor) * f } }
		pen_trace(doc, s)
	}
}

////////////////////////////////
// The selection

// Only shape i picked (and shown in the bar); -1: none.
@(private)
select_only :: proc(doc: ^Doc, i: int) {
	for &s in doc.shapes { s.picked = false }
	doc.selected = -1
	if i >= 0 && i < len(doc.shapes) {
		doc.shapes[i].picked = true
		doc.selected = i
	}
	picks_update(doc)
}

// The count and the kinds of the shapes picked, made again after the picks or the shapes changed; the one the bar
// shows stays one of them.
@(private)
picks_update :: proc(doc: ^Doc) {
	doc.picked_count, doc.picked_kinds = 0, {}
	last := -1
	for s, i in doc.shapes {
		if !s.picked { continue }
		doc.picked_count += 1
		doc.picked_kinds += {s.kind}
		last = i
	}
	if doc.selected < 0 || doc.selected >= len(doc.shapes) || !doc.shapes[doc.selected].picked { doc.selected = last }
}

// Shape i alone selected (-1: none): what a click on it does.
select :: proc(m: ^Model, i: int) {
	if !idle(m) { return }
	select_only(&m.doc, i)
	m.changes += 1
}

selection_count :: proc(m: ^Model) -> int { return m.doc.picked_count }

idle :: proc(m: ^Model) -> bool {
	_, ok := m.mode.(Idle)
	return ok
}

has_selection :: proc(m: ^Model) -> bool { return m.doc.selected >= 0 && m.doc.selected < len(m.doc.shapes) }

// The shape the bar shows: the one picked last.
selected_shape :: proc(m: ^Model) -> ^Shape {
	return has_selection(m) ? &m.doc.shapes[m.doc.selected] : nil
}

deselect :: proc(m: ^Model) -> bool {
	if !idle(m) || m.doc.selected < 0 { return false }
	select_only(&m.doc, -1)
	m.changes += 1
	return true
}

// Every shape selected (Ctrl+A).
select_all :: proc(m: ^Model) -> bool {
	if !idle(m) || len(m.doc.shapes) == 0 { return false }
	for &s in m.doc.shapes { s.picked = true }
	picks_update(&m.doc)
	m.changes += 1
	return true
}

////////////////////////////////
// Undo and redo

@(private)
snapshot_take :: proc(doc: ^Doc) -> Snapshot {
	out := Snapshot{shapes = make([]Shape, len(doc.shapes)), crop = doc.crop, has_crop = doc.has_crop}
	for s, i in doc.shapes { out.shapes[i] = shape_clone(s) }
	return out
}

@(private)
snapshot_free :: proc(s: ^Snapshot) {
	shapes_free(s.shapes)
	delete(s.shapes)
	s^ = {}
}

// The document becomes s (taken: its shapes are the document's now). Nothing is selected.
@(private)
snapshot_restore :: proc(doc: ^Doc, s: Snapshot) {
	shapes_free(doc.shapes[:])
	clear(&doc.shapes)
	append(&doc.shapes, ..s.shapes)
	delete(s.shapes)
	doc.crop, doc.has_crop = s.crop, s.has_crop
	select_only(doc, -1)
}

// A change begins: the document as it is now is kept, for the undo stack.
@(private)
change_begin :: proc(doc: ^Doc) {
	if doc.has_pending { snapshot_free(&doc.pending) }
	doc.pending, doc.has_pending = snapshot_take(doc), true
}

// The change ends: what was kept goes on the undo stack, unless nothing changed.
@(private)
change_end :: proc(doc: ^Doc) {
	picks_update(doc)
	if !doc.has_pending { return }
	doc.has_pending = false
	p := doc.pending
	doc.pending = {}
	if shapes_equal(p.shapes, doc.shapes[:]) && p.crop == doc.crop && p.has_crop == doc.has_crop {
		snapshot_free(&p)
		return
	}
	tk_undo.push(&doc.history, p, 0, snapshot_free)
	doc.edits += 1
}

// Whether anything was changed since the picture came (a program asks before it drops the changes).
changed :: proc(m: ^Model) -> bool { return tk_undo.can_undo(&m.doc.history) }

can_undo :: proc(m: ^Model) -> bool { return tk_undo.can_undo(&m.doc.history) && idle(m) }
can_redo :: proc(m: ^Model) -> bool { return tk_undo.can_redo(&m.doc.history) && idle(m) }

undo :: proc(m: ^Model) -> bool {
	if !can_undo(m) { return false }
	back, _ := tk_undo.undo(&m.doc.history, snapshot_take(&m.doc))
	snapshot_restore(&m.doc, back)
	m.doc.edits += 1
	m.changes += 1
	return true
}

redo :: proc(m: ^Model) -> bool {
	if !can_redo(m) { return false }
	again, _ := tk_undo.redo(&m.doc.history, snapshot_take(&m.doc))
	snapshot_restore(&m.doc, again)
	m.doc.edits += 1
	m.changes += 1
	return true
}

////////////////////////////////
// Operations on the document (in Idle: a gesture going on has the document)

// Adds a shape (taken: its samples and text are the document's now) on top, alone selected; one undo step.
add :: proc(m: ^Model, s: Shape) -> int {
	change_begin(&m.doc)
	append(&m.doc.shapes, s)
	i := len(m.doc.shapes) - 1
	shape_refresh(&m.doc, &m.doc.shapes[i])
	select_only(&m.doc, i)
	change_end(&m.doc)
	m.changes += 1
	return i
}

// The shapes picked taken away; one undo step.
delete_selection :: proc(m: ^Model) -> bool {
	if !idle(m) || !has_selection(m) { return false }
	change_begin(&m.doc)
	#reverse for &s, i in m.doc.shapes[:] {
		if !s.picked { continue }
		shape_free(&s)
		ordered_remove(&m.doc.shapes, i)
	}
	m.doc.selected = -1
	change_end(&m.doc)
	m.changes += 1
	return true
}

// Every shape taken away (the crop stays); one undo step.
delete_all :: proc(m: ^Model) -> bool {
	if !idle(m) || len(m.doc.shapes) == 0 { return false }
	change_begin(&m.doc)
	shapes_free(m.doc.shapes[:])
	clear(&m.doc.shapes)
	m.doc.selected = -1
	change_end(&m.doc)
	m.changes += 1
	return true
}

// Where the shapes picked go among the others: on top of all, under all, one up, one down.
Order :: enum u8 { Front, Back, Forward, Backward }

// The shapes' new order (each place: the index of the shape it takes); changed false: they are there already (or
// nothing is picked). Several picked keep their order among themselves; one step moves each past one other.
@(private)
order_plan :: proc(m: ^Model, o: Order) -> (order: []int, changed: bool) {
	if !idle(m) || !has_selection(m) { return }
	shapes := m.doc.shapes[:]
	n := len(shapes)
	order = make([]int, n, context.temp_allocator)
	switch o {
	case .Front, .Back:
		j := 0
		for pass in 0 ..< 2 {
			// (Front: the others, then the picked; Back: the other way)
			want := (pass == 0) == (o == .Back)
			for s, i in shapes { if s.picked == want { order[j] = i; j += 1 } }
		}
	case .Forward:
		for i in 0 ..< n { order[i] = i }
		for i := n - 2; i >= 0; i -= 1 {
			if shapes[order[i]].picked && !shapes[order[i + 1]].picked { order[i], order[i + 1] = order[i + 1], order[i] }
		}
	case .Backward:
		for i in 0 ..< n { order[i] = i }
		for i in 1 ..< n {
			if shapes[order[i]].picked && !shapes[order[i - 1]].picked { order[i], order[i - 1] = order[i - 1], order[i] }
		}
	}
	for v, i in order { if v != i { changed = true } }
	return
}

can_order :: proc(m: ^Model, o: Order) -> bool {
	_, ok := order_plan(m, o)
	return ok
}

// The shapes picked moved in the order (Home, End, Page Up, Page Down); one undo step. They stay selected.
order :: proc(m: ^Model, o: Order) -> bool {
	plan, ok := order_plan(m, o)
	if !ok { return false }
	change_begin(&m.doc)
	was := slice.clone(m.doc.shapes[:], context.temp_allocator)
	shown := m.doc.selected
	for v, i in plan {
		m.doc.shapes[i] = was[v]
		if v == shown { m.doc.selected = i }
	}
	change_end(&m.doc)
	m.changes += 1
	return true
}

// A copy of each shape picked, a little below and right of it, on top; the copies are the selection then. One undo
// step.
duplicate :: proc(m: ^Model) -> bool {
	if !idle(m) || !has_selection(m) { return false }
	doc := &m.doc
	change_begin(doc)
	n := len(doc.shapes)
	shown := -1
	for i in 0 ..< n {
		if !doc.shapes[i].picked { continue }
		c := shape_clone(doc.shapes[i])
		shape_translate(&c, Vec{1, 1} * (DUPLICATE_PX * doc.scale))
		doc.shapes[i].picked = false
		if i == doc.selected { shown = len(doc.shapes) }
		append(&doc.shapes, c)
	}
	doc.selected = shown
	change_end(doc)
	m.changes += 1
	return true
}

// Moves the shapes picked by d picture pixels (the arrow keys); one undo step.
nudge :: proc(m: ^Model, d: Vec) -> bool {
	if !idle(m) || !has_selection(m) { return false }
	change_begin(&m.doc)
	for &s in m.doc.shapes { if s.picked { shape_translate(&s, d) } }
	change_end(&m.doc)
	m.changes += 1
	return true
}

// A tool chosen: a drawing tool lets go of the selection (its properties are the tool's then).
tool_set :: proc(m: ^Model, t: Tool) {
	m.tool = t
	if t != .Select && idle(m) { select_only(&m.doc, -1) }
	m.changes += 1
}

// The kind of shape a tool draws (ok false: Select, Crop).
tool_kind :: proc(t: Tool) -> (k: Kind, ok: bool) {
	switch t {
	case .Select, .Crop: return
	case .Rectangle:   return .Rectangle, true
	case .Ellipse:     return .Ellipse, true
	case .Arrow:       return .Arrow, true
	case .Line:        return .Line, true
	case .Pen:         return .Pen, true
	case .Highlighter: return .Highlighter, true
	case .Text:        return .Text, true
	case .Pixelate:    return .Pixelate, true
	case .Blur:        return .Blur, true
	}
	return
}

// The tool that draws a kind: its style is that tool's.
kind_tool :: proc(k: Kind) -> Tool {
	switch k {
	case .Rectangle:   return .Rectangle
	case .Ellipse:     return .Ellipse
	case .Arrow:       return .Arrow
	case .Line:        return .Line
	case .Pen:         return .Pen
	case .Highlighter: return .Highlighter
	case .Text:        return .Text
	case .Pixelate:    return .Pixelate
	case .Blur:        return .Blur
	}
	return .Select
}

// The style a bar shows, and which of its properties apply: the selection's (what all the shapes picked have), else
// the tool's.
style_shown :: proc(m: ^Model) -> (style: Style, props: Props) {
	if s := selected_shape(m); s != nil {
		props = kind_props(s.kind)
		if m.doc.picked_count > 1 {
			for k in m.doc.picked_kinds { props &= kind_props(k) }
		}
		return s.style, props
	}
	if k, ok := tool_kind(m.tool); ok { return m.styles[m.tool], kind_props(k) }
	return STYLE_DEFAULT, {}
}

// to with the fields that differ between was and now set to now's: a change of the bar, given to every shape picked
// without changing what they do not share.
@(private)
style_merge :: proc(to, was, now: Style) -> Style {
	out := to
	if was.color != now.color             { out.color = now.color }
	if was.fill_color != now.fill_color   { out.fill_color = now.fill_color }
	if was.width != now.width             { out.width = now.width }
	if was.text_size != now.text_size     { out.text_size = now.text_size }
	if was.text_look != now.text_look     { out.text_look = now.text_look }
	if was.bold != now.bold               { out.bold = now.bold }
	if was.dash != now.dash               { out.dash = now.dash }
	if was.radius != now.radius           { out.radius = now.radius }
	if was.heads != now.heads             { out.heads = now.heads }
	if was.pixel_size != now.pixel_size   { out.pixel_size = now.pixel_size }
	if was.blur_radius != now.blur_radius { out.blur_radius = now.blur_radius }
	return out
}

// The one field that differs between two styles, when it is one a run goes through; None: another, or several.
@(private)
run_field :: proc(a, b: Style) -> Run_Field {
	x, y := a, b
	field := Run_Field.None
	if x.color != y.color { field = .Color; x.color = y.color }
	if x.fill_color != y.fill_color { if field != .None { return .None }; field = .Fill_Color; x.fill_color = y.fill_color }
	if x.width != y.width { if field != .None { return .None }; field = .Width; x.width = y.width }
	if x.radius != y.radius { if field != .None { return .None }; field = .Radius; x.radius = y.radius }
	return x == y ? field : .None
}

// A style set from a bar: on the shapes picked (one undo step) and on the tool that draws the one shown, else on the
// current tool. The values of one field that a slider runs through, one after the other on one selection, are one step.
style_set :: proc(m: ^Model, style: Style) -> bool {
	if !idle(m) { return false }
	if s := selected_shape(m); s != nil {
		if s.style == style { return false }
		was := s.style
		field := run_field(was, style)
		run := field != .None && m.run_field == field && m.run_shape == m.doc.selected + 1 && m.run_undo == len(m.doc.history.undo) && !tk_undo.can_redo(&m.doc.history)
		if !run { change_begin(&m.doc) }
		for &x in m.doc.shapes {
			if !x.picked { continue }
			x.style = style_merge(x.style, was, style)
			shape_refresh(&m.doc, &x)
		}
		if run { m.doc.edits += 1 } else { change_end(&m.doc) }
		m.run_field, m.run_shape, m.run_undo = field, field != .None ? m.doc.selected + 1 : 0, len(m.doc.history.undo)
		m.styles[kind_tool(m.doc.shapes[m.doc.selected].kind)] = style_merge(m.styles[kind_tool(m.doc.shapes[m.doc.selected].kind)], was, style)
		m.changes += 1
		return true
	}
	if _, ok := tool_kind(m.tool); !ok { return false }
	if m.styles[m.tool] == style { return false }
	m.styles[m.tool] = style
	m.changes += 1
	return true
}

// Takes the crop away (one undo step).
crop_clear :: proc(m: ^Model) -> bool {
	if !idle(m) || !m.doc.has_crop { return false }
	change_begin(&m.doc)
	m.doc.has_crop = false
	m.doc.crop = {}
	change_end(&m.doc)
	m.changes += 1
	return true
}

// The crop set to box (picture pixels, within the picture); one undo step. False: it keeps all of the picture, or it is
// the crop already.
crop_set :: proc(m: ^Model, box: Box) -> bool {
	if !idle(m) { return false }
	r := Box{picture_clamp(&m.doc, box.min), picture_clamp(&m.doc, box.max)}
	size := box_size(r)
	if size.x < 1 || size.y < 1 || (r.min == {0, 0} && r.max == m.doc.size) { return false }
	if m.doc.has_crop && m.doc.crop == r { return false }
	change_begin(&m.doc)
	m.doc.crop, m.doc.has_crop = r, true
	change_end(&m.doc)
	m.changes += 1
	return true
}

// The box of a box selection going on (picture pixels); ok false: none.
selecting_shown :: proc(m: ^Model) -> (box: Box, ok: bool) {
	s := m.mode.(Selecting) or_return
	return box_of(s.start, s.at), true
}

// The text being typed: its shape's index; ok false: none.
typing_index :: proc(m: ^Model) -> (index: int, ok: bool) {
	s := m.mode.(Typing) or_return
	return s.index, true
}

////////////////////////////////
// The interaction

// Applies an event. False: it means nothing in the current mode (a release with nothing pressed, a wheel during a drag).
step :: proc(m: ^Model, e: Event) -> bool {
	done := step_mode(m, e)
	if done { m.changes += 1 }
	return done
}

@(private)
step_mode :: proc(m: ^Model, e: Event) -> bool {
	doc := &m.doc
	switch &s in m.mode {
	case Idle:
		#partial switch v in e {
		case Press: return idle_press(m, v)
		case Wheel: return wheel(m, v)
		}
	case Drawing:
		#partial switch v in e {
		case Move:
			drawing_follow(m, s, to_picture(m.view, v.at), v.shift, v.time, v.pressure, v.tilt)
			return true
		case Release:
			if v.button != .Left { return false }
			sh := &doc.shapes[s.index]
			if sh.kind != .Pen { drawing_follow(m, s, to_picture(m.view, v.at), v.shift, 0, 0, {}) }
			// (a press with no drag drew nothing worth keeping: a box or a line too small to see; a pen's dot stays)
			r := shape_box(doc, sh)
			small := max(r.max.x - r.min.x, r.max.y - r.min.y) * m.view.zoom < SMALL_PX
			if small && sh.kind != .Pen {
				shape_free(sh)
				ordered_remove(&doc.shapes, s.index)
				select_only(doc, -1)
				change_end(doc)
				m.mode = Idle{}
				return true
			}
			if sh.kind == .Pen { pen_trace(doc, sh) }
			change_end(doc)
			m.mode = Idle{}
			return true
		}
	case Moving:
		#partial switch v in e {
		case Move:
			p := to_picture(m.view, v.at)
			picked_translate(doc, p - s.last)
			s.last = p
			return true
		case Release:
			if v.button != .Left { return false }
			p := to_picture(m.view, v.at)
			picked_translate(doc, p - s.last)
			change_end(doc)
			m.mode = Idle{}
			return true
		}
	case Resizing:
		#partial switch v in e {
		case Move:
			resizing_follow(m, s, to_picture(m.view, v.at), v.shift)
			return true
		case Release:
			if v.button != .Left { return false }
			resizing_follow(m, s, to_picture(m.view, v.at), v.shift)
			if s.index < 0 {
				r := box_size(doc.crop)
				if r.x < 1 || r.y < 1 { doc.has_crop, doc.crop = false, Box{} }
			}
			change_end(doc)
			m.mode = Idle{}
			return true
		}
	case Panning:
		#partial switch v in e {
		case Move:
			m.view.offset += v.at - s.last
			s.last = v.at
			return true
		case Release:
			m.view.offset += v.at - s.last
			m.mode = Idle{}
			return true
		}
	case Cropping:
		#partial switch v in e {
		case Move:
			cropping_follow(m, s.start, to_picture(m.view, v.at), v.shift)
			return true
		case Release:
			if v.button != .Left { return false }
			cropping_follow(m, s.start, to_picture(m.view, v.at), v.shift)
			r := box_size(doc.crop) * m.view.zoom
			if r.x < SMALL_PX || r.y < SMALL_PX { doc.has_crop, doc.crop = false, Box{} }   // (a click: no crop)
			change_end(doc)
			m.mode = Idle{}
			return true
		}
	case Selecting:
		#partial switch v in e {
		case Move:
			s.at = to_picture(m.view, v.at)
			return true
		case Release:
			if v.button != .Left { return false }
			s.at = to_picture(m.view, v.at)
			box := box_of(s.start, s.at)
			size := box_size(box) * m.view.zoom
			if max(size.x, size.y) >= SMALL_PX {
				// (what it touches, as a press takes a shape near its stroke)
				for &x, i in doc.shapes {
					if !box_touches(box, shape_box(doc, &x)) { continue }
					x.picked = true
					doc.selected = i
				}
			}
			picks_update(doc)
			m.mode = Idle{}
			return true
		}
	case Typing:
		#partial switch v in e {
		case Typed:
			sh := &doc.shapes[s.index]
			if sh.text == v.text { return false }
			delete(sh.text)
			sh.text = strings.clone(v.text)
			shape_refresh(doc, sh)
			return true
		case Type_End:
			typing_end(m, s, v.keep)
			return true
		case Press:
			// (a press elsewhere ends the text, kept; it does nothing else: the next press draws)
			typing_end(m, s, true)
			return true
		case Wheel:
			return wheel(m, v)
		}
	}
	return false
}

@(private)
picked_translate :: proc(doc: ^Doc, d: Vec) {
	for &x in doc.shapes { if x.picked { shape_translate(&x, d) } }
}

@(private)
idle_press :: proc(m: ^Model, v: Press) -> bool {
	doc := &m.doc
	if v.button == .Middle || (v.button == .Left && v.pan) {
		m.mode = Panning{last = v.at}
		m.view.fit = false
		return true
	}
	p := to_picture(m.view, v.at)
	tolerance := HIT_PX / m.view.zoom
	if v.button == .Right {
		// (a right press on a shape selects it, with any tool: the widget opens its menu; on a shape of the selection,
		// the selection stays, for its menu; elsewhere it means nothing)
		h := hit(doc, p, tolerance)
		if h < 0 { return false }
		if doc.shapes[h].picked { doc.selected = h } else { select_only(doc, h) }
		return true
	}
	if m.tool == .Crop {
		// (the crop's handles adjust it; a press elsewhere draws another)
		if h := crop_handle_hit(doc, p, HANDLE_PX / m.view.zoom); h != .None {
			change_begin(doc)
			m.mode = Resizing{index = -1, handle = h, start = p, a = doc.crop.min, b = doc.crop.max}
			return true
		}
		change_begin(doc)
		start := picture_clamp(doc, p)
		m.mode = Cropping{start = start}
		doc.crop, doc.has_crop = Box{start, start}, true
		return true
	}
	// (the selected shape's handles first, with any tool: a shape just drawn is resized at once)
	if h := handle_hit(doc, p, HANDLE_PX / m.view.zoom); h != .None {
		sh := &doc.shapes[doc.selected]
		change_begin(doc)
		m.mode = Resizing{index = doc.selected, handle = h, start = p, a = sh.a, b = sh.b}
		return true
	}
	h := hit(doc, p, tolerance)
	if h >= 0 && !v.shift && doc.shapes[h].kind == .Text && (v.double || m.tool == .Text) {
		typing_start(m, h, fresh = false)
		return true
	}
	if m.tool == .Select && v.shift {
		// (Shift: a shape added to the selection or taken from it; elsewhere a box that adds what it touches)
		if h >= 0 {
			doc.shapes[h].picked = !doc.shapes[h].picked
			if doc.shapes[h].picked { doc.selected = h }
			picks_update(doc)
			return true
		}
		m.mode = Selecting{start = p, at = p, add = true}
		return true
	}
	// (Select takes any shape; a drawing tool takes one of the selection, and draws over the others)
	if h >= 0 && (m.tool == .Select || doc.shapes[h].picked) {
		if doc.shapes[h].picked { doc.selected = h } else { select_only(doc, h) }
		change_begin(doc)
		m.mode = Moving{last = p}
		return true
	}
	kind, draws := tool_kind(m.tool)
	if !draws {
		// (Select on nothing: a box that picks what it touches)
		select_only(doc, -1)
		m.mode = Selecting{start = p, at = p}
		return true
	}
	change_begin(doc)
	sh := Shape{kind = kind, a = p, b = p, style = m.styles[m.tool]}
	if kind == .Pen { append(&sh.samples, ink.Sample{at = p, time = v.time, pressure = v.pressure, tilt = v.tilt}) }
	append(&doc.shapes, sh)
	i := len(doc.shapes) - 1
	select_only(doc, i)
	if kind == .Text {
		shape_refresh(doc, &doc.shapes[i])
		typing_start(m, i, fresh = true)
		return true
	}
	if kind == .Pen { pen_trace(doc, &doc.shapes[i]) }
	m.mode = Drawing{index = i}
	return true
}

@(private)
drawing_follow :: proc(m: ^Model, s: Drawing, p: Vec, shift: bool, time: f64, pressure: f32, tilt: [2]f32) {
	sh := &m.doc.shapes[s.index]
	#partial switch sh.kind {
	case .Rectangle, .Ellipse, .Highlighter, .Pixelate, .Blur:
		sh.b = shift ? square(sh.a, p) : p
	case .Arrow, .Line:
		sh.b = shift ? snap_45(sh.a, p) : p
	case .Pen:
		// (a sample only where the pointer went far enough: a held mouse adds none)
		last := sh.samples[len(sh.samples) - 1].at
		if length(p - last) * m.view.zoom < 1 { return }
		append(&sh.samples, ink.Sample{at = p, time = time, pressure = pressure, tilt = tilt})
		pen_trace(&m.doc, sh)
	}
}

// A handle follows the pointer: a box's side or corner, a line's end, the scale of a text or a drawing, or a side or a
// corner of the crop.
@(private)
resizing_follow :: proc(m: ^Model, s: Resizing, p: Vec, shift: bool) {
	doc := &m.doc
	if s.index < 0 {
		box: Shape
		shape_resize(&box, s.handle, s.a, s.b, p - s.start, false)
		doc.crop = box_of(picture_clamp(doc, box.a), picture_clamp(doc, box.b))
		doc.has_crop = true
		return
	}
	sh := &doc.shapes[s.index]
	if s.handle == .Scale {
		// (the shape as the gesture found it: change_begin kept the whole document)
		if !doc.has_pending || s.index >= len(doc.pending.shapes) { return }
		shape_scale(doc, sh, &doc.pending.shapes[s.index], p - s.start)
		return
	}
	shape_resize(sh, s.handle, s.a, s.b, p - s.start, shift)
}

@(private)
cropping_follow :: proc(m: ^Model, start, p: Vec, shift: bool) {
	q := picture_clamp(&m.doc, shift ? square(start, p) : p)
	m.doc.crop = box_of(start, q)
	m.doc.has_crop = true
}

@(private)
wheel :: proc(m: ^Model, v: Wheel) -> bool {
	if v.zoom {
		if v.delta.y == 0 { return false }
		view_zoom(m, math.pow(f32(ZOOM_STEP), -v.delta.y), v.at)
		return true
	}
	d := v.sideways ? Vec{v.delta.y, v.delta.x} : v.delta
	m.view.offset -= d * WHEEL_PAN_PX
	m.view.fit = false
	return true
}

@(private)
typing_start :: proc(m: ^Model, index: int, fresh: bool) {
	// (a new text was added inside a change already begun; an old one begins its change here)
	if !fresh { change_begin(&m.doc) }
	select_only(&m.doc, index)
	m.mode = Typing{index = index, before = strings.clone(m.doc.shapes[index].text), fresh = fresh}
	m.typing += 1
}

@(private)
typing_end :: proc(m: ^Model, s: Typing, keep: bool) {
	doc := &m.doc
	sh := &doc.shapes[s.index]
	if !keep {
		delete(sh.text)
		sh.text = strings.clone(s.before)
		shape_refresh(doc, sh)
	}
	// (a text left empty, or only blanks, is no text)
	if strings.trim_space(sh.text) == "" {
		shape_free(sh)
		ordered_remove(&doc.shapes, s.index)
		select_only(doc, -1)
	} else {
		select_only(doc, s.index)
	}
	delete(s.before)
	change_end(doc)
	m.mode = Idle{}
}
