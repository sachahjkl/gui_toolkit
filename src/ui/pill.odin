package ui

// A pill: a short label of a colour, as wide as its words, rounded at its ends: a light wash of the colour, a line of it
// around, an icon (Lucide's) and the words in the colour lightened. A version, a kind of change, a state, a tag. Where a
// tile (tile) is a block of full colour that reads as a button, a pill is a mark on the page.
//
//	ui.pill("added", "Added", lucide.SPARKLES, ui.hue(.Green))
//	ui.pill("ver", "1.2.0", lucide.TAG, ui.color("accent"), {mono = true})

import "core:fmt"
import "core:math"
import "../draw"

Pill_Options :: struct {
	mono: bool,   // its words in the monospace face (a version, a hash)
}

// How light the words and the icon are over the colour, the wash under them and the line around, of the colour.
@(private = "file") PILL_INK_LIGHT :: 0.25
@(private = "file") PILL_WASH :: 0.16
@(private = "file") PILL_LINE :: 0.55

// A pill of colour `c` (`icon` "": none). Its height is the text's line (dense), its width its words'. It takes no press.
pill :: proc(id, text, icon: string, c: Color, o := Pill_Options{}) {
	em := font_size()
	ink := draw.mix(c, Color{1, 1, 1, 1}, PILL_INK_LIGHT)
	h := math.round(dense(em * 1.55))
	next({width = children_sum(), height = px(h), axis = .X, cross = .Center, radius = h * 0.5,
		bg = c * {1, 1, 1, PILL_WASH}, border = c * {1, 1, 1, PILL_LINE}})
	b := build_box({.Draw_Background, .Draw_Border, .Fixed_Radius}, fmt.tprintf("###%s", id))
	a11y_default(b, {role = .Label, name = text})
	push_parent(b)
	defer pop_parent()
	spacer(px(math.round(em * 0.6)))
	if icon != "" {
		next({width = px(math.round(em * 1.1)), height = pct(1), font = lucide_icons(), font_size = em * 0.85, fg = ink, text_align = .Center, text_pad = 0})
		a11y({ignore = true})
		build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###icon", icon))
		spacer(px(math.round(em * 0.3)))
	}
	next({width = text_size(0), height = pct(1), fg = ink, text_pad = 0, font = o.mono ? mono_font() : nil, font_size = em * 0.88})
	a11y({ignore = true})
	build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###text", text))
	spacer(px(math.round(em * 0.7)))
}
