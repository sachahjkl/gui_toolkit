package scenarios_test

// Themes (ui themes.odin): theme_show applies a choice once and again only when what it shows changes (the choice, the
// theme's colours, the blend space, the glow); theme_recolor moves a program's colours to another theme; themes_read
// reads a user's file; the names of the modes and of the finishes. The machined finish by its pixels: its halos follow
// Theme.glow, its well is sunken, and a light palette or another finish draws it flat.

import "core:testing"
import "../../src/draw"
import "../../src/testkit/session"
import "../../src/ui"

// The colours of a theme's palette entries, to compare two themes.
@(private = "file")
entry_colors :: proc(t: ^ui.Theme) -> []ui.Color {
	out := make([]ui.Color, len(t.patterns), context.temp_allocator)
	for p, i in t.patterns { out[i] = p.color }
	return out
}

@(private = "file")
same_colors :: proc(a, b: []ui.Color) -> bool {
	if len(a) != len(b) { return false }
	for c, i in a { if c != b[i] { return false } }
	return true
}

// What apply_palette makes of a palette in a space, on a theme of its own.
@(private = "file")
applied :: proc(p: ui.Palette, space: draw.Blend_Space) -> []ui.Color {
	th: ui.Theme
	defer ui.theme_destroy(&th)
	ui.apply_palette(&th, p, space)
	return entry_colors(&th)
}

@(test)
theme_show_applies_once_and_again_on_a_change :: proc(t: ^testing.T) {
	th: ui.Theme
	defer ui.theme_destroy(&th)
	shown: ui.Theme_Shown
	choice := ui.Theme_Choice{name = "nord", mode = .Dark, finish = .Flat}
	testing.expect(t, ui.theme_show(&th, ui.THEMES[:], choice, &shown, .Linear), "the first call applies")
	testing.expect_value(t, shown.def.name, "Nord")
	testing.expect(t, !shown.light, "the dark version")
	nord, _, _ := ui.theme_find(ui.THEMES[:], "Nord")
	testing.expect(t, same_colors(entry_colors(&th), applied(ui.theme_palette(nord, false), .Linear)), "the palette of Nord's dark version")
	serial := th.serial
	testing.expect(t, !ui.theme_show(&th, ui.THEMES[:], choice, &shown, .Linear), "the same choice: nothing to apply")
	testing.expect_value(t, th.serial, serial)

	choice.mode = .Light
	testing.expect(t, ui.theme_show(&th, ui.THEMES[:], choice, &shown, .Linear), "another mode applies")
	testing.expect(t, shown.light, "the light version")
	testing.expect(t, th.serial != serial, "and bumps the serial")

	// a name that is not there: the list's first; an empty list: nothing
	testing.expect(t, ui.theme_show(&th, ui.THEMES[:], {name = "no such theme", mode = .Dark}, &shown, .Linear))
	testing.expect_value(t, shown.def.name, ui.THEMES[0].name)
	testing.expect(t, !ui.theme_show(&th, nil, choice, &shown, .Linear), "no theme to show")
}

// A program that draws in sRGB gets the alphas of its translucent entries for sRGB, and a change of space applies again.
@(test)
theme_show_applies_for_the_blend_space :: proc(t: ^testing.T) {
	th: ui.Theme
	defer ui.theme_destroy(&th)
	shown: ui.Theme_Shown
	choice := ui.Theme_Choice{name = "Midnight", mode = .Dark}
	mid, _, _ := ui.theme_find(ui.THEMES[:], "Midnight")
	p := ui.theme_palette(mid, false)
	linear, srgb := applied(p, .Linear), applied(p, .Srgb)
	testing.expect(t, !same_colors(linear, srgb), "the two spaces give translucent entries other alphas")

	testing.expect(t, ui.theme_show(&th, ui.THEMES[:], choice, &shown, .Srgb))
	testing.expect(t, same_colors(entry_colors(&th), srgb), "the entries of the sRGB space")
	serial := th.serial
	testing.expect(t, ui.theme_show(&th, ui.THEMES[:], choice, &shown, .Linear), "another space applies")
	testing.expect(t, same_colors(entry_colors(&th), linear), "the entries of the linear space")
	testing.expect(t, th.serial != serial, "and bumps the serial")
}

// The user edits the themes file and the program reads it again: the same name, other colours, and they show.
@(test)
theme_show_applies_a_definition_read_again :: proc(t: ^testing.T) {
	th: ui.Theme
	defer ui.theme_destroy(&th)
	shown: ui.Theme_Shown
	choice := ui.Theme_Choice{name = "Mine", mode = .Dark}
	first := ui.themes_read("[Mine]\nbg0 = #102030\n", ui.THEMES[:], ui.THEMES[0])
	defer ui.themes_destroy(&first)
	testing.expect(t, ui.theme_show(&th, first[:], choice, &shown, .Linear))
	testing.expect_value(t, ui.theme_lookup(&th, {}, "background"), draw.hex(0x102030ff))
	again := ui.themes_read("[Mine]\nbg0 = #405060\n", ui.THEMES[:], ui.THEMES[0])
	defer ui.themes_destroy(&again)
	testing.expect(t, ui.theme_show(&th, again[:], choice, &shown, .Linear), "the same name with other colours applies")
	testing.expect_value(t, ui.theme_lookup(&th, {}, "background"), draw.hex(0x405060ff))
	testing.expect(t, !ui.theme_show(&th, again[:], choice, &shown, .Linear), "and once")
}

// The glow is part of the look: a change of it alone applies and bumps the serial.
@(test)
theme_show_applies_the_glow :: proc(t: ^testing.T) {
	th: ui.Theme
	defer ui.theme_destroy(&th)
	shown: ui.Theme_Shown
	choice := ui.Theme_Choice{name = "Midnight", mode = .Dark, finish = .Machined}
	testing.expect(t, ui.theme_show(&th, ui.THEMES[:], choice, &shown, .Linear))
	testing.expect_value(t, th.glow, 0)
	serial := th.serial
	choice.glow = 1
	testing.expect(t, ui.theme_show(&th, ui.THEMES[:], choice, &shown, .Linear), "another glow applies")
	testing.expect_value(t, th.glow, 1)
	testing.expect(t, th.serial != serial, "and bumps the serial")
}

@(test)
modes_and_finishes_by_their_names :: proc(t: ^testing.T) {
	for name, m in ui.THEME_MODE_NAMES { testing.expect_value(t, ui.theme_mode_of(name), m) }
	testing.expect_value(t, ui.theme_mode_of("LIGHT"), ui.Theme_Mode.Light)
	testing.expect_value(t, ui.theme_mode_of("sepia"), ui.Theme_Mode.System)
	for name, f in ui.FINISH_NAMES { testing.expect_value(t, ui.finish_of(name), f) }
	testing.expect_value(t, ui.finish_of("Machined"), ui.Finish.Machined)
	testing.expect_value(t, ui.finish_of(""), ui.Finish.Flat)
}

@(test)
themes_read_reads_a_users_file :: proc(t: ^testing.T) {
	text := `accent = #ff0000
# a comment
; another
[Plain]
accent = #e5c07b
bg0=00ff00
red = #12345
yellow = #zzzzzz
nothing = #abcdef

[ Derived ]
from = nord
light.accent = #b58900
dark.text = #eeeeee
[]
`
	list := ui.themes_read(text, ui.THEMES[:], ui.THEMES[0])
	defer ui.themes_destroy(&list)
	testing.expect_value(t, len(list), 2)
	if len(list) != 2 { return }
	plain, derived := list[0], list[1]
	testing.expect_value(t, plain.name, "Plain")
	testing.expect_value(t, plain.versions, ui.Theme_Versions.Dark_Only)
	testing.expect_value(t, plain.dark.hues[0], 0xe5c07bff)
	testing.expect_value(t, plain.dark.steps[1], 0x00ff00ff)
	testing.expect_value(t, plain.dark.hues[5], ui.THEMES[0].dark.hues[5])   // (a short hex is skipped)
	testing.expect_value(t, plain.dark.hues[4], ui.THEMES[0].dark.hues[4])   // (and one that is not hex)
	testing.expect_value(t, plain.dark.texts, ui.THEMES[0].dark.texts)

	nord, _, _ := ui.theme_find(ui.THEMES[:], "Nord")
	testing.expect_value(t, derived.name, "Derived")
	testing.expect_value(t, derived.versions, ui.Theme_Versions.Both)
	testing.expect_value(t, derived.light.hues[0], 0xb58900ff)
	testing.expect_value(t, derived.light.steps, nord.light.steps)
	testing.expect_value(t, derived.dark.hues[0], nord.dark.hues[0])
	testing.expect_value(t, derived.dark.texts[2], 0xeeeeeeff)
}

@(test)
theme_recolor_moves_a_programs_colours :: proc(t: ^testing.T) {
	// (Graphite's greys are neutral: a tinted grey is a mix of a hue, see THEME_GREY_SPREAD)
	ref_def, _, _ := ui.theme_find(ui.THEMES[:], "Graphite")
	nord, _, _ := ui.theme_find(ui.THEMES[:], "Nord")
	mine := ref_def.dark
	ref := ui.theme_reference(mine)
	// a colour of the reference goes to the same colour of the other theme, its alpha kept
	testing.expect_value(t, ui.theme_recolor(&ref, nord.dark, mine.hues[0]), nord.dark.hues[0])
	testing.expect_value(t, ui.theme_recolor(&ref, nord.dark, mine.hues[5] & 0xffffff00 | 0x80), nord.dark.hues[5] & 0xffffff00 | 0x80)
	// a grey to the same place on the other's greys: the text to the text, the page to the page
	testing.expect(t, near_u32(ui.theme_recolor(&ref, nord.dark, mine.texts[2]), nord.dark.texts[2], 1), "the text to the text")
	testing.expect(t, near_u32(ui.theme_recolor(&ref, nord.light, mine.steps[1]), nord.light.steps[1], 1), "the page to the light version's page")
	// to its own theme, a colour stays
	testing.expect(t, near_u32(ui.theme_recolor(&ref, mine, mine.hues[3]), mine.hues[3], 2), "to itself, the same")
}

@(private = "file")
near_u32 :: proc(a, b: u32, d: int) -> bool {
	for k in u32(0) ..< 4 {
		x, y := int(a >> (k * 8) & 0xff), int(b >> (k * 8) & 0xff)
		if abs(x - y) > d { return false }
	}
	return true
}

////////////////////////////////
// The machined finish

@(private = "file") MACHINED_WINDOW :: [2]int{200, 120}
// The well: where it is and what reaches out of it (ui.MACHINED_OVERFLOW_PX).
@(private = "file") WELL :: ui.Rect{{60, 40}, {140, 80}}

@(private = "file")
well_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	ui.machined_well(dc, WELL, 6, {0.1, 0.1, 0.12, 1}, 1, {1, 0, 0, 1})
}

@(private = "file")
well_session :: proc(t: ^testing.T, finish: ui.Finish, light := false) -> ^session.Session {
	p := ui.palette_of("Midnight", light)
	p.finish = finish
	return session.start(t, {size = MACHINED_WINDOW, palette = p, build = proc(s: ^session.Session) {
		ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(200), height = ui.px(120)})
		b := ui.build_box({}, "###well")
		b.custom = well_draw
	}})
}

// What reaches out of the well: the band around it.
@(private = "file")
halo_changes :: proc(a, b: session.Image) -> (n: int) {
	for y in int(WELL.min.y) - ui.MACHINED_OVERFLOW_PX ..< int(WELL.max.y) + ui.MACHINED_OVERFLOW_PX {
		for x in int(WELL.min.x) - ui.MACHINED_OVERFLOW_PX ..< int(WELL.max.x) + ui.MACHINED_OVERFLOW_PX {
			inside := x >= int(WELL.min.x) && x < int(WELL.max.x) && y >= int(WELL.min.y) && y < int(WELL.max.y)
			if !inside && !session.near(session.pixel(a, x, y), session.pixel(b, x, y), 1) { n += 1 }
		}
	}
	return
}

@(test)
machined_halos_follow_the_glow :: proc(t: ^testing.T) {
	s := well_session(t, .Machined)
	s.own.theme.glow = 0
	session.frame(s)
	dark := session.capture(s)
	s.own.theme.glow = 1
	session.frame(s)
	lit := session.capture(s)
	testing.expect(t, halo_changes(dark, lit) > 0, "a focused well has a halo with the glow, none without")
}

@(test)
other_finishes_have_no_halo :: proc(t: ^testing.T) {
	s := well_session(t, .Flat)
	s.own.theme.glow = 0
	session.frame(s)
	a := session.capture(s)
	s.own.theme.glow = 1
	session.frame(s)
	b := session.capture(s)
	testing.expect_value(t, halo_changes(a, b), 0)
}

// The machined well is sunken: its inner shadow darkens its top, which the flat one draws in its plain colour.
@(test)
a_machined_well_is_sunken :: proc(t: ^testing.T) {
	flat := session.capture(well_session(t, .Flat))
	machined := session.capture(well_session(t, .Machined))
	x, y := int(WELL.min.x + WELL.max.x) / 2, int(WELL.min.y) + 3
	f, m := session.pixel(flat, x, y), session.pixel(machined, x, y)
	testing.expectf(t, int(m.r) + int(m.g) + int(m.b) < int(f.r) + int(f.g) + int(f.b), "the top of the well, flat %v, machined %v", f, m)
}

// The reliefs are made for the dark: a light palette is drawn flat.
@(test)
a_light_palette_is_drawn_flat :: proc(t: ^testing.T) {
	th: ui.Theme
	defer ui.theme_destroy(&th)
	p := ui.palette_of("Midnight", light = true)
	p.finish = .Machined
	ui.apply_palette(&th, p)
	testing.expect_value(t, th.finish, ui.Finish.Flat)
	p = ui.palette_of("Midnight")
	p.finish = .Machined
	ui.apply_palette(&th, p)
	testing.expect_value(t, th.finish, ui.Finish.Machined)
}

// A machined rule between two panes keeps its two lines, the dark one and the lit one under it: both are inside its box,
// which the pane under it, drawn after, does not cover.
@(test)
a_machined_rule_keeps_its_lit_line :: proc(t: ^testing.T) {
	p := ui.palette_of("Midnight", false)
	p.finish = .Machined
	s := session.start(t, {size = MACHINED_WINDOW, palette = p, build = proc(s: ^session.Session) {
		ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(200), height = ui.px(120), axis = .Y})
		if ui.column(id = "###panes") {
			ui.next({width = ui.fill(), height = ui.px(40), bg = {0.1, 0.1, 0.1, 1}})
			ui.build_box({.Draw_Background}, "###above")
			ui.hline(ui.fill())
			ui.next({width = ui.fill(), height = ui.fill(), bg = {0.1, 0.1, 0.1, 1}})
			ui.build_box({.Draw_Background}, "###below")
		}
	}})
	below := session.get(s, "below")
	testing.expect_value(t, int(below.rect.min.y), 42)   // (the rule takes two lines)
	img := session.capture(s)
	dark, lit, pane := session.pixel(img, 100, 40), session.pixel(img, 100, 41), session.pixel(img, 100, 50)
	testing.expectf(t, int(lit.r) > int(dark.r), "two lines: the dark %v, the lit %v", dark, lit)
	testing.expectf(t, !session.near(lit, pane, 2), "the lit line %v is not under the pane %v", lit, pane)
}

// The intents' buttons are soft: a deep fill of their hue on a dark page, words of that hue on it that read (AA).
@(test)
an_intent_button_is_a_soft_pair_of_its_hue :: proc(t: ^testing.T) {
	th: ui.Theme
	defer ui.theme_destroy(&th)
	shown: ui.Theme_Shown
	testing.expect(t, ui.theme_show(&th, ui.THEMES[:], {name = ui.THEMES[0].name, mode = .Dark}, &shown, .Linear))
	page := ui.theme_lookup(&th, {}, "background")
	for pair in ([][2]string{{"warn_button", "warn"}, {"danger_button", "bad"}, {"success_button", "good"}}) {
		fill := ui.theme_lookup(&th, {pair[0]}, "background")
		words := ui.theme_lookup(&th, {pair[0]}, "text")
		hue := ui.theme_lookup(&th, {pair[1]}, "text")
		testing.expectf(t, ui.luminance(fill) < ui.luminance(hue) && ui.luminance(fill) <= ui.luminance(page) + 0.05, "%s: a deep fill of its hue", pair[0])
		testing.expectf(t, ui.contrast(words, fill) >= 4.5, "%s: its words read on it (%.2f)", pair[0], ui.contrast(words, fill))
		testing.expectf(t, abs(ui.to_oklch(words)[2] - ui.to_oklch(hue)[2]) < 12, "%s: its words are of its hue", pair[0])
	}
}
