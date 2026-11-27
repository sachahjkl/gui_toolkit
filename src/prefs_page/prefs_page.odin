// Package prefs_page: a program's settings, built from its preferences (gt:config) with no code per preference, in the
// look of opencode native's settings.
//
//   * On the left, a sidebar the mouse resizes (its width kept: prefs_page.sidebar_width): its fold button and the search
//     in a well, then the pages (a page is a top group of the registry: its title and its icon from Page_Options.pages),
//     the one shown pressed in; at its foot, the program's version, the settings file (a click opens it) and Export /
//     Import. It folds to a rail (ui.Side_Panel, src/md/features/side-panels.md; its fold kept: prefs_page.sidebar_fold)
//     when it leaves the page less than BODY_MIN_EM, or by its fold button: a magnifier, the pages' icons, a "…" menu
//     with the foot.
//   * On the right: the page's title, then a line per preference: its title and its description on the left, its
//     control on the right (a switch, a segmented choice or a list, a number, a field with its unit), a reset button
//     while it is not at its default, a carved line between two lines of a group. A control the line has no room for goes under the words.
//     The preferences of an inner group (appearance.text) follow under its title; the advanced ones (Def.advanced) of
//     the page under "Advanced", folded until a click. A page of advanced ones alone shows them, under a sentence that
//     says they are technical (a fold would leave the page empty). A standard group whose title does not say what it is
//     for has a sentence under it (group_intro).
//   * While a search is typed: what matches in every page, under each page's title (config.Search).
//
// A preference's control comes from its value, in one table (controls.odin: control_of): its storage, its value kind
// (config.Value_Kind), its choices; never its name. A family is a font picker (its default the program's face:
// standard_face_of; standard_watch applies a choice live), a Theme the program's themes as cards (Page_Options.themes,
// and the user's themes file: Page_Options.themes_file), Keys a recorder (Page_Options.shortcut_prefs adds what the
// system said of a global shortcut), a Color a swatch that opens the colour picker in a popover. A preference can get a control of
// the program's own (Page_Options.custom). A program shows the page in place of its main view with back_bar and
// escape_leaves; setting_line draws one preference's line anywhere.
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
	// other words the palette finds the page by: a page with `build` and tags is an item of the settings source
	// (palette_settings_add), which shows it (the toolkit's Installation and Diagnostics pages have theirs)
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
	// the preferences with a control of the program's own, under their words, and that control (`custom`)
	custom_names: []string,
	// what the program has to say under a preference's line ("" nothing): a shortcut another program holds... (in red)
	problem:   proc(user: rawptr, name: string) -> string,
	// what the program says of a preference's state under its line, plainly ("" nothing): the keys a shortcut got
	status:    proc(user: rawptr, name: string) -> string,
	// what the program shows under a page's preferences (not in a search): its own buttons, a list
	page_foot: proc(user: rawptr, category: string, em: f32),
	custom:    proc(user: rawptr, name: string, em: f32),
	// the program's Updater (gt:update): under the line of update_pref ("": update.auto), its state and its buttons
	// (Check now; Install when a version is on offer; Restart now, by `restart`, when one is installed: the program's
	// procedure calls host.restart_after_exit, then quits)
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
	// the program's themes: a Theme preference shows as their cards (theme_cards), in the version appearance.mode asks
	// (nil: a Theme is a field, or the program's custom control); when it asks the system's, themes_light says which
	// version the program shows now (its ui.Theme_Shown.light: the page does not ask the system each frame)
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
	// the toolkit's own pages, after the program's: the licence (licence.odin: its state, Buy, a key, a file, Remove),
	// the installation (install.odin: the state, Install, Repair, Uninstall) and the diagnostics of the window the
	// settings are in (diagnostics.odin: its graphics adapter, its frame times, the versions, with a Copy button; a
	// host's window: diagnostics_of). nil (licence, install), no renderer (diagnostics): not shown
	licence:     ^Licence,
	install:     ^Install,
	diagnostics: Diagnostics_Source,
	// the program's changelog (changelog.odin): a What's new page, first of the toolkit's own (nil: not shown)
	changelog:   ^Changelog,
	// the program's views (panels.odin): the page "window" shows how far its frame's bottom panel goes across, and its
	// top panel's (views.md, section 6.1b); the choice is kept with the layout, not in the settings file (nil: not shown)
	views:       ^ui.Views,
}

// The page's state, kept by the program between frames (destroy). Keep it as long as the ui.State it is built in: the
// answers of its tasks (an export written, an import read) come in that state's builds.
Page :: struct {
	query:        ui.Line_Edit,
	current:      string,   // the category shown (owned; "": the first page)
	focus_search: bool,
	search:       config.Search,
	// the search `show` put in the field (owned; "": none, or the person's own search) and the page shown before it
	// (owned). A build that follows a gap (the settings were closed) puts that page back and clears that search: the
	// program's jump was for that one visit. The person's own search stays, as the last page does
	placed:       string,
	placed_over:  string,
	placed_new:   bool,   // `show` ran since the last build: the gap before this build is the opening, not a close
	last_build:   u64,    // the ui.State's build_index at the page's last build
	lines_build:  u64,    // the build of setting_line's last line (lines without the page)
	fields:       map[string]^Field,   // the free fields' text while typed
	// the number held by its slider (its preference's name, owned; "": none) and where it is: the value is written when
	// the slider is let go (not at the pointer's rate), the page shows it meanwhile
	held:         string,
	held_value:   f64,
	number_typed: bool,                // a number's field had the keyboard at the last build (editing)
	unfolded:     map[string]bool,     // the pages whose Advanced part is open (keys owned)
	// the sidebar (side-panels.md): its width (ems; the preference's, but while its handle moves) and its fold (the
	// preference's, read at each build)
	side:         ui.Side_Panel,
	nav_moving:   bool,
	nav_focus:    int,                 // 1 + the page whose button takes the focus at its next build (Up, Down; 0: none)
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
	font_families: ui.Font_Families,   // the families (ui.text_font_source), read at a picker's first opening (shared by the pickers)
	font_pickers:  map[string]^ui.Font_Picker,   // each Font_Family preference's picker, by its name (keys owned)
	// the Color preference whose picker is unfolded (owned; "": none), and that picker
	color_open:   string,
	color:        ui.Color_Pick,
	color_build:  u64,      // the build that last drew it
	rule_before:  bool,     // a line was drawn in this group: the next draws the rule between them
	// the preference whose control opens at its next build (owned; "": none): control_open
	opening:      string,
}

@(private)
Field :: struct {
	text:         ui.Line_Edit,
	box:          ui.Key,   // the field's box (last frame)
	synced:       string,   // the value the field was synced to (owned)
	synced_valid: bool,     // false before first sync or after invalidation (Reset)
	was_focused:  bool,     // whether the field had focus at the end of its last build
	dirty:        bool,     // the user edited `text` since the last sync, commit or cancel
	seen_build:   u64,      // ui.State.build_index at the field's last build
	error:        string,   // why the last text was refused (owned)
}

// Commits any free field with pending edited text to the registry the page was last built with (and notifies
// Page_Options.changed). Call before hiding, saving, closing or destroying the page while `prefs` and `user` are alive.
flush :: proc(p: ^Page) {
	if p == nil || p.prefs == nil { return }
	flush_all(p, p.prefs, {user = p.user, changed = p.changed})
}

destroy :: proc(p: ^Page) {
	ui.line_edit_destroy(&p.query)
	delete(p.current)
	delete(p.held)
	delete(p.placed)
	delete(p.placed_over)
	for k, f in p.fields { ui.line_edit_destroy(&f.text); delete(f.synced); delete(f.error); free(f); delete(k) }
	delete(p.fields)
	for k in p.unfolded { delete(k) }
	delete(p.unfolded)
	diagnostics_destroy(&p.diagnostics)
	for k, fp in p.font_pickers { ui.font_picker_destroy(fp); free(fp); delete(k) }
	delete(p.font_pickers)
	ui.font_families_destroy(&p.font_families)
	delete(p.color_open)
	ui.color_pick_destroy(&p.color)
	delete(p.opening)
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
	for _, fp in p.font_pickers { if fp.open { return true } }   // (its Escape closes it)
	// (the colour picker's too, while its line is built: another page shown leaves it closed for Escape)
	if p.color_open != "" && p.state != nil && p.color_build + 1 >= p.state.build_index { return true }
	k := ui.focus_key()
	if k == 0 { return false }
	for _, f in p.fields { if f.box == k { return true } }
	return false
}

// Whether Escape leaves the settings shown in place of the program's main view: it was pressed, and no editor of a
// preference has the keyboard (that Escape is the editor's). A program with its own dialogs open asks only when none is.
escape_leaves :: proc(p: ^Page) -> bool {
	// (editing first: an editor's Escape is left for it, not taken here)
	leave := !editing(p) && ui.key_press(.Escape)
	if leave { flush(p) }
	return leave
}

// A bar above the page shown in place of the main view: a back arrow (Lucide's in Page_Options.icon_font, else the word),
// whose tooltip is `back_tip` ("Back to the history (Escape)"), then `title`; as wide as its parent, 2.6 ems high. True
// when the arrow was pressed. `p`: the page it leaves.
back_bar :: proc(p: ^Page, o: Page_Options, title, back_tip: string, em: f32) -> (back: bool) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.6)), axis = .X, cross = .Center})
	if ui.row(id = "###prefs_back_bar") {
		ui.space(ui.SPACE_2)
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
		if back { flush(p) }
		ui.space(ui.ICON_GAP)
		ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 1.05), text_pad = 0})
		ui.label(fmt.tprintf("%s###prefs_back_title", title))
	}
	return
}

// Sizes, in ems: the sidebar (its default, least and most width, and the share of the page it may take), its rail
// (folded, side-panels.md), the least a page keeps beside the open sidebar (under it the sidebar folds), a control's
// height, the least width of the words beside a control, the share of its line past which a segmented choice goes under
// its words, a theme's card. (The gaps are the toolkit's scale: ui.PAGE_MARGIN and the other roles.)
@(private = "file") NAV_EM          :: 14
@(private = "file") NAV_MIN_EM      :: 9
@(private = "file") NAV_MAX_EM      :: 30
@(private = "file") NAV_SHARE_MAX   :: 0.5
RAIL_EM     :: 3.5
BODY_MIN_EM :: 26
@(private = "file") WORDS_MIN_EM    :: 12
@(private) WIDE_SHARE      :: 0.45
@(private) NUMBER_EM       :: 15
@(private) LIST_EM         :: 13
@(private) FIELD_EM        :: 15
@(private) NUMBER_FIELD_EM :: 9
@(private) SWITCH_EM       :: 3.6
@(private = "file") CARD_H_EM       :: 3.6
@(private = "file") CARD_RADIUS_PX  :: 8
@(private = "file") CARDS_PER_ROW   :: 3

// The sidebar's width, in ems, and its fold (ui.side_fold_format: "folded narrow", ""): the page's own state, kept with
// the settings (hidden: no page shows them).
SIDEBAR_PREF :: "prefs_page.sidebar_width"
SIDEBAR_FOLD_PREF :: "prefs_page.sidebar_fold"

@(private = "file", rodata)
SIDEBAR_DEFS := [?]config.Def{
	{name = SIDEBAR_PREF, description = "The width of the settings' sidebar, in ems.", kind = .Float, default = {f = NAV_EM},
		bounded = true, min = NAV_MIN_EM, max = NAV_MAX_EM, hidden = true},
	{name = SIDEBAR_FOLD_PREF, description = "Whether the settings' sidebar is folded to its rail, and on which side of its threshold.",
		kind = .String, hidden = true},
}

// The pages of `o`, or each category of the registry by name; then the toolkit's own (Page_Options.changelog, licence, install,
// diagnostics). `p`: the page being built (its Diagnostics page's state; nil for the palette).
@(private)
pages_of :: proc(prefs: ^config.Prefs, o: Page_Options, p: ^Page = nil) -> []Page_Info {
	out := program_pages_of(prefs, o)
	if o.changelog == nil && o.licence == nil && o.install == nil && o.diagnostics.renderer == nil { return out }
	all := make([dynamic]Page_Info, 0, len(out) + 3, context.temp_allocator)
	append(&all, ..out)
	if o.changelog != nil {
		pg := changelog_page_info(o.changelog)
		pg.title = i18n.tr(pg.title)
		append(&all, pg)
	}
	if o.licence != nil {
		pg := licence_page_info(o.licence)
		pg.title = i18n.tr(pg.title)
		append(&all, pg)
	}
	if o.install != nil {
		pg := install_page_info(o.install)
		pg.title = i18n.tr(pg.title)
		append(&all, pg)
	}
	if o.diagnostics.renderer != nil {
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
	now := p.state.build_index
	defer flush_unseen(p, prefs, o, now)
	p.diagnostics.source, p.diagnostics.version = o.diagnostics, o.version
	p.number_typed, p.rule_before = false, false
	placed_drop(p)
	pages := pages_of(prefs, o, p)
	if len(pages) == 0 { return }
	cur := 0
	for pg, i in pages { if pg.category == p.current { cur = i } }
	// (Windows would take the very keys a field records: the shortcuts let them go meanwhile)
	if o.shortcuts != nil && len(o.shortcut_prefs) > 0 { shortcuts.hold(o.shortcuts, ui.hotkey_recording()) }
	config.search_begin(&p.search, ui.line_edit_string(&p.query))
	if ui.row(.Start, {.Draw_Background}, "###prefs_page") {
		// (the split's width at the last layout: the fold does not change it, side-panels.md)
		total := ui.parent_box().size.x
		hi: f32 = NAV_MAX_EM
		if total > 0 { hi = clamp(total / em * NAV_SHARE_MAX, NAV_MIN_EM, NAV_MAX_EM) }
		// (as wide as its longest page title in the language in use, up to `hi`: past that a title wraps, never cut. The
		// person's width is kept when it is wider; the handle does not go under it)
		lo := clamp(nav_need_em(pages, o, em), NAV_MIN_EM, hi)
		if !p.nav_moving { p.side.width = f32(config.float_of(prefs, SIDEBAR_PREF)) }
		p.side.fold, _ = ui.side_fold_parse(config.string_of(prefs, SIDEBAR_FOLD_PREF))
		so := ui.Side_Panel_Options{unit = em, default_width = max(NAV_EM, lo), min_width = lo, max_width = hi, rail = RAIL_EM,
			content_min = BODY_MIN_EM, flush = true}
		width, folded, crossed := ui.side_panel_begin(&p.side, total, so)
		if crossed { fold_save(p, prefs) }
		nav(p, prefs, pages, cur, o, folded, width, em)
		h := ui.side_panel_handle("###prefs_split", &p.side, total, so)
		if h.fold_changed { fold_save(p, prefs) }
		if h.changed && !h.fold { p.nav_moving = true }
		if p.nav_moving && (h.finished || !h.dragging) {
			p.nav_moving = false
			// (written once, when the handle is let go: the file is not rewritten at the pointer's rate)
			_ = config.set_from_string(prefs, SIDEBAR_PREF, fmt.tprintf("%v", p.side.width), .User)
		}
		// (.Fits_Width: the body's width is what the sidebar leaves, a split, never its page's (least-width.md); else a
		// wide row of a page pushed the body past the edge of a dialog the settings are shown in)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		ui.push_parent(ui.build_box({.Fits_Width}, "###prefs_share"))
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###prefs_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###prefs_margins") {
				ui.space(ui.PAGE_MARGIN)
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column(id = "###prefs_body") {
					ui.space(PAGE_TOP)
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
							if intro := group_intro(pg.category); intro != "" { page_note(i18n.tr(intro), "prefs_intro", em) }
							if len(basic) == 0 && len(advanced) > 0 {
								// (a page of technical settings alone: a fold would leave it empty, so they show, said as such)
								page_note(i18n.tr("These are technical settings: their defaults are right for most people."), "prefs_technical", em)
								sections(p, prefs, o, pg.category, advanced[:], em)
							} else {
								sections(p, prefs, o, pg.category, basic[:], em)
								if pg.category == PANELS_PAGE { panel_lines(p, o, em) }
								if len(advanced) > 0 { advanced_part(p, prefs, o, pg.category, advanced[:], em) }
							}
							if o.page_foot != nil { o.page_foot(o.user, pg.category, em) }
						}
					}
					ui.space(ui.PAGE_MARGIN)
				}
				ui.space(ui.PAGE_MARGIN)
			}
		}
		ui.pop_parent()   // the body's share
	}
}

// A search `show` placed goes when the settings were closed since (the page was not built at the last build): the
// next opening is a fresh one, on the page the person had. Once the person changed the field, the search is theirs.
@(private = "file")
placed_drop :: proc(p: ^Page) {
	now := p.state != nil ? p.state.build_index : 0
	gap := p.last_build != 0 && p.last_build + 1 < now
	p.last_build = now
	if p.placed == "" { return }
	if ui.line_edit_string(&p.query) != p.placed {
		placed_forget(p)
	} else if gap && !p.placed_new {
		ui.line_edit_clear(&p.query)
		delete(p.current)
		p.current, p.placed_over = p.placed_over, ""
		placed_forget(p)
	}
	p.placed_new = false
}

@(private)
placed_forget :: proc(p: ^Page) {
	delete(p.placed)
	delete(p.placed_over)
	p.placed, p.placed_over, p.placed_new = "", "", false
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
		p.rule_before = false   // (a group's first line has its title above it, no rule)
		for name in names {
			if group_of(name) != g { continue }
			if first && g != category {
				section_heading(config.group_title(prefs, g), g, em)
				if intro := group_intro(g); intro != "" { page_note(i18n.tr(intro), fmt.tprintf("intro_%s", g), em) }
			}
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
	ui.space(ui.GROUP_GAP)
	ui.next({width = ui.fill(), height = ui.px(em * 1.6), font_size = math.round(em * 1.02), text_pad = 0})
	ui.label(fmt.tprintf("%s###sec_%s", title, id))
	ui.space(ui.LINE_GAP)
}

// A sentence in the weak text above a page's or a section's settings. `id`: its key, without "###".
@(private = "file")
page_note :: proc(text, id: string, em: f32) {
	if ui.tags("weak") {
		ui.next({width = ui.fill(), font_size = math.round(em * 0.9), text_pad = 0})
		ui.paragraph(fmt.tprintf("%s###%s", text, id))
	}
	ui.space(ui.LINE_GAP)
}

// The page's advanced preferences, folded under "Advanced" until a click (the page keeps it open). Only on a page that
// has ordinary ones too: a page of advanced ones alone shows them, under a sentence that says they are technical.
@(private = "file")
advanced_part :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, category: string, names: []string, em: f32) {
	open := p.unfolded[category]
	was := open
	ui.space(ui.GROUP_GAP)
	if ui.accordion("###advanced", i18n.tr("Advanced"), &open) {
		sections(p, prefs, o, category, names, em)
	}
	if open != was {
		if category in p.unfolded { p.unfolded[category] = open } else { p.unfolded[strings.clone(category)] = open }
	}
}

// The sidebar (side-panels.md). Open: the fold button and the search in their row, each page a button (its icon, its
// title), the one shown pressed in; at the foot the program's version, its settings file, Export and Import. Folded to
// its rail: the fold button at the same pixel, a magnifier, the pages' icons, a "…" menu with the foot. `width`: frame
// pixels.
@(private = "file")
nav :: proc(p: ^Page, prefs: ^config.Prefs, pages: []Page_Info, cur: int, o: Page_Options, folded: bool, width: f32, em: f32) {
	ui.next({width = ui.px(width), height = ui.fill(), axis = .Y})
	if ui.column(id = "###prefs_nav") {
		ui.space(PAGE_TOP)
		ui.next({width = ui.fill(), height = ui.px(math.round(em * ui.CONTROL_HEIGHT_EM)), axis = .X, cross = .Center})
		if ui.row(id = "###prefs_search_row") {
			// (the fold button's centre on the rail's centre, open and folded: it stays under the pointer that folds)
			ui.spacer(ui.px(fold_lead(em)))
			if ui.side_fold_button("###prefs_fold", folded, false, i18n.tr("Fold the sidebar"), i18n.tr("Open the sidebar")).clicked {
				fold_set(p, prefs, !folded)
			}
			if !folded {
				ui.space(ui.SPACE_1)
				ui.next({width = ui.fill(), height = ui.pct(1), radius = em * 0.45})
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
				ui.space(NAV_SIDE_TRAIL)
			}
		}
		if folded {
			// (the magnifier opens the sidebar with its field focused: the results show in the page, as any search's)
			ui.space(ui.LINE_GAP)
			if rail_button("###prefs_rail_search", lucide.SEARCH, ui.lucide_icons(), i18n.tr("Search settings"), false, em).clicked {
				fold_set(p, prefs, false)
				p.focus_search = true
			}
		}
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###prefs_nav_list") {
			ui.space(ui.LINE_GAP)
			keys := make([]ui.Key, len(pages), context.temp_allocator)
			move := -1
			for pg, i in pages {
				if pg.heading != "" && !folded {
					if i > 0 { ui.space(ui.ITEM_GAP) }
					ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
					if ui.row(id = fmt.tprintf("###nh%d", i)) {
						ui.spacer(ui.px(em * NAV_HEADING_LEAD_EM))
						if ui.tags("weak") {
							ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * NAV_HEADING_SIZE), text_pad = 0})
							ui.label(fmt.tprintf("%s###nhl%d", pg.heading, i))
						}
					}
				} else if pg.heading != "" && i > 0 {
					ui.space(ui.ITEM_GAP)
				}
				shown := i == cur && !config.searching(&p.search)
				sig: ui.Signal
				if folded {
					// (a page with no icon: the first letter of its title, in the page's font)
					glyph, glyph_font := pg.icon, o.icon_font
					if glyph_font == 0 || glyph == "" { glyph, glyph_font = first_letter(pg.title), ui.top_style().font }
					sig = rail_button(fmt.tprintf("###nav%d", i), glyph, glyph_font, pg.title, shown, em)
				} else {
					ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
					if ui.row(id = fmt.tprintf("###nv%d", i)) {
						ui.space(NAV_LEAD_EM)
						glyph := o.icon_font != 0 ? pg.icon : ""
						line := ui.Button_Options{face = .Row, selected = shown, width = ui.fill(), height = math.round(em * NAV_LINE_HEIGHT_EM), left = true, icon_font = o.icon_font}
						sig = ui.button(fmt.tprintf("###nav%d", i), pg.title, glyph, line)
						ui.space(NAV_TRAIL_EM)
					}
				}
				keys[i] = sig.box != nil ? sig.box.key : 0
				if p.nav_focus == i + 1 && sig.box != nil { p.nav_focus = 0; ui.focus_by_keys(sig.box.key) }
				if sig.clicked { page_choose(p, pg) }
				// (Up and Down on a page's button: the page before or after it, the focus with it)
				if sig.focused {
					if ui.key_press(.Up) && i > 0 { move = i - 1 }
					if ui.key_press(.Down) && i + 1 < len(pages) { move = i + 1 }
				}
				ui.space(ui.SPACE_1)
			}
			if move >= 0 {
				page_choose(p, pages[move])
				// (a page before this one was built in this build: its key is known; one after, at its next build)
				if move < len(keys) && keys[move] != 0 { ui.focus_by_keys(keys[move]) } else { p.nav_focus = move + 1 }
			}
		}
		if folded {
			nav_more(p, o, em)
		} else {
			if o.version != "" {
				ui.next({width = ui.fill(), height = ui.px(em * 1.6), axis = .X, cross = .Center})
				if ui.row(id = "###prefs_version") {
					ui.space(NAV_SIDE_TRAIL)
					if ui.tags("weak") {
						ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 0.8), text_pad = 0})
						ui.label(fmt.tprintf("%s###version", o.version))
					}
				}
			}
			nav_foot(p, o, em)
		}
		ui.space(ui.LINE_GAP)
	}
}

// A page chosen in the sidebar: shown, and the search done.
@(private = "file")
page_choose :: proc(p: ^Page, pg: Page_Info) {
	flush(p)
	delete(p.current)
	p.current = strings.clone(pg.category)
	ui.line_edit_set(&p.query, "")
}

// The space before the fold button: its centre on the rail's centre (the button's own side, the toolkit's).
@(private = "file")
fold_lead :: proc(em: f32) -> f32 {
	return math.round((math.round(RAIL_EM * em) - math.round(ui.SIDE_ICON_EM * em)) * 0.5)
}

// A manual fold or opening of the sidebar (it holds until the room next crosses its threshold), saved.
@(private = "file")
fold_set :: proc(p: ^Page, prefs: ^config.Prefs, folded: bool) {
	if ui.side_fold_set(&p.side.fold, folded) { fold_save(p, prefs) }
	if p.state != nil { p.state.anim_busy = true }
}

@(private = "file")
fold_save :: proc(p: ^Page, prefs: ^config.Prefs) {
	_ = config.set_from_string(prefs, SIDEBAR_FOLD_PREF, ui.side_fold_format(p.side.fold), .User)
}

// A square button of the rail, centred in it: a glyph of `font`, its tooltip and accessible name `tip`, lit when
// `selected` (the page shown).
@(private = "file")
rail_button :: proc(id, glyph: string, glyph_font: font.Font_Id, tip: string, selected: bool, em: f32) -> (sig: ui.Signal) {
	side := math.round(em * NAV_LINE_HEIGHT_EM)
	ui.next({width = ui.fill(), height = ui.px(side), axis = .X, cross = .Center})
	if ui.row(id = fmt.tprintf("%s_row", id)) {
		ui.spacer(ui.fill())
		sig = ui.button(id, "", glyph, {face = .Row, selected = selected, width = ui.px(side), height = side, icon_font = glyph_font, tip = tip})
		ui.a11y_default(sig.box, {name = tip})
		ui.spacer(ui.fill())
	}
	return
}

// The first letter of `s` (a page with no icon in the rail).
@(private = "file")
first_letter :: proc(s: string) -> string {
	end := len(s)
	for _, i in s { if i > 0 { end = i; break } }
	return strings.to_upper(s[:end], context.temp_allocator)
}

// The rail's foot: a "…" button whose menu holds what the open sidebar's foot shows: the version, the settings file,
// Export and Import, and what the last of them did.
@(private = "file")
nav_more :: proc(p: ^Page, o: Page_Options, em: f32) {
	MENU :: "###prefs_more_menu"
	sig := rail_button("###prefs_more", lucide.ELLIPSIS, ui.lucide_icons(), i18n.tr("More"), ui.menu_is_open(MENU), em)
	if sig.clicked && sig.box != nil {
		if ui.menu_is_open(MENU) { ui.menu_close() } else { ui.menu_open(MENU, sig.box.rect, sig.box.key) }
	}
	if ui.menu(MENU) {
		if o.version != "" { ui.menu_heading(o.version) }
		if o.file != "" {
			file_short(p, o)
			if ui.menu_item(p.file_shown, icon = lucide.FILE_TEXT, icon_font = ui.lucide_icons()).clicked { ui.open(o.file) }
		}
		if o.version != "" || o.file != "" { ui.menu_separator() }
		if ui.menu_item(i18n.tr("Export…"), icon = lucide.DOWNLOAD, icon_font = ui.lucide_icons()).clicked { export_ask(p) }
		if ui.menu_item(i18n.tr("Import…"), icon = lucide.UPLOAD, icon_font = ui.lucide_icons()).clicked { import_ask(p) }
		if p.note != "" { ui.menu_separator(); ui.menu_heading(p.note) }
	}
}

// Page_Options.file shortened with ~, made again when the file changes.
@(private = "file")
file_short :: proc(p: ^Page, o: Page_Options) {
	if p.file_of == o.file { return }
	delete(p.file_of); delete(p.file_shown)
	p.file_of = strings.clone(o.file)
	p.file_shown = home_short(o.file)
}

// A line of the sidebar: as tall as this many font sizes (at least: a title that wraps makes it taller).
@(private = "file") NAV_LINE_HEIGHT_EM :: 2.1
// Above the page's title and the sidebar's search: the window's own bar is over them, PAGE_MARGIN there leaves too much.
@(private = "file") PAGE_TOP :: ui.SPACE_4
// The sidebar's insets: before a control (the search, a page's row, Export), whose own padding moves its words in;
// after a control, and on both sides of plain words (the version, the file, the note), so they line up with the
// controls' words and keep clear of the splitter's handle.
@(private = "file") NAV_SIDE_LEAD :: ui.SPACE_3
@(private = "file") NAV_SIDE_TRAIL :: ui.SPACE_4
// The sidebar's room beside a page's row: before it, after it (nav's spacers), and before a heading. (Its face is inset
// in it by ui.ROW_FACE_INSET_EM: the face stands where the buttons stood.) A heading's lead puts its words where the
// rows' words start: an alignment, not a gap of the scale.
@(private = "file") NAV_LEAD_EM :: NAV_SIDE_LEAD - ui.ROW_FACE_INSET_EM
@(private = "file") NAV_TRAIL_EM :: NAV_SIDE_TRAIL - ui.ROW_FACE_INSET_EM
@(private = "file") NAV_HEADING_LEAD_EM :: NAV_SIDE_LEAD + 0.4
@(private = "file") NAV_HEADING_SIZE :: 0.75

// The width, in ems, the sidebar needs to show each page's title and each heading on one line, and the search's
// placeholder whole: its pages' buttons as button_width measures them, the sidebar's room beside them; the fold button
// before the search field, the field's glyph, padding and border around its placeholder (nav builds them).
@(private = "file")
nav_need_em :: proc(pages: []Page_Info, o: Page_Options, em: f32) -> f32 {
	glyph := o.icon_font != 0 && o.search_icon != "" ? em * 1.8 : em * 0.4
	border := 2 * max(1, math.round(ui.scale()))
	fold := fold_lead(em) + math.round(ui.SIDE_ICON_EM * em) + em * ui.SPACE_1
	need := fold + em * NAV_SIDE_TRAIL + glyph + 2 * em * 0.2 + border + em * 0.5 +
		ui.text_width(ui.top_style().font, em, i18n.tr("Search settings"))
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
		file_short(p, o)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###prefs_file") {
			ui.space(NAV_SIDE_TRAIL)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###prefs_file_col") {
				if link("###prefs_file_link", p.file_shown, i18n.tr("Open the settings file"), em, mono = true) { ui.open(o.file) }
			}
			ui.space(NAV_SIDE_TRAIL)
		}
	}
	ui.space(ui.LINE_GAP)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(id = "###prefs_transfer") {
		ui.space(NAV_SIDE_LEAD)
		h := ui.px(math.round(em * 1.7))
		ui.next({width = ui.text_size(em * 0.6), height = h, radius = em * 0.35, font_size = math.round(em * 0.86)})
		export_sig, import_sig: ui.Signal
		if ui.tags("ghost_button") { export_sig = ui.button("prefs_export", i18n.tr("Export…")) }
		ui.a11y_default(export_sig.box, {name = i18n.tr("Export the settings to a file (JSON, TOML, INI or this program's own)")})
		ui.space(ui.CONTROL_GAP)
		ui.next({width = ui.text_size(em * 0.6), height = h, radius = em * 0.35, font_size = math.round(em * 0.86)})
		if ui.tags("ghost_button") { import_sig = ui.button("prefs_import", i18n.tr("Import…")) }
		ui.a11y_default(import_sig.box, {name = i18n.tr("Import settings exported by this program")})
		if export_sig.clicked { export_ask(p) }
		if import_sig.clicked { import_ask(p) }
	}
	if p.note != "" {
		ui.space(ui.LINE_GAP)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###prefs_note") {
			ui.space(NAV_SIDE_TRAIL)
			if ui.tags(p.note_bad ? "bad" : "weak") {
				ui.next({width = ui.fill(), font_size = math.round(em * 0.8), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###note", p.note))
			}
			ui.space(NAV_SIDE_TRAIL)
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
		if differs_from_default(prefs, name) { return true }
	}
	return false
}

@(private = "file")
shortcut_of :: proc(o: Page_Options, name: string) -> (id: string, ok: bool) {
	for sp in o.shortcut_prefs { if sp.pref == name { return sp.id, true } }
	return
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
	ui.space(ui.LINE_GAP)
	return
}

@(private = "file")
page_title :: proc(title: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 2), font_size = math.round(em * 1.3), text_pad = 0})
	ui.label(fmt.tprintf("%s###prefs_title", title))
	ui.space(ui.LINE_GAP)
}

// One preference's line, as the page draws it (setting), out of the page: a program's own view of a few settings, the
// showcase's Values. `p` keeps its state (a field's text, an open picker) between builds; `o` the program's data.
setting_line :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, name: string) {
	p.prefs, p.state, p.changed, p.user = prefs, ui.current_state(), o.changed, o.user
	// (build resets it once a build; lines alone do at their first line of a build)
	if now := p.state.build_index; p.lines_build != now { p.lines_build = now; p.number_typed, p.rule_before = false, false }
	setting(p, prefs, o, name, ui.font_size())
}

// A preference's line: its title and its description, its control, a reset button while it is not at its default, a
// carved line above it when a line of its group came before. Nothing when a search hides it; the page's title before its first match in a search.
@(private = "file")
setting :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, name: string, em: f32) {
	show, heading := config.search_shows(&p.search, prefs, name)
	if !show { return }
	if heading != "" {
		ui.space(ui.GROUP_GAP)
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 1.6), font_size = math.round(em * 0.78), text_pad = 0})
			ui.label(fmt.tprintf("%s###sec_%s", strings.to_upper(heading, context.temp_allocator), heading))
		}
		p.rule_before = false
	}
	r := config.ref_of(prefs, name)
	e := config.entry(prefs, r)
	locked := e.source == .Policy || e.source == .Command_Line
	c := control_for(o, e)
	// (the carved line is between two lines of a group: none above the first, none under the last)
	if p.rule_before { ui.hline(ui.fill()) }
	p.rule_before = true
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = fmt.tprintf("###set_%s", name)) {
		// (its act name: the palette's Shift+Enter goes to this line, src/md/features/everything-palette.md)
		ui.act_name(ui.parent_box(), fmt.tprintf("setting:%s", name))
		// (a line of a list: ROW_PAD above its words and under them, the carved line between two)
		ui.space(ui.ROW_PAD)
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
				// (a setting whose title says it all has no description: no empty line under it)
				if note := note_of(e); note != "" {
					if ui.tags("weak") {
						ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
						if ranges := ui.word_ranges(note, query); len(ranges) > 0 {
							runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
							ui.match_runs(note, ranges, {}, &runs)
							ui.rich_paragraph("###d", runs[:])
						} else {
							ui.paragraph(fmt.tprintf("%s###d", note))
						}
					}
				}
			}
			ui.space(ui.CONTROL_GAP)
			if !locked && differs_from_default(prefs, name) {
				if reset_button(o, em) { reset(p, prefs, o, name) }
				ui.space(ui.CONTROL_GAP)
			}
			// (the line of the last build says the room: a control that leaves the words too little goes under them)
			w, share := control_width(o, e, c, em)
			line := ui.parent_box()
			room := line.rect.max.x - line.rect.min.x
			inline := w > 0 && (room <= 0 || (w <= room * share && room - w >= em * WORDS_MIN_EM))
			if inline {
				if ui.disabled(locked) { control(p, prefs, o, r, e, c, em, ui.px(math.round(w))) }
			} else {
				under = true
			}
		}
		if under {
			ui.space(ui.LINE_GAP)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###under") {
				if ui.disabled(locked) {
					if c == .Custom || c == .Theme {
						control_under(p, prefs, o, e, c, em)
					} else {
						ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
						if ui.row(id = "###under_row") { control(p, prefs, o, r, e, c, em, c == .Switch ? ui.px(math.round(em * SWITCH_EM)) : ui.fill()) }
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
		ui.space(ui.ROW_PAD)
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

@(private)
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

// Sets a preference from text. "" when it was set; else why not (owned), with what is allowed ("out of range: 1 to 64").
@(private)
apply :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, name, text: string) -> string {
	text := text
	// (a decimal typed with the language's mark, "1,5": the registry reads "1.5")
	if r := config.ref_of(prefs, name); r != config.NO_REF && config.entry(prefs, r).def.kind == .Float {
		if v, ok := i18n.parse_decimal(text); ok { text = fmt.tprintf("%v", v) }
	}
	err := config.set_from_string(prefs, name, text, .User)
	if err == .None {
		if o.changed != nil { o.changed(o.user, name) }
		return ""
	}
	msg := config.set_error_text(err)
	if r := config.ref_of(prefs, name); r != config.NO_REF {
		d := config.entry(prefs, r).def
		// (the bounds as the value is shown: "1 KiB to 100 MiB", "0 to 90 %")
		bound :: proc(d: config.Def, v: f64) -> string {
			x: config.Value
			if d.kind == .Int { x.i = i64(v) } else { x.f = v }
			return config.shown_text(d, x)
		}
		#partial switch err {
		case .Out_Of_Range: if d.bounded { msg = fmt.tprintf(i18n.tr("%s: %s to %s"), msg, bound(d, d.min), bound(d, d.max)) }
		case .Not_A_Choice: msg = fmt.tprintf("%s: %s", msg, strings.join(d.choices, ", ", context.temp_allocator))
		case .Bad_Type:     if hint := config.value_hint(d); hint != "" { msg = fmt.tprintf("%s: %s", msg, hint) }
		}
	}
	return strings.clone(msg)
}

@(private)
reset :: proc(p: ^Page, prefs: ^config.Prefs, o: Page_Options, name: string) {
	config.reset(prefs, name)
	if f, ok := p.fields[name]; ok { field_invalidate(f) }
	if o.changed != nil { o.changed(o.user, name) }
}

////////////////////////////////
// The themes as cards

@(private = "file")
Card :: struct { colors: ui.Theme_Colors, chosen: bool }

// The themes of `list`, `columns` to a row (all of the same width, a last row that is not full too), each in its own
// colours (its version `light`): its surface, its name in its text, its hues as dots, a ring of its accent around the
// one named `current`. The index of the one clicked, or -1.
theme_cards :: proc(list: []ui.Theme_Def, current: string, light: bool, em: f32, columns := CARDS_PER_ROW) -> (picked: int) {
	picked = -1
	gap := math.round(em * CARDS_GAP)
	n := max(columns, 1)
	for row := 0; row < len(list); row += n {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = fmt.tprintf("###themes%d", row)) {
			for i in row ..< min(row + n, len(list)) {
				// (each column is a cell of exactly 1/N of the row, holding its card and its part of the gaps: column c has
				// c/N of a gap before its card and (N-1-c)/N after, so every card is (row - (N-1) gaps) / N wide, the cards
				// of a last row that is not full too, at their columns. A row of fill() shares and gaps would split its
				// overflow by what each share holds, and a short row's cards would not match the full rows')
				col := i - row
				ui.next({width = ui.pct(1.0 / f32(n)), height = ui.children_sum(), axis = .X})
				if ui.row(id = fmt.tprintf("###thc%d", i)) {
					if col > 0 { ui.spacer(ui.px(gap * f32(col) / f32(n))) }
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
						ui.space(ui.INNER_PAD)
						ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
						if ui.row(id = "###n") {
							ui.space(ui.INNER_PAD)
							ui.next({width = ui.fill(), height = ui.px(em * 1.4), font_size = math.round(em * 0.92), fg = draw.hex(d.colors.texts[2]), text_pad = 0})
							ui.label(fmt.tprintf("%s###t", t.name))
							ui.space(ui.INNER_PAD)
						}
					}
					if after := n - 1 - col; after > 0 { ui.spacer(ui.px(gap * f32(after) / f32(n))) }
				}
			}
		}
		ui.space(CARDS_GAP)
	}
	return
}

// Between two theme cards, across and down: a grid of small tiles, closer than two items of a page.
@(private = "file") CARDS_GAP :: ui.SPACE_2

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
	// (the dots sit INNER_PAD from the card's edges, as its name does)
	x := r.min.x + math.round(ui.INNER_PAD * em)
	y := r.max.y - math.round(ui.INNER_PAD * em) - dot
	prev := draw.set_circular_corners(dc, true)
	defer draw.set_circular_corners(dc, prev)
	for h, i in t.hues {
		sz := i == 0 ? dot * 1.4 : dot
		if x + sz > r.max.x - math.round(ui.INNER_PAD * em) { break }   // (a narrow card shows fewer dots, never dots past its edge)
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
	if st.phase == .Downloading {
		ui.space(ui.LINE_GAP)
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 0.6))})
		ui.progress("###update_progress", update.progress(st), lively = true)
	}
	if st.phase == .Managed || st.phase == .Administered { return }
	ui.space(ui.LINE_GAP)
	// (a width of its own: a row that takes the program's base width, text_size() of no text, is a few pixels wide,
	// and the buttons in it wrap to their widest word though the line has room)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###update_buttons") {
		busy := st.phase == .Checking || st.phase == .Downloading || st.phase == .Installed
		if ui.button("update_check", i18n.tr("Check now"), lucide.REFRESH_CW, {disabled = busy, icon_font = ui.lucide_icons(), intent = .Primary}).clicked && !busy {
			update.check_now(o.updater)
		}
		if st.phase == .Available {
			ui.space(ui.CONTROL_GAP)
			if ui.button("update_install", fmt.tprintf(i18n.tr("Install %s"), st.version), lucide.DOWNLOAD, {icon_font = ui.lucide_icons(), intent = .Success}).clicked {
				update.install_now(o.updater)
			}
		}
		if st.phase == .Installed && o.restart != nil {
			ui.space(ui.CONTROL_GAP)
			if ui.button("update_restart", i18n.tr("Restart now"), lucide.POWER, {icon_font = ui.lucide_icons(), intent = .Success}).clicked { o.restart(o.user) }
		}
	}
}

// For a program's bar: what its Updater has to say now, as a button the user acts on there: "Install 0.16.0" when a
// version is on offer, "Downloading 0.16.0…" while it comes, "Restart to update to 0.16.0" once it is in place
// (`restart`: the program starts again). It is the one place of a program's window that shows the phase: the program's
// status line or toasts say only update.notice. Nothing when there is nothing to do; else its box, whose rect (the last
// layout's) is the room it takes, for a bar that fits its other parts beside it. Its height is the caller's (`next`), its
// width its words'.
//
// One place, three faces, one passing into the next: the button "Install" becomes the bar, which fills from its share as
// the program comes (the button's own green, ui.progress_fill); the bar becomes the button "Restart". The place is a
// ui.swap: its width glides, the button's shape morphs into the bar's well and back, and the words cross.
update_badge :: proc(u: ^update.Updater, restart: proc(user: rawptr), user: rawptr) -> ^ui.Box {
	if u == nil { return nil }
	em := ui.font_size()
	st := update.status(u)
	words, glyph: string
	#partial switch st.phase {
	case .Available:   words, glyph = fmt.tprintf(i18n.tr("Install %s"), st.version), lucide.DOWNLOAD
	case .Downloading: words = fmt.tprintf(i18n.tr("Downloading %s…"), st.version)
	case .Installed:   words, glyph = fmt.tprintf(i18n.tr("Restart to update to %s"), st.version), lucide.POWER
	case:              return nil
	}
	fs := math.round(em * 0.88)
	face_name := st.phase == .Downloading ? "downloading" : st.phase == .Available ? "install" : "restart"
	slot: ^ui.Box
	if ui.swap("###update_badge_slot", face_name) {
		slot = ui.parent_box()
		if st.phase == .Downloading {
			// (as wide as its words with the button's room around them: each face its own width. The share is the fill's:
			// the words do not say it again. It shows the share from its first frame: a bar that started full said "done"
			// before anything came)
			ui.next({width = ui.text_size(em * 0.6), height = ui.fill(), radius = em * ui.shape_of(.Control), font_size = fs, text_align = .Center})
			face := ui.label(fmt.tprintf("%s###update_badge", words)).box
			ui.progress_fill(face, update.progress(st))
		} else {
			natural: f32
			if ui.style({font_size = fs}) { natural = ui.button_width(words, glyph != "") }
			ui.next({width = ui.px(natural), height = ui.fill(), font_size = fs})
			sig := ui.button("update_badge", words, glyph, {icon_font = ui.lucide_icons(), intent = .Success})
			if sig.clicked {
				if st.phase == .Available { update.install_now(u) } else if restart != nil { restart(user) }
			}
		}
	}
	return slot
}
