package prefs_page_test

// What's new in two layouts, chosen by the page's width (src/md/features/whats-new.md). In a narrow dialog (the page
// about 300 px) it stacks: no rail, each kind's pill over its bullets, the bullets at the card's inner width. In a wide
// one, the rail and the pill beside its bullets. Near the threshold the layout never flips from frame to frame.

import "core:fmt"
import "core:strings"
import "core:testing"
import config "gt:config"
import prefs_page "gt:prefs_page"
import "gt:testkit/session"

// A dialog of `width` over the settings at What's new, the sidebar 380 px as in the report, laid out. The sidebar is
// open (side-panels.md: a dialog under 380 px + BODY_MIN_EM folds it; the person opened it there, a manual choice that
// holds while the dialog stays narrow), so the page is about 300 px in the narrow dialogs.
@(private = "file")
whats_new_start :: proc(t: ^testing.T, app: ^Dialog_App, width: f32) -> ^session.Session {
	app.width = width
	app.prefs = config.prefs_make()
	d := prefs_page.STANDARD_DEFAULTS
	d.theme, d.app_name = "Midnight", "Sample"
	prefs_page.standard_register(&app.prefs, prefs_page.STANDARD_ALL, d, context.temp_allocator)
	app.changelog = {english = dialog_changelog()}
	app.page.current = strings.clone(prefs_page.CHANGELOG_PAGE)
	s := session.start(t, {size = {1500, 800}, user = app, build = dialog_build})
	session.frames(s, 1)
	_ = config.set_from_string(&app.prefs, prefs_page.SIDEBAR_PREF, fmt.tprintf("%v", 380 / session.BASE_FONT_SIZE), .User)
	if width < 380 + prefs_page.BODY_MIN_EM * session.BASE_FONT_SIZE {
		_ = config.set_from_string(&app.prefs, prefs_page.SIDEBAR_FOLD_PREF, "narrow", .User)
	}
	session.frames(s, 4)
	return s
}

@(private = "file")
whats_new_end :: proc(app: ^Dialog_App) {
	prefs_page.destroy(&app.page)
	prefs_page.changelog_destroy(&app.changelog)
	delete(app.changelog.english)
	config.prefs_destroy(&app.prefs)
}

// No box of the page past the body's right edge.
@(private = "file")
within_body :: proc(t: ^testing.T, s: ^session.Session, width: f32) {
	body := session.find(s, "prefs_scroll")
	if !testing.expect(t, body != nil, "the page's body") { return }
	past := make([dynamic]string, context.temp_allocator)
	past_edge(body, body.rect.max.x, &past)
	testing.expectf(t, len(past) == 0, "%.0f px: every box within the body: %v", width, past[:])
}

@(test)
whats_new_stacks_in_a_dialog_660_px_wide :: proc(t: ^testing.T) { whats_new_stacked(t, 660, "whatsnew-stacked-660.png") }

@(test)
whats_new_stacks_in_a_dialog_700_px_wide :: proc(t: ^testing.T) { whats_new_stacked(t, 700, "whatsnew-stacked-700.png") }

@(private = "file")
whats_new_stacked :: proc(t: ^testing.T, width: f32, png: string) {
	app: Dialog_App
	s := whats_new_start(t, &app, width)
	defer whats_new_end(&app)
	session.save_png(s, png)
	column := session.find(s, "whats_new")
	card := session.find(s, "release_card")
	if !testing.expect(t, column != nil && card != nil, "the page and its first card") { return }
	// no rail: the card stands at the page's left edge, the row draws nothing of its own
	testing.expectf(t, card.rect.min.x - column.rect.min.x < 1, "%.0f px: no rail (the card %.0f px in)", width, card.rect.min.x - column.rect.min.x)
	testing.expect(t, card.parent != nil && card.parent.custom == nil, "the release row draws no rail")
	inner := card.rect.max.x - card.rect.min.x
	groups := 0
	for k in 0 ..< 4 {
		group := session.find(s, fmt.tprintf("group_%d", k), 0, card)
		if group == nil { continue }
		groups += 1
		pill := session.find(s, "type", 0, group)
		list := session.find(s, "list", 0, group)
		if !testing.expectf(t, pill != nil && list != nil, "group %d: its pill and its bullets", k) { continue }
		testing.expectf(t, pill.rect.max.y <= list.rect.min.y + 0.5, "group %d: the pill (bottom %.0f) over its bullets (top %.0f)", k, pill.rect.max.y, list.rect.min.y)
		lw := list.rect.max.x - list.rect.min.x
		testing.expectf(t, lw >= 0.85 * inner, "group %d: the bullets %.0f px of the card's %.0f", k, lw, inner)
	}
	testing.expect_value(t, groups, 4)
	within_body(t, s, width)
}

@(test)
whats_new_is_wide_in_a_dialog_1400_px_wide :: proc(t: ^testing.T) {
	app: Dialog_App
	s := whats_new_start(t, &app, 1400)
	defer whats_new_end(&app)
	session.save_png(s, "whatsnew-wide-1400.png")
	column := session.find(s, "whats_new")
	card := session.find(s, "release_card")
	if !testing.expect(t, column != nil && card != nil && card.parent != nil, "the page and its first card") { return }
	testing.expect(t, card.parent.custom != nil, "the release row draws the rail")
	testing.expectf(t, card.rect.min.x - column.rect.min.x >= 2 * session.BASE_FONT_SIZE - 1, "the rail's gutter before the card (%.0f px)", card.rect.min.x - column.rect.min.x)
	testing.expect(t, session.find(s, "group_stack") == nil, "no group stacked")
	for k in 0 ..< 4 {
		group := session.find(s, fmt.tprintf("group_%d", k), 0, card)
		if !testing.expectf(t, group != nil, "group %d shown", k) { continue }
		pill := session.find(s, "type", 0, group)
		list := session.find(s, "list", 0, group)
		if !testing.expectf(t, pill != nil && list != nil, "group %d: its pill and its bullets", k) { continue }
		testing.expectf(t, pill.rect.max.x <= list.rect.min.x + 0.5, "group %d: the pill (right %.0f) left of its bullets (left %.0f)", k, pill.rect.max.x, list.rect.min.x)
		testing.expectf(t, pill.rect.min.y < list.rect.max.y && list.rect.min.y < pill.rect.max.y, "group %d: the pill beside its bullets, on their first line", k)
	}
	within_body(t, s, 1400)
}

// Dialogs across the threshold, 5 px at a time: at each width the layout settles in one frame and stays (the scroll
// bar's coming and going never flips it), and every box stays within the body.
@(test)
whats_new_never_flips_near_the_threshold :: proc(t: ^testing.T) {
	app: Dialog_App
	s := whats_new_start(t, &app, 860)
	defer whats_new_end(&app)
	saw_stacked, saw_wide := false, false
	for width := f32(860); width <= 960; width += 5 {
		app.width = width
		session.frames(s, 2)
		stacked := session.find(s, "group_stack") != nil
		if stacked { saw_stacked = true } else { saw_wide = true }
		for _ in 0 ..< 3 {
			session.frames(s, 1)
			testing.expectf(t, (session.find(s, "group_stack") != nil) == stacked, "%.0f px: the layout stays %s", width, stacked ? "stacked" : "wide")
		}
		within_body(t, s, width)
	}
	testing.expect(t, saw_stacked && saw_wide, "the sweep crosses the threshold")
	// and back down: stacked again
	for width := f32(960); width >= 860; width -= 5 {
		app.width = width
		session.frames(s, 2)
	}
	testing.expect(t, session.find(s, "group_stack") != nil, "a narrow page stacks again")
}
