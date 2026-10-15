package ui

import "../draw"

// A palette is eleven sRGB colors; `apply_palette` expands it into the full tag-based theme the built-in widgets use.
Palette :: struct {
	bg, panel, panel2, text, weak, border, accent, accent_text, good, warn, bad: u32,   // 0xRRGGBBAA
	dark: bool,
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
Slot :: enum { Bg, Panel, Panel2, Text, Weak, Border, Accent, Accent_Text, Good, Warn, Bad, White, Black, Hover }

@(private)
Entry :: struct { tags: string, slot: Slot, alpha: f32 }

// ORDER MATTERS: a pattern wins by matching the most tags, ties go to the first. A button inside a card has the tags
// [card, button], so "card background" and "button background" tie: variants must come before containers.
@(private)
entries := [?]Entry{
	// generic names
	{"background", .Bg, 1}, {"text", .Text, 1}, {"border", .Border, 1}, {"hover", .Hover, 1},
	{"drop_shadow", .Black, 0.6}, {"selection", .Accent, 0.35}, {"cursor", .Text, 1}, {"focus border", .Accent, 1},
	{"accent", .Accent, 1}, {"track", .Panel2, 1},
	// variants
	{"weak text", .Weak, 1}, {"bad text", .Bad, 1}, {"good text", .Good, 1}, {"warn text", .Warn, 1},
	{"bad border", .Bad, 1}, {"good border", .Good, 1},
	{"accent_button background", .Accent, 1}, {"accent_button text", .Accent_Text, 1}, {"accent_button border", .Accent, 1},
	{"danger_button background", .Bad, 1}, {"danger_button text", .White, 1}, {"danger_button border", .Bad, 1},
	{"ghost_button background", .Panel, 0}, {"ghost_button border", .Panel, 0},
	{"icon_button background", .Panel, 0},
	{"button background", .Panel2, 1}, {"button border", .Border, 1},
	{"menu_item background", .Panel2, 0},
	{"selected background", .Accent, 0.28},
	{"input background", .Bg, 1}, {"input border", .Border, 1},
	{"scrim background", .Black, 0.55},
	// containers (last)
	{"card background", .Panel, 1}, {"card border", .Border, 1},
	{"bar background", .Panel, 1}, {"bar border", .Border, 1},
	{"floating background", .Panel2, 1}, {"floating text", .Text, 1}, {"floating border", .Border, 1},
}

@(private)
slot_color :: proc(p: Palette, s: Slot) -> u32 {
	switch s {
	case .Bg: return p.bg
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

// Creates the entries on first use, then only updates colors (so box colors cross-fade between palettes).
apply_palette :: proc(t: ^Theme, p: Palette) {
	if len(t.patterns) == 0 {
		for e in entries { theme_add(t, e.tags, {}) }
	}
	for e, i in entries {
		c := draw.hex(slot_color(p, e.slot))
		c.a *= e.alpha
		t.patterns[i].color = c
	}
}
