package tk_plugins

// A plugin's own words in the person's language (plugins.md, "As built: palette sources, menus, the tool bar, a
// plugin's languages"): its manifest's "l10n" translates its labels and titles; the language is the toolkit's
// (i18n.current), and a text with no translation stays the manifest's English.

import "base:runtime"
import "core:strings"
import "../ascii"
import i18n "../i18n"

// `text`, one of manifest `m`'s words, in the language in use: its translation for the language's tag ("fr-ca"), else
// for its primary subtag ("fr"), else `text`. The manifest's strings or `text`: nothing is made.
manifest_tr :: proc(m: ^Manifest, text: string) -> string {
	if len(m.l10n) == 0 || text == "" { return text }
	if i18n.current() == nil { return text }
	tag := ascii.lower(language_tag(), context.temp_allocator)   // ("fr-ca", as the manifest's keys are kept)
	primary := i18n.primary_of(tag)
	found := ""
	for t in m.l10n {
		if t.text != text { continue }
		if t.language == tag { return t.translation }
		if t.language == primary { found = t.translation }
	}
	return found != "" ? found : text
}

// Each build (host_build): a change of the language in use is said to each running plugin (its context.language, and
// its open views render again). One that starts later reads it in its start.
@(private)
language_follow :: proc(h: ^Host) {
	v := i18n.version()
	if v == h.language { return }
	h.language = v
	tag := language_tag()
	for p in h.plugins {
		if p.alive && !p.dropped { queue_push(p, Message{kind = .Language, text = strings.clone(tag, runtime.heap_allocator())}) }
	}
	h.source.version += 1   // (the plugins' palette items: their labels)
	settings_label(h)       // (the registry's titles of the plugins' settings: once per change, not per build)
}

// The language's tag a plugin's code reads (`context.language`): the toolkit's, "en" for English.
language_tag :: proc() -> string {
	l := i18n.current()
	if l == nil || l.tag == "" { return "en" }
	// (a system's locale: "fr_FR.UTF-8" is the tag "fr-FR")
	tag := l.tag
	if dot := strings.index_byte(tag, '.'); dot >= 0 { tag = tag[:dot] }
	out, _ := strings.replace_all(tag, "_", "-", context.temp_allocator)
	return out
}
