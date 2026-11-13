package ui

// The shades of a colour: from its lightest tint (S50) to its deepest (S950), as palettes number them. Each is the
// colour moved along OKLCH lightness to a fixed level, its hue kept, its chroma eased off towards both ends (a tint near
// white or a shade near black holds less colour, and stays in the sRGB gamut). Together with contrast(), they give
// colours by meaning that read on any theme: a soft fill of a hue and words of the same hue on it (soft_pair).

import "../draw"

Shade :: enum u8 { S50, S100, S200, S300, S400, S500, S600, S700, S800, S900, S950 }

// The OKLCH lightness of each shade, and the share of the colour's chroma it keeps.
@(private = "file")
SHADE_LIGHTNESS :: [Shade]f64{.S50 = 0.97, .S100 = 0.93, .S200 = 0.88, .S300 = 0.81, .S400 = 0.71, .S500 = 0.62, .S600 = 0.54, .S700 = 0.47, .S800 = 0.39, .S900 = 0.31, .S950 = 0.24}
@(private = "file")
SHADE_CHROMA :: [Shade]f64{.S50 = 0.22, .S100 = 0.35, .S200 = 0.55, .S300 = 0.75, .S400 = 0.92, .S500 = 1, .S600 = 1, .S700 = 0.92, .S800 = 0.8, .S900 = 0.65, .S950 = 0.55}

// The OKLCH lightness of the shade `s`.
shade_lightness :: proc(s: Shade) -> f64 {
	t := SHADE_LIGHTNESS
	return t[s]
}

// The shade `s` of `c` (its alpha kept).
shade :: proc(c: draw.Color, s: Shade) -> draw.Color {
	lch := to_oklch(c)
	chroma := SHADE_CHROMA
	return from_oklch({shade_lightness(s), lch[1] * chroma[s], lch[2]}, c.a)
}

// The shade `s` of a hue of the theme shown.
hue_shade :: proc(h: Hue, s: Shade) -> draw.Color {
	c := hue_color(h)
	c.a = 1
	return shade(c, s)
}

// Of the shades of `c`, the one nearest its own lightness that reads on `ground` at `ratio` (4.5: text, WCAG AA; 3:
// large text and marks): words of the same colour as a tinted ground. Darker shades are tried on a light ground, lighter
// ones on a dark ground. readable() of `c` when none does.
shade_on :: proc(c, ground: draw.Color, ratio: f32 = 4.5) -> draw.Color {
	if contrast(c, ground) >= ratio { return c }
	L := to_oklch(c)[0]
	lighter := luminance(ground) < READABLE_PIVOT
	best: Maybe(draw.Color)
	best_gap := 2.0
	for s in Shade {
		if lighter ? shade_lightness(s) < L : shade_lightness(s) > L { continue }
		x := shade(c, s)
		if contrast(x, ground) < ratio { continue }
		if gap := abs(shade_lightness(s) - L); gap < best_gap { best, best_gap = x, gap }
	}
	if b, ok := best.?; ok { return b }
	return readable(c, ground, ratio)
}

// A soft fill of `c` for the theme shown and the words on it in the same colour: a light tint (S100) on a light page,
// a deep one (S900) on a dark page, and the shade of `c` that reads on it (shade_on, 4.5). A tag, a soft button, a note.
soft_pair :: proc(c: draw.Color) -> (fill, ink: draw.Color) {
	page := color("background")
	page.a = 1
	return soft_pair_on(c, page)
}

// soft_pair for a page of colour `page` (the theme's, before it is shown: apply_palette). The words are a shade well
// apart from the fill (S200 on S900, S800 on S100), not the nearest one that just reads: a colour barely off its own
// fill looked muddy. shade_on when that one does not read (a hue that holds little lightness).
soft_pair_on :: proc(c, page: draw.Color) -> (fill, ink: draw.Color) {
	dark := luminance(page) < READABLE_PIVOT
	fill = shade(c, dark ? .S900 : .S100)
	fill.a = 1
	ink = shade(c, dark ? .S200 : .S800)
	ink.a = 1
	if contrast(ink, fill) < 4.5 { ink = shade_on(c, fill, 4.5) }
	return
}

// What an act means, and so its colour: each intent is one of the theme's hues, its button that hue's soft pair (the
// theme's "<intent>_button" tags). Neutral: the plain button, and a Cancel's: giving up is never coloured as a danger.
Intent :: enum u8 { Neutral, Primary, Info, Success, Warning, Danger }

// The hue of an intent.
intent_hue :: proc(i: Intent) -> Hue {
	switch i {
	case .Neutral, .Primary: return .Accent
	case .Info:    return .Blue
	case .Success: return .Green
	case .Warning: return .Yellow
	case .Danger:  return .Red
	}
	return .Accent
}

// The tag of an intent's buttons in the theme ("" for Neutral): push it before a button.
intent_tag :: proc(i: Intent) -> string {
	switch i {
	case .Neutral: return ""
	case .Primary: return "accent_button"
	case .Info:    return "info_button"
	case .Success: return "success_button"
	case .Warning: return "warn_button"
	case .Danger:  return "danger_button"
	}
	return ""
}
