package ui

// A place that shows one face at a time and morphs from one to the next (src/md/features/transitions.md): its size glides
// from the last face's to the new one's, the face's shape (its first box's own look) morphs from the old one to the new,
// and the content crosses over it: the old one, a record of its last drawing, fades out, the new one fades in.
//
//	if ui.swap("###badge", downloading ? "bar" : "button") {
//		if downloading { ui.progress("###bar", share) } else { ui.button("install", "Install") }
//	}

import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "base:runtime"
import "../draw"

// How long a change of face takes, the glide and the morph (ms), on SWAP_EASE.
// (700 on a sine was "too linear": a symmetric curve; 600 on the emphasized curve starts at once and lands slowly)
SWAP_MS :: 600
@(private = "file") SWAP_EASE :: Ease.Emphasized

// Everything of a run moves at once, on the one curve of the shape: the old content fades as the new face comes, whole,
// from the first frame to the last. (Parts one after the other read as steps, not as one change: the person saw it.)
@(private = "file") SWAP_ALPHA_EPS :: 0.002
// The clip of a run, past the morphing shape (logical px): along the axis, the room of an edge drawn outside a face's
// rect (a well's rim, 1 px); across it, the room of a shadow, which the words never need cut. (3 px along the axis
// showed a wider new face's body cut square past the shape's round end)
@(private = "file") SWAP_EDGE_ROOM :: 1
// The faces' other content (an icon, a bar's fill), as shares of the run: the old one gone by SWAP_OLD_GONE, the new one
// from SWAP_REST_FROM. The words morph across the whole run and the shape changes under them; the rest does not cross
// them while they slide (the person saw an icon over the first letters).
// (0.15: the words slide on the emphasized curve, quick at first, and cross an icon at the face's start within the
// first fifth; at 0.4 the old icon was still under them)
@(private = "file") SWAP_OLD_GONE :: 0.15
@(private = "file") SWAP_REST_FROM :: 0.4
// The words' roll, character by character, as shares of the run: an old character starts to rise out within the first
// SWAP_WORDS_OUT_STAGGER (the first on the left first) and is gone SWAP_WORDS_OUT_SPAN later; a new one starts to come up
// from SWAP_WORDS_IN_FROM, within the next SWAP_WORDS_IN_STAGGER, and is in place SWAP_WORDS_IN_SPAN later. Each moves by
// SWAP_WORDS_RISE of the font's size.
@(private = "file") SWAP_WORDS_OUT_STAGGER :: 0.3
@(private = "file") SWAP_WORDS_OUT_SPAN :: 0.3
@(private = "file") SWAP_WORDS_IN_FROM :: 0.15
@(private = "file") SWAP_WORDS_IN_STAGGER :: 0.4
@(private = "file") SWAP_WORDS_IN_SPAN :: 0.45
@(private = "file") SWAP_WORDS_RISE :: 0.7

// Whether `inner` is in `outer`'s subtree (not `outer` itself).
@(private = "file")
box_holds :: proc(outer, inner: ^Box) -> bool {
	if outer == nil || inner == nil { return false }
	for a := inner.parent; a != nil; a = a.parent { if a == outer { return true } }
	return false
}
@(private = "file") SWAP_ACROSS_ROOM :: 16

// A face's shape: what the morph draws (rect, radii, face, border). A colour of alpha 0: none.
@(private)
Swap_Shape :: struct {
	rect:     Rect,
	radii:    [4]f32,
	face:     Face,
	border:   Color,
	border_w: f32,
}

// A face's main words, as they were recorded: their text (owned, heap: cloned when it changes) and their ink.
@(private)
Swap_Words :: struct {
	text: string,
	ink:  Color,
	at:   Vec2,   // where they were drawn (their baseline origin, the face at its natural size)
}

Swap_Options :: struct {
	ms:    f32,           // the run's length (0: SWAP_MS)
	axis:  Axis,          // what is built in it is laid out along it (.X: a row)
	// where the faces hold along the axis while the swap glides: .Center (each stands past both edges by half), .Start (a
	// place read from its start, a bar's badge: the faces stay put and only stand past the end), .End
	align: Cross_Align,
}

// What a swap keeps between builds. On the heap, one per swap: the draw context holds the address of its pictures.
@(private)
Swap_Memory :: struct {
	face:     Key,                 // the face it shows (its name's hash)
	start:    f64,                 // when the run began (time_ms)
	ms:       f32,
	align:    Cross_Align,         // Swap_Options.align
	running:  bool,
	from:     Vec2,                // the size the run glides from
	shown:    Vec2,                // the size the last layout gave it
	pics:     [2]draw.Picture,     // the records of the content, bare: [cur] this face's last drawing, the other the face it left
	shapes:   [2]Swap_Shape,       // the face's shape with each record
	words:    [2]Swap_Words,       // the face's main words with each record (not in it: they morph by character)
	drawn_at: [2]Rect,             // where the swap was when each was drawn
	cur:      int,
	fresh:    bool,                // pics[cur] was recorded since the face last changed
	old:      bool,                // the other picture holds the face it left: the run replays it
	drawing:  bool,                // (swap_draw is drawing the box: draw_box draws it as any box)
	seen:     u64,
}

// `if ui.swap(id, face) { ... }`: a box sized by what is built in it (unless `next` says otherwise), its children laid out
// along `o.axis`, centred across it. `face` names what it shows now; when it changes, the size glides, the shape of the
// first box built in it is drawn at the glided size, its colour morphs from the old face's, the contents cross and the
// main words change by character. What is built in it keeps its own layout, held at the swap's start (o.align), never
// squeezed nor wrapped; during a change it is clipped to the morphing shape.
// Only the face built now takes input: the old one is a picture. Animations off: the face changes in one frame.
@(require_results, deferred_none = pop_parent)
swap :: proc(id: string, face: string, o: Swap_Options = {}) -> bool {
	s := gs()
	next_default({width = children_sum(), height = children_sum(), axis = o.axis, cross = .Center})
	b := build_box({}, id)
	push_parent(b)
	k := key_from_string(0, face)
	m := s.swaps[b.key] or_else nil
	if m == nil {
		m = new(Swap_Memory, runtime.heap_allocator())
		m.face = k
		s.swaps[b.key] = m
	} else if m.face != k {
		m.face = k
		if s.anim_rate != 0 {
			m.from, m.start, m.running = m.shown, s.time_ms, true
			// (a face never drawn, two changes between two frames, leaves the face drawn last as the old one)
			if m.fresh { m.cur, m.old, m.fresh = 1 - m.cur, true, false }
		}
	}
	m.ms = o.ms > 0 ? o.ms : SWAP_MS
	m.align = o.align
	m.seen = s.build_index
	if m.running && (s.anim_rate == 0 || s.time_ms - m.start >= f64(m.ms)) { m.running, m.old = false, false }
	if m.running { s.anim_busy = true }
	b.swap = m
	return true
}

// While drawing: whether `b` is drawn bare, its content without its shape (a swap's face, while the swap records it or
// morphs). A custom draw that paints its own ground (.Custom_Ground) skips it then.
box_bare :: proc(b: ^Box) -> bool {
	s := gs()
	return s.bare_key != 0 && b != nil && s.bare_key == b.key
}

// The shape `b` draws (none for nil): its rect, drawn radii, face and border, as draw_box would paint them.
@(private)
swap_shape_of :: proc(s: ^State, b: ^Box) -> Swap_Shape {
	if b == nil { return {} }
	sh := Swap_Shape{rect = b.rect, radii = box_drawn_radii(s, b), face = box_face(s, b)}
	// (a custom ground, a well, is sunk: the finish's light on a raised face is not its look)
	if .Custom_Ground in b.flags { sh.face.sheen, sh.face.rim = 0, false }
	if .Draw_Border in b.flags && .Row not_in b.flags && b.border.a > SWAP_ALPHA_EPS {
		sh.border, sh.border_w = b.border, max(1, math.round(s.scale))
	}
	return sh
}

// `a` toward `b` by `t`; a colour of alpha 0 takes the other's hue, so that a shape that comes from nothing does not
// pass through black.
@(private = "file")
swap_color_mix :: proc(a, b: Color, t: f32) -> Color {
	a, b := a, b
	if a.a <= SWAP_ALPHA_EPS { a = {b.r, b.g, b.b, 0} }
	if b.a <= SWAP_ALPHA_EPS { b = {a.r, a.g, a.b, 0} }
	return draw.mix(a, b, t)
}

@(private)
swap_shape_mix :: proc(a, b: Swap_Shape, t: f32) -> (m: Swap_Shape) {
	lerp :: proc(x, y, t: f32) -> f32 { return x + (y - x) * t }
	m.rect = {a.rect.min + (b.rect.min - a.rect.min) * t, a.rect.max + (b.rect.max - a.rect.max) * t}
	for i in 0 ..< 4 { m.radii[i] = lerp(a.radii[i], b.radii[i], t) }
	m.face.color = swap_color_mix(a.face.color, b.face.color, t)
	m.face.sheen = lerp(a.face.sheen, b.face.sheen, t)
	m.face.sunk = lerp(a.face.sunk, b.face.sunk, t)
	m.face.appear = lerp(a.face.appear, b.face.appear, t)
	m.face.rim = t < 0.5 ? a.face.rim : b.face.rim
	m.face.raised = t < 0.5 ? a.face.raised : b.face.raised
	m.border = swap_color_mix(a.border, b.border, t)
	m.border_w = a.border_w > 0 && b.border_w > 0 ? lerp(a.border_w, b.border_w, t) : max(a.border_w, b.border_w)
	return
}

@(private = "file")
swap_shape_draw :: proc(s: ^State, dc: ^draw.Context, sh: Swap_Shape) {
	if sh.rect.max.x <= sh.rect.min.x || sh.rect.max.y <= sh.rect.min.y { return }
	draw_face(s, dc, sh.rect, sh.radii, sh.face)
	if sh.border_w > 0 && sh.border.a > SWAP_ALPHA_EPS { draw.rect_corners(dc, sh.rect, colors4(sh.border), sh.radii, sh.border_w) }
}

// The swap's box drawn with its face (`face`, nil: none) bare.
@(private = "file")
swap_draw_bare :: proc(s: ^State, dc: ^draw.Context, b, face: ^Box, scale: f32) {
	was := s.bare_key
	s.bare_key = face != nil ? face.key : 0
	draw_box(s, dc, b, scale)
	s.bare_key = was
}

// How far the run is (0..1); 1 when none runs.
@(private)
swap_progress :: proc(m: ^Swap_Memory) -> f32 {
	if !m.running { return 1 }
	return clamp(f32(gs().time_ms - m.start) / m.ms, 0, 1)
}

// The size a swap shows along an axis it is sized by its children: `natural` (what is in it), or during a run on the way
// from the size it showed when the face changed.
@(private)
swap_glide :: proc(m: ^Swap_Memory, axis: Axis, natural: f32) -> f32 {
	if !m.running { return natural }
	p := swap_progress(m)
	from := m.from[int(axis)]
	return from + (natural - from) * ease_at(SWAP_EASE, p)
}

// A face's main words: the box with the widest text in its subtree (nil: none). An icon's glyph is narrower than the
// words beside it; a bar's words are its own box's.
@(private = "file")
swap_main_box :: proc(b: ^Box) -> (best: ^Box) {
	if b == nil { return nil }
	if b.text != "" { best = b }
	for c := b.first; c != nil; c = c.next {
		if m := swap_main_box(c); m != nil && (best == nil || m.text_dim.x > best.text_dim.x) { best = m }
	}
	return
}

// The rect `main` has at its natural size: a face drawn at a running swap's glided size is wider or narrower than what
// its layout gave its words; held as the swap holds its faces (Swap_Options.align).
@(private = "file")
swap_words_rect :: proc(m: ^Swap_Memory, main: ^Box, ai: int) -> Rect {
	r := main.rect
	room := r.max[ai] - r.min[ai]
	if main.size[ai] == room { return r }
	#partial switch m.align {
	case .Center: r.min[ai] -= (main.size[ai] - room) * 0.5
	case .End:    r.min[ai] -= main.size[ai] - room
	}
	r.max[ai] = r.min[ai] + main.size[ai]
	return r
}

// Keeps the main words of record `i` (`main`, nil: none): their text, cloned only when it changed, their ink and place.
@(private = "file")
swap_words_keep :: proc(s: ^State, m: ^Swap_Memory, i: int, main: ^Box, ai: int) {
	w := &m.words[i]
	text := main != nil ? main.text : ""
	if w.text != text {
		delete(w.text, runtime.heap_allocator())
		w.text = text == "" ? "" : strings.clone(text, runtime.heap_allocator())
	}
	if main == nil { return }
	w.ink = main.text_color
	rect := main.rect
	main.rect = swap_words_rect(m, main, ai)
	w.at = text_origin(s, main, main.text_dim)
	main.rect = rect
}

// The main words drawn once, morphing by character from `from` to the text of `main` (morph_text), their ink and their
// place from the old ones' (moved by `d`, as the old record) to the new ones' on `k`, never truncated.
@(private = "file")
swap_words_draw :: proc(s: ^State, dc: ^draw.Context, m: ^Swap_Memory, main: ^Box, from: Swap_Words, d: Vec2, ai: int, k: f32) {
	// (a roll of whole words: the old ones rise and fade, the new ones come up from below into their place, a little
	// after. Each word stays whole, set as a word: characters flipping through random letters read as a glitch, and
	// glyphs moving one by one lost their spacing and crossed each other, the person saw both)
	rect := main.rect
	main.rect = swap_words_rect(m, main, ai)
	to_at := text_origin(s, main, main.text_dim)
	main.rect = rect
	p := swap_progress(m)
	size := main.font_size
	rise := size * SWAP_WORDS_RISE
	// (each character rolls in its own slot, as an odometer: the old ones up and out, the new ones up from below, the
	// slots one after the other from the left; clipped to the line's band, so they roll under its edges rather than
	// float. A character's place is the width of the words before it, measured whole: kerning kept)
	line := Rect{{-1e6, min(from.at.y + d.y, to_at.y) - size * 0.95}, {1e6, max(from.at.y + d.y, to_at.y) + size * 0.3}}
	draw.push_clip(dc, line)
	defer draw.pop_clip(dc)
	roll :: proc(dc: ^draw.Context, b: ^Box, text: string, at: Vec2, ink: Color, p, from, stagger, span, rise: f32, going: bool) {
		n := utf8.rune_count(text)
		i := 0
		for r, off in text {
			defer i += 1
			if r == ' ' { continue }
			t := ease_at(.Out, (p - from - stagger * f32(i) / f32(max(n, 1))) / span)
			alpha := going ? 1 - t : t
			if alpha <= SWAP_ALPHA_EPS { continue }
			x := text_width(b.font, b.font_size, text[:off])
			y := going ? -rise * t : rise * (1 - t)
			c := ink
			c.a *= alpha
			draw.text(dc, b.font, b.font_size, at + {x, y}, c, text[off:off + utf8.rune_size(r)])
		}
	}
	if from.text != "" {
		roll(dc, main, from.text, from.at + d, from.ink, p, 0, SWAP_WORDS_OUT_STAGGER, SWAP_WORDS_OUT_SPAN, rise, true)
	}
	if main.text != "" {
		roll(dc, main, main.text, to_at, main.text_color, p, SWAP_WORDS_IN_FROM, SWAP_WORDS_IN_STAGGER, SWAP_WORDS_IN_SPAN, rise, false)
	}
}

// A swap drawn. At rest: as any box. During a run: one shape morphing from the old face's to the new one's, the old
// content's record fading out over it as the new face fades in whole, all on the shape's curve, clipped to the shape. Then its
// content drawn again, bare, into this face's record, with its shape kept, for the change that may come. Drawn twice
// rather than recorded and replayed: an idle swap costs no upload and its pixels are compared as any box's by the partial
// redraw (a replay is redrawn every frame).
@(private)
swap_draw :: proc(s: ^State, dc: ^draw.Context, b: ^Box, scale: f32) {
	m := b.swap
	m.drawing = true
	defer m.drawing = false
	face := b.first   // (its face: the first box built in it)
	main := swap_main_box(face)
	if !m.running {
		draw_box(s, dc, b, scale)
	} else {
		p := swap_progress(m)
		now := swap_shape_of(s, face)
		// (the old face held where the new one is: at the swap's start, centre or end along its axis as it is now; centred across)
		d: Vec2
		if m.old {
			was := m.drawn_at[1 - m.cur]
			d = draw.rect_center(b.rect) - draw.rect_center(was)
			ai := int(b.layout_axis)
			#partial switch m.align {
			case .Start: d[ai] = b.rect.min[ai] - was.min[ai]
			case .End:   d[ai] = b.rect.max[ai] - was.max[ai]
			}
		}
		from := now
		if m.old {
			from = m.shapes[1 - m.cur]
			from.rect = {from.rect.min + d, from.rect.max + d}
		}
		k := ease_at(SWAP_EASE, p)
		ai := int(b.layout_axis)
		sh := swap_shape_mix(from, now, k)
		// (along the axis, the face's own rect: it glides with the swap already, and a shape eased again lagged it)
		if face != nil {
			sh.rect.min[ai] = now.rect.min[ai]
			sh.rect.max[ai] = now.rect.max[ai]
		}
		swap_shape_draw(s, dc, sh)
		// (the contents inside the shape: words wider than it are revealed as it grows, never spilled past its edge. Along
		// the axis only, and a few pixels wide of the shape: what a face draws outside its rect (a well's lit rim and lip,
		// a key's shadow) comes with it on the curve. Clipped to the shape's own rect and corners, the bar's rim was cut
		// for the whole run and appeared at once on its last frame: the person saw the border go from nothing to full)
		clipped := sh.rect.max.x > sh.rect.min.x && sh.rect.max.y > sh.rect.min.y
		if clipped {
			room := sh.rect
			pad := SWAP_EDGE_ROOM * s.scale
			room.min[ai] -= pad
			room.max[ai] += pad
			across := 1 - ai
			room.min[across] -= SWAP_ACROSS_ROOM * s.scale
			room.max[across] += SWAP_ACROSS_ROOM * s.scale
			// (its corners the shape's, grown by the room: a square clip showed the wider new face's ground past the
			// shape's round end as a square band)
			r := sh.radii
			for &c in r { c += pad }
			draw.push_clip_rounded(dc, room, r)
		}
		defer if clipped { draw.pop_clip(dc) }
		if m.old {
			// (the old face's other content, its icon, a bar's fill, leaves in the first part: kept on the shape's curve,
			// it stood under the words sliding in, and the person saw them overlap)
			if a := 1 - ease_at(.Out, p / SWAP_OLD_GONE); a > SWAP_ALPHA_EPS {
				draw.push_alpha(dc, a)
				_ = draw.replay(dc, &m.pics[1 - m.cur], draw.affine_translate(d))   // (.Stale: the new face alone)
				draw.pop_alpha(dc)
			}
		}
		// (the new face whole, its edge and relief with it, on the shape's curve from the first frame: a face that came
		// bare and took its whole look over the second half showed its edge (a well's rim) all at once at the end)
		// (its main words hidden: they are drawn once, morphing by character, over both faces)
		// (its other content, its icon, comes once the old one has gone and the words have made room: on the shape's
		// curve it came under the words still sliding, and the person saw them overlap)
		words := main != nil ? main.text : ""
		if k > SWAP_ALPHA_EPS {
			if main != nil { main.text = "" }
			rest := ease_at(.Out, (p - SWAP_REST_FROM) / (1 - SWAP_REST_FROM))
			Kept :: struct { box: ^Box, transparency: f32 }
			kept := make([dynamic]Kept, context.temp_allocator)
			if face != nil {
				for c := face.first; c != nil; c = c.next {
					if c == main || box_holds(c, main) { continue }
					append(&kept, Kept{c, c.transparency})
					c.transparency = 1 - (1 - c.transparency) * rest
				}
			}
			if k < 1 { draw.push_alpha(dc, k) }
			draw_box(s, dc, b, scale)
			if k < 1 { draw.pop_alpha(dc) }
			// (set back: the transparency is the face's own)
			for e in kept { e.box.transparency = e.transparency }
			if main != nil { main.text = words }
		}
		if main != nil {
			if m.old {
				swap_words_draw(s, dc, m, main, m.words[1 - m.cur], d, ai, k)
			} else {
				// (no old face recorded: the words as they are)
				rect := main.rect
				main.rect = swap_words_rect(m, main, ai)
				draw_box_text(s, dc, main)
				main.rect = rect
			}
		}
	}
	// (animations off there is no run to replay it in; a swap inside a recording is drawn into it, not recorded again)
	if s.anim_rate != 0 && draw.recording(dc) == nil {
		m.shapes[m.cur] = swap_shape_of(s, face)
		// (recorded without its main words: a run morphs them, it does not fade them)
		words := main != nil ? main.text : ""
		swap_words_keep(s, m, m.cur, main, int(b.layout_axis))
		if main != nil { main.text = "" }
		draw.picture_begin(dc, &m.pics[m.cur])
		swap_draw_bare(s, dc, b, face, scale)
		draw.picture_end(dc)
		if main != nil { main.text = words }
		m.drawn_at[m.cur] = b.rect
		m.fresh = true
	}
}

// The swaps no longer built (one build of grace, as an animation's).
@(private)
swap_trim :: proc(s: ^State) {
	dead := make([dynamic]Key, context.temp_allocator)
	for k, m in s.swaps { if m.seen + 1 < s.build_index { append(&dead, k) } }
	for k in dead {
		swap_free(s.swaps[k])
		delete_key(&s.swaps, k)
	}
}

@(private)
swap_destroy :: proc(s: ^State) {
	for _, m in s.swaps { swap_free(m) }
	delete(s.swaps)
}

@(private = "file")
swap_free :: proc(m: ^Swap_Memory) {
	for &p in m.pics { draw.picture_destroy(&p) }
	for w in m.words { delete(w.text, runtime.heap_allocator()) }
	free(m, runtime.heap_allocator())
}
