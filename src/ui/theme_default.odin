package ui

import "../draw"

// A palette is the sRGB colours of the built-in widgets; `apply_palette` expands it into the full tag-based theme they
// use. A program makes it from a theme (themes.odin: theme_palette).
Palette :: struct {
	bg, panel, panel2, text, weak, border, accent, accent_text, good, warn, bad: u32,   // 0xRRGGBBAA
	dark:   bool,
	finish: Finish,   // how raised surfaces are painted; their "sheen" entry (0..1) says how strongly
	bar:    u32,      // menu / status bars (0 = panel)
	well:   u32,      // sunken surfaces: fields, wells (0 = the page a step darker)
	translucent: bool, // `bg` has alpha < 1 and the app shows the OS backdrop behind it (see platform.set_backdrop)
	// the theme's other hues, for code's colours (0: the accent)
	blue, purple, cyan, rose: u32,
}

// Slots a theme entry can point at.
@(private)
Slot :: enum { Bg, Bg_Solid, Panel, Panel2, Text, Weak, Border, Accent, Accent_Text, Good, Warn, Bad, White, Black, Hover, Bar, Well, Blue, Purple, Cyan, Rose,
	// an intent's soft pair (soft_pair_on of its hue on the page): its fill, its words
	Accent_Soft, Accent_Ink, Info_Soft, Info_Ink, Good_Soft, Good_Ink, Warn_Soft, Warn_Ink, Bad_Soft, Bad_Ink }

@(private)
Entry :: struct { tags: string, slot: Slot, alpha: f32 }

// ORDER MATTERS: a pattern wins by matching the most tags, ties go to the first. A button inside a card has the tags
// [card, button], so "card background" and "button background" tie: variants must come before containers.
@(private)
entries := [?]Entry{
	// generic names
	{"background", .Bg, 1}, {"text", .Text, 1}, {"border", .Border, 1}, {"hover", .Hover, 1},
	{"drop_shadow", .Black, 0.6}, {"selection", .Accent, 0.35}, {"selection text", .Text, 1}, {"cursor", .Text, 1}, {"focus border", .Accent, 1},
	// the hues, for what a program colours by meaning (hue())
	{"hue_accent", .Accent, 1}, {"hue_blue", .Blue, 1}, {"hue_purple", .Purple, 1}, {"hue_green", .Good, 1}, {"hue_yellow", .Warn, 1},
	{"hue_red", .Bad, 1}, {"hue_cyan", .Cyan, 1}, {"hue_rose", .Rose, 1},
	{"accent", .Accent, 1}, {"track", .Panel2, 1}, {"sheen", .White, 0}, {"well", .Well, 1},
	{"find_match background", .Warn, 0.62}, {"find_current background", .Warn, 0.85}, {"find_text", .Black, 1},
	{"link", .Accent, 1}, {"code_bg", .Panel2, 1},   // rich_paragraph: links, inline code
	// what a search found in a line (match.odin): the text's own colour on a tint of the accent (the accent's own colour on
	// its tint read badly: two shades of one hue)
	{"match", .Text, 1}, {"match_bg", .Accent, 0.18},
	// source code's classes (code.odin, tk_syntax): keywords, strings, comments, calls and directives, types and numbers
	{"code_keyword", .Purple, 1}, {"code_string", .Good, 1}, {"code_comment", .Weak, 1}, {"code_func", .Blue, 1}, {"code_type", .Cyan, 1},
	// a diff (tk_diff, under the tag "diff"): a line added or removed on a tint, what changed in it on a stronger one. (Those of a
	// kind first: under the tag "diff", "diff_added text" and "diff text" tie, the first wins.)
	{"diff_added background", .Good, 0.13}, {"diff_removed background", .Bad, 0.13},
	{"diff_added mark", .Good, 0.36}, {"diff_removed mark", .Bad, 0.36},
	{"diff_added text", .Text, 1}, {"diff_removed text", .Text, 1}, {"diff_added sign", .Good, 1}, {"diff_removed sign", .Bad, 1},
	{"diff text", .Text, 1}, {"diff sign", .Weak, 1}, {"diff mark_text", .Text, 1}, {"diff line_number", .Weak, 1},
	{"diff gap", .Weak, 1}, {"diff divider", .Border, 1},
	{"resize_grip shade", .Border, 1},   // the bevel in a dialog's or a floating panel's corner: toward the border, darker on a light theme, lighter on a dark one
	// variants
	{"weak text", .Weak, 1}, {"bad text", .Bad, 1}, {"good text", .Good, 1}, {"warn text", .Warn, 1},
	{"bad border", .Bad, 1}, {"good border", .Good, 1}, {"warn border", .Warn, 1},
	// (the intents' buttons: a soft fill of their hue, their words in that hue, deep enough to read: soft_pair_on)
	{"accent_button background", .Accent_Soft, 1}, {"accent_button text", .Accent_Ink, 1}, {"accent_button border", .Accent_Soft, 1},
	{"danger_button background", .Bad_Soft, 1}, {"danger_button text", .Bad_Ink, 1}, {"danger_button border", .Bad_Soft, 1},
	{"success_button background", .Good_Soft, 1}, {"success_button text", .Good_Ink, 1}, {"success_button border", .Good_Soft, 1},
	{"info_button background", .Info_Soft, 1}, {"info_button text", .Info_Ink, 1}, {"info_button border", .Info_Soft, 1},
	{"cancel_button background", .Bad_Soft, 1}, {"cancel_button text", .Bad_Ink, 1}, {"cancel_button border", .Bad_Soft, 1},
	// a button whose action is undone with care, not lost (end a task, stop a service): amber, dark text on it
	{"warn_button background", .Warn_Soft, 1}, {"warn_button text", .Warn_Ink, 1}, {"warn_button border", .Warn_Soft, 1},
	{"ghost_button background", .Panel, 0}, {"ghost_button border", .Panel, 0}, {"ghost_button sheen", .White, 0},
	{"icon_button background", .Panel, 0}, {"icon_button sheen", .White, 0},
	{"accent_button sheen", .White, 1}, {"danger_button sheen", .White, 1}, {"warn_button sheen", .White, 1},
	{"success_button sheen", .White, 1}, {"info_button sheen", .White, 1}, {"cancel_button sheen", .White, 1},
	{"button background", .Panel2, 1}, {"button border", .Border, 1}, {"button sheen", .White, 1},
	// a segmented control's labels: half sit on the sliding pill, half on the track; an engraving (lit below on the pill,
	// shadowed above on the track) set them a pixel apart to the eye
	{"button segment sheen", .White, 0},
	{"menu_item background", .Panel2, 0}, {"menu_item sheen", .White, 0},
	{"selected background", .Accent, 0.22}, {"selected border", .Accent, 1}, {"selected sheen", .White, 0.6},
	// the selected row of a menu is a filled, rounded row (a tint of the accent, no outline): the outline of a selected
	// item belongs to lists and fields, and a ring around a row with a faint fill reads as a focus box, not as a highlight
	{"menu_item selected background", .Accent, 0.30}, {"menu_item selected border", .Accent, 0},
	{"weak_selected background", .Accent, 0.09}, {"weak_selected border", .Accent, 0.35},
	{"kbd sheen", .White, 0.7},
	{"remove_button hot text", .Bad, 1},   // "hot": the box is under the pointer (build_box)
	{"zebra background", .Bg_Solid, 0.45},
	// a list's rows (List_State.zebra, .rules): every second row a shade off the page, a hairline under each row
	{"list_row zebra background", .Hover, 0.008}, {"rule border", .Border, 0.8},
	{"input background", .Bg_Solid, 1}, {"input border", .Border, 1},
	// a sunken box (well): the surface carved in
	{"well background", .Well, 1}, {"well border", .Border, 1},
	// a field inside an input_frame (tag "bare"): the frame is its surface, its border and its focus ring
	{"bare input background", .Bg_Solid, 0}, {"bare input border", .Border, 0}, {"bare focus border", .Accent, 0},
	{"bare background", .Bg_Solid, 0}, {"bare border", .Border, 0},
	{"kbd background", .Panel2, 1}, {"kbd text", .Weak, 1}, {"kbd border", .Border, 1},
	{"scrim background", .Black, 0.55},
	// docking (docking.odin): where a dragged panel would land, and the squares of the drop targets
	{"dock_preview background", .Accent, 0.22}, {"dock_preview border", .Accent, 0.85},
	{"dock_marker background", .Panel2, 0.94}, {"dock_marker border", .Border, 1},
	// a folded pane's strip (panes.odin, a dock's folded side): the surface of the bars it sits beside
	{"pane_strip background", .Bar, 1},
	// containers (last)
	{"card background", .Panel, 1}, {"card border", .Border, 1},
	{"bar background", .Bar, 1}, {"bar border", .Border, 1}, {"bar sheen", .White, 0.6},
	{"floating background", .Panel2, 1}, {"floating text", .Text, 1}, {"floating border", .Border, 1},
}

// Interaction state fills. `alpha` is a fraction of the way from the surface under the box to the slot's colour in sRGB
// values (draw.alpha_like_srgb when drawn into linear light), so a step reads alike on dark and light palettes and in
// both blend spaces: about +7 % toward white (dark palettes) or black (light ones) under the pointer, +12 % while
// pressed. "hover_fill" over a clickable box under the pointer, "press_fill" while the left button is held on it,
// "hover_border": the border that much toward the tint (fields). Same ORDER rule as `entries` (roles first).
@(private)
state_entries := [?]Entry{
	{"menu_item hover_fill", .Hover, 0}, {"menu_item press_fill", .Hover, 0.08},   // a hovered item is the selected one
	{"remove_button hover_fill", .Bad, 0.14}, {"remove_button press_fill", .Bad, 0.24},
	{"accent_button hover_fill", .Hover, 0.10}, {"accent_button press_fill", .Hover, 0.18},
	{"danger_button hover_fill", .Hover, 0.10}, {"danger_button press_fill", .Hover, 0.18},
	{"warn_button hover_fill", .Hover, 0.10}, {"warn_button press_fill", .Hover, 0.18},
	{"success_button hover_fill", .Hover, 0.10}, {"success_button press_fill", .Hover, 0.18},
	{"info_button hover_fill", .Hover, 0.10}, {"info_button press_fill", .Hover, 0.18},
	{"cancel_button hover_fill", .Hover, 0.10}, {"cancel_button press_fill", .Hover, 0.18},
	{"ghost_button hover_fill", .Hover, 0.08}, {"ghost_button press_fill", .Hover, 0.14},
	{"icon_button hover_fill", .Hover, 0.08}, {"icon_button press_fill", .Hover, 0.14},
	{"segment hover_fill", .Hover, 0.07}, {"segment press_fill", .Hover, 0.12},
	{"list_row hover_fill", .Hover, 0.05}, {"list_row press_fill", .Hover, 0.09},
	{"tab hover_fill", .Hover, 0.06}, {"tab press_fill", .Hover, 0.10},
	{"button hover_fill", .Hover, 0.07}, {"button press_fill", .Hover, 0.13},
	{"input hover_border", .Hover, 0.22},
	{"hover_fill", .Hover, 0.07}, {"press_fill", .Hover, 0.12}, {"hover_border", .Hover, 0},
}

// The well of a palette that names none: its page this much toward black.
@(private) WELL_DARKEN :: 0.35

@(private)
slot_color :: proc(p: Palette, s: Slot) -> u32 {
	switch s {
	case .Bg: return p.bg
	case .Bg_Solid: return p.bg | 0xff   // inputs stay opaque on translucent palettes
	case .Bar: return p.bar != 0 ? p.bar : p.panel
	case .Well:
		if p.well != 0 { return p.well }
		w := draw.mix(draw.hex(p.bg | 0xff), {0, 0, 0, 1}, WELL_DARKEN)
		return u32(w.r * 255) << 24 | u32(w.g * 255) << 16 | u32(w.b * 255) << 8 | 0xff
	case .Panel: return p.panel
	case .Panel2: return p.panel2
	case .Text: return p.text
	case .Weak: return p.weak
	case .Border: return p.border
	case .Accent: return p.accent
	case .Accent_Text: return p.accent_text
	case .Good: return p.good
	case .Warn: return p.warn
	case .Bad: return p.bad
	case .White: return 0xffffffff
	case .Black: return 0x000000ff
	case .Hover: return p.dark ? 0xffffffff : 0x000000ff
	case .Blue: return p.blue != 0 ? p.blue : p.accent
	case .Purple: return p.purple != 0 ? p.purple : p.accent
	case .Cyan: return p.cyan != 0 ? p.cyan : p.accent
	case .Rose: return p.rose != 0 ? p.rose : p.accent
	case .Accent_Soft, .Accent_Ink, .Info_Soft, .Info_Ink, .Good_Soft, .Good_Ink, .Warn_Soft, .Warn_Ink, .Bad_Soft, .Bad_Ink:
		return 0xff00ffff   // (computed colours: slot_rgba)
	}
	return 0xff00ffff
}

// A slot's colour (linear): the palette's, or for an intent's soft pair, made from its hue on the palette's page.
@(private)
slot_rgba :: proc(p: Palette, s: Slot) -> draw.Color {
	soft :: proc(p: Palette, hue: Slot, ink: bool) -> draw.Color {
		fill, words := soft_pair_on(draw.hex(slot_color(p, hue) | 0xff), draw.hex(slot_color(p, .Bg_Solid)))
		return ink ? words : fill
	}
	#partial switch s {
	case .Accent_Soft: return soft(p, .Accent, false)
	case .Accent_Ink:  return soft(p, .Accent, true)
	case .Info_Soft:   return soft(p, .Blue, false)
	case .Info_Ink:    return soft(p, .Blue, true)
	case .Good_Soft:   return soft(p, .Good, false)
	case .Good_Ink:    return soft(p, .Good, true)
	case .Warn_Soft:   return soft(p, .Warn, false)
	case .Warn_Ink:    return soft(p, .Warn, true)
	case .Bad_Soft:    return soft(p, .Bad, false)
	case .Bad_Ink:     return soft(p, .Bad, true)
	}
	return draw.hex(slot_color(p, s))
}

// Creates the entries on first use, then only updates colors (so box colors cross-fade between palettes). `space`: the
// blend space of the renderer the theme draws with; translucent entries (tuned for linear light) get the alpha that
// looks the same over the palette's background in it (draw.alpha_like_linear). Apply again when the space changes.
apply_palette :: proc(t: ^Theme, p: Palette, space := draw.Blend_Space.Linear) {
	if !t.palette_made || len(t.patterns) < t.palette_at + len(entries) + len(state_entries) {
		// (entries the app added before are kept in front of these: for equal specificity the first one wins)
		t.palette_at, t.palette_made = len(t.patterns), true
		for e in entries { theme_add(t, e.tags, {}) }
		for e in state_entries { theme_add(t, e.tags, {}) }
	}
	bg := draw.hex(slot_color(p, .Bg_Solid))
	changed := false
	for e, i in entries {
		c := slot_rgba(p, e.slot)
		c.a *= e.alpha
		c.a = draw.alpha_like_linear(space, c, c.a, bg)
		k := t.palette_at + i
		if t.patterns[k].color != c { t.patterns[k].color = c; changed = true }
	}
	// state fills keep their fraction: it is converted where it is drawn, over the surface actually under it
	for e, i in state_entries {
		c := draw.hex(slot_color(p, e.slot))
		c.a = e.alpha
		k := t.palette_at + len(entries) + i
		if t.patterns[k].color != c { t.patterns[k].color = c; changed = true }
	}
	// (the finish asked is drawn on both: on a light palette the reliefs take lighter shades and stronger lights,
	// machined.odin's relief_shade and relief_shine)
	if t.finish != p.finish { t.finish = p.finish; changed = true }
	if t.dark != p.dark { t.dark = p.dark; changed = true }
	if changed { t.serial += 1 }
}

// The fill of an interaction state ("hover_fill", "press_fill") under the tags of `b`, to draw over `under` (the
// opaque surface below it): its alpha is the one that gives the theme's sRGB step in the blend space of the frame.
// For custom draw procs that paint their own hover (rows, nodes of a graph).
state_fill :: proc(b: ^Box, name: string, under: Maybe(Color) = nil) -> Color {
	c := color_from_tags(gs(), b.tags_key, name)
	o := under.? or_else box_under(b)
	c.a = draw.alpha_like_srgb(gs().space, c, c.a, o)
	return c
}

// The opaque colour under `b`: its own background when opaque, else the nearest ancestor's, else the theme's.
box_under :: proc(b: ^Box) -> Color {
	for p := b; p != nil; p = p.parent {
		if .Draw_Background in p.flags && p.bg.a > 0.5 { return {p.bg.r, p.bg.g, p.bg.b, 1} }
	}
	return gs().backdrop
}

// Mixes `a` toward `b` by `t` in sRGB values (linear colours in and out): one step of the theme's state scale.
srgb_step :: proc(a, b: Color, t: f32) -> Color {
	m := srgb_mix(a, b, t)
	m.a = a.a
	return m
}
