// Package prefs_page: a program's settings, built from its preferences (gt:config) with no code per preference, in the
// look of opencode native's settings.
//
//   * On the left, a sidebar the mouse resizes (its width kept: prefs_page.sidebar_width): the search in a well, then
//     the pages (a page is a top group of the registry: its title and its icon from Page_Options.pages), the one shown
//     pressed in; at its foot, the program's version, the settings file (a click opens it) and Export / Import. A narrow
//     page shows the pages' icons alone.
//   * On the right: the page's title, then a line per preference: its title and its description on the left, its
//     control on the right (a switch, a segmented choice or a list, a number, a field with its unit), a reset button
//     while it is not at its default, a carved line under it. A control the line has no room for goes under the words.
//     The preferences of an inner group (appearance.text) follow under its title; the advanced ones (Def.advanced) of
//     the page under "Advanced", folded until a click.
//   * While a search is typed: what matches in every page, under each page's title (config.Search).
//
// A preference can get a control of the program's own (Page_Options.custom): a font picker. The standard preferences
// (standard.odin) need none: Page_Options.themes shows appearance.theme as cards (and the user's themes file:
// Page_Options.themes_file), Page_Options.shortcut_prefs shows global shortcuts with what the system said of them. A program shows
// the page in place of its main view with back_bar and escape_leaves.
//
// A change goes through config.set_from_string at the User layer, so every observer of the registry runs; then
// Page_Options.changed, where the program applies what changed (its loop writes the file: config.user_writer_save).
package tk_prefs_page

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "../ascii"
import config "../config"
import "../draw"
import "../font"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"
import host "../host"
import shortcuts "../shortcuts"
import "../ui"
import update "../update"

// A page: a category of the registry, its title (English, shown translated: i18n.later) and its icon (a glyph of
// Page_Options.icon_font; "": none). `names`: the preferences it shows, in this order, whatever their category (nil: those of
// `category`, in the registry's order); a program whose pages are not its registry's categories keeps those for its other
// views (an editor of every preference).
Page_Info :: struct {
	category, title, icon: string,
	names:                 []string,
	// a page of the program's own, with no preference (a server's state, a list it keeps): it builds the page under its
	// title (a search does not look in it). `category` still names it (Page.current, show)
	build:                 proc(user: rawptr, em: f32),
	user:                  rawptr,     // what `build` is given (nil: Page_Options.user)
	// other words the palette finds the page by: a page with `build` and tags is a command of palette_commands, which
	// shows it (the toolkit's Installation and Diagnostics pages have theirs)
	tags:                  []string,
	// a heading above the page in the sidebar, which starts a group of pages ("CLIENT", "SERVER"; "": none)
	heading:               string,
}

// A global shortcut's preference: `pref` holds its keys (as platform.hotkey_text writes them), `id` is the shortcut's id
// in the program's shortcuts.Service.
Shortcut_Pref :: struct { pref, id: string }

// What a program gives the page.
Page_Options :: struct {
	user:      rawptr,
	// after a value was set or reset (it was valid): save the file, apply it
	changed:   proc(user: rawptr, name: string),
	// while a slider is held, each value it moves to (the file is written when it is let go): the program shows it at
	// once (a rounding, a size), without writing it
	preview:   proc(user: rawptr, name: string, value: f64),
	// the values a String preference without its own choices may take, and their labels (nil, nil: a free field)
	choices:   proc(user: rawptr, name: string) -> (labels, values: []string),
	// the preferences with a control of the program's own, under their words (the themes' cards), and that control
	custom_names: []string,
	// the String preferences that hold a key combination (platform.hotkey_text): a field that records the keys pressed
	// (ui.hotkey_field) in place of one to type in
	hotkeys:   []string,
	// what the program has to say under a preference's line ("" nothing): a shortcut another program holds... (in red)
	problem:   proc(user: rawptr, name: string) -> string,
	// what the program says of a preference's state under its line, plainly ("" nothing): the keys a shortcut got
	status:    proc(user: rawptr, name: string) -> string,
	// what the program shows under a page's preferences (not in a search): its own buttons, a list
	page_foot: proc(user: rawptr, category: string, em: f32),
	custom:    proc(user: rawptr, name: string, em: f32),
	// the program's Updater (gt:update): under the line of update_pref ("": update.auto), its state and its buttons
	// (Check now; Install when a version is on offer; Restart now, by `restart`, when one is installed)
	updater:     ^update.Updater,
	update_pref: string,
	restart:     proc(user: rawptr),
	// the pages in their order (one with no preference is not shown); nil: each category of the registry, by name, its
	// title from config.group_title
	pages:     []Page_Info,
	icon_font: font.Font_Id,   // the font of the pages' icons, and of the two below (0: none, words instead)
	search_icon, reset_icon: string,
	// the program's preferences file: at the foot of the sidebar, shortened with ~, a click opens it with the system's
	// program (ui.open) ("": none shown)
	file:      string,
	// the program and its version ("Papier 0.15.0"): a line at the bottom of the pages, above the foot ("" none)
	version:   string,
	// the program's themes: appearance.theme shows as their cards (theme_cards), in the version appearance.mode asks
	// (nil: appearance.theme is a field, or the program's custom control); when it asks the system's, themes_light says
	// which version the program shows now (its ui.Theme_Shown.light: the page does not ask the system each frame)
	themes:       []ui.Theme_Def,
	themes_light: bool,
	// the user's own themes (themes_file.odin): under the cards, a line that says they can be made, and the file, which a
	// click makes from its template when needed and opens in the system's editor (nil: no such line). Its `all` is
	// what `themes` is given
	themes_file:  ^Themes_File,
	// the program's global shortcuts: each preference of shortcut_prefs records keys, and says under its line what the
	// system made of them (shortcuts.status_text, shortcuts.problem_text); while a field records, the page holds the
	// service (shortcuts.hold)
	shortcuts:      ^shortcuts.Service,
	shortcut_prefs: []Shortcut_Pref,
	// the toolkit's own pages, after the program's: the installation (install.odin: the state, Install, Repair,
	// Uninstall) and the diagnostics of the window the settings are in (diagnostics.odin: its graphics adapter, its
	// frame times, the versions, with a Copy button). nil: not shown
	install:     ^Install,
	diagnostics: ^host.Host,
}

// The page's state, kept by the program between frames (destroy). Keep it as long as the ui.State it is built in: the
// answers of its tasks (an export written, an import read) come in that state's builds.
Page :: struct {
	query:        ui.Line_Edit,
	current:      string,   // the category shown (owned; "": the first page)
	focus_search: bool,
	search:       config.Search,
	fields:       map[string]^Field,   // the free fields' text while typed
	// the number held by its slider (its preference's name, owned; "": none) and where it is: the value is written when
	// the slider is let go (not at the pointer's rate), the page shows it meanwhile
	held:         string,
	held_value:   f64,
	number_typed: bool,                // a number's field had the keyboard at the last build (editing)
	unfolded:     map[string]bool,     // the pages whose Advanced part is open (keys owned)
	nav_em:       f32,                 // the sidebar's width while its handle moves (ems)
	nav_moving:   bool,
	file_of:      string,              // the file `file_shown` was made for (owned)
	file_shown:   string,              // Page_Options.file shortened with ~ (owned)
	note:         string,              // what the last export or import did, at the sidebar's foot (owned; "": nothing)
	note_bad:     bool,
	// (what the answers of the tasks need: the last build's)
	prefs:        ^config.Prefs,
	state:        ^ui.State,
	changed:      proc(user: rawptr, name: string),
	user:         rawptr,
	diagnostics:  Diagnostics_View,    // the Diagnostics page's (diagnostics.odin)
}

@(private)
Field :: struct {
	text:   ui.Line_Edit,
	box:    ui.Key,   // the field's box (last frame)
	synced: string,   // the value the field shows (owned)
	error:  string,   // why the last text was refused (owned)
}

destroy :: proc(p: ^Page) {
	ui.line_edit_destroy(&p.query)
	delete(p.current)
	delete(p.held)
	for k, f in p.fields { ui.line_edit_destroy(&f.text); delete(f.synced); delete(f.error); free(f); delete(k) }
	delete(p.fields)
	for k in p.unfolded { delete(k) }
	delete(p.unfolded)
	diagnostics_destroy(&p.diagnostics)
	delete(p.file_of)
	delete(p.file_shown)
	delete(p.note)
	p^ = {}
}

// Gives the search the keyboard at the next build (a program's Ctrl+, opens the page with it).
focus_search :: proc(p: ^Page) { p.focus_search = true }

// Whether a field of a preference has the keyboard: its Escape is the field's, not the program's.
editing :: proc(p: ^Page) -> bool {
	if ui.hotkey_recording() { return true }   // (its Escape gives the recording up)
	if p.number_typed { return true }
	k := ui.focus_key()
	if k == 0 { return false }
	for _, f in p.fields { if f.box == k { return true } }
	return false
}

// Whether Escape leaves the settings shown in place of the program's main view: it was pressed, and no editor of a
// preference has the keyboard (that Escape is the editor's). A program with its own dialogs open asks only when none is.
escape_leaves :: proc(p: ^Page) -> bool {
	return ui.key_press(.Escape) && !editing(p)
}

// A bar above the page shown in place of the main view: a back arrow (Lucide's in Page_Options.icon_font, else the word),
// whose tooltip is `back_tip` ("Back to the history (Escape)"), then `title`; as wide as its parent, 2.6 ems high. True
// when the arrow was pressed. `p`: the page it leaves.
back_bar :: proc(p: ^Page, o: Page_Options, title, back_tip: string, em: f32) -> (back: bool) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.6)), axis = .X, cross = .Center})
	if ui.row(id = "###prefs_back_bar") {
		ui.spacer(ui.px(em * 0.5))
		icon := o.icon_font != 0
		if icon {
			ui.next({width = ui.px(math.round(em * 2.1)), height = ui.px(math.round(em * 2.1)), font = o.icon_font, radius = em * 0.4})
		} else {
			ui.next({width = ui.text_size(em * 0.6), height = ui.px(math.round(em * 2.1)), radius = em * 0.4})
		}
		sig: ui.Signal
		if ui.tags("ghost_button") { sig = ui.button("prefs_back", icon ? lucide.ARROW_LEFT : i18n.tr("Back")) }
		ui.a11y_default(sig.box, {name = back_tip})
		if ui.hovered_for(sig) {
			if ui.tooltip() {
				ui.next({width = ui.text_size(em * 0.6), height = ui.px(ui.dense(em * 1.8))})
				ui.label(fmt.tprintf("%s###tip", back_tip))
			}
		}
		back = sig.clicked
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 1.05), text_pad = 0})
		ui.label(fmt.tprintf("%s###prefs_back_title", title))
	}
	return
}

// Sizes, in ems: the sidebar (its default, least and most width, and the share of the page it may take), its icons
// alone and the page width under which it shows them, the margins of the page, a control's height, the least width of
// the words beside a control, a segmented choice's room around its longest label and the share of its line past which
// it goes under its words, a theme's card.
@(private = "file") NAV_EM          :: 14
@(private = "file") NAV_MIN_EM      :: 9
@(private = "file") NAV_MAX_EM      :: 30
@(private = "file") NAV_SHARE_MAX   :: 0.5
@(private = "file") NAV_ICONS_EM    :: 4
@(private = "file") NARROW_EM       :: 40
@(private = "file") MARGIN_EM       :: 1.4
@(private = "file") CONTROL_H_EM    :: 2
@(private = "file") WORDS_MIN_EM    :: 12
@(private = "file") SEGMENT_PAD_EM  :: 1.8
@(private = "file") WIDE_SHARE      :: 0.45
@(private = "file") SEGMENTS_MAX    :: 4      // more choices: a list
@(private = "file") NUMBER_EM       :: 15
@(private = "file") LIST_EM         :: 13
@(private = "file") FIELD_EM        :: 15
@(private = "file") NUMBER_FIELD_EM :: 9
@(private = "file") SWITCH_EM       :: 3.6
@(private = "file") CARD_H_EM       :: 3.6
@(private = "file") CARD_RADIUS_PX  :: 8
@(private = "file") CARDS_PER_ROW   :: 3

// The sidebar's width, in ems: the page's own state, kept with the settings (hidden: no page shows it).
SIDEBAR_PREF :: "prefs_page.sidebar_width"

@(private = "file", rodata)
SIDEBAR_DEFS := [?]config.Def{
	{name = SIDEBAR_PREF, description = "The width of the settings' sidebar, in ems.", kind = .Float, default = {f = NAV_EM},
		bounded = true, min = NAV_MIN_EM, max = NAV_MAX_EM, hidden = true},
}

// The pages of `o`, or each category of the registry by name; then the toolkit's own (Page_Options.install, diagnostics).
// `p`: the page being built (its Diagnostics page's state; nil for the palette).
@(private)
pages_of :: proc(prefs: ^config.Prefs, o: Page_Options, p: ^Page = nil) -> []Page_Info {
	out := program_pages_of(prefs, o)
	if o.install == nil && o.diagnostics == nil { return out }
	all := make([dynamic]Page_Info, 0, len(out) + 2, context.temp_allocator)
	append(&all, ..out)
	if o.install != nil {
		pg := install_page_info(o.install)
		pg.title = i18n.tr(pg.title)
		append(&all, pg)
	}
	if o.diagnostics != nil {
		pg := diagnostics_page_info(p)
		pg.title = i18n.tr(pg.title)
		append(&all, pg)
	}
	return all[:]
}

@(private = "file")
program_pages_of :: proc(prefs: ^config.Prefs, o: Page_Options) -> []Page_Info {
	if o.pages != nil {
		// (a page with no preference in this registry is not shown: a program that registers some only on one system)
		kept := make([dynamic]Page_Info, context.temp_allocator)
		for pg in o.pages {
			if pg.build == nil && len(page_names(prefs, pg)) == 0 { continue }
			// (a program's words are English, marked with i18n.later: shown in the language in use)
			shown := pg
			shown.title, shown.heading = i18n.tr(pg.title), i18n.tr(pg.heading)
			append(&kept, shown)
		}
		return kept[:]
	}
	cats := make([dynamic]string, context.temp_allocator)
	for c in config.groups_of(prefs) { append(&cats, c) }
	out := make([]Page_Info, len(cats), context.temp_allocator)
	for c, i in cats { out[i] = {category = c, title = config.group_title(prefs, c)} }
	return out
}

// The preferences of a page: its own list (those registered), else its category's; never a hidden one (Def.hidden: the
// program's own).
page_names :: proc(prefs: ^config.Prefs, pg: Page_Info) -> []string {
	if pg.build != nil { return nil }
	if pg.names == nil { return names_of(prefs, pg.category) }
	out := make([dynamic]string, 0, len(pg.names), context.temp_allocator)
	for name in pg.names {
		r, ok := prefs.index[name]
		if ok && !prefs.entries[r].def.hidden { append(&out, name) }
	}
	return out[:]
}

// The names of a category's preferences, in their order in the registry (the order the program declared them in); not the
// hidden ones.
@(private)
names_of :: proc(prefs: ^config.Prefs, category: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for e in prefs.entries {
		path := config.path_of(e.def.name)
		if len(path) > 0 && path[0] == category && !e.def.hidden { append(&out, e.def.name) }
	}
	return out[:]
}

// Builds the page, as large as its parent gives (`next` before it). `prefs` is the registry.
build :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options) {
	em := ui.font_size()
	// (the sidebar's width is the page's own preference: registered at its first build)
	if config.ref_of(prefs, SIDEBAR_PREF) == config.NO_REF { config.register(prefs, SIDEBAR_DEFS[:]) }
	p.prefs, p.state, p.changed, p.user = prefs, ui.current_state(), o.changed, o.user
	p.diagnostics.host, p.diagnostics.version = o.diagnostics, o.version
	p.number_typed = false
	pages := pages_of(prefs, o, p)
	if len(pages) == 0 { return }
	cur := 0
	for pg, i in pages { if pg.category == p.current { cur = i } }
	// (Windows would take the very keys a field records: the shortcuts let them go meanwhile)
	if o.shortcuts != nil && len(o.shortcut_prefs) > 0 { shortcuts.hold(o.shortcuts, ui.hotkey_recording()) }
	config.search_begin(&p.search, ui.line_edit_string(&p.query))
	if ui.row(.Start, {.Draw_Background}, "###prefs_page") {
		total := ui.parent_box().size.x
		narrow := total > 0 && total < em * NARROW_EM
		icons := narrow && o.icon_font != 0
		hi: f32 = NAV_MAX_EM
		if total > 0 { hi = clamp(total / em * NAV_SHARE_MAX, NAV_MIN_EM, NAV_MAX_EM) }
		// (as wide as its longest page title in the language in use, up to `hi`: past that a title wraps, never cut. The
		// person's width is kept when it is wider; the handle does not go under it)
		lo := clamp(nav_need_em(pages, o, em), NAV_MIN_EM, hi)
		width := p.nav_moving ? p.nav_em : f32(config.float_of(prefs, SIDEBAR_PREF))
		width = clamp(width, lo, hi)
		nav(p, pages, cur, o, icons, icons ? NAV_ICONS_EM : width, em)
		if icons {
			ui.next({width = ui.px(max(2, math.round(2 * ui.scale()))), height = ui.fill(), bg = ui.color("border")})
			ui.build_box({.Draw_Background, .Groove}, "###prefs_div")
		} else {
			size := width
			res := ui.splitter("###prefs_split", .X, &size, lo, hi, {default_size = max(NAV_EM, lo), unit = em, flush = true})
			if res.changed { p.nav_em = size; p.nav_moving = true }
			if p.nav_moving && (res.finished || !res.dragging) {
				p.nav_moving = false
				// (written once, when the handle is let go: the file is not rewritten at the pointer's rate)
				_ = config.set_from_string(prefs, SIDEBAR_PREF, fmt.tprintf("%v", p.nav_em), .User)
			}
		}
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###prefs_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###prefs_margins") {
				ui.spacer(ui.px(em * MARGIN_EM))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column(id = "###prefs_body") {
					ui.spacer(ui.px(em * 1.1))
					if config.searching(&p.search) {
						page_title(i18n.tr("Search"), em)
						for pg in pages {
							config.search_page(&p.search, pg.title)
							for name in page_names(prefs, pg) { setting(p, prefs, o, name, em) }
						}
						if p.search.found == 0 {
							if ui.tags("weak") {
								ui.next({width = ui.fill(), text_pad = 0})
								ui.paragraph(fmt.tprintf("%s###prefs_none", i18n.tr("No setting matches.")))
							}
						}
					} else {
						pg := pages[cur]
						if pg.build != nil {
							page_title(pg.title, em)
							pg.build(pg.user != nil ? pg.user : o.user, em)
						} else {
							names := page_names(prefs, pg)
							if page_header(pg.title, page_changed(prefs, o, names), o, em) {
								for name in names {
									e := config.entry(prefs, config.ref_of(prefs, name))
									if e.source == .User { reset(p, prefs, o, name) }
								}
							}
							basic := make([dynamic]string, context.temp_allocator)
							advanced := make([dynamic]string, context.temp_allocator)
							for name in names {
								if config.entry(prefs, config.ref_of(prefs, name)).def.advanced { append(&advanced, name) } else { append(&basic, name) }
							}
							sections(p, prefs, o, pg.category, basic[:], em)
							if len(advanced) > 0 { advanced_part(p, prefs, o, pg.category, advanced[:], em) }
							if o.page_foot != nil { o.page_foot(o.user, pg.category, em) }
						}
					}
					ui.spacer(ui.px(em * 1.5))
				}
				ui.spacer(ui.px(em * MARGIN_EM))
			}
		}
	}
}

// The preferences of a page in sections: those of its own group first, then each inner group's under its title, in
// the order their first preference came.
@(private = "file")
sections :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, category: string, names: []string, em: f32) {
	order := make([dynamic]string, context.temp_allocator)
	append(&order, category)
	for name in names {
		g := group_of(name)
		if !slice.contains(order[:], g) { append(&order, g) }
	}
	for g in order {
		first := true
		for name in names {
			if group_of(name) != g { continue }
			if first && g != category { section_heading(config.group_title(prefs, g), g, em) }
			first = false
			setting(p, prefs, o, name, em)
		}
	}
}

// The group a preference is directly in ("" for a name of one segment).
@(private = "file")
group_of :: proc(name: string) -> string {
	path := config.path_of(name)
	return len(path) > 0 ? path[len(path) - 1] : ""
}

@(private = "file")
section_heading :: proc(title, id: string, em: f32) {
	ui.spacer(ui.px(em * 1.2))
	ui.next({width = ui.fill(), height = ui.px(em * 1.6), font_size = math.round(em * 1.02), text_pad = 0})
	ui.label(fmt.tprintf("%s###sec_%s", title, id))
	ui.spacer(ui.px(em * 0.2))
}

// The page's advanced preferences, folded under "Advanced" until a click (the page keeps it open).
@(private = "file")
advanced_part :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, category: string, names: []string, em: f32) {
	open := p.unfolded[category]
	was := open
	ui.spacer(ui.px(em * 0.8))
	if ui.accordion("###advanced", i18n.tr("Advanced"), &open) {
		sections(p, prefs, o, category, names, em)
	}
	if open != was {
		if category in p.unfolded { p.unfolded[category] = open } else { p.unfolded[strings.clone(category)] = open }
	}
}

// The pages: the search above them, each page a button (its icon, its title), the one shown pressed in; at the foot the
// program's version, its settings file, Export and Import. `width`: in ems.
@(private = "file")
nav :: proc(p: ^Page, pages: []Page_Info, cur: int, o: Page_Options, icons: bool, width: f32, em: f32) {
	ui.next({width = ui.px(math.round(em * width)), height = ui.fill(), axis = .Y})
	if ui.column(id = "###prefs_nav") {
		ui.spacer(ui.px(em * 1.1))
		if !icons {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###prefs_search_row") {
				ui.spacer(ui.px(em * 0.7))
				ui.next({width = ui.fill(), height = ui.px(math.round(em * CONTROL_H_EM)), radius = em * 0.45})
				if ui.input_frame("###prefs_search") {
					if o.icon_font != 0 && o.search_icon != "" {
						ui.next({width = ui.px(em * 1.8), height = ui.pct(1), font = o.icon_font, text_align = .Center})
						if ui.tags("weak") { ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###sic", o.search_icon)) }
					} else {
						ui.spacer(ui.px(em * 0.4))
					}
					ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.2})
					if ui.tags("bare") {
						res := ui.line_edit("###prefs_query", &p.query, {placeholder = i18n.tr("Search settings")})
						if p.focus_search { p.focus_search = false; ui.set_focus(res.box.key) }
					}
				}
				ui.spacer(ui.px(em * 0.9))
			}
		}
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###prefs_nav_list") {
			ui.spacer(ui.px(em * 0.6))
			for pg, i in pages {
				if pg.heading != "" && !icons {
					if i > 0 { ui.spacer(ui.px(em * 0.6)) }
					ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
					if ui.row(id = fmt.tprintf("###nh%d", i)) {
						ui.spacer(ui.px(em * NAV_HEADING_LEAD_EM))
						if ui.tags("weak") {
							ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * NAV_HEADING_SIZE), text_pad = 0})
							ui.label(fmt.tprintf("%s###nhl%d", pg.heading, i))
						}
					}
				} else if pg.heading != "" && i > 0 {
					ui.spacer(ui.px(em * 0.6))
				}
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if ui.row(id = fmt.tprintf("###nv%d", i)) {
					ui.spacer(ui.px(em * NAV_LEAD_EM))
					shown := i == cur && !config.searching(&p.search)
					glyph := o.icon_font != 0 ? pg.icon : ""
					line := ui.Button_Options{face = shown ? .Toggled : .Ghost, width = ui.fill(), height = math.round(em * NAV_LINE_HEIGHT_EM), left = true, icon_font = o.icon_font}
					if ui.button(fmt.tprintf("###nav%d", i), icons ? "" : pg.title, glyph, line).clicked {
						delete(p.current)
						p.current = strings.clone(pg.category)
						ui.line_edit_set(&p.query, "")   // (a page chosen: the search is done)
					}
					ui.spacer(ui.px(em * NAV_TRAIL_EM))
				}
				ui.spacer(ui.px(em * 0.2))
			}
		}
		if o.version != "" {
			ui.next({width = ui.fill(), height = ui.px(em * 1.6), axis = .X, cross = .Center})
			if ui.row(id = "###prefs_version") {
				ui.spacer(ui.px(em * (icons ? 0.4 : 0.9)))
				if ui.tags("weak") {
					ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 0.8), text_pad = 0})
					ui.label(fmt.tprintf("%s###version", o.version))
				}
			}
		}
		if !icons { nav_foot(p, o, em) }
		ui.spacer(ui.px(em * 0.6))
	}
}

// A line of the sidebar: as tall as this many font sizes (at least: a title that wraps makes it taller).
@(private = "file") NAV_LINE_HEIGHT_EM :: 2.1
// The sidebar's room beside a page's button: before it, after it (nav's spacers), and before a heading.
@(private = "file") NAV_LEAD_EM :: 0.7
@(private = "file") NAV_TRAIL_EM :: 0.9
@(private = "file") NAV_HEADING_LEAD_EM :: 1.1
@(private = "file") NAV_HEADING_SIZE :: 0.75

// The width, in ems, the sidebar needs to show each page's title and each heading on one line: its pages' buttons as
// button_width measures them, the sidebar's room beside them.
@(private = "file")
nav_need_em :: proc(pages: []Page_Info, o: Page_Options, em: f32) -> f32 {
	need: f32
	for pg in pages {
		need = max(need, em * (NAV_LEAD_EM + NAV_TRAIL_EM) + ui.button_width(pg.title, o.icon_font != 0 && pg.icon != ""))
		if pg.heading != "" {
			need = max(need, em * NAV_HEADING_LEAD_EM + ui.text_width(ui.top_style().font, math.round(em * NAV_HEADING_SIZE), pg.heading))
		}
	}
	return math.ceil(need) / em
}

// The sidebar's foot: the settings file (a click opens it), Export and Import, and what the last of them did.
@(private = "file")
nav_foot :: proc(p: ^Page, o: Page_Options, em: f32) {
	if o.file != "" {
		if p.file_of != o.file {
			delete(p.file_of); delete(p.file_shown)
			p.file_of = strings.clone(o.file)
			p.file_shown = home_short(o.file)
		}
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###prefs_file") {
			ui.spacer(ui.px(em * 0.9))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###prefs_file_col") {
				if link("###prefs_file_link", p.file_shown, i18n.tr("Open the settings file"), em, mono = true) { ui.open(o.file) }
			}
			ui.spacer(ui.px(em * 0.9))
		}
	}
	ui.spacer(ui.px(em * 0.3))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(id = "###prefs_transfer") {
		ui.spacer(ui.px(em * 0.7))
		h := ui.px(math.round(em * 1.7))
		ui.next({width = ui.text_size(em * 0.6), height = h, radius = em * 0.35, font_size = math.round(em * 0.86)})
		export_sig, import_sig: ui.Signal
		if ui.tags("ghost_button") { export_sig = ui.button("prefs_export", i18n.tr("Export…")) }
		ui.a11y_default(export_sig.box, {name = i18n.tr("Export the settings to a file (JSON, TOML, INI or this program's own)")})
		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.text_size(em * 0.6), height = h, radius = em * 0.35, font_size = math.round(em * 0.86)})
		if ui.tags("ghost_button") { import_sig = ui.button("prefs_import", i18n.tr("Import…")) }
		ui.a11y_default(import_sig.box, {name = i18n.tr("Import settings exported by this program")})
		if export_sig.clicked { export_ask(p) }
		if import_sig.clicked { import_ask(p) }
	}
	if p.note != "" {
		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###prefs_note") {
			ui.spacer(ui.px(em * 0.9))
			if ui.tags(p.note_bad ? "bad" : "weak") {
				ui.next({width = ui.fill(), font_size = math.round(em * 0.8), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###note", p.note))
			}
			ui.spacer(ui.px(em * 0.9))
		}
	}
}

// A path with the user's home folder written ~ (owned).
@(private)
home_short :: proc(path: string, allocator := context.allocator) -> string {
	key := ODIN_OS == .Windows ? "USERPROFILE" : "HOME"
	home, ok := os.lookup_env(key, context.temp_allocator)
	if ok && home != "" && len(path) > len(home) && strings.has_prefix(path, home) && (path[len(home)] == '/' || path[len(home)] == '\\') {
		return strings.concatenate({"~", path[len(home):]}, allocator)
	}
	return strings.clone(path, allocator)
}

// Words that act as a link: the theme's link colour, a hand over them, a screen reader's link; they wrap. True when
// clicked. `tip`: what a click does.
@(private)
link :: proc(id, text, tip: string, em: f32, mono := false) -> bool {
	ui.next({width = ui.fill(), height = ui.text_size(), font = mono ? ui.mono_font() : ui.top_style().font, font_size = math.round(em * (mono ? 0.78 : 0.86)), text_pad = 0, fg = ui.color("link"), cursor = .Hand})
	ui.a11y({role = .Link, name = text, description = tip})
	// (a long path wraps: the sidebar is as narrow as the user makes it)
	sig := ui.signal(ui.build_box({.Clickable, .Focusable, .Draw_Focus_Ring, .Draw_Text, .Text_Wrap, .No_Text_Trunc}, fmt.tprintf("%s%s", text, id)))
	if ui.hovered_for(sig) {
		if ui.tooltip() {
			ui.next({width = ui.text_size(em * 0.6), height = ui.px(ui.dense(em * 1.8))})
			ui.label(fmt.tprintf("%s###tip", tip))
		}
	}
	return sig.clicked
}

// Whether a preference of the page is the user's and not its default.
@(private = "file")
page_changed :: proc(prefs: ^config.Prefs, o: Page_Options, names: []string) -> bool {
	for name in names {
		if differs_from_default(prefs, name, is_hotkey(o, name)) { return true }
	}
	return false
}

// Whether the preference holds a key combination: a field that records the keys.
@(private = "file")
is_hotkey :: proc(o: Page_Options, name: string) -> bool {
	if slice.contains(o.hotkeys, name) { return true }
	_, ok := shortcut_of(o, name)
	return ok
}

@(private = "file")
shortcut_of :: proc(o: Page_Options, name: string) -> (id: string, ok: bool) {
	for sp in o.shortcut_prefs { if sp.pref == name { return sp.id, true } }
	return
}

// Whether the preference's control goes under its words, drawn by control_under: the themes' cards, the program's own.
@(private = "file")
is_custom :: proc(o: Page_Options, name: string) -> bool {
	if len(o.themes) > 0 && name == THEME_PREF { return true }
	return o.custom != nil && slice.contains(o.custom_names, name)
}

// The page's title, and while a preference of it is the user's, a button that puts them all back to their defaults.
// True: it was pressed.
@(private = "file")
page_header :: proc(title: string, changed: bool, o: Page_Options, em: f32) -> (restore: bool) {
	ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
	if ui.row(id = "###prefs_head") {
		ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 1.3), text_pad = 0})
		ui.label(fmt.tprintf("%s###prefs_title", title))
		if changed {
			ui.next({width = ui.text_size(em * 0.6), height = ui.px(math.round(em * 1.7)), radius = em * 0.35, font_size = math.round(em * 0.86)})
			sig: ui.Signal
			if ui.tags("ghost_button") { sig = ui.button("restore", i18n.tr("Restore defaults")) }
			ui.a11y_default(sig.box, {name = i18n.tr("Put every setting of this page back to its default")})
			restore = sig.clicked
		}
	}
	ui.spacer(ui.px(em * 0.6))
	return
}

@(private = "file")
page_title :: proc(title: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 2), font_size = math.round(em * 1.3), text_pad = 0})
	ui.label(fmt.tprintf("%s###prefs_title", title))
	ui.spacer(ui.px(em * 0.6))
}

// A preference's line: its title and its description, its control, a reset button while it is not at its default, a
// carved line under it. Nothing when a search hides it; the page's title before its first match in a search.
@(private = "file")
setting :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, name: string, em: f32) {
	show, heading := config.search_shows(&p.search, prefs, name)
	if !show { return }
	if heading != "" {
		ui.spacer(ui.px(em * 0.6))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 1.6), font_size = math.round(em * 0.78), text_pad = 0})
			ui.label(fmt.tprintf("%s###sec_%s", strings.to_upper(heading, context.temp_allocator), heading))
		}
	}
	r := config.ref_of(prefs, name)
	e := config.entry(prefs, r)
	locked := e.source == .Policy || e.source == .Command_Line
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = fmt.tprintf("###set_%s", name)) {
		ui.spacer(ui.px(em * 0.4))
		under := false   // the control goes under the words (a wide choice, the program's own)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###line") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###words") {
				// (a search: its words lit in the title and the description)
				query := ui.line_edit_string(&p.query)
				title := config.title_of(e.def)
				ui.next({width = ui.fill(), height = ui.px(em * 1.5), font_size = math.round(em * 0.92), text_pad = 0})
				ui.matched_label("###t", title, ui.word_ranges(title, query))
				if ui.tags("weak") {
					note := note_of(e)
					ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
					if ranges := ui.word_ranges(note, query); len(ranges) > 0 {
						runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
						ui.match_runs(note, ranges, {}, &runs)
						ui.rich_paragraph("###d", runs[:])
					} else {
						ui.paragraph(fmt.tprintf("%s###d", note))
					}
				}
				ui.spacer(ui.px(em * 0.2))
			}
			ui.spacer(ui.px(em * 0.8))
			if !locked && differs_from_default(prefs, name, is_hotkey(o, name)) {
				if reset_button(o, em) { reset(p, prefs, o, name) }
				ui.spacer(ui.px(em * 0.3))
			}
			// (the line of the last build says the room: a control that leaves the words too little goes under them)
			w, share := control_width(o, e, em)
			line := ui.parent_box()
			room := line.rect.max.x - line.rect.min.x
			inline := w > 0 && (room <= 0 || (w <= room * share && room - w >= em * WORDS_MIN_EM))
			if inline {
				if ui.disabled(locked) { control(p, prefs, o, r, e, em, ui.px(math.round(w))) }
			} else {
				under = true
			}
		}
		if under {
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###under") {
				if ui.disabled(locked) {
					if is_custom(o, name) {
						control_under(p, prefs, o, r, e, em)
					} else {
						ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
						if ui.row(id = "###under_row") { control(p, prefs, o, r, e, em, e.def.kind == .Bool ? ui.px(math.round(em * SWITCH_EM)) : ui.fill()) }
					}
				}
			}
		}
		if f, ok := p.fields[name]; ok && f.error != "" {
			if ui.tags("bad") {
				ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###err", f.error))
			}
		}
		if o.updater != nil && name == (o.update_pref != "" ? o.update_pref : UPDATE_AUTO_PREF) { updater_under(o, em) }
		// (a global shortcut's lines are the toolkit's words of what the system said; the others', the program's)
		said, why: string
		if id, ok := shortcut_of(o, name); ok {
			asked := strings.trim_space(e.value.s)
			st := shortcuts.status(o.shortcuts, id)
			said, why = shortcuts.status_text(asked, st), shortcuts.problem_text(asked, st)
		} else {
			if o.status != nil { said = o.status(o.user, name) }
			if o.problem != nil { why = o.problem(o.user, name) }
		}
		if said != "" {
			if ui.tags("weak") {
				ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###status", said))
			}
		}
		if why != "" {
			if ui.tags("bad") {
				ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###problem", why))
			}
		}
		ui.spacer(ui.px(em * 0.5))
		ui.hline(ui.fill())
		ui.spacer(ui.px(em * 0.3))
	}
}

// The description, and what the reader must know besides: a value the command line or a policy sets, a restart.
@(private = "file")
note_of :: proc(e: ^config.Entry) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, config.description_of(e.def))
	#partial switch e.source {
	case .Command_Line: append(&parts, i18n.tr("Set on the command line for this run."))
	case .Policy:       append(&parts, i18n.tr("Locked by a policy."))
	}
	if e.def.restart { append(&parts, i18n.tr("Takes effect at the next start.")) }
	return strings.join(parts[:], " ", context.temp_allocator)
}

@(private = "file")
reset_button :: proc(o: Page_Options, em: f32) -> bool {
	sz := math.round(em * 1.6)
	if o.icon_font != 0 && o.reset_icon != "" {
		ui.next({width = ui.px(sz), height = ui.px(sz), font = o.icon_font, radius = em * 0.35})
	} else {
		ui.next({width = ui.text_size(em * 0.5), height = ui.px(sz), radius = em * 0.35, font_size = math.round(em * 0.86)})
	}
	label := o.icon_font != 0 && o.reset_icon != "" ? o.reset_icon : i18n.tr("Reset")
	sig: ui.Signal
	if ui.tags("ghost_button") { sig = ui.button("reset", label) }
	ui.a11y_default(sig.box, {name = i18n.tr("Back to the default")})
	if ui.hovered_for(sig) {
		if ui.tooltip() {
			ui.next({width = ui.text_size(em * 0.6), height = ui.px(ui.dense(em * 1.8))})
			ui.label(fmt.tprintf("%s###tip", i18n.tr("Back to the default")))
		}
	}
	return sig.clicked
}

// The width a preference's control asks on its line, and the share of the line it may take at most (a segmented
// choice: WIDE_SHARE); 0: it goes under the words (the themes' cards, the program's own).
@(private = "file")
control_width :: proc(o: Page_Options, e: ^config.Entry, em: f32) -> (w: f32, share: f32) {
	name := e.def.name
	share = 1
	if is_custom(o, name) { return 0, share }
	switch e.def.kind {
	case .Bool: return em * SWITCH_EM, share
	case .String:
		if is_hotkey(o, name) { return em * LIST_EM, share }
		labels, values := choices_of(o, e)
		if len(values) == 0 { return em * FIELD_EM, share }
		if len(values) <= SEGMENTS_MAX {
			widest: f32
			for l in labels { widest = max(widest, ui.text_width(ui.top_style().font, em, l)) }
			return f32(len(labels)) * (widest + em * SEGMENT_PAD_EM), WIDE_SHARE
		}
		return em * LIST_EM, share
	case .Int, .Float:
		if is_number(e.def) { return em * NUMBER_EM, share }
		unit: f32 = e.def.unit != "" ? em * 0.4 + ui.text_width(ui.top_style().font, math.round(em * 0.86), i18n.tr(e.def.unit)) : 0
		return em * NUMBER_FIELD_EM + unit, share
	}
	return
}

// The control of a preference, `width` wide: on its line, or under its words when the line has no room.
@(private = "file")
control :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, r: config.Ref, e: ^config.Entry, em: f32, width: ui.Size) {
	name := e.def.name
	h := ui.px(math.round(em * CONTROL_H_EM))
	switch e.def.kind {
	case .Bool:
		v := e.value.b
		ui.next({width = width, height = h})
		ui.a11y({name = config.title_of(e.def)})
		if ui.toggle("###sw", "", &v) { apply(p, prefs, o, name, v ? "true" : "false") }
	case .String:
		if is_hotkey(o, name) {
			hk, _ := platform.hotkey_parse(e.value.s)
			ui.next({width = width, height = h})
			if ui.hotkey_field("###keys", &hk) { apply(p, prefs, o, name, platform.hotkey_text(hk)) }
			return
		}
		labels, values := choices_of(o, e)
		if len(values) == 0 { field(p, prefs, o, r, e, em, width); return }
		sel := -1
		for c, i in values { if c == e.value.s { sel = i } }
		if len(values) <= SEGMENTS_MAX {
			ui.next({width = width, height = h})
			if ui.segmented("###seg", labels, &sel) && sel >= 0 { apply(p, prefs, o, name, values[sel]) }
		} else {
			ui.next({width = width, height = h})
			if sel < 0 { sel = 0 }
			if ui.dropdown("###dd", labels, &sel) { apply(p, prefs, o, name, values[sel]) }
		}
	case .Int, .Float:
		if is_number(e.def) { number(p, prefs, o, r, e, em, width) } else { field(p, prefs, o, r, e, em, width) }
	}
}

// A control under the words: the themes' cards (and the line of the user's themes file), or the program's own
// (Page_Options.custom).
@(private = "file")
control_under :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, r: config.Ref, e: ^config.Entry, em: f32) {
	if len(o.themes) > 0 && e.def.name == THEME_PREF && e.def.kind == .String {
		// (the cards in the version the look shows: appearance.mode's, or the one the program shows for the system's)
		light := o.themes_light
		if config.ref_of(prefs, MODE_PREF) != config.NO_REF {
			#partial switch ui.theme_mode_of(config.string_of(prefs, MODE_PREF)) {
			case .Dark:  light = false
			case .Light: light = true
			}
		}
		if at := theme_cards(o.themes, e.value.s, light, em); at >= 0 {
			apply(p, prefs, o, THEME_PREF, o.themes[at].name)
		}
		if o.themes_file != nil { themes_file_line(p, o.themes_file, em) }
		return
	}
	if o.custom != nil && slice.contains(o.custom_names, e.def.name) { o.custom(o.user, e.def.name, em) }
}

// Under the themes' cards: that one can make one's own, and the file (a click makes it when needed and opens it).
@(private = "file")
themes_file_line :: proc(p: ^Page, tf: ^Themes_File, em: f32) {
	ui.spacer(ui.px(em * 0.2))
	if ui.tags("weak") {
		ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
		ui.paragraph(fmt.tprintf("%s###themes_own", i18n.tr("Make themes of your own: each is a few lines in this file, which explains how. They show here as soon as it is saved.")))
	}
	ui.spacer(ui.px(em * 0.2))
	shown := home_short(tf.path, context.temp_allocator)
	if link("###themes_file", shown, i18n.tr("Open the themes file in the system's editor (made at the first click)"), em, mono = true) && p.state != nil {
		themes_file_open(tf, p.state)
	}
	if tf.error != "" {
		if ui.tags("bad") {
			ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
			ui.paragraph(fmt.tprintf("%s###themes_error", tf.error))
		}
	}
}

// A String preference's choices: its own (their labels, else the values capitalised, in the language in use), or the
// program's.
@(private = "file")
choices_of :: proc(o: Page_Options, e: ^config.Entry) -> (labels, values: []string) {
	if len(e.def.choices) > 0 {
		own := len(e.def.choice_labels) == len(e.def.choices)
		out := make([]string, len(e.def.choices), context.temp_allocator)
		for c, i in e.def.choices { out[i] = i18n.tr(own ? e.def.choice_labels[i] : capitalised(c)) }
		return out, e.def.choices
	}
	if o.choices != nil {
		// (the program's labels are its English, i18n.later: translated here, where they show)
		labels, values = o.choices(o.user, e.def.name)
		out := make([]string, len(labels), context.temp_allocator)
		for l, i in labels { out[i] = i18n.tr(l) }
		return out, values
	}
	return
}

// A value as a label: its first letter upper case, its underscores spaces ("top_right": "Top right").
@(private = "file")
capitalised :: proc(s: string) -> string {
	if s == "" { return s }
	t, _ := strings.replace_all(s, "_", " ", context.temp_allocator)
	if t[0] < 'a' || t[0] > 'z' { return t }
	return strings.concatenate({ascii.upper(t[:1]), t[1:]}, context.temp_allocator)   // (a value: ASCII)
}

// A bounded number is a ui.number (its slider, its field, − and +); the others, and a size in bytes, are fields.
@(private = "file")
is_number :: proc(d: config.Def) -> bool {
	return d.bounded && !d.bytes && d.max > d.min
}

// A float's step: round, and cutting its range in at most a few hundred (0.1, 1, 10...).
@(private = "file")
float_step :: proc(span: f64) -> f64 {
	return math.pow(10, math.ceil(math.log10(span / FLOAT_STEPS_MAX)))
}
@(private = "file") FLOAT_STEPS_MAX :: 200

// A bounded number: ui.number with its slider. A drag is written when it is let go (the file is not rewritten at the
// pointer's rate; while held, the page keeps the value and Page_Options.preview shows it); a key, a click, the wheel, a
// button or what is typed, at once.
@(private = "file")
number :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, r: config.Ref, e: ^config.Entry, em: f32, width: ui.Size) {
	d := e.def
	name := d.name
	held := p.held != "" && p.held == name
	nk := ui.key_from_string(ui.parent_box().key, "###num")
	ui.next({width = width, height = ui.px(math.round(em * CONTROL_H_EM))})
	ui.a11y({name = config.title_of(d)})
	value: f64
	if d.kind == .Int {
		v := held ? int(math.round(p.held_value)) : int(e.value.i)
		ui.number("###num", &v, lo = int(d.min), hi = int(d.max), unit = i18n.tr(d.unit), slider = true)
		value = f64(v)
	} else {
		v := held ? p.held_value : e.value.f
		ui.number("###num", &v, lo = d.min, hi = d.max, step = float_step(d.max - d.min), unit = i18n.tr(d.unit), slider = true)
		value = v
	}
	if ui.focus_key() == ui.key_from_string(nk, "###value") { p.number_typed = true }
	if ui.active_key() == ui.key_from_string(nk, "###slider") {
		moved := !held || value != p.held_value
		if !held { delete(p.held); p.held = strings.clone(name) }
		p.held_value = value
		if moved && o.preview != nil { o.preview(o.user, name, value) }
		return
	}
	if held { delete(p.held); p.held = "" }
	if d.kind == .Int {
		if i64(math.round(value)) != e.value.i { apply(p, prefs, o, name, fmt.tprintf("%d", i64(math.round(value)))) }
	} else if value != e.value.f {
		apply(p, prefs, o, name, fmt.tprintf("%v", value))
	}
}

// A free field, its unit after it: Enter or leaving it applies the text; a refused one says why under the line.
@(private = "file")
field :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, r: config.Ref, e: ^config.Entry, em: f32, width: ui.Size) {
	name := e.def.name
	f, ok := p.fields[name]
	if !ok {
		f = new(Field)
		p.fields[strings.clone(name)] = f
	}
	current := config.value_string(prefs, r)
	typing := f.box != 0 && ui.focus_key() == f.box
	if f.synced != current && !typing { ui.line_edit_set(&f.text, current); delete(f.synced); f.synced = strings.clone(current) }
	numeric := e.def.kind != .String
	// (a number's field: its width less its unit's, which follows it)
	fw := width
	if numeric && e.def.unit != "" && width.kind == .Pixels { fw = ui.px(math.round(em * NUMBER_FIELD_EM)) }
	ui.next({width = fw, height = ui.px(math.round(em * CONTROL_H_EM))})
	ui.a11y({name = config.title_of(e.def)})
	res := ui.line_edit("###field", &f.text)
	f.box = res.box.key
	left := !res.focused && typing   // (the keyboard went elsewhere this frame)
	if res.committed || (left && ui.line_edit_string(&f.text) != current) {
		err := apply(p, prefs, o, name, ui.line_edit_string(&f.text))
		delete(f.error)
		f.error = err
		delete(f.synced); f.synced = ""
	}
	if res.cancelled { delete(f.synced); f.synced = ""; delete(f.error); f.error = "" }
	if numeric && e.def.unit != "" {
		ui.spacer(ui.px(em * 0.4))
		if ui.tags("weak") {
			ui.next({width = ui.text_size(0), height = ui.px(math.round(em * CONTROL_H_EM)), text_pad = 0, font_size = math.round(em * 0.86)})
			ui.label(fmt.tprintf("%s###unit", i18n.tr(e.def.unit)))
		}
	}
}

// Sets a preference from text. "" when it was set; else why not (owned), with what is allowed ("out of range: 1 to 64").
@(private)
apply :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, name, text: string) -> string {
	err := config.set_from_string(prefs, name, text, .User)
	if err == .None {
		if o.changed != nil { o.changed(o.user, name) }
		return ""
	}
	msg := config.set_error_text(err)
	if r := config.ref_of(prefs, name); r != config.NO_REF {
		d := config.entry(prefs, r).def
		unit := d.unit != "" ? strings.concatenate({" ", i18n.tr(d.unit)}, context.temp_allocator) : ""
		num :: proc(v: f64, kind: config.Kind) -> string { return kind == .Int ? fmt.tprintf("%d", i64(v)) : fmt.tprintf("%g", v) }
		#partial switch err {
		case .Out_Of_Range: if d.bounded { msg = fmt.tprintf(i18n.tr("%s: %s to %s%s"), msg, num(d.min, d.kind), num(d.max, d.kind), unit) }
		case .Not_A_Choice: msg = fmt.tprintf("%s: %s", msg, strings.join(d.choices, ", ", context.temp_allocator))
		}
	}
	return strings.clone(msg)
}

@(private)
reset :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, name: string) {
	config.reset(prefs, name)
	if f, ok := p.fields[name]; ok { delete(f.synced); f.synced = ""; delete(f.error); f.error = "" }
	if o.changed != nil { o.changed(o.user, name) }
}

////////////////////////////////
// The themes as cards

@(private = "file")
Card :: struct { colors: ui.Theme_Colors, chosen: bool }

// The themes of `list`, three to a row, each in its own colours (its version `light`): its surface, its name in its
// text, its hues as dots, a ring of its accent around the one named `current`. The index of the one clicked, or -1.
theme_cards :: proc(list: []ui.Theme_Def, current: string, light: bool, em: f32) -> (picked: int) {
	picked = -1
	for row := 0; row < len(list); row += CARDS_PER_ROW {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = fmt.tprintf("###themes%d", row)) {
			for i in row ..< row + CARDS_PER_ROW {
				if i > row { ui.spacer(ui.px(em * 0.5)) }
				if i >= len(list) { ui.next({width = ui.fill(), height = ui.px(1)}); ui.build_box({}, fmt.tprintf("###th_pad%d", i)); continue }
				t := list[i]
				chosen := ascii.equal_fold(t.name, current)   // (a theme's name: what programs store)
				ui.next({width = ui.fill(), height = ui.px(math.round(em * CARD_H_EM)), axis = .Y, cursor = .Hand})
				ui.a11y({role = .Radio_Button, name = t.name, toggled = chosen ? .True : .False})
				b := ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###th%d", i))
				d := ui.frame_new(Card)
				d.colors, _ = ui.theme_version(t, light)
				d.chosen = chosen
				b.custom, b.custom_user = card_draw, d
				if ui.signal(b).clicked && !chosen { picked = i }
				if ui.parent(b) {
					ui.spacer(ui.px(em * 0.55))
					ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
					if ui.row(id = "###n") {
						ui.spacer(ui.px(em * 0.8))
						ui.next({width = ui.fill(), height = ui.px(em * 1.4), font_size = math.round(em * 0.92), fg = draw.hex(d.colors.texts[2]), text_pad = 0})
						ui.label(fmt.tprintf("%s###t", t.name))
					}
				}
			}
		}
		ui.spacer(ui.px(em * 0.5))
	}
	return
}

@(private = "file")
card_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Card)(user)
	t := d.colors
	r := b.rect
	s := ui.scale()
	px := max(1, math.round(s))
	radius := math.round(CARD_RADIUS_PX * s)
	draw.rect(dc, r, draw.hex(t.steps[3] | 0xff), radius)
	accent := draw.hex(t.hues[0])
	edge := d.chosen ? accent : draw.mix(draw.hex(t.steps[5]), draw.hex(t.texts[1]), 0.35 * b.hot_t)
	draw.rect(dc, r, edge, radius, d.chosen ? 2 * px : px)
	// its hues as dots along the bottom: the accent first, larger
	em := ui.font_size()
	dot := math.round((r.max.y - r.min.y) * 0.16)
	x := r.min.x + math.round(0.8 * em)
	y := r.max.y - math.round(0.55 * em) - dot
	prev := draw.set_circular_corners(dc, true)
	defer draw.set_circular_corners(dc, prev)
	for h, i in t.hues {
		sz := i == 0 ? dot * 1.4 : dot
		cy := y + dot * 0.5
		draw.rect(dc, {{x, cy - sz * 0.5}, {x + sz, cy + sz * 0.5}}, draw.hex(h | 0xff), sz * 0.5)
		x += sz + math.round(dot * 0.45)
	}
}


// The Updater's state, in words, and what can be done with it.
@(private = "file")
updater_under :: proc(o: Page_Options, em: f32) {
	st := update.status(o.updater)
	if ui.tags("weak") {
		ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
		ui.paragraph(fmt.tprintf("%s###update_state", update.status_words(st)))
	}
	if st.phase == .Managed { return }
	ui.spacer(ui.px(em * 0.4))
	ui.next({height = ui.children_sum()})
	if ui.row() {
		busy := st.phase == .Checking || st.phase == .Downloading || st.phase == .Installed
		if ui.button("update_check", i18n.tr("Check now"), lucide.REFRESH_CW, {disabled = busy, icon_font = ui.lucide_icons(), intent = .Primary}).clicked && !busy {
			update.check_now(o.updater)
		}
		if st.phase == .Available {
			ui.spacer(ui.px(em * 0.5))
			if ui.button("update_install", fmt.tprintf(i18n.tr("Install %s"), st.version), lucide.DOWNLOAD, {icon_font = ui.lucide_icons(), intent = .Success}).clicked {
				update.install_now(o.updater)
			}
		}
		if st.phase == .Installed && o.restart != nil {
			ui.spacer(ui.px(em * 0.5))
			if ui.button("update_restart", i18n.tr("Restart now"), lucide.POWER, {icon_font = ui.lucide_icons(), intent = .Success}).clicked { o.restart(o.user) }
		}
	}
}

// For a program's status bar: what its Updater has to say now, as a button the user acts on there: "Install 0.16.0"
// when a version is on offer, "Downloading 0.16.0…" while it comes, "Restart to update to 0.16.0" once it is in place
// (`restart`: the program starts again). Nothing when there is nothing to do; true when it built something. Its height
// is the caller's (`next`), its width its words'.
update_badge :: proc(u: ^update.Updater, restart: proc(user: rawptr), user: rawptr) -> bool {
	if u == nil { return false }
	em := ui.font_size()
	st := update.status(u)
	words, glyph: string
	#partial switch st.phase {
	case .Available:   words, glyph = fmt.tprintf(i18n.tr("Install %s"), st.version), lucide.DOWNLOAD
	case .Downloading: words = fmt.tprintf(i18n.tr("Downloading %s…"), st.version)
	case .Installed:   words, glyph = fmt.tprintf(i18n.tr("Restart to update to %s"), st.version), lucide.POWER
	case:              return false
	}
	if st.phase == .Downloading {
		ui.next_merge({width = ui.text_size(em * 0.6), font_size = math.round(em * 0.88), text_align = .Center})
		if ui.tags("weak") { ui.label(fmt.tprintf("%s###update_badge", words)) }
		return true
	}
	ui.next_merge({font_size = math.round(em * 0.88)})
	if ui.button("update_badge", words, glyph, {icon_font = ui.lucide_icons(), intent = .Success}).clicked {
		if st.phase == .Available { update.install_now(u) } else if restart != nil { restart(user) }
	}
	return true
}
