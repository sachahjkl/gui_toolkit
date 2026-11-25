package tk_prefs_page

// The settings in a program's command palette: the toolkit's settings source (`:`, in the plain search too), one item
// per preference the pages show, under "Settings · <page>", its value in use at its right. Enter on a switch flips it
// and the palette stays open, its mark following; Enter on another setting unfolds its control under its row (the run
// mode: palette_run.odin), a change written at once, Enter keeps it, Escape puts back the value of before. Shift+Enter
// goes to it: the settings show its page, its line at the top of the page, focused and lit (its act name,
// "setting:<name>"). A setting the policy or the command line fixes shows its value and why, no control.
// src/md/features/palette.md, src/md/features/everything-palette.md.
//
//	// once, at the start: the source asks for the page options each time it reads or acts
//	prefs_page.palette_settings_add(&app.palette, &app.palette_settings, &app.prefs, &app.page, settings_options, open_settings, app)

import "core:fmt"
import "core:strings"
import config "../config"
import i18n "../i18n"
import lucide "../lucide"
import "../ui"

// The settings source. The program keeps it at a place that does not move while the palette has it.
Palette_Settings :: struct {
	source:  ui.Palette_Source,
	runner:  ui.Palette_Runner,   // its run mode: a setting's control
	prefs:   ^config.Prefs,
	page:    ^Page,
	// the page options as they are now, asked when the source reads or acts: their slices (the themes, the pages) can
	// be made again between two of its reads, so the source keeps none of them
	options: proc(user: rawptr) -> Page_Options,
	open:    proc(user: rawptr),    // shows the program's settings, `page` already on the setting chosen (nil: none)
	user:    rawptr,
	count:   int,                   // the preferences registered when the items were last read: a new one reads again
}

// Adds the settings source to the palette, once (a second call is the first's: palette_add is idempotent), and the
// commands' forms (palette_forms_use). The pages a program shows change rarely: when they do, it bumps
// `s.source.version`. A program with its own settings model (Wren's about:config) gives its own source of the prefix
// Settings instead.
palette_settings_add :: proc(p: ^ui.Command_Palette, s: ^Palette_Settings, prefs: ^config.Prefs, page: ^Page, options: proc(user: rawptr) -> Page_Options, open: proc(user: rawptr), user: rawptr = nil) {
	if ui.palette_has(p, &s.source) { return }
	s.prefs, s.page, s.options, s.open, s.user = prefs, page, options, open, user
	s.runner = settings_runner(s)
	s.source = {
		name = "setting", title = i18n.later("Settings"), prefix = .Settings, plain = true, remember = true, enter = i18n.later("Change"),
		read = settings_read, mark = settings_mark, value = settings_value, reach = settings_reach, act = settings_act,
		poll = settings_poll, runner = &s.runner, user = s, toolkit = true, version = 1,
	}
	s.count = len(prefs.entries)
	ui.palette_add(p, &s.source)
	if p.forms.open == nil { palette_forms_use(p) }
}

// (at each build while the palette is open) A preference registered since: the items are read again. A value's change
// is not one: a switch's mark and the values shown follow it without a new ranking.
@(private = "file")
settings_poll :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source) {
	s := (^Palette_Settings)(src.user)
	if n := len(s.prefs.entries); n != s.count {
		s.count = n
		src.version += 1
	}
}

// One item per preference the pages show: its title, its page in its group, its name as its last text (a search by
// "appearance.theme" finds it), its act name. A page of its own with tags is an item too: choosing it shows that page.
// A switch stays; another runs (its control); a preference the policy or the command line fixes is disabled, its
// reason its detail.
@(private = "file")
settings_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	s := (^Palette_Settings)(src.user)
	prefs := s.prefs
	// (in the answer's own arena: the registry and the page options can go before the palette lets go of the answer)
	a: ui.Palette_Answer
	al := ui.palette_answer_allocator(&a)
	items := make([dynamic]ui.Palette_Item, al)
	for pg in pages_of(prefs, s.options(s.user)) {
		icon := pg.icon != "" ? pg.icon : lucide.SLIDERS_HORIZONTAL
		if pg.build != nil && pg.tags != nil {
			append(&items, ui.palette_item_clone({id = pg.category, title = pg.title, group = i18n.tr("Settings"), icon = icon, tags = pg.tags}, al))
			continue
		}
		group := fmt.tprintf(i18n.tr("Settings · %s"), pg.title)
		for name in page_names(prefs, pg) {
			r := prefs.index[name]
			e := &prefs.entries[r]
			d := e.def
			why := ""
			#partial switch e.source {
			case .Policy:       why = i18n.tr("Locked by a policy.")
			case .Command_Line: why = i18n.tr("Set on the command line for this run.")
			}
			append(&items, ui.palette_item_clone({
				id = name, title = i18n.tr(config.title_of(d)), group = group, icon = icon, tags = d.tags, last = name, detail = why,
				act = fmt.tprintf("setting:%s", name), stays = d.kind == .Bool, disabled = why != "", runs = d.kind != .Bool && why == "",
			}, al))
		}
	}
	a.items = items[:]
	ui.palette_answer(q, &a)
}

// A switch on.
@(private = "file")
settings_mark :: proc(src: ^ui.Palette_Source, id: string) -> bool {
	s := (^Palette_Settings)(src.user)
	r, ok := s.prefs.index[id]
	if !ok || s.prefs.entries[r].def.kind != .Bool { return false }
	return config.bool_of(s.prefs, id)
}

// The longest value a row shows whole, in characters: a path or an address longer is cut in its middle.
@(private = "file") VALUE_SHOWN_MAX :: 28

// The value in use at a row's right, as the page shows it: a choice's label, a family's name ("Default" for the
// program's), a number with its unit. A switch shows its mark instead.
@(private = "file")
settings_value :: proc(src: ^ui.Palette_Source, id: string) -> string {
	s := (^Palette_Settings)(src.user)
	r, ok := s.prefs.index[id]
	if !ok { return "" }
	e := &s.prefs.entries[r]
	d := e.def
	switch d.kind {
	case .Bool:
		return ""
	case .String:
		v := e.value.s
		for c, i in d.choices {
			if c != v { continue }
			return i18n.tr(len(d.choice_labels) == len(d.choices) ? d.choice_labels[i] : c)
		}
		if v == "" { return i18n.tr("Default") }
		if n := strings.rune_count(v); n > VALUE_SHOWN_MAX {
			// (the byte offsets of its half's rune and of the last half's first)
			half := VALUE_SHOWN_MAX / 2
			head, tail, k := len(v), len(v), 0
			for _, at in v {
				if k == half { head = at }
				if k == n - half + 1 { tail = at }
				k += 1
			}
			return fmt.tprintf("%s…%s", v[:head], v[tail:])
		}
		return v
	case .Int, .Float:
		return i18n.decimal_marks(config.shown_text(d, e.value))
	}
	return ""
}

// A setting the settings show (a registered one no page hides) can be reached while the program can show its settings.
// Go: its page, the page's search cleared (it would hide the line), its Advanced part unfolded when it is one; then the
// program shows its settings, and go to finds the line in a next build.
@(private = "file")
settings_reach :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, id: string, go: bool) -> bool {
	s := (^Palette_Settings)(src.user)
	r, ok := s.prefs.index[id]
	if !ok || s.open == nil || s.prefs.entries[r].def.hidden { return false }
	if !go { return true }
	o := s.options(s.user)
	pg := s.page
	flush_all(pg, s.prefs, o)
	for page in pages_of(s.prefs, o) {
		for n in page_names(s.prefs, page) {
			if n != id { continue }
			delete(pg.current)
			pg.current = strings.clone(page.category)
			if s.prefs.entries[r].def.advanced {
				if page.category in pg.unfolded { pg.unfolded[page.category] = true } else { pg.unfolded[strings.clone(page.category)] = true }
			}
		}
	}
	ui.line_edit_clear(&pg.query)
	placed_forget(pg)
	s.open(s.user)
	return true
}

// A switch flips (the program's `changed` saves it); a page of its own is shown in the settings; a setting that did not
// open its run mode (none of the page's controls for it) is shown alone on its page.
@(private = "file")
settings_act :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, c: ui.Palette_Choice) {
	s := (^Palette_Settings)(src.user)
	o := s.options(s.user)
	if r, ok := s.prefs.index[c.id]; ok && s.prefs.entries[r].def.kind == .Bool {
		if config.set_bool(s.prefs, c.id, !config.bool_of(s.prefs, c.id)) == .None && o.changed != nil {
			o.changed(o.user, c.id)
		}
		return
	}
	show(s.page, s.prefs, o, c.id)
	if s.open != nil { s.open(s.user) }
}

// The page shows preference `name` alone: its search holds the name (in quotes: that one, not the others it begins), and
// its page is the one under the search. `name` may also be a page's category (the item of a page of its own): that
// page, the search cleared. The search is for this visit: once the settings close (a build without the page), the next
// opening shows the page the person had, the search empty, unless the person changed the search meanwhile.
show :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, name: string) {
	flush_all(p, prefs, o)
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
