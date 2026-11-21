package ui

// The words on a selection (src/md/features/selection-contrast.md): a selected row's ground is a tint of the accent, not
// the page, so the colours made for the page do not hold there. A selected row computes its inks against its own ground,
// kept by (ground, colour), and gives them down to what is built in it (Box.ink, Box.ink_weak).

// WCAG AA for text: every word on a selection reads at this ratio at least, the weak ones too.
SELECTION_INK_RATIO :: 4.5

// The inks kept per window: a few grounds (a list's strong and weak selection, a menu's, the palette's) times a few
// colours. Past it the oldest is computed again: a cost, not a fault.
@(private) SELECTION_INK_MEMO :: 32
// Halvings of the weak ink's search: 1/4096 of the way, below a step of 8-bit sRGB.
@(private = "file") SELECTION_WEAK_STEPS :: 12

// The inks of a selection for one colour: `text` the colour made readable on the ground, `weak` the quieter words.
Selection_Ink :: struct { text, weak: Color }

// What a colour is to a selection: the text (it takes the row's ink), a quiet text (weak, faint, soft: the weak ink), or
// a colour of its own (a fault's red, a link: its hue kept, made readable).
@(private)
Ink_Kind :: enum u8 { Text, Quiet, Own }

@(private)
Selection_Ink_Memo :: struct { ground, hot, fg: Color, share: f32, ink: Selection_Ink }

// What a window keeps of the selection inks: the theme's texts and the weak one's share, for the theme's serial; the
// inks computed.
@(private)
Selection_Inks :: struct {
	made:   bool,
	theme:  ^Theme,
	serial: u64,
	text:   [2]Color,   // the theme's text and bright text: what takes the row's ink
	quiet:  [3]Color,   // the theme's weak, faint and soft text: what takes the weak ink
	share:  f32,        // the weak text's contrast on the page over the text's: how much quieter weak is (0..1)
	memo:   [SELECTION_INK_MEMO]Selection_Ink_Memo,
	count, next: int,
}

// The inks of `fg` on a selection whose face is `ground` at rest and `hot` under the pointer (both opaque; the
// same when it does not react). `text`: `fg` readable on both at SELECTION_INK_RATIO. `weak`: `text` mixed toward the
// ground as far as keeps the ratio `text` has times `share` (the theme's weak over its text, on the page), never under
// SELECTION_INK_RATIO: the weak words keep the step the theme gives them below the text where the ground has room, and
// read where it has not. Pure: the tests call it.
selection_ink :: proc(ground, hot, fg: Color, share: f32) -> (ink: Selection_Ink) {
	worst :: proc(c, a, b: Color) -> f32 { return min(contrast(c, a), contrast(c, b)) }
	g, h := Color{ground.r, ground.g, ground.b, 1}, Color{hot.r, hot.g, hot.b, 1}
	ink.text = readable(readable(fg, g, SELECTION_INK_RATIO), h, SELECTION_INK_RATIO)
	if worst(ink.text, g, h) < SELECTION_INK_RATIO {
		// (the two grounds pulled it apart, one each side of readable's pivot: of black and white, the one that reads
		// better on both)
		black, white := Color{0, 0, 0, fg.a}, Color{1, 1, 1, fg.a}
		ink.text = worst(black, g, h) > worst(white, g, h) ? black : white
	}
	ink.weak = ink.text
	target := max(SELECTION_INK_RATIO, worst(ink.text, g, h) * clamp(share, 0, 1))
	lo, hi: f32 = 0, 1
	for _ in 0 ..< SELECTION_WEAK_STEPS {
		mid := (lo + hi) * 0.5
		if worst(srgb_step(ink.text, g, mid), g, h) >= target { lo = mid } else { hi = mid }
	}
	if lo > 0 { ink.weak = srgb_step(ink.text, g, lo) }
	return
}

// A selected row's inks (b: a .Chosen box being built, its colours set): its ground is its background over what is under
// it, at rest and under the pointer, so its words read in both with no colour moving under them. (Not pressed: a press is
// the moment of a click, not a state anyone reads in.) Its words are the theme's selection ink (Theme_Selection.ink) when
// it gives one, else its text.
@(private)
chosen_inks :: proc(s: ^State, b, parent: ^Box, own_fg: bool) {
	under := box_under(parent)
	if under.a <= 0 { under = theme_lookup(s.theme, nil, "background"); under.a = 1 }   // (no frame drawn yet: no backdrop)
	// (do not gate on .Draw_Background: a program's custom-drawn .Chosen row omits .Draw_Background while still
	// carrying the theme's selection fill in b.target_bg; when b.target_bg.a == 0, face_over returns `under`)
	ground := face_over(b.target_bg, under, s.space)
	hot := ground
	if .Draw_Hot_Effects in b.flags {
		hover := color_from_tags(s, b.tags_key, "hover_fill")
		hot = srgb_step(ground, {hover.r, hover.g, hover.b, 1}, hover.a)
	}
	src := color("ink")
	if src.a <= 0 { src = color("text") }
	ink := selection_ink_of(s, ground, hot, {src.r, src.g, src.b, 1})
	b.ink, b.ink_weak, b.ink_ground, b.ink_hot = ink.text, ink.weak, ground, hot
	// (its own words, a sidebar's page drawn as a row, are on the same ground)
	if !own_fg { b.target_text = ink_for_state(s, b, b.target_text) }
}

// The colour of words `fg` drawn inside `row` (a selected/.Chosen row or any ancestor carrying a selection ink):
// returns `fg` unchanged when `row == nil` or `row.ink.a <= 0`; otherwise maps theme text to `row.ink`, quiet text
// (weak, faint, soft) to `row.ink_weak`, and any other colour (a badge, a fault's red) to its hue made readable on
// `row`'s ground. For a program that sets an explicit `next({fg = ...})` inside a selected row.
ink_for :: proc(row: ^Box, fg: Color) -> Color {
	if row == nil || row.ink.a <= 0 { return fg }
	return ink_for_state(gs(), row, fg)
}

// The colour of words `fg` built in `parent`, which has an ink: the text takes the ink, a quiet text the weak ink, a
// colour of its own (a fault's red) keeps its hue made readable on the selection; under an ink with no ground (a
// caption's band) everything takes the ink.
@(private)
ink_for_state :: proc(s: ^State, parent: ^Box, fg: Color) -> Color {
	if parent.ink_ground.a <= 0 { return parent.ink }
	switch ink_kind(s, fg) {
	case .Text:  return parent.ink
	case .Quiet: return parent.ink_weak.a > 0 ? parent.ink_weak : parent.ink
	case .Own:   return selection_ink_of(s, parent.ink_ground, parent.ink_hot, fg).text
	}
	return parent.ink
}

// What `fg` is to a selection under the theme shown (Ink_Kind). The texts are found by their colour: a "kbd text" or a
// "diff sign" is the weak text under another name.
@(private)
ink_kind :: proc(s: ^State, fg: Color) -> Ink_Kind {
	k := selection_inks_fresh(s)
	for q in k.quiet { if q == fg { return .Quiet } }
	for t in k.text { if t == fg { return .Text } }
	return .Own
}

// The inks of `fg` on a selection (selection_ink), kept: computed once per (ground, colour) and theme, not per row and
// frame.
@(private)
selection_ink_of :: proc(s: ^State, ground, hot, fg: Color) -> Selection_Ink {
	k := selection_inks_fresh(s)
	for i in 0 ..< k.count {
		m := &k.memo[i]
		if m.ground == ground && m.hot == hot && m.fg == fg && m.share == k.share { return m.ink }
	}
	ink := selection_ink(ground, hot, fg, k.share)
	k.memo[k.next] = {ground, hot, fg, k.share, ink}
	k.next = (k.next + 1) % SELECTION_INK_MEMO
	k.count = min(k.count + 1, SELECTION_INK_MEMO)
	return ink
}

// The window's selection inks, made again when the theme or its colours changed.
@(private = "file")
selection_inks_fresh :: proc(s: ^State) -> ^Selection_Inks {
	k := &s.selection_inks
	serial: u64 = s.theme != nil ? s.theme.serial : 0
	if k.made && k.theme == s.theme && k.serial == serial { return k }
	k^ = {made = true, theme = s.theme, serial = serial}
	if s.theme == nil { return k }
	page := theme_lookup(s.theme, nil, "background")
	page.a = 1
	k.text = {theme_lookup(s.theme, nil, "text"), theme_lookup(s.theme, nil, "bright text")}
	k.quiet = {theme_lookup(s.theme, nil, "weak text"), theme_lookup(s.theme, nil, "faint text"), theme_lookup(s.theme, nil, "soft text")}
	k.share = clamp(contrast(k.quiet[0], page) / max(contrast(k.text[0], page), 1), 0, 1)
	return k
}
