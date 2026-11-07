package ui

import "core:math"
import "../draw"

// Contrast: words that read on what is under them, whatever the colours. Colours here are linear (draw's); OKLCH is the space a colour
// is moved in, its hue and its chroma kept, its lightness alone changed: what the eye sees as "the same colour, darker".

READABLE_PIVOT :: 0.18   // a ground darker than this (WCAG luminance): words go lighter on it, else darker
READABLE_STEPS :: 24
READABLE_STEP  :: 0.04   // of OKLCH lightness, at each step

// WCAG's relative luminance of a linear colour.
luminance :: proc(c: draw.Color) -> f32 { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

// WCAG's contrast ratio of two colours (1 to 21). AA asks 4.5 of text, 3 of large text and of what is not text.
contrast :: proc(a, b: draw.Color) -> f32 {
	la, lb := luminance(a) + 0.05, luminance(b) + 0.05
	return max(la, lb) / min(la, lb)
}

// A linear colour in OKLCH (L 0..1, chroma, hue degrees).
to_oklch :: proc(c: draw.Color) -> [3]f64 { return srgb_to_oklch({srgb_encoded(c.r), srgb_encoded(c.g), srgb_encoded(c.b)}) }

// An OKLCH colour as a linear one (out of the sRGB gamut: clipped).
from_oklch :: proc(lch: [3]f64, alpha: f32 = 1) -> draw.Color {
	s := oklch_to_srgb(lch[0], lch[1], lch[2])
	return draw.srgb(s[0], s[1], s[2], alpha)
}

// `fg` as it reads on `ground` at `ratio` at least: as it is if it does, else moved along its OKLCH lightness away from the ground's
// (lighter on a dark ground, darker on a light one) until it does; at the end of the way, black or white.
readable :: proc(fg, ground: draw.Color, ratio: f32) -> draw.Color {
	if contrast(fg, ground) >= ratio { return fg }
	lch := to_oklch(fg)
	up := luminance(ground) < READABLE_PIVOT
	for _ in 1 ..= READABLE_STEPS {
		lch[0] = clamp(lch[0] + (up ? READABLE_STEP : -READABLE_STEP), 0, 1)
		c := from_oklch(lch, fg.a)
		if contrast(c, ground) >= ratio { return c }
	}
	return up ? {1, 1, 1, fg.a} : {0, 0, 0, fg.a}
}

@(private = "file")
srgb_encoded :: proc(x: f32) -> f32 { return clamp(x <= 0.0031308 ? 12.92 * x : 1.055 * math.pow(x, 1 / 2.4) - 0.055, 0, 1) }
