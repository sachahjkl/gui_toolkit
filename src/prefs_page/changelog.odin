package tk_prefs_page

// What's new, the same in every program: its CHANGELOG.md, readable in the program (a page of the settings, after the
// program's own), and after an update a message that stays until it is clicked, which opens that page. The changelog is
// written in English; a program may give translations, the one of the language in use is shown, else the English one.
//
//	app.changelog = {english = #load("../CHANGELOG.md", string)}
//	opts.changelog = &app.changelog                                                  the settings show the page
//	prefs_page.changelog_register(&prefs)                                            with the other preferences
//	prefs_page.changelog_after_update(&app.changelog, &prefs, APP_VERSION, &app.announcer, open_whats_new, app)   once, at start
//	prefs_page.changelog_destroy(&app.changelog)                                     at the end

import "core:fmt"
import "core:math"
import "core:strings"
import config "../config"
import "../draw"
import i18n "../i18n"
import lucide "../lucide"
import markdown "../markdown"
import "../ui"

// The page's category (Page.current; show(p, CHANGELOG_PAGE) opens it).
CHANGELOG_PAGE :: "whats_new"
// The version the program last started as (hidden): another one is an update, whose news are shown once.
SEEN_VERSION_PREF :: "general.seen_version"

Changelog :: struct {
	english:      string,             // the program's CHANGELOG.md (the program's: #load), the one shown by default
	translations: []Changelog_Text,   // the same in other languages (none today: the changelogs stay English)
	// the page's state: the text its releases were read from, the releases (owned), how many are shown
	read_from:    string,
	releases:     [dynamic]Changelog_Release,
	shown:        int,
}

// A version of the changelog, as the page shows it: its number, its day and time, its groups of changes.
Changelog_Release :: struct {
	version, stamp: string,                 // slices of the text read
	groups:         [dynamic]Changelog_Group,
}

// The changes of one type (Added, Fixed...) of a version: their Markdown list, laid out by gt:markdown.
Changelog_Group :: struct {
	type: string,
	list: string,         // owned: "- item" a line
	doc:  markdown.Doc,
}

// The versions the page shows at first, and how many more each "older versions" press adds.
CHANGELOG_SHOWN_FIRST :: 12

Changelog_Text :: struct { language, text: string }   // a language's tag ("fr") and its changelog

@(rodata) SEEN_DEFS := [?]config.Def{
	{name = SEEN_VERSION_PREF, description = "The version the program last started as: another one is an update, whose news show once.", kind = .String, default = {s = ""}, hidden = true},
}

// Registers the hidden preference of the version last seen (once, with the program's own).
changelog_register :: proc(prefs: ^config.Prefs) {
	if config.ref_of(prefs, SEEN_VERSION_PREF) == config.NO_REF { config.register(prefs, SEEN_DEFS[:]) }
}

// The changelog of the language in use: its translation when the program gives one, else the English one.
changelog_text :: proc(c: ^Changelog) -> string {
	if l := i18n.current(); l != nil {
		for t in c.translations { if t.language == l.tag && t.text != "" { return t.text } }
	}
	return c.english
}

// Once, at start (the window open, `announcer` ready): when the program starts as another version than the last time,
// a message that stays until it is clicked says so, and the click calls `open` (the program shows its settings at
// CHANGELOG_PAGE: show). The first start of all says nothing (no version before it). The version is kept at once: the
// next start says nothing more. True when the message was said.
changelog_after_update :: proc(c: ^Changelog, prefs: ^config.Prefs, version: string, announcer: ^ui.Announcer, open: proc(user: rawptr), user: rawptr) -> bool {
	changelog_register(prefs)
	seen := config.string_of(prefs, SEEN_VERSION_PREF)
	if seen == version { return false }
	_ = config.set_string(prefs, SEEN_VERSION_PREF, version)
	if seen == "" || c.english == "" { return false }
	ui.announce(announcer, .Good, fmt.tprintf(i18n.tr("Updated to %s"), version), i18n.tr("What's new: click to read it"), open, user, stays = true)
	return true
}

changelog_destroy :: proc(c: ^Changelog) {
	changelog_releases_free(c)
	delete(c.releases)
	c.releases = nil
}

@(private = "file")
changelog_releases_free :: proc(c: ^Changelog) {
	for &r in c.releases {
		for &g in r.groups { delete(g.list); markdown.doc_destroy(&g.doc) }
		delete(r.groups)
	}
	clear(&c.releases)
}

// The versions of a changelog's text ("## [1.2.0] - 2026-11-15 14:07", "### Added", "- item" and its following lines),
// newest first; [Unreleased] and the links at the end are left out. Read again when the text changes (a language).
@(private)
changelog_read :: proc(c: ^Changelog, text: string) {
	if raw_data(c.read_from) == raw_data(text) && len(c.read_from) == len(text) { return }
	changelog_releases_free(c)
	c.read_from = text
	r: ^Changelog_Release
	g: ^Changelog_Group
	list := strings.builder_make(context.temp_allocator)
	close_group :: proc(g: ^Changelog_Group, list: ^strings.Builder) {
		if g != nil { g.list = strings.clone(strings.trim_space(strings.to_string(list^))) }
		strings.builder_reset(list)
	}
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		switch {
		case strings.has_prefix(line, "## ["):
			close_group(g, &list)
			g = nil
			version, _, after := strings.partition(line[len("## ["):], "]")
			if strings.equal_fold(version, "unreleased") { r = nil; continue }
			append(&c.releases, Changelog_Release{version = version, stamp = strings.trim_space(strings.trim_prefix(after, " - "))})
			r = &c.releases[len(c.releases) - 1]
		case r != nil && strings.has_prefix(line, "### "):
			close_group(g, &list)
			append(&r.groups, Changelog_Group{type = strings.trim_space(line[len("### "):])})
			g = &r.groups[len(r.groups) - 1]
		case g != nil && strings.has_prefix(line, "["):   // (the versions' links at the end)
			close_group(g, &list)
			g, r = nil, nil
		case g != nil:
			strings.write_string(&list, line)
			strings.write_byte(&list, '\n')
		}
	}
	close_group(g, &list)
	if c.shown == 0 { c.shown = CHANGELOG_SHOWN_FIRST }
}

// The hue of a type of change: what comes green, what changed blue, what was fixed purple, what went red.
@(private = "file")
change_hue :: proc(type: string) -> ui.Hue {
	switch type {
	case "Added":      return .Green
	case "Changed":    return .Blue
	case "Fixed":      return .Purple
	case "Removed":    return .Red
	case "Deprecated": return .Yellow
	case "Security":   return .Rose
	}
	return .Cyan
}

@(private)
changelog_page_info :: proc(c: ^Changelog) -> Page_Info {
	return {category = CHANGELOG_PAGE, title = i18n.later("What's new"), icon = lucide.SCROLL_TEXT, build = changelog_build, user = c, tags = CHANGELOG_TAGS[:]}
}

@(private = "file", rodata) CHANGELOG_TAGS := [?]string{"changelog", "release notes", "news", "version", "update"}

// The page: a timeline, newest first. A rail on the left, a dot on it at each version (the newest lit in the accent);
// beside it each version's card: its number as a chip, its day and time, "Latest" on the newest, then its changes by
// type, each type a tile of its hue over its list.
@(private = "file")
changelog_build :: proc(user: rawptr, em: f32) {
	c := (^Changelog)(user)
	changelog_read(c, changelog_text(c))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###whats_new") {
		n := min(c.shown, len(c.releases))
		for i in 0 ..< n {
			changelog_release_build(c, &c.releases[i], i, i == n - 1 && n == len(c.releases), em)
		}
		if n < len(c.releases) {
			ui.spacer(ui.px(em * 0.6))
			ui.next({height = ui.px(ui.dense(em * 2))})
			older := min(len(c.releases) - n, CHANGELOG_SHOWN_FIRST)
			if ui.button("###whats_new_older", fmt.tprintf(i18n.tr("Show %d older versions"), older), o = {face = .Ghost}).clicked { c.shown += older }
		}
	}
}

@(private = "file")
Rail_Draw :: struct { line, dot: ui.Color, last, lit: bool, dot_y, gutter: f32 }

@(private = "file")
changelog_release_build :: proc(c: ^Changelog, r: ^Changelog_Release, i: int, last: bool, em: f32) {
	newest := i == 0
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(.Start, {}, fmt.tprintf("###release_%d", i)) {
		// the rail, drawn by the row in its left gutter (as tall as the card beside it): its line, not past the last dot;
		// the dot level with the version's chip
		row := ui.parent_box()
		d := ui.frame_new(Rail_Draw)
		d^ = {line = ui.color("border"), dot = newest ? ui.color("accent") : ui.color("weak text"), last = last, lit = newest, dot_y = math.round(em * 1.55), gutter = math.round(em * 2)}
		row.custom, row.custom_user = rail_draw, d
		ui.spacer(ui.px(d.gutter))
		// the card
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.tags("card") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y, radius = em * 0.6})
			card := ui.build_box({.Draw_Background, .Draw_Border, .Plate}, "###release_card")
			ui.push_parent(card)
			defer ui.pop_parent()
			ui.spacer(ui.px(em * 0.8))
			// its head: the version, its day and time, Latest
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.9))})
			if ui.row(.Center, {}, "###release_head") {
				ui.spacer(ui.px(em * 1))
				ui.next({font_size = em * 1.05})
				ui.tile("ver", r.version, newest ? ui.color("accent") : ui.color("weak text"))
				ui.spacer(ui.px(em * 0.7))
				if ui.tags("weak") { ui.label(fmt.tprintf("%s###stamp", r.stamp)) }
				if newest {
					ui.spacer(ui.px(em * 0.6))
					ui.tile("latest", i18n.tr("Latest"), ui.hue(.Green))
				}
			}
			// its changes, by type
			for &g, k in r.groups {
				ui.spacer(ui.px(em * 0.5))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if ui.row(.Start, {}, fmt.tprintf("###group_%d", k)) {
					ui.spacer(ui.px(em * 1))
					ui.next({width = ui.px(math.round(em * 6.5)), height = ui.children_sum(), axis = .Y})
					// (its type in English, as the changelog)
					if ui.column(id = "###type") { ui.tile("type", g.type, ui.hue(change_hue(g.type))) }
					ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
					if ui.column(id = "###list") { markdown.view(&g.doc, fmt.tprintf("list_%d_%d", i, k), g.list, {}) }
					ui.spacer(ui.px(em * 1))
				}
			}
			ui.spacer(ui.px(em * 0.9))
		}
	}
	if !last { ui.spacer(ui.px(math.round(em * 0.9))) }
}

@(private = "file")
rail_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Rail_Draw)(user)
	r := b.rect
	s := max(1, ui.scale())
	cx := math.round(r.min.x + d.gutter * 0.5)
	cy := r.min.y + d.dot_y
	w := math.round(2 * s)
	// (the line goes on into the gap under the row, to the next dot; the last one's ends at its dot)
	bottom := d.last ? cy : r.max.y + 40 * s
	draw.rect(dc, {{cx - w * 0.5, r.min.y}, {cx + w * 0.5, bottom}}, d.line)
	rad := math.round(5 * s)
	if d.lit { draw.rect(dc, {{cx - rad * 1.9, cy - rad * 1.9}, {cx + rad * 1.9, cy + rad * 1.9}}, d.dot * {1, 1, 1, 0.22}, rad * 1.9) }
	draw.rect(dc, {{cx - rad, cy - rad}, {cx + rad, cy + rad}}, d.dot, rad)
}
