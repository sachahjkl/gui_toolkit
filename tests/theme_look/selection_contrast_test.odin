package theme_look_test

// Words on a selection (src/md/features/selection-contrast.md), in every theme of ui.THEMES, dark and light: a selected
// row's title, its weak and faint words, a colour of its own and what a search lit in it read on the row's face at rest and
// under the pointer (WCAG AA, 4.5); off a selection, the lit letters read on their tint, the text on the page at 4.5 and the weak
// text at 3 (a hint beside the text, not the text).

import "core:fmt"
import "core:testing"
import "gt:draw"
import "gt:testkit/session"
import "gt:ui"

// AA for text; the weak text on the page is held to AA for large text and what is not text: it is never the only
// carrier of what a row says (the title is), and the theme's step below the text is its point.
@(private = "file") TEXT_RATIO :: 4.5
@(private = "file") WEAK_PAGE_RATIO :: 3.0

// The selections a row can wear: a list's (strong and calm), a menu's, a navigation's (the palette's, a sidebar's).
@(private = "file")
SELECTION_TAGS := [?][]string{{"list_row", "selected"}, {"list_row", "weak_selected"}, {"menu_item", "selected"}, {"menu_item", "nav", "selected"}}

@(private = "file")
Probe :: struct {
	lit: [len(SELECTION_TAGS)]ui.Rich_Style,   // a matched range's style in each selected row
	off: ui.Rich_Style,                        // and off a selection
}

@(private = "file")
probe_build :: proc(s: ^session.Session) {
	p := (^Probe)(s.user)
	for set, i in SELECTION_TAGS {
		for tg in set { ui.push_tags(tg) }
		ui.next({width = ui.px(500), height = ui.px(30), axis = .X})
		row := ui.build_box({.Clickable, .Draw_Hot_Effects, .Draw_Background, .Row, .Chosen}, fmt.tprintf("###sel%d", i))
		for _ in set { ui.pop_tags() }
		if ui.parent(row) {
			ui.label(fmt.tprintf("Title###title%d", i))
			if ui.tags("weak") {
				ui.label(fmt.tprintf("Detail###weak%d", i))
				ui.label_fuzzy(fmt.tprintf("example.org###fuzzy%d", i), {{0, 4}})
			}
			if ui.tags("faint") { ui.label(fmt.tprintf("Hint###faint%d", i)) }
			if ui.tags("bad") { ui.label(fmt.tprintf("Fault###bad%d", i)) }
			runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
			ui.match_runs("matched", {{0, 3}}, {}, &runs)
			p.lit[i] = runs[0].style
		}
	}
	runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
	ui.match_runs("matched", {{0, 3}}, {}, &runs)
	p.off = runs[0].style
}

// The weakest of `c` on each ground.
@(private = "file")
weakest :: proc(c: ui.Color, grounds: []ui.Color) -> f32 {
	w: f32 = 21
	for g in grounds { w = min(w, ui.contrast(c, g)) }
	return w
}

@(test)
every_theme_reads_on_its_selection :: proc(t: ^testing.T) {
	p: Probe
	s := session.start(t, {size = {600, 300}, user = &p, no_renderer = true, build = probe_build})
	for th in ui.THEMES {
		for light in ([]bool{false, true}) {
			if (light && th.versions == .Dark_Only) || (!light && th.versions == .Light_Only) { continue }
			name := fmt.tprintf("%s (%s)", th.name, light ? "light" : "dark")
			ui.use(s.state)
			ui.apply_palette(s.state.theme, ui.theme_palette(th, light), s.state.space)
			session.frames(s, 2)
			ui.use(s.state)
			page := ui.theme_lookup(s.state.theme, nil, "background")
			page.a = 1
			text := ui.theme_lookup(s.state.theme, nil, "text")
			weak := ui.theme_lookup(s.state.theme, nil, "weak text")
			testing.expectf(t, ui.contrast(text, page) >= TEXT_RATIO, "%s: the text on the page (%.2f)", name, ui.contrast(text, page))
			testing.expectf(t, ui.contrast(weak, page) >= WEAK_PAGE_RATIO, "%s: the weak text on the page (%.2f)", name, ui.contrast(weak, page))
			// off a selection: the lit letters on their tint over the page
			on_tint := ui.face_over(p.off.background, page, s.state.space)
			testing.expectf(t, ui.contrast(p.off.color, on_tint) >= TEXT_RATIO, "%s: the lit letters on their tint (%.2f)", name, ui.contrast(p.off.color, on_tint))
			for _, i in SELECTION_TAGS {
				row := session.get(s, fmt.tprintf("sel%d", i))
				// (the rows stand on the page: no frame is drawn, so the window's backdrop is not the theme's)
				ground := ui.face_over(row.target_bg, page, s.state.space)
				grounds := []ui.Color{ground, ui.state_fill(row, "hover_fill", ground)}
				// (the words stay on the side of the ground the theme's text is on, light words in a dark theme, unless the end
				// of that side does not read there: a bright accent's tint takes dark words, as the accent itself does)
				title := session.get(s, fmt.tprintf("title%d", i)).target_text
				light_text := ui.luminance(text) > ui.luminance(page)
				if (ui.luminance(title) > ui.luminance(ground)) != light_text {
					end := light_text ? ui.Color{1, 1, 1, 1} : ui.Color{0, 0, 0, 1}
					testing.expectf(t, weakest(end, grounds) < TEXT_RATIO, "%s, selection %v: its title crosses to the other side with room on its own", name, SELECTION_TAGS[i])
				}
				for part in ([]string{"title", "weak", "faint", "bad", "fuzzy"}) {
					b := session.get(s, fmt.tprintf("%s%d", part, i))
					w := weakest(b.target_text, grounds)
					testing.expectf(t, w >= TEXT_RATIO, "%s, selection %v: its %s (%.2f)", name, SELECTION_TAGS[i], part, w)
				}
				// label_fuzzy on a selection: underlined in the row's weak ink, never on match_bg
				if fz := session.get(s, fmt.tprintf("fuzzy%d", i)); fz != nil && fz.custom_user != nil {
					d := (^ui.Fuzzy_Draw)(fz.custom_user)
					testing.expectf(t, d.underline, "%s, selection %v: label_fuzzy underlined on a selection", name, SELECTION_TAGS[i])
				}
				// what the find bar found, on the page and on this selection: find_match_ink on the match's composite ground
				find_ink := ui.theme_lookup(s.state.theme, nil, "find_text")
				for name_bg in ([]string{"find_match background", "find_current background"}) {
					tint := ui.theme_lookup(s.state.theme, nil, name_bg)
					for g in ([]ui.Color{page, ground}) {
						over := ui.face_over(tint, g, s.state.space)
						ink := ui.find_match_ink(find_ink, over)
						c := ui.contrast(ink, over)
						testing.expectf(t, c >= TEXT_RATIO, "%s, selection %v: what the find found (%s, %.2f)", name, SELECTION_TAGS[i], name_bg, c)
					}
				}
				// a lit range on a selection: the row's ink (no colour of its own), no tint, and a mark that is no colour
				lit := p.lit[i]
				testing.expectf(t, lit.color.a == 0 && lit.background.a == 0 && lit.underline, "%s, selection %v: the lit letters underlined in the ink (%v)", name, SELECTION_TAGS[i], lit)
			}
		}
	}
}

// The inks of a selection, by their rule: the text readable on the ground and its state's, the weak text the text mixed
// toward the ground no further than the theme's own step allows, never under AA.
@(test)
selection_ink_keeps_the_themes_step :: proc(t: ^testing.T) {
	navy, white := draw.hex(0x000080ff), draw.hex(0xffffffff)
	ink := ui.selection_ink(navy, navy, white, 0.5)
	testing.expect_value(t, ink.text, white)
	r := ui.contrast(ink.weak, navy)
	testing.expectf(t, r >= TEXT_RATIO && r < ui.contrast(white, navy), "on a deep ground the weak words are quieter (%.2f)", r)
	testing.expectf(t, r >= ui.contrast(white, navy) * 0.5 - 0.05, "no quieter than the theme's step (%.2f)", r)
	// a ground with no room: the weak words are the text
	brown := draw.hex(0x83634eff)
	ink = ui.selection_ink(brown, brown, draw.hex(0xedededff), 0.5)
	testing.expectf(t, ui.contrast(ink.text, brown) >= TEXT_RATIO && ui.contrast(ink.weak, brown) >= TEXT_RATIO, "both read on a mid ground (%.2f, %.2f)", ui.contrast(ink.text, brown), ui.contrast(ink.weak, brown))
	// a grey that does not read is moved away from the ground, on it and on its face under the pointer (a list row's step)
	grey := draw.hex(0x8f8f8fff)
	lifted := ui.srgb_step(brown, white, 0.05)
	ink = ui.selection_ink(brown, lifted, grey, 1)
	testing.expectf(t, weakest(ink.text, {brown, lifted}) >= TEXT_RATIO, "made readable on both faces (%.2f)", weakest(ink.text, {brown, lifted}))
}

// A custom-drawn .Chosen row (without .Draw_Background, e.g. opencode native's sidebar rows under Old Head) still uses
// its theme selection fill as the ground, and ui.ink_for(row, fg) maps text, weak and custom colours without flattening
// them all to the title colour.
@(test)
custom_chosen_row_and_ink_for :: proc(t: ^testing.T) {
	Res :: struct { title, weak, custom, plain: ui.Color }
	res: Res
	s := session.start(t, {size = {400, 120}, no_renderer = true, user = &res, build = proc(s: ^session.Session) {
		r := (^Res)(s.user)
		ui.next({width = ui.px(300), height = ui.px(30)})
		plain := ui.build_box({}, "###plain")
		r.plain = ui.ink_for(plain, ui.color("weak text"))
		// custom-drawn .Chosen row with "selected" tag pushed, no .Draw_Background
		if ui.tags("list_row", "selected") {
			ui.next({width = ui.px(300), height = ui.px(30)})
			row := ui.build_box({.Clickable, .Chosen}, "###custom_sel")
			r.title = ui.ink_for(row, ui.color("text"))
			r.weak = ui.ink_for(row, ui.color("weak text"))
			r.custom = ui.ink_for(row, draw.hex(0xc02020ff))
		}
	}})
	ui.use(s.state)
	ui.apply_palette(s.state.theme, ui.palette_of("Old Head", light = true), s.state.space)
	session.frames(s, 2)
	ui.use(s.state)
	navy := draw.hex(0x000080ff)
	// Old Head's selection is navy (#000080) with white ink; without .Draw_Background it used to pick black against #c0c0c0
	testing.expectf(t, ui.contrast(res.title, navy) >= TEXT_RATIO && ui.luminance(res.title) > 0.8, "white ink on navy: %v (%.2f)", res.title, ui.contrast(res.title, navy))
	testing.expectf(t, ui.contrast(res.weak, navy) >= TEXT_RATIO && res.weak != res.title, "weak ink distinct and readable: %v (%.2f)", res.weak, ui.contrast(res.weak, navy))
	testing.expectf(t, ui.contrast(res.custom, navy) >= TEXT_RATIO && res.custom != res.title, "custom colour keeps hue and reads: %v (%.2f)", res.custom, ui.contrast(res.custom, navy))
	testing.expect_value(t, res.plain, ui.theme_lookup(s.state.theme, nil, "weak text"))
	testing.expect_value(t, ui.ink_for(nil, draw.hex(0x123456ff)), draw.hex(0x123456ff))
}
