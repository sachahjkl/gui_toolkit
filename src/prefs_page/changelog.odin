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
import "core:strings"
import config "../config"
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
	doc:          markdown.Doc,       // the page's laid-out text
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
	markdown.doc_destroy(&c.doc)
}

@(private)
changelog_page_info :: proc(c: ^Changelog) -> Page_Info {
	return {category = CHANGELOG_PAGE, title = i18n.later("What's new"), icon = lucide.SCROLL_TEXT, build = changelog_build, user = c, tags = CHANGELOG_TAGS[:]}
}

@(private = "file", rodata) CHANGELOG_TAGS := [?]string{"changelog", "release notes", "news", "version", "update"}

@(private = "file")
changelog_build :: proc(user: rawptr, em: f32) {
	c := (^Changelog)(user)
	text := changelog_text(c)
	// (its first line, "# Changelog", is the page's own title)
	if strings.has_prefix(text, "# ") { _, _, text = strings.partition(text, "\n") }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###whats_new") { markdown.view(&c.doc, "whats_new_md", text, {}) }
}
