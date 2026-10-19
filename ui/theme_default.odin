package ui

import "../draw"

// A palette is eleven sRGB colors; `apply_palette` expands it into the full tag-based theme the built-in widgets use.
Palette :: struct {
	bg, panel, panel2, text, weak, border, accent, accent_text, good, warn, bad: u32,   // 0xRRGGBBAA
	dark:   bool,
	finish: Finish,   // how raised surfaces are painted; their "sheen" entry (0..1) says how strongly
	bar:    u32,      // menu / status bars (0 = panel)
	translucent: bool, // `bg` has alpha < 1 and the app shows the OS backdrop behind it (see platform.set_backdrop)
}

PALETTE_MIDNIGHT :: Palette{
	bg = 0x0f1220ff, panel = 0x171b2fff, panel2 = 0x20253dff, text = 0xe6e9f5ff, weak = 0x8d95b5ff, border = 0x2b3150ff,
	accent = 0x7c8cffff, accent_text = 0x0b0e1cff, good = 0x4ade80ff, warn = 0xfbbf24ff, bad = 0xf87171ff, dark = true,
}

PALETTE_DAYLIGHT :: Palette{
	bg = 0xf3f4f7ff, panel = 0xffffffff, panel2 = 0xe9ecf2ff, text = 0x1f2430ff, weak = 0x6b7380ff, border = 0xd9dde4ff,
	accent = 0x3b5bdbff, accent_text = 0xffffffff, good = 0x2f9e5aff, warn = 0xc98a10ff, bad = 0xd6333fff, dark = false,
}

// Slots a theme entry can point at.
@(private)
Slot :: enum { Bg, Bg_Solid, Panel, Panel2, Text, Weak, Border, Accent, Accent_Text, Good, Warn, Bad, White, Black, Hover, Bar }

@(private)
Entry :: struct { tags: string, slot: Slot, alpha: f32 }

// ORDER MATTERS: a pattern wins by matching the most tags, ties go to the first. A button inside a card has the tags
// [card, button], so "card background" and "button background" tie: variants must come before containers.
@(private)
entries := [?]Entry{
	// generic names
	{"background", .Bg, 1}, {"text", .Text, 1}, {"border", .Border, 1}, {"hover", .Hover, 1},
	{"drop_shadow", .Black, 0.6}, {"selection", .Accent, 0.35}, {"cursor", .Text, 1}, {"focus border", .Accent, 1},
	{"accent", .Accent, 1}, {"track", .Panel2, 1}, {"sheen", .White, 0},
	// variants
	{"weak text", .Weak, 1}, {"bad text", .Bad, 1}, {"good text", .Good, 1}, {"warn text", .Warn, 1},
	{"bad border", .Bad, 1}, {"good border", .Good, 1}, {"warn border", .Warn, 1},
	{"accent_button background", .Accent, 1}, {"accent_button text", .Accent_Text, 1}, {"accent_button border", .Accent, 1},
	{"danger_button background", .Bad, 1}, {"danger_button text", .White, 1}, {"danger_button border", .Bad, 1},
	{"ghost_button background", .Panel, 0}, {"ghost_button border", .Panel, 0}, {"ghost_button sheen", .White, 0},
	{"icon_button background", .Panel, 0}, {"icon_button sheen", .White, 0},
	{"accent_button sheen", .White, 1}, {"danger_button sheen", .White, 1},
	{"button background", .Panel2, 1}, {"button border", .Border, 1}, {"button sheen", .White, 1},
	{"menu_item background", .Panel2, 0}, {"menu_item sheen", .White, 0},
	{"selected background", .Accent, 0.22}, {"selected border", .Accent, 1}, {"selected sheen", .White, 0.6},
	{"weak_selected background", .Accent, 0.09}, {"weak_selected border", .Accent, 0.35},
	{"kbd sheen", .White, 0.7},
	{"zebra background", .Bg_Solid, 0.45},
	{"input background", .Bg_Solid, 1}, {"input border", .Border, 1},
	{"kbd background", .Panel2, 1}, {"kbd text", .Weak, 1}, {"kbd border", .Border, 1},
	{"scrim background", .Black, 0.55},
	// containers (last)
	{"card background", .Panel, 1}, {"card border", .Border, 1},
	{"bar background", .Bar, 1}, {"bar border", .Border, 1}, {"bar sheen", .White, 0.6},
	{"floating background", .Panel2, 1}, {"floating text", .Text, 1}, {"floating border", .Border, 1},
}

@(private)
slot_color :: proc(p: Palette, s: Slot) -> u32 {
	switch s {
	case .Bg: return p.bg
	case .Bg_Solid: return p.bg | 0xff   // inputs stay opaque on translucent palettes
	case .Bar: return p.bar != 0 ? p.bar : p.panel
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
	}
	return 0xff00ffff
}

// Creates the entries on first use, then only updates colors (so box colors cross-fade between palettes). `space`: the
// blend space of the renderer the theme draws with; translucent entries (tuned for linear light) get the alpha that
// looks the same over the palette's background in it (draw.alpha_like_linear). Apply again when the space changes.
apply_palette :: proc(t: ^Theme, p: Palette, space := draw.Blend_Space.Linear) {
	if len(t.patterns) == 0 {
		for e in entries { theme_add(t, e.tags, {}) }
	}
	bg := draw.hex(slot_color(p, .Bg_Solid))
	for e, i in entries {
		c := draw.hex(slot_color(p, e.slot))
		c.a *= e.alpha
		c.a = draw.alpha_like_linear(space, c, c.a, bg)
		t.patterns[i].color = c
	}
	t.finish = p.finish
}
