package ui

import "../draw"

// A lively progress fill, for what the user waits on and watches come (a download): the green of a success button
// (intent .Success: the "Install" it was, the "Restart" it becomes), lit at its top, inside a darker border, flush in a
// well. A quiet ui.progress stays the default elsewhere.
//
// Words on the box (a badge) change ink where the green is under them: the theme's over the empty well, the success
// button's over the green. One ink for both read on one of them only.

@(private = "file") LIVELY_LIGHT :: 0.18   // the top: the button's colour toward white
@(private = "file") LIVELY_EDGE :: 0.35    // the border: toward black
// how long the fill takes to reach a new share (600 left it a tenth behind a download that ended, and the bar
// became the button at nine tenths)
@(private = "file") PROGRESS_FILL_MS :: 250

@(private = "file")
Lively_Draw :: struct { t: f32, well, green, ink, well_ink: Color }

// `b` shows a lively fill of `t` (0..1) under its words, if it has some (a label: a badge that became a download's bar,
// its words drawn by the fill). The share moves smoothly to `t`. `from` (0..1): where the fill starts the first time the
// box shows it; -1: at `t`. Its well is its background (.Custom_Ground): a swap morphs from or to it.
progress_fill :: proc(b: ^Box, t: f32, from: f32 = -1) {
	d := frame_new(Lively_Draw)
	share := clamp(t, 0, 1)
	// (a run of a set time on a curve, not anim's tail: the full bar drains in PROGRESS_FILL_MS, its landing soft)
	d.t = tween(key_from_string(b.key, "lively"), share, PROGRESS_FILL_MS, .Out, from >= 0 ? clamp(from, 0, 1) : share)
	d.well = color("well")
	d.green, d.ink = color("success_button background"), color("success_button text")
	b.custom, b.custom_user = lively_draw, d
	// (the well is its shape: a background a swap reads as its face, painted by lively_draw itself, not under it. Its
	// colour takes the fill's green by its share: a full bar morphing into a button was a dark well under a green that
	// faded, a dip to black in the middle of the change)
	b.flags += {.Draw_Background, .Custom_Ground}
	b.target_bg = draw.mix(d.well, d.green, d.t)
	b.bg = b.target_bg
	// (its words' ink as seen, the same way: a swap morphing a full bar's words starts from the green's ink, not from the
	// well's, which no pixel showed. Its own draw keeps each ink where it goes)
	d.well_ink = b.text_color
	b.text_color = draw.mix(d.well_ink, d.ink, d.t)
	// (the box keeps its words for its size and its reading; the fill draws them, over the well, in two inks)
	b.flags -= {.Draw_Text}
}

@(private = "file")
lively_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Lively_Draw)(user)
	s := gs()
	r := b.rect
	h := r.max.y - r.min.y
	if h <= 0 || r.max.x <= r.min.x { return }
	radius := rad(min(b.radius > 0 ? b.radius : h * 0.5, h * 0.5))
	// (drawn bare, in a swap: the well is the swap's morphing shape)
	if !box_bare(b) { machined_well(dc, r, radius, d.well) }
	words := b.text != ""
	ink := b.text_color
	defer b.text_color = ink
	b.text_color = d.well_ink
	if words { draw_box_text(s, dc, b) }
	if d.t <= 0 { return }
	// (flush with the track: its edges, its left corners; its leading edge straight, and the track's shape clips it, so
	// it never pokes past the track's right corners. Its border is drawn round the whole track and clipped to the fill:
	// the fill's top, bottom and left lines are the track's, its right line the leading edge)
	// (from nothing: the track's rounded clip shapes its first pixels. A fill at least as wide as the corner jumped from
	// nothing to a stub at the first percent, and the person saw "the first step filled at once")
	p := px1()
	f := Rect{r.min, {r.min.x + (r.max.x - r.min.x) * d.t, r.max.y}}
	edge := draw.mix(d.green, Color{0, 0, 0, 1}, LIVELY_EDGE)
	stops := [?]draw.Gradient_Stop{{color = draw.mix(d.green, draw.WHITE, LIVELY_LIGHT), pos = 0}, {color = d.green, pos = 1}}
	rr := [4]f32{radius, radius, radius, radius}
	draw.push_clip_rounded(dc, r, rr)
	draw.push_clip(dc, f)
	draw.gradient(dc, r, {kind = .Linear, start = {0, 0}, end = {0, h}, stops = stops[:]}, rr)
	draw.rect(dc, r, edge, radius, p)
	if words {
		b.text_color = d.ink
		draw_box_text(s, dc, b)
	}
	draw.pop_clip(dc)
	if d.t < 1 && f.max.x - r.min.x > p { draw.rect(dc, {{f.max.x - p, r.min.y}, {f.max.x, r.max.y}}, edge) }
	draw.pop_clip(dc)
}
