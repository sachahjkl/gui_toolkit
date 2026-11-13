package tk_prefs_page

// The settings in a program's command palette: each preference the pages show is a line of it, under "Settings" and its
// page's title; chosen, the program opens its settings and `show` puts that one alone on the page (its search holds its
// name), on its page underneath (the search cleared, the page is there).
//
//	// when the settings change (app.prefs.version), in memory of the program's: not at each frame
//	settings, names := prefs_page.palette_commands(&app.prefs, opts, table_allocator)
//	app.table = slice.concatenate([][]ui.Command{app_commands, settings}, table_allocator)
//	app.table_version = app.prefs.version + 1
//	// each frame
//	if i, _ := ui.palette(&app.palette, app.table, disabled, {version = app.table_version}); i >= len(app_commands) {
//		app.settings_open = true
//		prefs_page.show(&app.page, &app.prefs, opts, names[i - len(app_commands)])
//	}

import "core:fmt"
import "core:strings"
import config "../config"
import i18n "../i18n"
import lucide "../lucide"
import "../ui"

// One command per preference the pages show (temp memory), and the preference each names. Its label is the title the
// page gives it; its group "Settings · <page>"; its icon the page's, else Lucide's sliders (the palette draws it in the
// state's icon_font).
palette_commands :: proc(prefs: ^config.Prefs, o: Page_Options, allocator := context.temp_allocator) -> (commands: []ui.Command, names: []string) {
	out := make([dynamic]ui.Command, allocator)
	ns := make([dynamic]string, allocator)
	for pg in pages_of(prefs, o) {
		icon := pg.icon != "" ? pg.icon : lucide.SLIDERS_HORIZONTAL
		// (a page of its own with tags is a command: chosen, `show` puts it up)
		if pg.build != nil && pg.tags != nil {
			append(&out, ui.Command{label = strings.clone(pg.title, allocator), group = i18n.tr("Settings"), icon = icon, tags = pg.tags})
			append(&ns, pg.category)
			continue
		}
		group := fmt.aprintf(i18n.tr("Settings · %s"), pg.title, allocator = allocator)
		for name in page_names(prefs, pg) {
			r := prefs.index[name]
			d := prefs.entries[r].def
			append(&out, ui.Command{label = config.title_of(d, allocator), group = group, icon = icon, tags = d.tags})
			append(&ns, name)
		}
	}
	return out[:], ns[:]
}

// The page shows preference `name` alone: its search holds the name (in quotes: that one, not the others it begins), and
// its page is the one under the search. `name` may also be a page's category (the command of a page of its own): that
// page, the search cleared.
show :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, name: string) {
	// (a page's category, from its own command: the page, the search cleared)
	for pg in pages_of(prefs, o) {
		if pg.category != name { continue }
		delete(p.current)
		p.current = strings.clone(pg.category)
		ui.line_edit_clear(&p.query)
		return
	}
	for pg in pages_of(prefs, o) {
		for n in page_names(prefs, pg) {
			if n != name { continue }
			delete(p.current)
			p.current = strings.clone(pg.category)
		}
	}
	ui.line_edit_set(&p.query, fmt.tprintf("\"%s\"", name))
	p.focus_search = true
}
