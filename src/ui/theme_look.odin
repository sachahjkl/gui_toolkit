package ui

// What a theme says of its look beside its colours (src/md/features/theme-design.md): the radius of each role, the
// selection of each role and the text on it, the focus style, whether it moves, its font, its relief, its scroll bar's
// form, its caption. Each part's zero value is the
// toolkit's look from before themes carried one, so a theme, a program's palette and a test's palette say only what
// differs, and every theme that says nothing looks as it did.

import "../draw"

// What a corner's radius belongs to.
Shape_Role :: enum u8 {
	Control,        // a button, a field, a frame of fields, a dropdown, the find bar
	Row,            // a row's face: a list's, a menu's, the palette's, a dialog's choice
	Card,           // card, list_card
	Dialog,         // a dialog, an internal window
	Menu,           // a menu's panel
	Tooltip,
	Scroll_Thumb,   // the scroll bar's thumb (logical pixels)
	Scroll_Arrow,   // the scroll bar's arrow buttons (logical pixels)
}

// The radius of each role before the rounding setting (set_rounding): in ems of the font size, the scroll bar's in
// logical pixels.
Theme_Shape :: [Shape_Role]f32

// The radii every theme had before a theme could say its own: what a theme without a shape keeps.
SHAPE_DEFAULT :: Theme_Shape{.Control = 0.45, .Row = 0.45, .Card = 0.6, .Dialog = 0.8, .Menu = 0.5, .Tooltip = 0.4, .Scroll_Thumb = 3, .Scroll_Arrow = 2}

// What is selected: text, a list's row, a menu's item, a navigation's row (a sidebar's page, the palette's row), a
// list's row while the list does not have the keyboard.
Selection_Role :: enum u8 { Text, List, Menu, Nav, Weak }

Theme_Selection :: struct {
	fill: u32,   // 0xRRGGBBAA, sRGB; 0: the accent at the role's own alpha
	ink:  u32,   // the text on it; 0: the text as it is
}

// How the keyboard's focus is drawn around a box.
Focus_Style :: enum u8 {
	Ring_Glow,   // a solid ring and, in every finish but Flat, a glow around it
	Ring,        // the ring alone
	Dotted,      // a dotted rectangle (Windows' focus rectangle)
}

Theme_Focus :: struct {
	style: Focus_Style,
	width: f32,   // logical pixels; 0: FOCUS_RING_PX for a ring, 1 for the dots
	inset: f32,   // the dotted rectangle this far inside the box, logical pixels (a row's is on its face)
	color: u32,   // 0xRRGGBBAA, sRGB; 0: the theme's "focus border"
}

Theme_Font :: struct {
	family: string,   // the interface's family; "": the program's. The person's family wins (use_text_family)
	size:   f32,      // a factor of the program's font size; 0: 1
}

// How a scroll bar is drawn (scrollbar.odin); its parts and their places are the standard's in each form.
Scroll_Bar_Form :: enum u8 {
	Standard,   // the desktop's bar (src/md/features/scroll-bar.md): gradients, a lit thumb, a grip
	Keys,       // a flat track; the arrow buttons and the thumb keys of the relief (machined_bevel)
}

Theme_Scroll_Bar :: struct {
	form:  Scroll_Bar_Form,
	track: u32,   // Keys: the trough, 0xRRGGBBAA, sRGB; 0: the raised face half way to white
}

// How a caption button (window_buttons) is drawn.
Caption_Buttons :: enum u8 {
	System,   // Windows 10's: a fill under the pointer, the close button red, the icon font's glyphs
	Keys,     // a square key of the relief centred in the button's box, its glyph drawn as shapes
}

// The title bar the program draws (title_bar). Each colour 0xRRGGBBAA, sRGB.
Theme_Caption :: struct {
	active, inactive: [2]u32,   // the band, from its left to its right; both 0: no band; the second 0: the first
	ink:     u32,               // the text on the band; 0: the text as it is
	bold:    bool,              // the band's text bold
	buttons: Caption_Buttons,
}

Theme_Look :: struct {
	shape:      Maybe(Theme_Shape),                 // nil: SHAPE_DEFAULT
	selections: [Selection_Role]Theme_Selection,
	focus:      Theme_Focus,
	still:      bool,                               // its look has no motion (under Animations.System)
	font:       Theme_Font,
	relief:     Maybe(Relief),                      // nil: the program's finish's preset (relief_of); set: it wins
	scroll_bar: Theme_Scroll_Bar,
	caption:    Theme_Caption,
}

// The scroll bar and the caption of the theme shown; their zero values (the toolkit's) with no theme.
@(private)
scroll_bar_shown :: proc() -> Theme_Scroll_Bar {
	if s := current; s != nil && s.theme != nil { return s.theme.look.scroll_bar }
	return {}
}

@(private)
caption_shown :: proc() -> Theme_Caption {
	if s := current; s != nil && s.theme != nil { return s.theme.look.caption }
	return {}
}

// Whether a caption gives a band (Theme_Caption.active or .inactive).
@(private)
caption_has_band :: proc(c: Theme_Caption) -> bool { return c.active != {} || c.inactive != {} }

// The two stops of a caption's band, active or not, as colours (the second 0: the first; one side 0: the other's).
@(private)
caption_stops :: proc(c: Theme_Caption, active: bool) -> (left, right: Color) {
	stops := active ? c.active : c.inactive
	if stops == {} { stops = active ? c.inactive : c.active }
	if stops[1] == 0 { stops[1] = stops[0] }
	return draw.hex(stops[0]), draw.hex(stops[1])
}

// The band of the theme shown over `r`, active or not, for a program that draws its own title bar (a row of tabs with
// window_buttons) instead of title_bar. False: the theme gives no band, nothing is drawn.
caption_band :: proc(dc: ^draw.Context, r: Rect, active: bool) -> bool {
	c := caption_shown()
	if !caption_has_band(c) { return false }
	caption_band_fill(dc, r, c, active)
	return true
}

// The text on the band of the theme shown (nil: no band, or a band that keeps the text as it is).
caption_band_ink :: proc() -> Maybe(Color) {
	c := caption_shown()
	if !caption_has_band(c) || c.ink == 0 { return nil }
	return draw.hex(c.ink)
}

// Whether the text on the band of the theme shown is bold.
caption_band_bold :: proc() -> bool {
	c := caption_shown()
	return caption_has_band(c) && c.bold
}

// A caption's band over `r`: its two stops from left to right, interpolated in sRGB values as Windows drew them.
@(private)
caption_band_fill :: proc(dc: ^draw.Context, r: Rect, c: Theme_Caption, active: bool) {
	left, right := caption_stops(c, active)
	if left == right { draw.rect(dc, r, left); return }
	stops := [2]draw.Gradient_Stop{{color = left, pos = 0}, {color = right, pos = 1}}
	g := draw.Gradient{kind = .Linear, space = .Srgb, end = Vec2{r.max.x - r.min.x, 0}, stops = stops[:]}
	draw.gradient(dc, r, g, {})
}

// The radius of `role` in the theme shown, before the rounding setting: ems of the font size (a widget multiplies it
// by its font size), the scroll bar's roles in logical pixels.
shape_of :: proc(role: Shape_Role) -> f32 {
	shape := SHAPE_DEFAULT
	if s := current; s != nil && s.theme != nil { shape = s.theme.look.shape.? or_else SHAPE_DEFAULT }
	return shape[role]
}

// The dotted focus rectangle of Focus_Style.Dotted: dots `p` square every two dots along the inside of `r`, a dot in
// each corner. (A rect per dot: the draw list's dashes are a path's, and an antialiased dash of one pixel is a smear.)
@(private)
focus_dots :: proc(dc: ^draw.Context, r: Rect, p: f32, c: Color) {
	if r.max.x - r.min.x < 2 * p || r.max.y - r.min.y < 2 * p { return }
	step := 2 * p
	for x := r.min.x; x < r.max.x - p * 0.5; x += step {
		draw.rect(dc, {{x, r.min.y}, {x + p, r.min.y + p}}, c)
		draw.rect(dc, {{x, r.max.y - p}, {x + p, r.max.y}}, c)
	}
	for y := r.min.y + step; y < r.max.y - p * 1.5; y += step {
		draw.rect(dc, {{r.min.x, y}, {r.min.x + p, y + p}}, c)
		draw.rect(dc, {{r.max.x - p, y}, {r.max.x, y + p}}, c)
	}
}
