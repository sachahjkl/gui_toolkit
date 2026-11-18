package ui

// What a theme says of its look beside its colours (src/md/features/theme-design.md): the radius of each role, the
// selection of each role and the text on it, the focus style, whether it moves, its font. Each part's zero value is the
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

Theme_Look :: struct {
	shape:      Maybe(Theme_Shape),                 // nil: SHAPE_DEFAULT
	selections: [Selection_Role]Theme_Selection,
	focus:      Theme_Focus,
	still:      bool,                               // its look has no motion (under Animations.System)
	font:       Theme_Font,
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
