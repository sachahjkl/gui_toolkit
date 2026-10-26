package ui

import "core:math"
import "core:unicode/utf8"
import "../draw"
import "../font"
import "../platform"

// An integrated title bar (platform.set_integrated_title): the app's own boxes are the title bar.
//
//   if ui.title_bar("###titlebar") {      // a row; its empty parts drag the window
//       ui.label("My app")                // (text that is not clickable drags too)
//       tabs, buttons...                  // clickable boxes stay the app's
//       ui.spacer(ui.fill())
//       ui.window_buttons()               // minimize, maximize / restore, close
//   }
//
// With Build_Params.window set, end_build tells the window where the title bar is (platform.set_chrome_regions): every
// box with .Window_Caption is a caption, the clickable boxes over it are holes, window_buttons are the caption buttons.
// The window procedure answers the system's hit tests from that, so dragging, double-click to maximize, Aero Snap,
// Snap Layouts over the maximize button (Windows 11), the system menu on a right click and the resize band along the
// top behave as with the system's title bar.

// Logical size of a caption button (Windows 10 / 11: 46 x 32 px at 100 %); its height is the title bar's.
CAPTION_BUTTON_WIDTH :: 46
CAPTION_GLYPH_SIZE   :: 10
CAPTION_CLOSE_HOT    :: 0xc42b1cff   // the system's close button under the pointer

// `if title_bar(id) { ... }`: a row (size from `next` / the style) whose empty parts drag the window.
@(deferred_none = pop_parent)
title_bar :: proc(id: string, flags: Box_Flags = {}) -> bool {
	set_next_axis(.X, .Center)
	b := build_box(flags + {.Window_Caption}, id)
	a11y_default(b, {role = .Title_Bar})
	push_parent(b)
	return true
}

// What screen readers call the caption buttons: minimize, maximize, restore, close (set_window_button_names
// translates them; the strings must outlive the builds).
@(private) window_button_names := [4]string{"Minimize", "Maximize", "Close", "Restore"}   // (Caption_Button's order, then restore)

set_window_button_names :: proc(minimize, maximize, restore, close: string) {
	window_button_names = {minimize, maximize, close, restore}
}

@(private)
Caption_Draw :: struct {
	button: platform.Caption_Button,
	maxed:  bool,
	active: bool,
	dark:   bool,
	under:  Color,   // what the button is drawn over (the title bar's background)
	glyph_font: font.Font_Id,
	dpi:    f32,
}

// The caption buttons (minimize, maximize or restore, close) in the current row, as tall as it, at the system's width
// and with its colours (the close button red under the pointer; dimmed glyphs while the window is inactive). Clicks
// act on Build_Params.window; the button clicked is returned too (`ok` false: none).
window_buttons :: proc() -> (clicked: platform.Caption_Button, ok: bool) {
	s := g
	dpi := s.zoom > 0 ? s.scale / s.zoom : s.scale   // the system's size: the UI zoom does not apply
	w := math.round(CAPTION_BUTTON_WIDTH * dpi)
	maxed := s.window != nil && platform.is_maximized(s.window)
	active := s.window == nil || s.window.active
	if !s.caption_font_tried {
		s.caption_font_tried = true
		// Windows 11's icon font, else Windows 10's; without either the glyphs are drawn as shapes
		id, found := font.load_system(s.fonts, "Segoe Fluent Icons")
		if !found { id, found = font.load_system(s.fonts, "Segoe MDL2 Assets") }
		s.caption_font = found ? id : 0
	}
	under := parent_box().bg
	if under.a < 0.5 { under = s.backdrop }
	dark := color("hover").r > 0.5   // the palette's hover tint is white on dark themes
	ids := [platform.Caption_Button]string{.Minimize = "###wb_min", .Maximize = "###wb_max", .Close = "###wb_close"}
	for b in platform.Caption_Button {
		next({width = px(w), height = pct(1)})
		box := build_box({.Clickable}, ids[b])
		box.cursor = .Arrow
		d := frame_new(Caption_Draw)
		d^ = {button = b, maxed = maxed, active = active, dark = dark, under = under, glyph_font = s.caption_font, dpi = dpi}
		box.custom, box.custom_user = caption_draw, d
		s.caption_keys[b] = box.key
		names := window_button_names
		a11y_default(box, {role = .Button, name = b == .Maximize && maxed ? names[3] : names[int(b)]})
		if signal(box).clicked {
			clicked, ok = b, true
			if s.window != nil {
				switch b {
				case .Minimize: platform.minimize(s.window)
				case .Maximize: platform.toggle_maximize(s.window)
				case .Close:    platform.request_close(s.window)
				}
			}
		}
	}
	return
}

@(private)
caption_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Caption_Draw)(user)
	hot := b.hot_t
	press := b.active_t
	// the system's fills (WinUI: subtle fill secondary / tertiary), mixed in sRGB over the title bar as it does
	glyph := d.dark ? draw.Color{1, 1, 1, 1} : draw.Color{0, 0, 0, 1}
	bg: Color
	if d.button == .Close && hot + press > 0.001 {
		red := draw.hex(CAPTION_CLOSE_HOT)
		bg = srgb_mix(d.under, red, math.min(hot + press, 1) * (1 - 0.1 * press))
		glyph = draw.mix(glyph, draw.Color{1, 1, 1, 1}, math.min(hot + press, 1))
		glyph.a = 1 - 0.3 * press
	} else {
		tint := d.dark ? draw.Color{1, 1, 1, 1} : draw.Color{0, 0, 0, 1}
		k := d.dark ? 0.0605 * hot * (1 - press) + 0.0419 * press : 0.0373 * hot * (1 - press) + 0.0241 * press
		bg = srgb_mix(d.under, tint, k)
		if !d.active && hot < 0.01 { glyph.a = 0.36 }
		else if press > 0.01 { glyph.a = 1 - 0.2 * press }
	}
	if hot + press > 0.001 { draw.rect(dc, b.rect, bg) }
	glyph_size := math.round(CAPTION_GLYPH_SIZE * d.dpi)
	c := draw.rect_center(b.rect)
	if d.glyph_font != 0 {
		cp: rune
		switch d.button {
		case .Minimize: cp = 0xE921
		case .Maximize: cp = d.maxed ? 0xE923 : 0xE922
		case .Close:    cp = 0xE8BB
		}
		gl := font.glyph(g.fonts, d.glyph_font, glyph_size, cp)
		if gl.size.x > 0 {
			buf, n := utf8.encode_rune(cp)
			pen := draw.Vec2{math.round(c.x - (gl.offset.x + gl.size.x * 0.5)), math.round(c.y - (gl.offset.y + gl.size.y * 0.5))}
			draw.text(dc, d.glyph_font, glyph_size, pen, glyph, string(buf[:n]))
			return
		}
	}
	caption_shape(dc, d, c, glyph_size, glyph)
}

// The glyphs drawn as shapes, when no icon font is installed: 1 px strokes on whole pixels.
@(private)
caption_shape :: proc(dc: ^draw.Context, d: ^Caption_Draw, c: Vec2, size: f32, color: Color) {
	t := max(1, math.round(d.dpi))
	half := math.round(size * 0.5)
	cx, cy := math.round(c.x), math.round(c.y)
	switch d.button {
	case .Minimize:
		draw.rect(dc, {{cx - half, cy}, {cx + half, cy + t}}, color)
	case .Maximize:
		if d.maxed {
			o := math.round(size * 0.2)
			back := Rect{{cx - half + o, cy - half}, {cx + half, cy + half - o}}
			front := Rect{{cx - half, cy - half + o}, {cx + half - o, cy + half}}
			draw.rect(dc, {back.min, {back.max.x, back.min.y + t}}, color)
			draw.rect(dc, {{back.max.x - t, back.min.y}, back.max}, color)
			draw.rect(dc, front, color, 0, t)
		} else {
			draw.rect(dc, {{cx - half, cy - half}, {cx + half, cy + half}}, color, 0, t)
		}
	case .Close:
		len := size * math.SQRT_TWO
		bar := Rect{{cx - len * 0.5, cy - t * 0.5}, {cx + len * 0.5, cy + t * 0.5}}
		for angle in ([2]f32{math.PI / 4, -math.PI / 4}) {
			draw.push_transform(dc, draw.affine_around(draw.affine_rotate(angle), {cx, cy}))
			draw.rect(dc, bar, color)
			draw.pop_transform(dc)
		}
	}
}

// `a` and `b` (linear) mixed by `t` as an sRGB blend would (how the system's caption buttons are specified).
@(private)
srgb_mix :: proc(a, b: Color, t: f32) -> Color {
	enc :: proc(c: f32) -> f32 { return c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1 / 2.4) - 0.055 }
	ea := [3]f32{enc(a.r), enc(a.g), enc(a.b)}
	eb := [3]f32{enc(b.r), enc(b.g), enc(b.b)}
	m := ea + (eb - ea) * t
	out := draw.srgb(m.x, m.y, m.z, 1)
	return out
}

// After layout: the title bar of this build, for the window's hit tests (end_build).
@(private)
chrome_collect :: proc(s: ^State) {
	c := &s.chrome
	platform.chrome_regions_clear(c)
	collect_captions(s.root, s.root.rect, c)
	if len(c.caption) > 0 {
		collect_holes(s, s.root, s.root.rect, c)
	}
	for b in platform.Caption_Button {
		k := s.caption_keys[b]
		if k == 0 { continue }
		if box := s.boxes[k]; box != nil && box.last_build == s.build_index {
			c.buttons[b] = platform.Region{box.rect.min, box.rect.max}
		}
	}
	// the open menus are the app's wherever they are: one that reaches the window's edge or corner takes the pointer
	// there, not the resize band (whose cursor showed over the menu, and whose moves never reached it)
	for lv in s.menus {
		if box := s.boxes[lv.panel]; box != nil && box.last_build == s.build_index {
			r := clip_rect(box.rect, s.root.rect)
			if r.max.x > r.min.x && r.max.y > r.min.y { append(&c.overlays, platform.Region{r.min, r.max}) }
		}
	}
	if s.window != nil && platform.is_integrated_title(s.window) { platform.set_chrome_regions(s.window, c) }
}

@(private)
clip_rect :: proc(a, b: Rect) -> Rect {
	return {{max(a.min.x, b.min.x), max(a.min.y, b.min.y)}, {min(a.max.x, b.max.x), min(a.max.y, b.max.y)}}
}

@(private)
collect_captions :: proc(b: ^Box, clip: Rect, c: ^platform.Chrome_Regions) {
	r := clip_rect(b.rect, clip)
	if r.max.x <= r.min.x || r.max.y <= r.min.y { return }
	if .Window_Caption in b.flags { append(&c.caption, platform.Region{r.min, r.max}) }
	inner := .Clip in b.flags ? r : clip
	for ch := b.first; ch != nil; ch = ch.next { collect_captions(ch, inner, c) }
}

// Every clickable box over a caption (wherever it is in the tree: a popup over the title bar too) is the app's.
@(private)
collect_holes :: proc(s: ^State, b: ^Box, clip: Rect, c: ^platform.Chrome_Regions) {
	r := clip_rect(b.rect, clip)
	if r.max.x <= r.min.x || r.max.y <= r.min.y { return }
	if .Clickable in b.flags && !is_caption_button_key(s, b.key) {
		for cap in c.caption {
			o := clip_rect(r, Rect{cap.min, cap.max})
			if o.max.x > o.min.x && o.max.y > o.min.y {
				// a leaning box keeps its shape unless a clip cut it (then its rect is what is left of it)
				if b.slant != {} && r == b.rect {
					append(&c.slanted, platform.Slanted_Region{b.rect.min, b.rect.max, b.slant})
				} else {
					append(&c.holes, platform.Region{r.min, r.max})
				}
				break
			}
		}
	}
	inner := .Clip in b.flags ? r : clip
	for ch := b.first; ch != nil; ch = ch.next { collect_holes(s, ch, inner, c) }
}

@(private)
is_caption_button_key :: proc(s: ^State, k: Key) -> bool {
	for ck in s.caption_keys { if ck == k { return true } }
	return false
}

// The title bar regions of the last build (what end_build gave the window): for tests and for apps that hit test
// themselves.
chrome_regions :: proc(s: ^State) -> ^platform.Chrome_Regions { return &s.chrome }
