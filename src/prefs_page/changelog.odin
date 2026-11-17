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
import "../ascii"
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
	// the page's state: the text its releases were read from, the releases (owned)
	read_from:    string,
	releases:     [dynamic]Changelog_Release,
	// the search and the kinds hidden; what they keep, worked out when one of them or the text changes (never per frame)
	search:       ui.Line_Edit,
	kinds_off:    bit_set[Change_Kind],
	shown:        [dynamic]Changelog_Shown,
	shown_for:    string,                   // (owned) the search the list was made for, folded
	shown_kinds:  bit_set[Change_Kind],
	shown_from:   string,                   // the text it was made from
	kinds_in:     bit_set[Change_Kind],     // the kinds the changelog has: a toggle each
}

// A version of the changelog, as the page shows it: its number, its day and time, its groups of changes.
Changelog_Release :: struct {
	version, stamp: string,                 // slices of the text read
	groups:         [dynamic]Changelog_Group,
}

// The changes of one kind (Added, Fixed...) of a version: their Markdown list, laid out by gt:markdown.
Changelog_Group :: struct {
	type:   string,
	kind:   Change_Kind,
	list:   string,         // owned: "- item" a line
	folded: string,         // owned: the list in ASCII lower case, what the search reads
	doc:    markdown.Doc,
}

// The kinds of change of Keep a Changelog; Other for a heading it does not name.
Change_Kind :: enum u8 { Added, Changed, Deprecated, Removed, Fixed, Security, Other }

// A version the search and the kinds keep, and which of its groups.
Changelog_Shown :: struct {
	release: int,
	groups:  u64,   // bit k: its group k shows
}

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
	ui.line_edit_destroy(&c.search)
	delete(c.shown)
	delete(c.shown_for)
	c.shown, c.shown_for = nil, ""
}

@(private = "file")
changelog_releases_free :: proc(c: ^Changelog) {
	for &r in c.releases {
		for &g in r.groups { delete(g.list); delete(g.folded); markdown.doc_destroy(&g.doc) }
		delete(r.groups)
	}
	clear(&c.releases)
	c.shown_from = ""   // (the list goes with them)
}

@(private = "file")
change_kind :: proc(type: string) -> Change_Kind {
	switch type {
	case "Added":      return .Added
	case "Changed":    return .Changed
	case "Deprecated": return .Deprecated
	case "Removed":    return .Removed
	case "Fixed":      return .Fixed
	case "Security":   return .Security
	}
	return .Other
}

// The versions and groups the search and the kinds keep, made again when one of them or the text changed. A version
// whose number or day holds the search shows its groups of the kinds kept; else only those whose text holds it.
@(private)
changelog_filter :: proc(c: ^Changelog) {
	query := strings.trim_space(ui.line_edit_string(&c.search))
	folded := ascii.lower(query)
	if raw_data(c.shown_from) == raw_data(c.read_from) && len(c.shown_from) == len(c.read_from) && c.shown_kinds == c.kinds_off && c.shown_for == folded { return }
	delete(c.shown_for)
	c.shown_for, c.shown_kinds, c.shown_from = strings.clone(folded), c.kinds_off, c.read_from
	clear(&c.shown)
	for &r, i in c.releases {
		whole := folded == "" || ascii.contains_fold(r.version, folded) || ascii.contains_fold(r.stamp, folded)
		groups: u64
		for &g, k in r.groups {
			if k >= 64 || g.kind in c.kinds_off { continue }
			if whole || strings.contains(g.folded, folded) { groups |= 1 << u64(k) }
		}
		if groups != 0 { append(&c.shown, Changelog_Shown{release = i, groups = groups}) }
	}
}

// The versions of a changelog's text ("## [1.2.0] - 2026-11-15 14:07", "### Added", "- item" and its following lines),
// newest first; [Unreleased] and the links at the end are left out. Read again when the text changes (a language).
@(private)
changelog_read :: proc(c: ^Changelog, text: string) {
	if raw_data(c.read_from) == raw_data(text) && len(c.read_from) == len(text) { return }
	changelog_releases_free(c)
	c.read_from = text
	c.kinds_in = {}
	r: ^Changelog_Release
	g: ^Changelog_Group
	list := strings.builder_make(context.temp_allocator)
	close_group :: proc(g: ^Changelog_Group, list: ^strings.Builder) {
		if g != nil {
			g.list = strings.clone(strings.trim_space(strings.to_string(list^)))
			g.folded = ascii.lower(g.list, context.allocator)
		}
		strings.builder_reset(list)
	}
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		switch {
		case strings.has_prefix(line, "## ["):
			close_group(g, &list)
			g = nil
			version, _, after := strings.partition(line[len("## ["):], "]")
			if ascii.equal_fold(version, "unreleased") { r = nil; continue }
			append(&c.releases, Changelog_Release{version = version, stamp = strings.trim_space(strings.trim_prefix(after, " - "))})
			r = &c.releases[len(c.releases) - 1]
		case r != nil && strings.has_prefix(line, "### "):
			close_group(g, &list)
			type := strings.trim_space(line[len("### "):])
			append(&r.groups, Changelog_Group{type = type, kind = change_kind(type)})
			g = &r.groups[len(r.groups) - 1]
			c.kinds_in += {g.kind}
		case g != nil && strings.has_prefix(line, "["):   // (the versions' links at the end)
			close_group(g, &list)
			g, r = nil, nil
		case g != nil:
			strings.write_string(&list, line)
			strings.write_byte(&list, '\n')
		}
	}
	close_group(g, &list)
}

// The icon of a type of change.
@(private = "file")
change_icon :: proc(type: string) -> string {
	switch type {
	case "Added":      return lucide.SPARKLES
	case "Changed":    return lucide.REFRESH_CW
	case "Fixed":      return lucide.WRENCH
	case "Removed":    return lucide.CIRCLE_MINUS
	case "Deprecated": return lucide.ARCHIVE
	case "Security":   return lucide.SHIELD_CHECK
	}
	return lucide.TAG
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

// The page: a search and a toggle per kind of change over a timeline, newest first. A rail on the left, a dot on it at
// each version (the newest lit in the accent); beside it each version's card: its number as a pill, its day and time,
// "Latest" on the newest, then its changes by kind, each under a pill of its hue. Every version is there: only those
// near the view are built (a lazy column), the others stand as their height.
@(private = "file")
changelog_build :: proc(user: rawptr, em: f32) {
	c := (^Changelog)(user)
	changelog_read(c, changelog_text(c))
	changelog_filter(c)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###whats_new") {
		changelog_tools_build(c, em)
		ui.space(ui.ITEM_GAP)
		if len(c.shown) == 0 {
			if ui.tags("weak") { ui.label(fmt.tprintf("%s###whats_new_none", i18n.tr("No version holds that."))) }
			return
		}
		lz := ui.lazy_begin()
		for s, n in c.shown {
			r := &c.releases[s.release]
			if ui.lazy_item(lz, fmt.tprintf("###release_%s", r.version)) {
				changelog_release_build(c, r, s, n == len(c.shown) - 1, em)
			}
		}
	}
}

// The search over the versions and a toggle per kind the changelog has (on: shown), and how many versions are kept. They
// flow: on a page narrower than all of them (the settings in a dialog), the toggles and the count go to the next line,
// each whole; in one row their sum pushed the page past its edge.
@(private = "file")
changelog_tools_build :: proc(c: ^Changelog, em: f32) {
	gap := math.round(em * ui.CONTROL_GAP)
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.flow({gap, gap}, "###whats_new_tools") {
		ui.next({width = ui.px(math.round(em * 16))})
		ui.line_edit("###whats_new_search", &c.search, {placeholder = i18n.tr("Search the versions"), clearable = true})
		for k in Change_Kind {
			if k not_in c.kinds_in { continue }
			on := k not_in c.kinds_off
			word := change_kind_word(k)
			ui.next({height = ui.px(ui.dense(em * 1.9))})
			// (on: held down, its icon in its hue; off: a ghost, weak, its icon grey)
			o := ui.Button_Options{face = on ? .Toggled : .Ghost, quiet = !on, icon_font = ui.lucide_icons(), icon_color = on ? ui.hue(change_hue(word)) : ui.color("weak text"),
				tip = on ? fmt.tprintf(i18n.tr("Hide the changes of kind %s"), word) : fmt.tprintf(i18n.tr("Show the changes of kind %s"), word)}
			if ui.button(fmt.tprintf("###kind_%v", k), word, change_icon(word), o).clicked { c.kinds_off ~= {k} }
		}
		// (a share of what its line leaves, its words its least: at the end of the line its words fit on, whole. A fill()
		// spacer before it went to a line of its own once the line was full, and took it all)
		count := fmt.tprintf(i18n.tr("%d of %d versions"), len(c.shown), len(c.releases))
		if ui.tags("weak") {
			w := ui.fill()
			w.least = math.ceil(ui.text_width(ui.top_style().font, em, count) + 2 * ui.top_style().text_pad)
			ui.next({width = w, height = ui.px(ui.dense(em * 1.9)), text_align = .Right})
			ui.label(fmt.tprintf("%s###whats_new_count", count))
		}
	}
}

// A kind's word, as the changelog writes it (English, as the changelog).
@(private = "file")
change_kind_word :: proc(k: Change_Kind) -> string {
	switch k {
	case .Added:      return "Added"
	case .Changed:    return "Changed"
	case .Deprecated: return "Deprecated"
	case .Removed:    return "Removed"
	case .Fixed:      return "Fixed"
	case .Security:   return "Security"
	case .Other:      return "Other"
	}
	return ""
}

@(private = "file")
Rail_Draw :: struct { line, dot: ui.Color, last, lit: bool, dot_y, gutter: f32 }

@(private = "file")
changelog_release_build :: proc(c: ^Changelog, r: ^Changelog_Release, s: Changelog_Shown, last: bool, em: f32) {
	newest := s.release == 0
	i := s.release
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(.Start, {}, "###release") {
		// the rail, drawn by the row in its left gutter (as tall as the card beside it): its line, not past the last dot;
		// the dot level with the version's chip (the middle of the card's head, CARD_PAD under its top)
		row := ui.parent_box()
		d := ui.frame_new(Rail_Draw)
		head := ui.dense(em * 1.9)
		dot_y := math.round(em * ui.CARD_PAD) + math.round(head * 0.5)
		d^ = {line = ui.color("border"), dot = newest ? ui.color("accent") : ui.color("weak text"), last = last, lit = newest, dot_y = dot_y, gutter = math.round(em * 2)}
		row.custom, row.custom_user = rail_draw, d
		ui.spacer(ui.px(d.gutter))
		// the card
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.tags("card") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y, radius = em * 0.6})
			card := ui.build_box({.Draw_Background, .Draw_Border, .Plate}, "###release_card")
			ui.push_parent(card)
			defer ui.pop_parent()
			// (ui.card's inset: CARD_PAD on its four sides)
			ui.space(ui.CARD_PAD)
			// its head: the version, its day and time, Latest. They flow, each whole, a line as tall as the head: on a narrow
			// page the day goes under the version (the first line stays level with the rail's dot); in one row the three
			// pushed the page past its edge
			gap := math.round(em * ui.CONTROL_GAP)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(.Start, {}, "###release_head") {
				ui.space(ui.CARD_PAD)
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.flow({gap, 0}, "###release_head_flow") {
					ui.pill("ver", r.version, lucide.TAG, newest ? ui.color("accent") : ui.color("weak text"), {mono = true})
					if ui.tags("weak") {
						ui.next({width = ui.text_size(), height = ui.px(head)})
						ui.label(fmt.tprintf("%s###stamp", r.stamp))
					}
					if newest { ui.pill("latest", i18n.tr("Latest"), lucide.ROCKET, ui.hue(.Green)) }
				}
				ui.space(ui.CARD_PAD)
			}
			// its changes, by type
			for &g, k in r.groups {
				if k >= 64 || s.groups & (1 << u64(k)) == 0 { continue }
				ui.space(ui.LINE_GAP)
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if ui.row(.Start, {}, fmt.tprintf("###group_%d", k)) {
					ui.space(ui.CARD_PAD)
					ui.next({width = ui.px(math.round(em * 6.5)), height = ui.children_sum(), axis = .Y})
					// (its type in English, as the changelog)
					if ui.column(id = "###type") { ui.pill("type", g.type, change_icon(g.type), ui.hue(change_hue(g.type))) }
					ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
					if ui.column(id = "###list") { markdown.view(&g.doc, fmt.tprintf("list_%d_%d", i, k), g.list, {}) }
					ui.space(ui.CARD_PAD)
				}
			}
			ui.space(ui.CARD_PAD)
		}
	}
	if !last { ui.space(ui.ITEM_GAP) }
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
