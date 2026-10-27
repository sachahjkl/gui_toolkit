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

PALETTE_GRAPHITE :: Palette{
	bg = 0x151515ff, panel = 0x1e1e1eff, panel2 = 0x2a2a2aff, text = 0xeaeaeaff, weak = 0x8e8e8eff, border = 0x353535ff,
	accent = 0x4cc2ffff, accent_text = 0x06222fff, good = 0x5dd39eff, warn = 0xf4c95dff, bad = 0xff6b6bff, dark = true,
}

PALETTE_NORD :: Palette{
	bg = 0x2e3440ff, panel = 0x3b4252ff, panel2 = 0x434c5eff, text = 0xeceff4ff, weak = 0x9aa5b8ff, border = 0x4c566aff,
	accent = 0x88c0d0ff, accent_text = 0x1d2430ff, good = 0xa3be8cff, warn = 0xebcb8bff, bad = 0xbf616aff, dark = true,
}

PALETTE_DRACULA :: Palette{
	bg = 0x1e1f29ff, panel = 0x282a36ff, panel2 = 0x343746ff, text = 0xf8f8f2ff, weak = 0x9aa0c8ff, border = 0x44475aff,
	accent = 0xbd93f9ff, accent_text = 0x1a1326ff, good = 0x50fa7bff, warn = 0xf1fa8cff, bad = 0xff5555ff, dark = true,
}

PALETTE_AMBER :: Palette{
	bg = 0x16120bff, panel = 0x201a10ff, panel2 = 0x2d2415ff, text = 0xffe9c2ff, weak = 0xb59a66ff, border = 0x3d311cff,
	accent = 0xffb000ff, accent_text = 0x1a1200ff, good = 0x9acd32ff, warn = 0xffd54fff, bad = 0xff7043ff, dark = true,
}

// Windows 7: sky-blue glass behind white panels, glossy silver buttons, Aero blue for selection
PALETTE_AERO :: Palette{
	bg = 0xb9d1ee8c, panel = 0xfbfcfeff, panel2 = 0xe3e9f1ff, text = 0x1b2633ff, weak = 0x4f6178ff, border = 0x8ea6c6ff,
	accent = 0x2f86dbff, accent_text = 0xffffffff, good = 0x2e9e45ff, warn = 0xd08c00ff, bad = 0xd13b2eff, dark = false,
	finish = .Glass, bar = 0x6fa3dcb0, translucent = true,
}

// Bootstrap 2 (2012): white page, grey wells, gradient buttons with embossed text, blue focus glow
PALETTE_BOOTSTRAP :: Palette{
	bg = 0xffffffff, panel = 0xf5f5f5ff, panel2 = 0xe9e9e9ff, text = 0x333333ff, weak = 0x8a8a8aff, border = 0xccccccff,
	accent = 0x0a6fd1ff, accent_text = 0xffffffff, good = 0x51a351ff, warn = 0xf89406ff, bad = 0xd2463fff, dark = false,
	finish = .Gradient,
}

// Editor and terminal palettes, each from its own scheme (the scheme's background, its line highlight as the second panel,
// its foreground, its muted text lifted where it is under 4:1 on the background, its own accent), with the dark text of
// the scheme on the accent.

// Gruvbox (Pavel Pertsev): warm browns, cream text, orange accent
PALETTE_GRUVBOX :: Palette{
	bg = 0x282828ff, panel = 0x32302fff, panel2 = 0x3c3836ff, text = 0xebdbb2ff, weak = 0xa89984ff, border = 0x504945ff,
	accent = 0xfe8019ff, accent_text = 0x282828ff, good = 0xb8bb26ff, warn = 0xfabd2fff, bad = 0xfb4934ff, dark = true,
}

PALETTE_GRUVBOX_LIGHT :: Palette{
	bg = 0xfbf1c7ff, panel = 0xf9f5d7ff, panel2 = 0xebdbb2ff, text = 0x3c3836ff, weak = 0x7c6f64ff, border = 0xd5c4a1ff,
	accent = 0xaf3a03ff, accent_text = 0xfbf1c7ff, good = 0x79740eff, warn = 0xb57614ff, bad = 0x9d0006ff, dark = false,
}

// Naysayer (the Emacs theme of Jonathan Blow's streams): a deep teal, tan text, the green of its strings
PALETTE_NAYSAYER :: Palette{
	bg = 0x062329ff, panel = 0x0a2d36ff, panel2 = 0x0c4754ff, text = 0xd1b897ff, weak = 0x86a09eff, border = 0x14505eff,
	accent = 0x2ec09cff, accent_text = 0x062329ff, good = 0x44b340ff, warn = 0xe0b45aff, bad = 0xe5646aff, dark = true,
}

// Solarized (Ethan Schoonover), the two modes of one set of sixteen colors
PALETTE_SOLARIZED :: Palette{
	bg = 0x002b36ff, panel = 0x073642ff, panel2 = 0x0b3e4aff, text = 0x93a1a1ff, weak = 0x768c93ff, border = 0x15505eff,
	accent = 0x268bd2ff, accent_text = 0x002b36ff, good = 0x859900ff, warn = 0xb58900ff, bad = 0xdc322fff, dark = true,
}

PALETTE_SOLARIZED_LIGHT :: Palette{
	bg = 0xfdf6e3ff, panel = 0xf5efdcff, panel2 = 0xeee8d5ff, text = 0x586e75ff, weak = 0x657b83ff, border = 0xded8c4ff,
	accent = 0x268bd2ff, accent_text = 0xfdf6e3ff, good = 0x859900ff, warn = 0xb58900ff, bad = 0xdc322fff, dark = false,
}

// Monokai (Wimer Hazenberg): the olive-black of Sublime Text, the green of its functions
PALETTE_MONOKAI :: Palette{
	bg = 0x272822ff, panel = 0x2d2e27ff, panel2 = 0x3e3d32ff, text = 0xf8f8f2ff, weak = 0x9b9780ff, border = 0x49483eff,
	accent = 0xa6e22eff, accent_text = 0x272822ff, good = 0xa6e22eff, warn = 0xfd971fff, bad = 0xf92672ff, dark = true,
}

// Tokyo Night (enkia): indigo night, periwinkle accent
PALETTE_TOKYO_NIGHT :: Palette{
	bg = 0x1a1b26ff, panel = 0x1f2335ff, panel2 = 0x292e42ff, text = 0xc0caf5ff, weak = 0x8089b5ff, border = 0x3b4261ff,
	accent = 0x7aa2f7ff, accent_text = 0x1a1b26ff, good = 0x9ece6aff, warn = 0xe0af68ff, bad = 0xf7768eff, dark = true,
}

// Catppuccin, Mocha (dark) and Latte (light)
PALETTE_CATPPUCCIN :: Palette{
	bg = 0x1e1e2eff, panel = 0x262637ff, panel2 = 0x313244ff, text = 0xcdd6f4ff, weak = 0xa6adc8ff, border = 0x45475aff,
	accent = 0xcba6f7ff, accent_text = 0x1e1e2eff, good = 0xa6e3a1ff, warn = 0xf9e2afff, bad = 0xf38ba8ff, dark = true,
}

PALETTE_CATPPUCCIN_LATTE :: Palette{
	bg = 0xeff1f5ff, panel = 0xf8f9fbff, panel2 = 0xe6e9efff, text = 0x4c4f69ff, weak = 0x6c6f85ff, border = 0xccd0daff,
	accent = 0x8839efff, accent_text = 0xffffffff, good = 0x40a02bff, warn = 0xdf8e1dff, bad = 0xd20f39ff, dark = false,
}

// One Dark (Atom)
PALETTE_ONE_DARK :: Palette{
	bg = 0x282c34ff, panel = 0x2c313aff, panel2 = 0x353b45ff, text = 0xc8ccd4ff, weak = 0x8a93a2ff, border = 0x3e4451ff,
	accent = 0x61afefff, accent_text = 0x21252bff, good = 0x98c379ff, warn = 0xe5c07bff, bad = 0xe06c75ff, dark = true,
}

// Everforest (sainnhe): a green-grey forest, soft contrast
PALETTE_EVERFOREST :: Palette{
	bg = 0x2d353bff, panel = 0x343f44ff, panel2 = 0x3d484dff, text = 0xd3c6aaff, weak = 0x9da9a0ff, border = 0x475258ff,
	accent = 0xa7c080ff, accent_text = 0x2d353bff, good = 0xa7c080ff, warn = 0xdbbc7fff, bad = 0xe67e80ff, dark = true,
}
Named_Palette :: struct { name: string, palette: Palette }

// The built-in palettes, for theme pickers and settings (names are what apps store).
NAMED_PALETTES := [?]Named_Palette{
	{"Midnight", PALETTE_MIDNIGHT},
	{"Graphite", PALETTE_GRAPHITE},
	{"Daylight", PALETTE_DAYLIGHT},
	{"Nord", PALETTE_NORD},
	{"Dracula", PALETTE_DRACULA},
	{"Amber", PALETTE_AMBER},
	{"Aero", PALETTE_AERO},
	{"Bootstrap", PALETTE_BOOTSTRAP},
	{"Gruvbox", PALETTE_GRUVBOX},
	{"Gruvbox Light", PALETTE_GRUVBOX_LIGHT},
	{"Naysayer", PALETTE_NAYSAYER},
	{"Solarized", PALETTE_SOLARIZED},
	{"Solarized Light", PALETTE_SOLARIZED_LIGHT},
	{"Monokai", PALETTE_MONOKAI},
	{"Tokyo Night", PALETTE_TOKYO_NIGHT},
	{"Catppuccin", PALETTE_CATPPUCCIN},
	{"Catppuccin Latte", PALETTE_CATPPUCCIN_LATTE},
	{"One Dark", PALETTE_ONE_DARK},
	{"Everforest", PALETTE_EVERFOREST},
}

// The built-in palette of that name (case-insensitive); ok = false when there is none.
palette_named :: proc(name: string) -> (Palette, bool) {
	for np in NAMED_PALETTES {
		if len(np.name) != len(name) { continue }
		same := true
		for i in 0 ..< len(name) {
			a, b := np.name[i], name[i]
			if a >= 'A' && a <= 'Z' { a += 32 }
			if b >= 'A' && b <= 'Z' { b += 32 }
			if a != b { same = false; break }
		}
		if same { return np.palette, true }
	}
	return {}, false
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
	{"link", .Accent, 1}, {"code_bg", .Panel2, 1},   // rich_paragraph: links, inline code
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
	// the selected row of a menu is a filled, rounded row (a tint of the accent, no outline): the outline of a selected
	// item belongs to lists and fields, and a ring around a row with a faint fill reads as a focus box, not as a highlight
	{"menu_item selected background", .Accent, 0.30}, {"menu_item selected border", .Accent, 0},
	{"weak_selected background", .Accent, 0.09}, {"weak_selected border", .Accent, 0.35},
	{"kbd sheen", .White, 0.7},
	{"remove_button hot text", .Bad, 1},   // "hot": the box is under the pointer (build_box)
	{"zebra background", .Bg_Solid, 0.45},
	{"input background", .Bg_Solid, 1}, {"input border", .Border, 1},
	{"kbd background", .Panel2, 1}, {"kbd text", .Weak, 1}, {"kbd border", .Border, 1},
	{"scrim background", .Black, 0.55},
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
	{"ghost_button hover_fill", .Hover, 0.08}, {"ghost_button press_fill", .Hover, 0.14},
	{"icon_button hover_fill", .Hover, 0.08}, {"icon_button press_fill", .Hover, 0.14},
	{"segment hover_fill", .Hover, 0.07}, {"segment press_fill", .Hover, 0.12},
	{"list_row hover_fill", .Hover, 0.05}, {"list_row press_fill", .Hover, 0.09},
	{"tab hover_fill", .Hover, 0.06}, {"tab press_fill", .Hover, 0.10},
	{"button hover_fill", .Hover, 0.07}, {"button press_fill", .Hover, 0.13},
	{"input hover_border", .Hover, 0.22},
	{"hover_fill", .Hover, 0.07}, {"press_fill", .Hover, 0.12}, {"hover_border", .Hover, 0},
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
	if !t.palette_made || len(t.patterns) < t.palette_at + len(entries) + len(state_entries) {
		// (entries the app added before are kept in front of these: for equal specificity the first one wins)
		t.palette_at, t.palette_made = len(t.patterns), true
		for e in entries { theme_add(t, e.tags, {}) }
		for e in state_entries { theme_add(t, e.tags, {}) }
	}
	bg := draw.hex(slot_color(p, .Bg_Solid))
	changed := false
	for e, i in entries {
		c := draw.hex(slot_color(p, e.slot))
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
	if t.finish != p.finish { t.finish = p.finish; changed = true }
	if changed { t.serial += 1 }
}

// The fill of an interaction state ("hover_fill", "press_fill") under the tags of `b`, to draw over `under` (the
// opaque surface below it): its alpha is the one that gives the theme's sRGB step in the blend space of the frame.
// For custom draw procs that paint their own hover (rows, nodes of a graph).
state_fill :: proc(b: ^Box, name: string, under: Maybe(Color) = nil) -> Color {
	c := color_from_tags(g, b.tags_key, name)
	o := under.? or_else box_under(b)
	c.a = draw.alpha_like_srgb(g.space, c, c.a, o)
	return c
}

// The opaque colour under `b`: its own background when opaque, else the nearest ancestor's, else the theme's.
box_under :: proc(b: ^Box) -> Color {
	for p := b; p != nil; p = p.parent {
		if .Draw_Background in p.flags && p.bg.a > 0.5 { return {p.bg.r, p.bg.g, p.bg.b, 1} }
	}
	return g.backdrop
}

// Mixes `a` toward `b` by `t` in sRGB values (linear colours in and out): one step of the theme's state scale.
srgb_step :: proc(a, b: Color, t: f32) -> Color {
	m := srgb_mix(a, b, t)
	m.a = a.a
	return m
}
