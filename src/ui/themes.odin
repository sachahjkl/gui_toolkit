package ui

// Themes: a theme is a name and the colours of a dark version and a light one (or of one of them), each a few greys
// (the steps of the surfaces, the texts) and eight hues. A program shows one version of one theme: `theme_palette` makes
// the palette of the built-in widgets from it, and `theme_recolor` moves the colours a program draws itself from its
// own reference theme to the one shown. A user's themes come from a file of theirs (`themes_read`).
//
//   steps:  well (sunken: fields, code), bg0 (the page), bg1 (bars), bg2 (panels, cards), bg3 (raised: buttons), line
//   texts:  faint, weak, text, bright
//   hues:   accent, blue, purple, green, yellow, red, cyan, rose

import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"
import "../ascii"
import "../draw"
import "../platform"

Theme_Colors :: struct {
	steps: [6]u32,   // 0xRRGGBBAA, sRGB
	texts: [4]u32,
	hues:  [8]u32,
}

// The versions a theme has.
Theme_Versions :: enum u8 { Both, Dark_Only, Light_Only }

Theme_Def :: struct {
	name:        string,
	dark, light: Theme_Colors,
	versions:    Theme_Versions,
	finish:      Maybe(Finish),   // the finish it is made for (Aero: Glass); nil: the program's choice
	translucent: bool,            // its page has alpha < 1: the system's backdrop shows through (Palette.translucent)
	accent_text: u32,             // the text on its accent; 0: of its darkest and brightest, the one that reads better
}

// Which version a program shows: the system's (platform.dark_mode_preferred), or one of them.
Theme_Mode :: enum u8 { System, Dark, Light }

THEME_MODE_NAMES := [Theme_Mode]string{.System = "system", .Dark = "dark", .Light = "light"}

// Whether `mode` shows the light version now.
theme_wants_light :: proc(mode: Theme_Mode) -> bool {
	switch mode {
	case .Light:  return true
	case .Dark:   return false
	case .System: return !platform.dark_mode_preferred()
	}
	return false
}

// The mode of a name of THEME_MODE_NAMES (ASCII case ignored); System for any other.
theme_mode_of :: proc(name: string) -> Theme_Mode {
	for n, m in THEME_MODE_NAMES { if ascii.equal_fold(n, name) { return m } }
	return .System
}

// The colours of the version shown: the light one when asked and the theme has it, else the dark one, else the light.
theme_version :: proc(t: Theme_Def, light: bool) -> (c: Theme_Colors, is_light: bool) {
	switch t.versions {
	case .Dark_Only:  return t.dark, false
	case .Light_Only: return t.light, true
	case .Both:       return light ? t.light : t.dark, light
	}
	return t.dark, false
}

// The palette of the built-in widgets for a version of `t` (`light`: asked for, see theme_version). `finish`: the
// program's, unless the theme has its own.
theme_palette :: proc(t: Theme_Def, light: bool, finish: Finish = .Flat) -> Palette {
	c, is_light := theme_version(t, light)
	accent_text := t.accent_text != 0 ? t.accent_text : theme_on_accent(c)
	return Palette{
		bg = c.steps[1], bar = c.steps[2], panel = c.steps[3], panel2 = c.steps[4], border = c.steps[5], well = c.steps[0],
		text = c.texts[2], weak = c.texts[1],
		accent = c.hues[0], accent_text = accent_text, good = c.hues[3], warn = c.hues[4], bad = c.hues[5],
		dark = !is_light, finish = t.finish.? or_else finish, translucent = t.translucent,
		blue = c.hues[1], purple = c.hues[2], cyan = c.hues[6], rose = c.hues[7],
	}
}

// The text on the accent: of the theme's darkest step and brightest text, the one of more contrast with it (a pale
// accent wants the dark one, a deep one the bright one, whatever the version).
theme_on_accent :: proc(c: Theme_Colors) -> u32 {
	accent := draw.hex(c.hues[0])
	dark, bright := c.steps[1] | 0xff, c.texts[3]
	sum :: proc(v: u32) -> f32 { x := draw.hex(v); return x.r + x.g + x.b }
	if sum(dark) > sum(bright) { dark, bright = bright, dark }
	return contrast(draw.hex(dark), accent) >= contrast(draw.hex(bright), accent) ? dark : bright
}

// The theme of this name in `list` (ASCII case ignored), and where; ok = false when there is none.
theme_find :: proc(list: []Theme_Def, name: string) -> (t: Theme_Def, at: int, ok: bool) {
	for x, i in list { if ascii.equal_fold(x.name, name) { return x, i, true } }
	return {}, -1, false
}

// A version of a theme as a palette, by its name: "Nord" (its dark version, or its only one), "Nord Light".
Named_Palette :: struct { name: string, palette: Palette }

// Every version of every theme of `list`, dark first (the names and the list are `allocator`'s).
theme_palettes :: proc(list: []Theme_Def, finish: Finish = .Flat, allocator := context.temp_allocator) -> []Named_Palette {
	out := make([dynamic]Named_Palette, allocator)
	for t in list {
		if t.versions != .Light_Only { append(&out, Named_Palette{strings.clone(t.name, allocator), theme_palette(t, false, finish)}) }
		if t.versions != .Dark_Only {
			name := t.versions == .Light_Only ? strings.clone(t.name, allocator) : strings.concatenate({t.name, " Light"}, allocator)
			append(&out, Named_Palette{name, theme_palette(t, true, finish)})
		}
	}
	return out[:]
}

// A palette of a theme of THEMES by its name: the dark version, or the light one (ui.THEMES[0] for a name that is not
// there). For examples and tests; a program keeps its theme and mode and calls theme_palette.
palette_of :: proc(name: string, light := false) -> Palette {
	t, _, ok := theme_find(THEMES[:], name)
	if !ok { t = THEMES[0] }
	return theme_palette(t, light)
}

// What a program shows: a theme of its list by its name, the mode (light, dark, the system's), the finish (a theme made
// for one keeps its own), the halos of the machined finish (Theme.glow).
Theme_Choice :: struct {
	name:   string,
	mode:   Theme_Mode,
	finish: Finish,
	glow:   f32,
}

// What theme_show applied last: one for each Theme.
Theme_Shown :: struct {
	key:   u64,         // the theme's colours, the choice, the blend space and the system's light or dark it was applied for
	def:   Theme_Def,   // the theme shown (its name is the list's)
	light: bool,        // its light version is shown
}

// Shows `c` with `t`: the palette of its theme's version (theme_palette), its halos. `space`: the blend space of the
// renderer `t` draws with (render.blend_space), as apply_palette takes it. Call it once a frame: it applies only when
// the choice, the theme's definition (a themes file read again) or the space changed, or, in the System mode, when the
// system went light or dark (platform.color_scheme_serial); otherwise it costs a lookup in `list` and a hash. A name
// that is not in `list` shows its first theme. True when it applied: the program then gives its windows' title bars the
// version shown (platform.set_dark_title(w, !shown.light)).
theme_show :: proc(t: ^Theme, list: []Theme_Def, c: Theme_Choice, shown: ^Theme_Shown, space: draw.Blend_Space) -> bool {
	if len(list) == 0 { return false }
	def, _, ok := theme_find(list, c.name)
	if !ok { def = list[0] }
	key := theme_show_key(def, c, space)
	if key == shown.key { return false }
	shown.key = key
	light := theme_wants_light(c.mode)
	_, shown.light = theme_version(def, light)
	shown.def = def
	apply_palette(t, theme_palette(def, light, c.finish), space)
	// (the halos are drawn from Theme.glow, not from the palette: a change of it alone is a change of the look too)
	if t.glow != c.glow { t.glow = c.glow; t.serial += 1 }
	return true
}

// Everything theme_show's result depends on, as one hash. The fields go through a zeroed struct (no padding garbage);
// the name is hashed apart.
@(private = "file")
theme_show_key :: proc(def: Theme_Def, c: Theme_Choice, space: draw.Blend_Space) -> u64 {
	Fields :: struct {
		dark, light:   Theme_Colors,
		accent_text:   u32,
		glow:          f32,
		scheme:        u32,
		versions:      Theme_Versions,
		own_finish:    Finish,
		has_finish:    bool,
		translucent:   bool,
		mode:          Theme_Mode,
		finish:        Finish,
		space:         draw.Blend_Space,
	}
	f: Fields
	f.dark, f.light, f.accent_text, f.versions, f.translucent = def.dark, def.light, def.accent_text, def.versions, def.translucent
	f.own_finish, f.has_finish = def.finish.?
	f.glow, f.mode, f.finish, f.space = c.glow, c.mode, c.finish, space
	f.scheme = c.mode == .System ? platform.color_scheme_serial() : 0
	h := u64(FNV64_OFFSET_BASIS)
	fnv64_mix(&h, transmute([]u8)def.name)
	fnv64_mix(&h, mem.ptr_to_bytes(&f))
	return h | 1   // (0 is "nothing shown yet")
}

////////////////////////////////
// Colours moved from one theme to another

// The theme a program's own colours were chosen in, and where its greys stand: twelve levels (0..255, the mean of the
// channels) for, in order, what is under its well, its well, bg0..bg3, its line, its faint, weak texts, a text between
// weak and text, its text, its bright text. theme_reference makes them from its colours.
Theme_Reference :: struct {
	colors: Theme_Colors,
	levels: [12]f32,
}

theme_reference :: proc(c: Theme_Colors) -> Theme_Reference {
	r := Theme_Reference{colors = c}
	stops := theme_grey_stops(c)
	for s, i in stops { r.levels[i] = (s.r + s.g + s.b) / 3 }
	return r
}

// A colour of the program's (chosen in `ref`) in theme `to`. A grey goes to the same place on `to`'s greys; a colour to
// `to`'s hue of the nearest of `ref`'s hues, mixed with `to`'s grey as much as it was with `ref`'s. The alpha stays.
theme_recolor :: proc(ref: ^Theme_Reference, to: Theme_Colors, c: u32) -> u32 {
	col := rgb3(c)
	a := c & 0xff
	lo, hi := min(col.r, col.g, col.b), max(col.r, col.g, col.b)
	if hi - lo <= THEME_GREY_SPREAD { return pack3(theme_grey(ref, to, (col.r + col.g + col.b) / 3), a) }
	// c = (1 - k) grey + k hue: the hue of ref's it is nearest to, and how much of it
	best, best_k, best_grey, best_err := 0, f32(1), f32(0), max(f32)
	for h, i in ref.colors.hues {
		base := rgb3(h)
		for step in 0 ..= THEME_MIX_STEPS {
			k := f32(step) / THEME_MIX_STEPS
			grey, err: f32
			if k >= 1 {
				d := col - base
				err = d.r * d.r + d.g * d.g + d.b * d.b
			} else {
				g := (col - base * k) / (1 - k)
				grey = (g.r + g.g + g.b) / 3
				if grey < 0 || grey > 255 { continue }
				d := (g - grey) * (1 - k)
				err = d.r * d.r + d.g * d.g + d.b * d.b
			}
			if err < best_err { best, best_k, best_grey, best_err = i, k, grey, err }
		}
	}
	out := rgb3(to.hues[best]) * best_k
	if best_k < 1 { out += theme_grey(ref, to, best_grey) * (1 - best_k) }
	return pack3(out, a)
}

// Channels this close make a grey; how finely a colour's share of its hue is looked for.
THEME_GREY_SPREAD :: 3
THEME_MIX_STEPS   :: 64

// The twelve greys of a theme (Theme_Reference.levels says what each is).
@(private = "file")
theme_grey_stops :: proc(t: Theme_Colors) -> [12][3]f32 {
	well := rgb3(t.steps[0])
	under := rgb3(t.steps[1]) + (well - rgb3(t.steps[1])) * 2   // (past the well, as far again)
	return {
		under, well, rgb3(t.steps[1]), rgb3(t.steps[2]), rgb3(t.steps[3]), rgb3(t.steps[4]), rgb3(t.steps[5]),
		rgb3(t.texts[0]), rgb3(t.texts[1]), rgb3(t.texts[1]) * 0.3 + rgb3(t.texts[2]) * 0.7, rgb3(t.texts[2]), rgb3(t.texts[3]),
	}
}

// The grey of `ref` at `level`, on `to`'s greys.
@(private = "file")
theme_grey :: proc(ref: ^Theme_Reference, to: Theme_Colors, level: f32) -> [3]f32 {
	stops := theme_grey_stops(to)
	if level <= ref.levels[0] { return stops[0] }
	for i in 1 ..< len(ref.levels) {
		if level <= ref.levels[i] {
			f := (level - ref.levels[i - 1]) / max(ref.levels[i] - ref.levels[i - 1], 0.001)
			return stops[i - 1] * (1 - f) + stops[i] * f
		}
	}
	return stops[len(stops) - 1]
}

@(private = "file")
rgb3 :: proc(c: u32) -> [3]f32 { return {f32(c >> 24 & 0xff), f32(c >> 16 & 0xff), f32(c >> 8 & 0xff)} }

@(private = "file")
pack3 :: proc(c: [3]f32, a: u32) -> u32 {
	ch :: proc(v: f32) -> u32 { return u32(clamp(math.round(v), 0, 255)) }
	return ch(c.r) << 24 | ch(c.g) << 16 | ch(c.b) << 8 | a
}

////////////////////////////////
// A user's themes: a file of theirs

// The keys of a theme in a themes file, in the order of Theme_Colors (steps, texts, hues).
THEME_KEYS :: [18]string{"well", "bg0", "bg1", "bg2", "bg3", "line", "faint", "weak", "text", "bright", "accent", "blue", "purple", "green", "yellow", "red", "cyan", "rose"}

// The themes of a user's file. Each `[Name]` section is one theme; it starts as `base`'s dark version with no light one,
// `from = Name` starts it from a theme of `catalog` instead, and each `key = #rrggbb` sets a colour (THEME_KEYS; `light.`
// before the key: of its light version, which it then has). Blank lines and lines starting with # or ; are skipped. The
// names are `allocator`'s (themes_destroy).
themes_read :: proc(text: string, catalog: []Theme_Def, base: Theme_Def, allocator := context.allocator) -> [dynamic]Theme_Def {
	out := make([dynamic]Theme_Def, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' || l[0] == ';' { continue }
		if l[0] == '[' && l[len(l) - 1] == ']' {
			name := strings.trim_space(l[1:len(l) - 1])
			if name == "" { continue }
			t := base
			t.versions = .Dark_Only
			t.name = strings.clone(name, allocator)
			append(&out, t)
			continue
		}
		eq := strings.index_byte(l, '=')
		if len(out) == 0 || eq < 0 { continue }
		theme_key(&out[len(out) - 1], catalog, ascii.lower(strings.trim_space(l[:eq])), strings.trim_space(l[eq + 1:]))
	}
	return out
}

themes_destroy :: proc(list: ^[dynamic]Theme_Def, allocator := context.allocator) {
	for t in list { delete(t.name, allocator) }
	delete(list^)
	list^ = nil
}

@(private = "file")
theme_key :: proc(t: ^Theme_Def, catalog: []Theme_Def, key, value: string) {
	if key == "from" {
		if b, _, ok := theme_find(catalog, value); ok { name := t.name; t^ = b; t.name = name }
		return
	}
	c, ok := theme_hex(value)
	if !ok { return }
	cols := &t.dark
	k := key
	if strings.has_prefix(k, "light.") {
		cols, k = &t.light, k[len("light."):]
		t.versions = .Both
	} else if strings.has_prefix(k, "dark.") {
		k = k[len("dark."):]
	}
	for n, i in THEME_KEYS {
		if n != k { continue }
		switch {
		case i < 6:  cols.steps[i] = c
		case i < 10: cols.texts[i - 6] = c
		case:        cols.hues[i - 10] = c
		}
	}
}

// #rrggbb (or rrggbb) as 0xRRGGBBFF.
@(private = "file")
theme_hex :: proc(s: string) -> (u32, bool) {
	h := strings.trim_prefix(s, "#")
	if len(h) != 6 { return 0, false }
	v, ok := strconv.parse_uint(h, 16)
	if !ok { return 0, false }
	return u32(v) << 8 | 0xff, true
}

////////////////////////////////
// The themes of the toolkit

// For theme pickers and settings: the names are what programs store. The first is the default.
THEMES := [?]Theme_Def{
	// indigo night; in the light version a cool daylight
	{"Midnight",
		{{0x0a0c17ff, 0x0f1220ff, 0x171b2fff, 0x171b2fff, 0x20253dff, 0x2b3150ff}, {0x5a6283ff, 0x8d95b5ff, 0xe6e9f5ff, 0xffffffff},
			{0x7c8cffff, 0x60a5faff, 0xa78bfaff, 0x4ade80ff, 0xfbbf24ff, 0xf87171ff, 0x22d3eeff, 0xf472b6ff}},
		{{0xe6e8eeff, 0xf3f4f7ff, 0xffffffff, 0xffffffff, 0xe9ecf2ff, 0xd9dde4ff}, {0x9aa1adff, 0x6b7380ff, 0x1f2430ff, 0x000000ff},
			{0x3b5bdbff, 0x2563ebff, 0x7c3aedff, 0x2f9e5aff, 0xc98a10ff, 0xd6333fff, 0x0e7490ff, 0xdb2777ff}}, .Both, nil, false, 0},
	{"Graphite",
		{{0x0e0e0eff, 0x151515ff, 0x1e1e1eff, 0x1e1e1eff, 0x2a2a2aff, 0x353535ff}, {0x5e5e5eff, 0x8e8e8eff, 0xeaeaeaff, 0xffffffff},
			{0x4cc2ffff, 0x60a5faff, 0xa78bfaff, 0x5dd39eff, 0xf4c95dff, 0xff6b6bff, 0x4cc2ffff, 0xf472b6ff}}, {}, .Dark_Only, nil, false, 0},
	// a kernel's console at night: blue black, a hairline lit along the top of every surface, square tiles of colour (finish Edged)
	{"Kernel",
		{{0x070a10ff, 0x0a0e16ff, 0x0f1520ff, 0x121a27ff, 0x1a2436ff, 0x243048ff}, {0x4a5670ff, 0x7f8ca6ff, 0xc8d2e2ff, 0xeef3fbff},
			{0x3d7fd6ff, 0x5b9be8ff, 0x9a7ae0ff, 0x62d07aff, 0xe0a85aff, 0xd9434fff, 0x4cc2b0ff, 0xd4568fff}}, {}, .Dark_Only, .Edged, false, 0xffffffff},
	// a terminal's amber
	{"Amber",
		{{0x100d07ff, 0x16120bff, 0x201a10ff, 0x201a10ff, 0x2d2415ff, 0x3d311cff}, {0x7a6640ff, 0xb59a66ff, 0xffe9c2ff, 0xfff6e5ff},
			{0xffb000ff, 0x7fb2e5ff, 0xc49ae0ff, 0x9acd32ff, 0xffd54fff, 0xff7043ff, 0x7fd6c8ff, 0xf2a0b8ff}}, {}, .Dark_Only, nil, false, 0},
	// Everforest (sainnhe): a green-grey forest, soft contrast
	{"Everforest",
		{{0x272e33ff, 0x2d353bff, 0x343f44ff, 0x343f44ff, 0x3d484dff, 0x475258ff}, {0x7a8478ff, 0x9da9a0ff, 0xd3c6aaff, 0xfdf6e3ff},
			{0xa7c080ff, 0x7fbbb3ff, 0xd699b6ff, 0xa7c080ff, 0xdbbc7fff, 0xe67e80ff, 0x83c092ff, 0xe69875ff}}, {}, .Dark_Only, nil, false, 0},
	// Windows 7: sky-blue glass behind white panels, glossy silver buttons, Aero blue for selection
	{"Aero", {},
		{{0xe9eef5ff, 0xb9d1ee8c, 0x6fa3dcb0, 0xfbfcfeff, 0xe3e9f1ff, 0x8ea6c6ff}, {0x8193a8ff, 0x4f6178ff, 0x1b2633ff, 0x000000ff},
			{0x2f86dbff, 0x2f86dbff, 0x7a5cc7ff, 0x2e9e45ff, 0xd08c00ff, 0xd13b2eff, 0x1f8fa3ff, 0xc2477aff}}, .Light_Only, .Glass, true, 0xffffffff},
	// Bootstrap 2 (2012): white page, grey wells, gradient buttons with embossed text, blue focus glow
	{"Bootstrap", {},
		{{0xf5f5f5ff, 0xffffffff, 0xf5f5f5ff, 0xf5f5f5ff, 0xe9e9e9ff, 0xccccccff}, {0xb0b0b0ff, 0x8a8a8aff, 0x333333ff, 0x000000ff},
			{0x0a6fd1ff, 0x0a6fd1ff, 0x7a43b6ff, 0x51a351ff, 0xf89406ff, 0xd2463fff, 0x2f96b4ff, 0xc7317aff}}, .Light_Only, .Gradient, false, 0xffffffff},
	// silver on near black; in the light version graphite on white (silver would vanish there)
	{"Silver",
		{{0x050506ff, 0x08090aff, 0x0d0e10ff, 0x131417ff, 0x1b1c20ff, 0x2a2c31ff}, {0x5d6067ff, 0x8e9198ff, 0xe6e7eaff, 0xffffffff},
			{0xc9ced6ff, 0x8fa9c9ff, 0xa99bc4ff, 0x9cc4a3ff, 0xd9c48fff, 0xd98a8aff, 0x95c3c8ff, 0xc9a0b4ff}},
		{{0xe6e7eaff, 0xf7f7f8ff, 0xeff0f2ff, 0xffffffff, 0xffffffff, 0xd6d8dcff}, {0xa3a6adff, 0x6b6e75ff, 0x1b1c20ff, 0x000000ff},
			{0x4a4f58ff, 0x3d6a9eff, 0x6b56a3ff, 0x3d7f4bff, 0x9a7615ff, 0xb23a3aff, 0x2f7c86ff, 0xa64a72ff}}, .Both, nil, false, 0},
	// total black, white its only colour; in the light version white paper and black
	{"Void",
		{{0x000000ff, 0x030303ff, 0x070707ff, 0x0d0d0dff, 0x141414ff, 0x222222ff}, {0x4a4a4aff, 0x7a7a7aff, 0xd8d8d8ff, 0xffffffff},
			{0xf0f0f0ff, 0x8a9bb0ff, 0x9e94b3ff, 0x8fb39aff, 0xc9b98aff, 0xc98585ff, 0x8fb8bcff, 0xbd98aaff}},
		{{0xeeeeeeff, 0xffffffff, 0xf8f8f8ff, 0xffffffff, 0xffffffff, 0xe2e2e2ff}, {0xa0a0a0ff, 0x6a6a6aff, 0x111111ff, 0x000000ff},
			{0x111111ff, 0x3a5f8cff, 0x5f4f8fff, 0x3a7346ff, 0x8a6a12ff, 0xa83434ff, 0x2c6f78ff, 0x974468ff}}, .Both, nil, false, 0},
	// warm black and champagne gold; in the light version ivory and bronze
	{"Champagne",
		{{0x080706ff, 0x0b0a08ff, 0x100f0cff, 0x161511ff, 0x1e1c17ff, 0x302d26ff}, {0x6b6558ff, 0x9a9384ff, 0xebe5d6ff, 0xfffaf0ff},
			{0xd8c08aff, 0x93a6b8ff, 0xb3a0bfff, 0xa7bf95ff, 0xe0c27aff, 0xd98f7eff, 0x9cbfb5ff, 0xd4a3a0ff}},
		{{0xebe5d6ff, 0xfbf8f1ff, 0xf3eee3ff, 0xfffdf8ff, 0xffffffff, 0xddd5c3ff}, {0xa39b88ff, 0x726b5cff, 0x24211bff, 0x0b0a08ff},
			{0x8a6d2fff, 0x3f6485ff, 0x6e5487ff, 0x50733aff, 0x9a7415ff, 0xa8452fff, 0x3e7a6cff, 0x9c5560ff}}, .Both, nil, false, 0},
	// blue black and ice; in the light version cold white and steel blue
	{"Glacier",
		{{0x04070aff, 0x06090dff, 0x0a0f14ff, 0x10161dff, 0x172029ff, 0x25303bff}, {0x56636fff, 0x8796a3ff, 0xe3ecf2ff, 0xffffffff},
			{0xa8d8f0ff, 0x86b4e0ff, 0xa9a3d9ff, 0x8fcbb0ff, 0xdcc98aff, 0xe0898fff, 0x8fd3d8ff, 0xc9a3c4ff}},
		{{0xe4ebf0ff, 0xf7fafcff, 0xeef3f7ff, 0xffffffff, 0xffffffff, 0xd3dde5ff}, {0x9aa7b2ff, 0x617080ff, 0x16202aff, 0x04070aff},
			{0x2b6c8fff, 0x2f64a3ff, 0x5a52a3ff, 0x2f7d5cff, 0x8c7516ff, 0xb23d4aff, 0x237a85ff, 0x8f4f86ff}}, .Both, nil, false, 0},
	// green black and jade; in the light version pale green white and deep jade
	{"Jade",
		{{0x040705ff, 0x060a08ff, 0x0a100cff, 0x0f1712ff, 0x162019ff, 0x243228ff}, {0x5a6b60ff, 0x8a9c90ff, 0xe2ece5ff, 0xffffffff},
			{0x7fd1a8ff, 0x8fb0c9ff, 0xaa9fc9ff, 0x8fd18fff, 0xd6c98aff, 0xd98c8cff, 0x86cfc4ff, 0xc9a0b8ff}},
		{{0xe2ebe5ff, 0xf6faf7ff, 0xedf3efff, 0xffffffff, 0xffffffff, 0xd0dcd4ff}, {0x96a69bff, 0x5d6f63ff, 0x14201aff, 0x040705ff},
			{0x2f7a57ff, 0x3a6a8fff, 0x5f5596ff, 0x2f7a3aff, 0x86731aff, 0xa9403fff, 0x22756cff, 0x8f4f72ff}}, .Both, nil, false, 0},
	// wine black and rose gold; in the light version rosy white and garnet
	{"Bordeaux",
		{{0x090506ff, 0x0c0708ff, 0x120b0cff, 0x191012ff, 0x221619ff, 0x362429ff}, {0x6e5a5eff, 0x9e878bff, 0xf0e4e5ff, 0xfff7f8ff},
			{0xe3a6a1ff, 0x98a8c4ff, 0xbca0c9ff, 0xa3c49aff, 0xe0c084ff, 0xe5807fff, 0x98c4c0ff, 0xe39fb7ff}},
		{{0xefe3e2ff, 0xfcf6f5ff, 0xf6eeedff, 0xfffbfaff, 0xffffffff, 0xe3d3d2ff}, {0xa8939aff, 0x7a6267ff, 0x2a1a1eff, 0x0c0708ff},
			{0x9a4a52ff, 0x456691ff, 0x734f8fff, 0x4f7a3fff, 0x93711aff, 0xb03838ff, 0x3a7570ff, 0xa34468ff}}, .Both, nil, false, 0},
	// Rosé Pine, and Rosé Pine Dawn
	{"Rosé Pine",
		{{0x13111eff, 0x191724ff, 0x1f1d2eff, 0x26233aff, 0x2a273fff, 0x403d52ff}, {0x6e6a86ff, 0x908caaff, 0xe0def4ff, 0xf5f3ffff},
			{0xebbcbaff, 0x9ccfd8ff, 0xc4a7e7ff, 0x8fbf9fff, 0xf6c177ff, 0xeb6f92ff, 0x9ccfd8ff, 0xebbcbaff}},
		{{0xf2e9e1ff, 0xfaf4edff, 0xf4ede6ff, 0xfffaf3ff, 0xfffdf9ff, 0xdfdad9ff}, {0x9893a5ff, 0x797593ff, 0x575279ff, 0x26233aff},
			{0xd7827eff, 0x286983ff, 0x907aa9ff, 0x4f8a5cff, 0xea9d34ff, 0xb4637aff, 0x56949fff, 0xd7827eff}}, .Both, nil, false, 0},
	// Kanagawa (wave), and Kanagawa Lotus
	{"Kanagawa",
		{{0x16161dff, 0x1a1a22ff, 0x1f1f28ff, 0x2a2a37ff, 0x363646ff, 0x54546dff}, {0x727169ff, 0x938aa9ff, 0xdcd7baff, 0xf2ecd0ff},
			{0x7e9cd8ff, 0x7fb4caff, 0x957fb8ff, 0x98bb6cff, 0xe6c384ff, 0xe46876ff, 0x7aa89fff, 0xd27e99ff}},
		{{0xdcd5acff, 0xf2ecbcff, 0xeae3b4ff, 0xf6f1c8ff, 0xfaf6d6ff, 0xd5cea3ff}, {0x8a8980ff, 0x716e61ff, 0x545464ff, 0x1f1f28ff},
			{0x4d699bff, 0x4d699bff, 0x624c83ff, 0x6f894eff, 0xa07e1bff, 0xc84053ff, 0x597b75ff, 0xb35b79ff}}, .Both, nil, false, 0},
	{"Monokai",
		{{0x161713ff, 0x1c1d19ff, 0x22231eff, 0x272822ff, 0x30312aff, 0x3e3d32ff}, {0x75715eff, 0x9d9a8aff, 0xf8f8f2ff, 0xffffffff},
			{0xfd971fff, 0x66d9efff, 0xae81ffff, 0xa6e22eff, 0xe6db74ff, 0xf92672ff, 0x78dce8ff, 0xff6188ff}},
		{{0xe8e6dfff, 0xfafaf8ff, 0xf2f1ecff, 0xffffffff, 0xffffffff, 0xd9d7cfff}, {0xa59f85ff, 0x75715eff, 0x272822ff, 0x000000ff},
			{0xd96a00ff, 0x0f8fa8ff, 0x7c4dffff, 0x5c8a00ff, 0x9e8600ff, 0xd01b5fff, 0x0f8fa8ff, 0xe0457bff}}, .Both, nil, false, 0},
	{"Gruvbox",
		{{0x141617ff, 0x1a1c1dff, 0x1d2021ff, 0x282828ff, 0x32302fff, 0x45403dff}, {0x7c6f64ff, 0xa89984ff, 0xebdbb2ff, 0xfbf1c7ff},
			{0xfe8019ff, 0x83a598ff, 0xd3869bff, 0xb8bb26ff, 0xfabd2fff, 0xfb4934ff, 0x8ec07cff, 0xd3869bff}},
		{{0xebdbb2ff, 0xfbf1c7ff, 0xf2e5bcff, 0xfdf6d8ff, 0xfffbe8ff, 0xd5c4a1ff}, {0xa89984ff, 0x7c6f64ff, 0x3c3836ff, 0x282828ff},
			{0xaf3a03ff, 0x076678ff, 0x8f3f71ff, 0x79740eff, 0xb57614ff, 0x9d0006ff, 0x427b58ff, 0x8f3f71ff}}, .Both, nil, false, 0},
	{"Dracula",
		{{0x15161cff, 0x1b1c24ff, 0x21222cff, 0x282a36ff, 0x303241ff, 0x44475aff}, {0x6272a4ff, 0x9ea6c9ff, 0xf8f8f2ff, 0xffffffff},
			{0xbd93f9ff, 0x8be9fdff, 0xbd93f9ff, 0x50fa7bff, 0xf1fa8cff, 0xff5555ff, 0x8be9fdff, 0xff79c6ff}},
		{{0xeee9d4ff, 0xfffbebff, 0xf4efdaff, 0xfffdf4ff, 0xffffffff, 0xdcd6bfff}, {0x9a948aff, 0x6c664bff, 0x1f1f1fff, 0x000000ff},
			{0x644ac9ff, 0x036a96ff, 0x644ac9ff, 0x14710aff, 0x846e15ff, 0xcb3a2aff, 0x036a96ff, 0xa3144dff}}, .Both, nil, false, 0},
	{"Nord",
		{{0x1f232bff, 0x252a33ff, 0x2a2f3aff, 0x2e3440ff, 0x3b4252ff, 0x434c5eff}, {0x616e88ff, 0x8a96acff, 0xe5e9f0ff, 0xeceff4ff},
			{0x88c0d0ff, 0x81a1c1ff, 0xb48eadff, 0xa3be8cff, 0xebcb8bff, 0xbf616aff, 0x8fbcbbff, 0xd08770ff}},
		{{0xd8dee9ff, 0xeceff4ff, 0xe5e9f0ff, 0xf6f8fbff, 0xffffffff, 0xcdd3deff}, {0x8a93a6ff, 0x5c6a83ff, 0x2e3440ff, 0x1d222bff},
			{0x5e81acff, 0x5e81acff, 0x8f6c8dff, 0x6e8a55ff, 0xb08a3aff, 0xbf616aff, 0x4f8f8fff, 0xc0704fff}}, .Both, nil, false, 0},
	{"Tokyo Night",
		{{0x101118ff, 0x14151eff, 0x16161eff, 0x1a1b26ff, 0x24283bff, 0x2f344dff}, {0x565f89ff, 0x787fa8ff, 0xc0caf5ff, 0xe4e9ffff},
			{0x7aa2f7ff, 0x7aa2f7ff, 0xbb9af7ff, 0x9ece6aff, 0xe0af68ff, 0xf7768eff, 0x7dcfffff, 0xff9e64ff}},
		{{0xd5d6dbff, 0xe9e9edff, 0xe1e2e7ff, 0xf2f2f5ff, 0xfafafcff, 0xc4c8daff}, {0x8990b3ff, 0x6172b0ff, 0x3760bfff, 0x1e2a5aff},
			{0x2e7de9ff, 0x2e7de9ff, 0x9854f1ff, 0x587539ff, 0x8c6c3eff, 0xf52a65ff, 0x007197ff, 0xb15c00ff}}, .Both, nil, false, 0},
	{"Catppuccin",
		{{0x0b0b12ff, 0x11111bff, 0x181825ff, 0x1e1e2eff, 0x282839ff, 0x313244ff}, {0x6c7086ff, 0x9399b2ff, 0xcdd6f4ff, 0xf2f5ffff},
			{0xcba6f7ff, 0x89b4faff, 0xcba6f7ff, 0xa6e3a1ff, 0xf9e2afff, 0xf38ba8ff, 0x94e2d5ff, 0xf5c2e7ff}},
		{{0xdce0e8ff, 0xeff1f5ff, 0xe6e9efff, 0xf7f8faff, 0xffffffff, 0xccd0daff}, {0x9ca0b0ff, 0x6c6f85ff, 0x4c4f69ff, 0x1e2030ff},
			{0x8839efff, 0x1e66f5ff, 0x8839efff, 0x40a02bff, 0xdf8e1dff, 0xd20f39ff, 0x179299ff, 0xea76cbff}}, .Both, nil, false, 0},
	{"One Dark",
		{{0x14161aff, 0x1b1d23ff, 0x21252bff, 0x282c34ff, 0x2c313aff, 0x3e4451ff}, {0x5c6370ff, 0x8a919eff, 0xd7dae0ff, 0xffffffff},
			{0x61afefff, 0x61afefff, 0xc678ddff, 0x98c379ff, 0xe5c07bff, 0xe06c75ff, 0x56b6c2ff, 0xd19a66ff}},
		{{0xe5e5e6ff, 0xfafafaff, 0xf0f0f1ff, 0xffffffff, 0xffffffff, 0xdbdbdcff}, {0xa0a1a7ff, 0x696c77ff, 0x383a42ff, 0x000000ff},
			{0x4078f2ff, 0x4078f2ff, 0xa626a4ff, 0x50a14fff, 0xc18401ff, 0xe45649ff, 0x0184bcff, 0x986801ff}}, .Both, nil, false, 0},
	{"Campbell",
		{{0x050505ff, 0x0c0c0cff, 0x121212ff, 0x181818ff, 0x202020ff, 0x303030ff}, {0x767676ff, 0x9e9e9eff, 0xccccccff, 0xf2f2f2ff},
			{0x3b78ffff, 0x3b78ffff, 0xb4009eff, 0x16c60cff, 0xc19c00ff, 0xe74856ff, 0x61d6d6ff, 0xb4009eff}},
		{{0xdededeff, 0xf7f7f7ff, 0xeeeeeeff, 0xffffffff, 0xffffffff, 0xd0d0d0ff}, {0x8a8a8aff, 0x5e5e5eff, 0x0c0c0cff, 0x000000ff},
			{0x0037daff, 0x0037daff, 0x881798ff, 0x13a10eff, 0xc19c00ff, 0xc50f1fff, 0x3a96ddff, 0x881798ff}}, .Both, nil, false, 0},
	{"Retro",
		{{0x000000ff, 0x050505ff, 0x0b0b0bff, 0x121212ff, 0x1a1a1aff, 0x2b2b2bff}, {0x626262ff, 0x9c9c94ff, 0xe8e6dcff, 0xffffffff},
			{0xffaf00ff, 0x5f87ffff, 0xaf87ffff, 0x87d75fff, 0xffd75fff, 0xff5f5fff, 0x5fd7d7ff, 0xff87afff}},
		{{0xe4dfd0ff, 0xf5f2e8ff, 0xece8dbff, 0xfbf9f2ff, 0xffffffff, 0xd2ccb9ff}, {0x9a9484ff, 0x6a655aff, 0x1a1a1aff, 0x000000ff},
			{0xd75f00ff, 0x005fd7ff, 0x8700afff, 0x008700ff, 0xaf8700ff, 0xd70000ff, 0x008787ff, 0xd7005fff}}, .Both, nil, false, 0},
	{"Naysayer",
		{{0x03161bff, 0x041c22ff, 0x052026ff, 0x062329ff, 0x0b2d34ff, 0x154049ff}, {0x4e7a6eff, 0x8f9f88ff, 0xd1b897ff, 0xffffffff},
			{0x8cde94ff, 0x7ad0c6ff, 0xc39ad8ff, 0x44b340ff, 0xe0c46cff, 0xf0605cff, 0x2ec09cff, 0xd68fa3ff}},
		{{0xe6dcc4ff, 0xf4ecd8ff, 0xece2caff, 0xfaf5e8ff, 0xfffcf2ff, 0xd6c9a8ff}, {0x9a8f74ff, 0x5f6b5cff, 0x062329ff, 0x021014ff},
			{0x2e8a4fff, 0x1f7f86ff, 0x8a4fa0ff, 0x2f7f2bff, 0x9c7a12ff, 0xc0392bff, 0x16806aff, 0xb05072ff}}, .Both, nil, false, 0},
	{"Solarized",
		{{0x001d24ff, 0x00232bff, 0x002731ff, 0x002b36ff, 0x073642ff, 0x0f4552ff}, {0x586e75ff, 0x839496ff, 0xe4dfcdff, 0xfdf6e3ff},
			{0x268bd2ff, 0x268bd2ff, 0x6c71c4ff, 0x859900ff, 0xb58900ff, 0xdc322fff, 0x2aa198ff, 0xd33682ff}},
		{{0xeee8d5ff, 0xfdf6e3ff, 0xf5efdcff, 0xfffbeeff, 0xffffffff, 0xddd6c1ff}, {0x93a1a1ff, 0x657b83ff, 0x073642ff, 0x002b36ff},
			{0x268bd2ff, 0x268bd2ff, 0x6c71c4ff, 0x859900ff, 0xb58900ff, 0xdc322fff, 0x2aa198ff, 0xd33682ff}}, .Both, nil, false, 0},
}

// The finishes by their names, for settings.
FINISH_NAMES := [Finish]string{.Flat = "flat", .Gradient = "gradient", .Glass = "glass", .Machined = "machined", .Edged = "edged"}

// The finish of a name of FINISH_NAMES (ASCII case ignored); Flat for any other.
finish_of :: proc(name: string) -> Finish {
	for n, f in FINISH_NAMES { if ascii.equal_fold(n, name) { return f } }
	return .Flat
}
