package tk_plugins

// The settings' Plugins page: each plugin, its state, its switch (off until the person turns it on), Stop while its
// runtime runs, why it was refused or failed; Reload plugins above them. A prefs_page.Page_Info of this package's:
// prefs_page imports no engine, so a program without plugins does not link one.

import "core:fmt"
import "core:math"
import "core:strings"
import i18n "../i18n"
import lucide "../lucide"
import prefs_page "../prefs_page"
import "../ui"

PLUGINS_PAGE :: "plugins"

@(private, rodata) PAGE_TAGS := [?]string{"plugins", "extensions", "javascript", "scripts"}

// The Plugins page, for Page_Options.pages.
page_info :: proc(h: ^Host) -> prefs_page.Page_Info {
	return {category = PLUGINS_PAGE, title = i18n.later("Plugins"), icon = lucide.PUZZLE, build = page_build, user = h, tags = PAGE_TAGS[:]}
}

@(private)
page_build :: proc(user: rawptr, em: f32) {
	h := (^Host)(user)
	ui.next({width = ui.text_size(em * 0.6), height = ui.px(math.round(em * 2))})
	if ui.button("plugins_reload", i18n.tr("Reload plugins"), lucide.REFRESH_CW, {icon_font = ui.lucide_icons()}).clicked { reload(h) }
	ui.space(ui.ITEM_GAP)
	if !h.loaded {
		if ui.tags("weak") { line("plugins_reading", i18n.tr("Reading the plugins' folder…"), em) }
		return
	}
	if len(h.plugins) == 0 {
		if ui.tags("weak") { line("plugins_none", fmt.tprintf(i18n.tr("No plugin. A plugin is a folder in %s."), h.folder), em) }
		return
	}
	words := PLUGIN_STATE_WORDS
	for p, i in h.plugins {
		key := p.manifest.id != "" ? p.manifest.id : fmt.tprintf("%d", i)
		title := p.manifest.version != "" ? fmt.tprintf("%s %s", p.manifest.name, p.manifest.version) : p.manifest.name
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.2)), axis = .X, cross = .Center})
		if ui.row(id = fmt.tprintf("###plugin_%s", key)) {
			if p.state == .Refused {
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s###plugin_name_%s", title, key))
			} else {
				on := p.enabled && !p.asks_more   // (on in plugins.toml, but asking for more: off until the person allows it)
				ui.next({width = ui.fill(), height = ui.pct(1)})
				if ui.toggle(fmt.tprintf("###plugin_switch_%s", key), title, &on) { set_enabled(h, p.manifest.id, on) }
			}
			ui.space(ui.CONTROL_GAP)
			// (Off is the switch's: the word says only what the switch does not)
			if p.state != .Off && p.state != .Ready {
				ui.next({width = ui.text_size(0), height = ui.pct(1)})
				if ui.tags(p.state == .Failed || p.state == .Not_Responding ? "bad" : "weak") {
					ui.label(fmt.tprintf("%s###plugin_state_%s", i18n.tr(words[p.state]), key))
				}
			}
			if p.alive {
				ui.space(ui.CONTROL_GAP)
				ui.next({width = ui.text_size(em * 0.6), height = ui.px(math.round(em * 1.8))})
				if ui.button(fmt.tprintf("plugin_stop_%s", key), i18n.tr("Stop")).clicked { stop(h, p.manifest.id) }
			} else if p.state == .Failed {
				ui.space(ui.CONTROL_GAP)
				ui.next({width = ui.text_size(em * 0.6), height = ui.px(math.round(em * 1.8))})
				if ui.button(fmt.tprintf("plugin_restart_%s", key), i18n.tr("Restart")).clicked { _ = restart(h, p.manifest.id) }
			}
		}
		why := p.state == .Refused ? p.refused : p.state == .Failed ? p.failure : ""
		if why != "" {
			if ui.tags("weak") { line(fmt.tprintf("plugin_why_%s", key), why, em) }
		}
		// (what it asks, said once: before a grant as what turning it on will ask, after it as what it has)
		if len(p.manifest.permissions) > 0 && p.state != .Refused {
			words := make([dynamic]string, context.temp_allocator)
			for w in p.manifest.permissions { append(&words, i18n.tr(permission_words(w, h.o.app))) }
			lead := p.asks_more ? i18n.tr("It asks to") : i18n.tr("It may")
			if ui.tags("weak") { line(fmt.tprintf("plugin_asks_%s", key), fmt.tprintf("%s: %s.", lead, strings.join(words[:], "; ", context.temp_allocator)), em) }
		}
		if len(p.granted) > 0 || len(p.picked) > 0 {
			ui.next({width = ui.text_size(em * 0.6), height = ui.px(math.round(em * 1.8))})
			if ui.button(fmt.tprintf("plugin_revoke_%s", key), i18n.tr("Take back its permissions")).clicked { revoke(h, p.manifest.id) }
		}
		ui.space(ui.LINE_GAP)
	}
}

@(private)
line :: proc(id, text: string, em: f32) {
	ui.next({width = ui.fill(), font_size = math.round(em * 0.9), text_pad = 0})
	ui.paragraph(fmt.tprintf("%s###%s", text, id))
}
