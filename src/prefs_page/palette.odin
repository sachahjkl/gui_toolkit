package tk_prefs_page

// The settings in a program's command palette: the toolkit's settings source (`:`, in the plain search too), one item
// per preference the pages show, under "Settings · <page>". Choosing a switch flips it and the palette stays open, its
// mark following; choosing another setting puts it alone on its page (`show`) and asks the program to show its settings
// (`open`). src/md/features/palette.md.
//
//	// once, and again when the page options change
//	prefs_page.palette_settings_add(&app.palette, &app.palette_settings, &app.prefs, &app.page, opts, open_settings, app)

import "core:fmt"
import "core:strings"
import config "../config"
import i18n "../i18n"
import lucide "../lucide"
import "../ui"

// The settings source. The program keeps it at a place that does not move while the palette has it.
Palette_Settings :: struct {
	source:  ui.Palette_Source,
	prefs:   ^config.Prefs,
	page:    ^Page,
	options: Page_Options,          // the program's: its slices valid while the palette has the source
	open:    proc(user: rawptr),    // shows the program's settings, `page` already on the setting chosen (nil: none)
	user:    rawptr,
	count:   int,                   // the preferences registered when the items were last read: a new one reads again
}

// Adds the settings source to the palette, or gives it new options. A program with its own settings model (Wren's
// about:config) gives its own source of the prefix Settings instead.
palette_settings_add :: proc(p: ^ui.Command_Palette, s: ^Palette_Settings, prefs: ^config.Prefs, page: ^Page, o: Page_Options, open: proc(user: rawptr), user: rawptr = nil) {
	version := s.source.version
	s.prefs, s.page, s.options, s.open, s.user = prefs, page, o, open, user
	s.source = {
		name = "setting", title = i18n.later("Settings"), prefix = .Settings, plain = true, remember = true, enter = i18n.later("Show"),
		read = settings_read, mark = settings_mark, act = settings_act, poll = settings_poll, user = s, toolkit = true,
		version = version + 1,
	}
	s.count = len(prefs.entries)
	ui.palette_add(p, &s.source)
}

// (at each build while the palette is open) A preference registered since: the items are read again. A value's change
// is not one: a switch's mark follows it without a new ranking.
@(private = "file")
settings_poll :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source) {
	s := (^Palette_Settings)(src.user)
	if n := len(s.prefs.entries); n != s.count {
		s.count = n
		src.version += 1
	}
}

// One item per preference the pages show: its title, its page in its group, its name as its last text (a search by
// "appearance.theme" finds it). A page of its own with tags is an item too: choosing it shows that page. A switch
// stays; a preference the policy fixes is disabled.
@(private = "file")
settings_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	s := (^Palette_Settings)(src.user)
	prefs := s.prefs
	items := make([dynamic]ui.Palette_Item, context.temp_allocator)
	for pg in pages_of(prefs, s.options) {
		icon := pg.icon != "" ? pg.icon : lucide.SLIDERS_HORIZONTAL
		if pg.build != nil && pg.tags != nil {
			append(&items, ui.Palette_Item{id = pg.category, title = pg.title, group = i18n.tr("Settings"), icon = icon, tags = pg.tags})
			continue
		}
		group := fmt.tprintf(i18n.tr("Settings · %s"), pg.title)
		for name in page_names(prefs, pg) {
			r := prefs.index[name]
			d := prefs.entries[r].def
			append(&items, ui.Palette_Item{
				id = name, title = i18n.tr(config.title_of(d)), group = group, icon = icon, tags = d.tags, last = name,
				stays = d.kind == .Bool, disabled = config.is_locked(prefs, config.Ref(r)),
			})
		}
	}
	ui.palette_answer(p, src, q.serial, items[:])
}

// A switch on.
@(private = "file")
settings_mark :: proc(src: ^ui.Palette_Source, id: string) -> bool {
	s := (^Palette_Settings)(src.user)
	r, ok := s.prefs.index[id]
	if !ok || s.prefs.entries[r].def.kind != .Bool { return false }
	return config.bool_of(s.prefs, id)
}

// A switch flips (the program's `changed` saves it); another setting, or a page, is shown in the settings.
@(private = "file")
settings_act :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, c: ui.Palette_Choice) {
	s := (^Palette_Settings)(src.user)
	if r, ok := s.prefs.index[c.id]; ok && s.prefs.entries[r].def.kind == .Bool {
		if config.set_bool(s.prefs, c.id, !config.bool_of(s.prefs, c.id)) == .None && s.options.changed != nil {
			s.options.changed(s.options.user, c.id)
		}
		return
	}
	show(s.page, s.prefs, s.options, c.id)
	if s.open != nil { s.open(s.user) }
}

// The page shows preference `name` alone: its search holds the name (in quotes: that one, not the others it begins), and
// its page is the one under the search. `name` may also be a page's category (the item of a page of its own): that
// page, the search cleared. The search is for this visit: once the settings close (a build without the page), the next
// opening shows the page the person had, the search empty, unless the person changed the search meanwhile.
show :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, name: string) {
	// (a page's category, from its own item: the page, the search cleared)
	for pg in pages_of(prefs, o) {
		if pg.category != name { continue }
		delete(p.current)
		p.current = strings.clone(pg.category)
		ui.line_edit_clear(&p.query)
		placed_forget(p)
		return
	}
	// (the page the person had, put back when the settings close: a second jump keeps the first one's)
	over := p.placed != "" ? strings.clone(p.placed_over) : strings.clone(p.current)
	placed_forget(p)
	p.placed_over = over
	for pg in pages_of(prefs, o) {
		for n in page_names(prefs, pg) {
			if n != name { continue }
			delete(p.current)
			p.current = strings.clone(pg.category)
		}
	}
	query := fmt.tprintf("\"%s\"", name)
	ui.line_edit_set(&p.query, query)
	p.placed = strings.clone(query)
	p.placed_new = true
	p.focus_search = true
}
