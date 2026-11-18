package tk_plugins

// What the person grants a plugin (plugins.md, decision 4): a plugin that asks for permissions is off until the person
// turns it on, and turning it on shows what it asks, in words, in a dialog. Allow grants that set (kept in
// plugins.toml); a new version that asks more is off again until the person allows the new set; one that asks the
// same or less starts as before. gt-runtime's plugin (Host_Options.single) asks at its start: the program was
// started to run it.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import i18n "../i18n"
import "../ui"

// The grant dialog's view id.
GRANT_VIEW :: "plugins.grant"

// Grants plugin `id` what its manifest asks, and turns it on. Interface thread: the dialog's Allow calls it, a test
// too. False: no such plugin, or refused.
grant :: proc(h: ^Host, id: string) -> bool {
	context.allocator = runtime.heap_allocator()   // (a plugin's memory is freed on its reader's thread, by the heap)
	p := find(h, id)
	if p == nil || p.refused != "" { return false }
	for g in p.granted { delete(g) }
	clear(&p.granted)
	for w in p.manifest.permissions { append(&p.granted, strings.clone(w)) }
	p.asks_more = false
	p.enabled = true
	p.suspended = false
	if !p.alive { p.state = .Ready }
	h.source.version += 1
	toml_write(h)
	return true
}

// Takes back what plugin `id` was granted: its permissions and the files it was given. A plugin that asks for
// permissions is off until they are granted again; its process stops.
revoke :: proc(h: ^Host, id: string) {
	context.allocator = runtime.heap_allocator()
	p := find(h, id)
	if p == nil { return }
	for g in p.granted { delete(g) }
	clear(&p.granted)
	for g in p.picked { delete(g) }
	clear(&p.picked)
	if len(p.manifest.permissions) > 0 {
		p.asks_more = true
		plugin_stop(p)
		if !p.alive { p.state = .Off }
	}
	h.source.version += 1
	toml_write(h)
}

// The dialog that asks for plugin `id`'s permissions, at the next build.
@(private)
grant_ask :: proc(h: ^Host, id: string) {
	delete(h.grant_for)
	h.grant_for = strings.clone(id)
	h.grant_due = true
}

// Each build (host_build): the dialog registered, opened when due; gt-runtime's plugin asks once at its start.
@(private)
grant_build :: proc(h: ^Host) {
	vs := ui.state_views(h.state)
	if !h.grant_view {
		h.grant_view = true
		ui.view_register(vs, GRANT_VIEW, grant_dialog, ui.View_Options{title = i18n.later("Permissions"), home = .Dialog, width_em = 30})
	}
	if h.o.single != "" && h.loaded && !h.single_asked {
		h.single_asked = true
		if len(h.plugins) == 1 && h.plugins[0].asks_more && h.plugins[0].refused == "" { grant_ask(h, h.plugins[0].manifest.id) }
	}
	if h.grant_due {
		h.grant_due = false
		ui.view_open(vs, GRANT_VIEW, h)
	}
}

// The dialog: the plugin, what each permission lets it do, Allow and Not now.
@(private)
grant_dialog :: proc(v: ^ui.View, h: ^Host) {
	p := find(h, h.grant_for)
	if p == nil { ui.view_end(v, 0); return }
	em := ui.font_size()
	if ui.dialog_body("###grant_body") {
		ui.next({width = ui.fill()})
		ui.paragraph(fmt.tprintf("%s###grant_intro", fmt.tprintf(i18n.tr("%s asks to:"), p.manifest.name)))
		ui.space(ui.LINE_GAP)
		for w, i in p.manifest.permissions {
			ui.next({width = ui.fill(), font_size = math.round(em * 0.95)})
			ui.paragraph(fmt.tprintf("• %s###grant_word_%d", i18n.tr(permission_words(w)), i))
		}
		ui.space(ui.LINE_GAP)
		if ui.tags("weak") {
			ui.next({width = ui.fill(), font_size = math.round(em * 0.9)})
			ui.paragraph(fmt.tprintf("%s###grant_note", i18n.tr("You can take this back in the settings' Plugins page.")))
		}
	}
	if ui.dialog_buttons("###grant_buttons") {
		if ui.button("grant_later", i18n.tr("Not now")).clicked { ui.view_end(v, 0) }
		if ui.button("grant_allow", i18n.tr("Allow"), o = {intent = .Primary}).clicked {
			_ = grant(h, p.manifest.id)
			ui.view_end(v, 1)
		}
	}
}
