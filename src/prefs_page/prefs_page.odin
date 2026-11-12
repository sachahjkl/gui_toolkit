// Package prefs_page: a program's settings, built from its preferences (gt:config) with no code per preference, in the
// look of opencode native's settings.
//
//   * On the left: the search in a well, then the pages (a page is a category of the registry: its title and its icon
//     from Options.pages), the one shown pressed in. A narrow page shows their icons alone.
//   * On the right: the page's title, then a line per preference: its title and its description on the left, its
//     control on the right (a switch, a segmented choice or a list, a slider, a field with its unit), a reset button
//     while it is not at its default, a carved line under it.
//   * While a search is typed: what matches in every page, under each page's title (config.Search).
//
// A preference can get a control of the program's own (Options.custom): a font picker. The standard preferences
// (standard.odin) need none: Options.themes shows appearance.theme as cards, Options.shortcut_prefs shows global
// shortcuts with what the system said of them. A program shows the page in place of its main view with back_bar and
// escape_leaves.
//
// A change goes through config.set_from_string at the User layer, so every observer of the registry runs; then
// Options.changed, where the program applies what changed (its loop writes the file: config.user_writer_save).
package tk_prefs_page

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "../ascii"
import config "../config"
import "../draw"
import "../font"
import lucide "../lucide"
import "../platform"
import shortcuts "../shortcuts"
import "../ui"
import update "../update"

// A page: a category of the registry, its title and its icon (a glyph of Options.icon_font; "": none). `names`: the
// preferences it shows, in this order, whatever their category (nil: those of `category`, in the registry's order); a
// program whose pages are not its registry's categories keeps those for its other views (an editor of every preference).
Page_Info :: struct {
	category, title, icon: string,
	names:                 []string,
}

// A global shortcut's preference: `pref` holds its keys (as platform.hotkey_text writes them), `id` is the shortcut's id
// in the program's shortcuts.Service.
Shortcut_Pref :: struct { pref, id: string }

// What a program gives the page.
Options :: struct {
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
	// the program's Updater (gt:update): under the line of update_pref ("update.auto"), its state and its buttons (Check
	// now; Install when a version is on offer; Restart now, by `restart`, when one is installed)
	updater:     ^update.Updater,
	update_pref: string,
	restart:     proc(user: rawptr),
	// the pages in their order (one with no preference is not shown); nil: each category of the registry, by name, its
	// title from config.category_title
	pages:     []Page_Info,
	icon_font: font.Font_Id,   // the font of the pages' icons, and of the two below (0: none, words instead)
	search_icon, reset_icon: string,
	foot:      string,         // a faint line under the pages ("prefs: prefs.txt")
	// the program and its version ("Papier 0.15.0"): a line at the bottom of the pages, above the foot ("" none)
	version:   string,
	// the program's themes: appearance.theme shows as their cards (theme_cards), in the version appearance.mode asks
	// (nil: appearance.theme is a field, or the program's custom control); when it asks the system's, themes_light says
	// which version the program shows now (its ui.Theme_Shown.light: the page does not ask the system each frame)
	themes:       []ui.Theme_Def,
	themes_light: bool,
	// the program's global shortcuts: each preference of shortcut_prefs records keys, and says under its line what the
	// system made of them (shortcuts.status_text, shortcuts.problem_text); while a field records, the page holds the
	// service (shortcuts.hold)
	shortcuts:      ^shortcuts.Service,
	shortcut_prefs: []Shortcut_Pref,
}

// The page's state, kept by the program between frames (destroy).
Page :: struct {
	query:        ui.Text_Field,
	current:      string,   // the category shown (owned; "": the first page)
	focus_search: bool,
	search:       config.Search,
	fields:       map[string]^Field,   // the free fields' text while typed
	// the slider held (its preference's name, owned; "": none) and where it is: ui.slider moves its value only while the
	// button is down, so the value is kept here between frames and written on the release
	held:         string,
	held_value:   f32,
}

@(private)
Field :: struct {
	text:   ui.Text_Field,
	box:    ui.Key,   // the field's box (last frame)
	synced: string,   // the value the field shows (owned)
	error:  string,   // why the last text was refused (owned)
}

destroy :: proc(p: ^Page) {
	ui.field_destroy(&p.query)
	delete(p.current)
	delete(p.held)
	for k, f in p.fields { ui.field_destroy(&f.text); delete(f.synced); delete(f.error); free(f); delete(k) }
	delete(p.fields)
	p^ = {}
}

// Gives the search the keyboard at the next build (a program's Ctrl+, opens the page with it).
focus_search :: proc(p: ^Page) { p.focus_search = true }

// Whether a field of a preference has the keyboard: its Escape is the field's, not the program's.
editing :: proc(p: ^Page) -> bool {
	if ui.hotkey_recording() { return true }   // (its Escape gives the recording up)
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

// A bar above the page shown in place of the main view: a back arrow (Lucide's in Options.icon_font, else the word),
// whose tooltip is `back_tip` ("Back to the history (Escape)"), then `title`; as wide as its parent, 2.6 ems high. True
// when the arrow was pressed. `p`: the page it leaves.
back_bar :: proc(p: ^Page, o: Options, title, back_tip: string, em: f32) -> (back: bool) {
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
		if ui.tags("ghost_button") { sig = ui.button(fmt.tprintf("%s###prefs_back", icon ? lucide.ARROW_LEFT : "Back")) }
		ui.a11y_default(sig.box, {name = back_tip})
		if ui.hovered_for(sig, 0.4) {
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

// Sizes, in ems: the pages' column (with its icons alone, and the page width under which it is), the margins of the
// page, a control's height, a segmented choice's room around its longest label and the share of its line past which it
// goes under its words, a theme's card.
@(private = "file") NAV_EM          :: 14
@(private = "file") NAV_ICONS_EM    :: 4
@(private = "file") NARROW_EM       :: 40
@(private = "file") MARGIN_EM       :: 1.4
@(private = "file") CONTROL_H_EM    :: 2
@(private = "file") SEGMENT_PAD_EM  :: 1.8
@(private = "file") WIDE_SHARE      :: 0.45
@(private = "file") SEGMENTS_MAX    :: 4      // more choices: a list
@(private = "file") SLIDER_STEPS_MAX :: 200   // a bounded number with more steps than this: a field
@(private = "file") CARD_H_EM       :: 3.6
@(private = "file") CARD_RADIUS_PX  :: 8
@(private = "file") CARDS_PER_ROW   :: 3

// The pages of `o`, or each category of the registry by name.
@(private)
pages_of :: proc(prefs: ^config.Prefs, o: Options) -> []Page_Info {
	if o.pages != nil {
		// (a page with no preference in this registry is not shown: a program that registers some only on one system)
		kept := make([dynamic]Page_Info, context.temp_allocator)
		for pg in o.pages { if len(page_names(prefs, pg)) > 0 { append(&kept, pg) } }
		return kept[:]
	}
	cats := make([dynamic]string, context.temp_allocator)
	for e in prefs.entries { if !e.def.hidden && !slice.contains(cats[:], e.def.category) { append(&cats, e.def.category) } }
	slice.sort(cats[:])
	out := make([]Page_Info, len(cats), context.temp_allocator)
	for c, i in cats { out[i] = {category = c, title = config.category_title(c)} }
	return out
}

// The preferences of a page: its own list (those registered), else its category's; never a hidden one (Def.hidden: the
// program's own).
page_names :: proc(prefs: ^config.Prefs, pg: Page_Info) -> []string {
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
	for e in prefs.entries { if e.def.category == category && !e.def.hidden { append(&out, e.def.name) } }
	return out[:]
}

// Builds the page, as large as its parent gives (`next` before it). `prefs` is the registry.
build :: proc(p: ^Page, prefs: ^config.Prefs, o: Options) {
	em := ui.font_size()
	pages := pages_of(prefs, o)
	if len(pages) == 0 { return }
	cur := 0
	for pg, i in pages { if pg.category == p.current { cur = i } }
	// (Windows would take the very keys a field records: the shortcuts let them go meanwhile)
	if o.shortcuts != nil && len(o.shortcut_prefs) > 0 { shortcuts.hold(o.shortcuts, ui.hotkey_recording()) }
	config.search_begin(&p.search, ui.field_string(&p.query))
	if ui.row(.Start, {.Draw_Background}, "###prefs_page") {
		narrow := ui.parent_box().size.x > 0 && ui.parent_box().size.x < em * NARROW_EM
		nav(p, pages, cur, o, narrow, em)
		ui.next({width = ui.px(max(2, math.round(2 * ui.scale()))), height = ui.fill(), bg = ui.color("border")})
		ui.build_box({.Draw_Background, .Groove}, "###prefs_div")
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###prefs_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###prefs_margins") {
				ui.spacer(ui.px(em * MARGIN_EM))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column(id = "###prefs_body") {
					ui.spacer(ui.px(em * 1.1))
					if config.searching(&p.search) {
						page_title("Search", em)
						for pg in pages {
							config.search_page(&p.search, pg.title)
							for name in page_names(prefs, pg) { setting(p, prefs, o, name, em) }
						}
						if p.search.found == 0 {
							if ui.tags("weak") {
								ui.next({width = ui.fill(), text_pad = 0})
								ui.paragraph("No setting matches.###prefs_none")
							}
						}
					} else {
						names := page_names(prefs, pages[cur])
						if page_header(pages[cur].title, page_changed(prefs, o, names), o, em) {
							for name in names {
								e := config.entry(prefs, config.ref_of(prefs, name))
								if e.source == .User { reset(p, prefs, o, name) }
							}
						}
						for name in names { setting(p, prefs, o, name, em) }
						if o.page_foot != nil { o.page_foot(o.user, pages[cur].category, em) }
					}
					ui.spacer(ui.px(em * 1.5))
				}
				ui.spacer(ui.px(em * MARGIN_EM))
			}
		}
	}
}

// The pages: the search above them, each page a button (its icon, its title), the one shown pressed in.
@(private = "file")
nav :: proc(p: ^Page, pages: []Page_Info, cur: int, o: Options, narrow: bool, em: f32) {
	icons := narrow && o.icon_font != 0
	ui.next({width = ui.px(em * (icons ? NAV_ICONS_EM : NAV_EM)), height = ui.fill(), axis = .Y})
	if ui.column(id = "###prefs_nav") {
		ui.spacer(ui.px(em * 1.1))
		if !icons {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###prefs_search_row") {
				ui.spacer(ui.px(em * 0.7))
				ui.next({width = ui.fill(), height = ui.px(math.round(em * CONTROL_H_EM)), radius = em * 0.45})
				if ui.field_frame("###prefs_search") {
					if o.icon_font != 0 && o.search_icon != "" {
						ui.next({width = ui.px(em * 1.8), height = ui.pct(1), font = o.icon_font, text_align = .Center})
						if ui.tags("weak") { ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###sic", o.search_icon)) }
					} else {
						ui.spacer(ui.px(em * 0.4))
					}
					ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.2})
					if ui.tags("bare") {
						res := ui.line_edit("###prefs_query", &p.query, "Search settings")
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
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if ui.row(id = fmt.tprintf("###nv%d", i)) {
					ui.spacer(ui.px(em * 0.7))
					shown := i == cur && !config.searching(&p.search)
					if ui.nav_item(fmt.tprintf("###nav%d", i), icons ? "" : pg.title, pg.icon, o.icon_font, shown, em).clicked {
						delete(p.current)
						p.current = strings.clone(pg.category)
						ui.field_set(&p.query, "")   // (a page chosen: the search is done)
					}
					ui.spacer(ui.px(em * 0.9))
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
			if o.foot == "" || icons { ui.spacer(ui.px(em * 0.6)) }
		}
		if o.foot != "" && !icons {
			ui.next({width = ui.fill(), height = ui.px(em * 1.6), axis = .X, cross = .Center})
			if ui.row(id = "###prefs_foot") {
				ui.spacer(ui.px(em * 0.9))
				if ui.tags("weak") {
					ui.next({width = ui.fill(), height = ui.pct(1), font = ui.mono_font(), font_size = math.round(em * 0.72), text_pad = 0})
					ui.label(fmt.tprintf("%s###foot", o.foot))
				}
			}
			ui.spacer(ui.px(em * 0.6))
		}
	}
}

// Whether a preference of the page is the user's and not its default.
@(private = "file")
page_changed :: proc(prefs: ^config.Prefs, o: Options, names: []string) -> bool {
	for name in names {
		if differs_from_default(prefs, name, is_hotkey(o, name)) { return true }
	}
	return false
}

// Whether the preference holds a key combination: a field that records the keys.
@(private = "file")
is_hotkey :: proc(o: Options, name: string) -> bool {
	if slice.contains(o.hotkeys, name) { return true }
	_, ok := shortcut_of(o, name)
	return ok
}

@(private = "file")
shortcut_of :: proc(o: Options, name: string) -> (id: string, ok: bool) {
	for sp in o.shortcut_prefs { if sp.pref == name { return sp.id, true } }
	return
}

// Whether the preference's control goes under its words, drawn by control_under: the themes' cards, the program's own.
@(private = "file")
is_custom :: proc(o: Options, name: string) -> bool {
	if len(o.themes) > 0 && name == THEME_PREF { return true }
	return o.custom != nil && slice.contains(o.custom_names, name)
}

// The page's title, and while a preference of it is the user's, a button that puts them all back to their defaults.
// True: it was pressed.
@(private = "file")
page_header :: proc(title: string, changed: bool, o: Options, em: f32) -> (restore: bool) {
	ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
	if ui.row(id = "###prefs_head") {
		ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 1.3), text_pad = 0})
		ui.label(fmt.tprintf("%s###prefs_title", title))
		if changed {
			ui.next({width = ui.text_size(em * 0.6), height = ui.px(math.round(em * 1.7)), radius = em * 0.35, font_size = math.round(em * 0.86)})
			sig: ui.Signal
			if ui.tags("ghost_button") { sig = ui.button("Restore defaults###restore") }
			ui.a11y_default(sig.box, {name = "Put every setting of this page back to its default"})
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
setting :: proc(p: ^Page, prefs: ^config.Prefs, o: Options, name: string, em: f32) {
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
				query := ui.field_string(&p.query)
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
			if ui.disabled(locked) { under = !control(p, prefs, o, r, e, em) }
		}
		if under {
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###under") {
				if ui.disabled(locked) { control_under(p, prefs, o, r, e, em) }
			}
		}
		if f, ok := p.fields[name]; ok && f.error != "" {
			if ui.tags("bad") {
				ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###err", f.error))
			}
		}
		if o.updater != nil && name == o.update_pref { updater_under(o, em) }
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
	append(&parts, e.def.description)
	#partial switch e.source {
	case .Command_Line: append(&parts, "Set on the command line for this run.")
	case .Policy:       append(&parts, "Locked by a policy.")
	}
	if e.def.restart { append(&parts, "Takes effect at the next start.") }
	return strings.join(parts[:], " ", context.temp_allocator)
}

@(private = "file")
reset_button :: proc(o: Options, em: f32) -> bool {
	sz := math.round(em * 1.6)
	if o.icon_font != 0 && o.reset_icon != "" {
		ui.next({width = ui.px(sz), height = ui.px(sz), font = o.icon_font, radius = em * 0.35})
	} else {
		ui.next({width = ui.text_size(em * 0.5), height = ui.px(sz), radius = em * 0.35, font_size = math.round(em * 0.86)})
	}
	label := o.icon_font != 0 && o.reset_icon != "" ? o.reset_icon : "Reset"
	sig: ui.Signal
	if ui.tags("ghost_button") { sig = ui.button(fmt.tprintf("%s###reset", label)) }
	ui.a11y_default(sig.box, {name = "Back to the default"})
	if ui.hovered_for(sig, 0.4) {
		if ui.tooltip() {
			ui.next({width = ui.text_size(em * 0.6), height = ui.px(ui.dense(em * 1.8))})
			ui.label("Back to the default###tip")
		}
	}
	return sig.clicked
}

// The control of a preference, on its line. False when it goes under the words instead (control_under draws it then).
@(private = "file")
control :: proc(p: ^Page, prefs: ^config.Prefs, o: Options, r: config.Ref, e: ^config.Entry, em: f32) -> bool {
	name := e.def.name
	if is_custom(o, name) { return false }   // (under the words: control_under)
	switch e.def.kind {
	case .Bool:
		v := e.value.b
		ui.next({width = ui.px(em * 3.6), height = ui.px(math.round(em * CONTROL_H_EM))})
		ui.a11y({name = config.title_of(e.def)})
		if ui.toggle("###sw", "", &v).clicked { apply(p, prefs, o, name, v ? "true" : "false") }
	case .String:
		if is_hotkey(o, name) {
			hk, _ := platform.hotkey_parse(e.value.s)
			ui.next({width = ui.px(em * 13), height = ui.px(math.round(em * CONTROL_H_EM))})
			if ui.hotkey_field("###keys", &hk) { apply(p, prefs, o, name, platform.hotkey_text(hk)) }
			return true
		}
		labels, values := choices_of(o, e)
		if len(values) == 0 { field(p, prefs, o, r, e, em); return true }
		sel := -1
		for c, i in values { if c == e.value.s { sel = i } }
		if len(values) <= SEGMENTS_MAX {
			widest: f32
			for l in labels { widest = max(widest, ui.text_width(ui.top_style().font, em, l)) }
			w := f32(len(labels)) * (widest + em * SEGMENT_PAD_EM)
			line := ui.parent_box()
			if room := line.rect.max.x - line.rect.min.x; room > 0 && w > room * WIDE_SHARE { return false }
			ui.next({width = ui.px(math.round(w)), height = ui.px(math.round(em * CONTROL_H_EM))})
			if ui.segmented("###seg", labels, &sel) && sel >= 0 { apply(p, prefs, o, name, values[sel]) }
		} else {
			ui.next({width = ui.px(em * 13), height = ui.px(math.round(em * CONTROL_H_EM))})
			if sel < 0 { sel = 0 }
			if ui.dropdown("###dd", labels, &sel) { apply(p, prefs, o, name, values[sel]) }
		}
	case .Int, .Float:
		if lo, hi, step, ok := slider_of(e.def); ok {
			held := p.held != "" && p.held == name
			v := held ? p.held_value : (e.def.kind == .Int ? f32(e.value.i) : f32(e.value.f))
			ui.next({width = ui.px(em * 15), height = ui.px(math.round(em * CONTROL_H_EM))})
			ui.a11y({name = config.title_of(e.def)})
			sig := ui.slider("###sl", &v, lo, hi, step, slider_format(e.def))
			// written when the button comes up (the file is not rewritten at the pointer's rate), or at once for a key or a
			// click; while it is down, the value is the page's (held), the preference's when it is up again
			if sig.pointer_pressed || sig.dragging {
				moved := !held || v != p.held_value
				if !held { delete(p.held); p.held = strings.clone(name) }
				p.held_value = v
				if moved && o.preview != nil { o.preview(o.user, name, f64(v)) }
			} else {
				if held { delete(p.held); p.held = "" }
				text := e.def.kind == .Int ? fmt.tprintf("%d", i64(math.round(v))) : fmt.tprintf("%g", v)
				if text != config.value_string(prefs, r) { apply(p, prefs, o, name, text) }
			}
		} else {
			field(p, prefs, o, r, e, em)
		}
	}
	return true
}

// A control under the words: the themes' cards, the program's own (Options.custom), or a choice too wide for the line.
@(private = "file")
control_under :: proc(p: ^Page, prefs: ^config.Prefs, o: Options, r: config.Ref, e: ^config.Entry, em: f32) {
	if len(o.themes) > 0 && e.def.name == THEME_PREF && e.def.kind == .String {
		// (the cards in the version the look shows: appearance.mode's, or the one the program shows for the system's)
		light := o.themes_light
		if m := config.ref_of(prefs, MODE_PREF); m != config.NO_REF {
			#partial switch ui.theme_mode_of(config.get_string(prefs, m)) {
			case .Dark:  light = false
			case .Light: light = true
			}
		}
		if at := theme_cards(o.themes, e.value.s, light, em); at >= 0 {
			apply(p, prefs, o, THEME_PREF, o.themes[at].name)
		}
		return
	}
	if o.custom != nil && slice.contains(o.custom_names, e.def.name) { o.custom(o.user, e.def.name, em); return }
	if e.def.kind == .String {
		labels, values := choices_of(o, e)
		if len(values) > 0 && len(values) <= SEGMENTS_MAX {
			sel := -1
			for c, i in values { if c == e.value.s { sel = i } }
			ui.next({width = ui.fill(), height = ui.px(math.round(em * CONTROL_H_EM))})
			if ui.segmented("###seg", labels, &sel) && sel >= 0 { apply(p, prefs, o, e.def.name, values[sel]) }
			return
		}
	}
}

// A String preference's choices: its own (their labels capitalised), or the program's.
@(private = "file")
choices_of :: proc(o: Options, e: ^config.Entry) -> (labels, values: []string) {
	if len(e.def.choices) > 0 {
		out := make([]string, len(e.def.choices), context.temp_allocator)
		for c, i in e.def.choices { out[i] = capitalised(c) }
		return out, e.def.choices
	}
	if o.choices != nil { return o.choices(o.user, e.def.name) }
	return
}

@(private = "file")
capitalised :: proc(s: string) -> string {
	if s == "" || s[0] < 'a' || s[0] > 'z' { return s }
	return strings.concatenate({ascii.upper(s[:1]), s[1:]}, context.temp_allocator)   // (a value: ASCII)
}

// A bounded number with few steps is a slider; the others, and a size in bytes, are fields.
@(private = "file")
slider_of :: proc(d: config.Def) -> (lo, hi, step: f32, ok: bool) {
	if !d.bounded || d.bytes { return }
	span := d.max - d.min
	if span <= 0 { return }
	if d.kind == .Int {
		if span > SLIDER_STEPS_MAX { return }
		return f32(d.min), f32(d.max), 1, true
	}
	return f32(d.min), f32(d.max), f32(float_step(span)), true
}

// A round step that cuts `span` in at most SLIDER_STEPS_MAX: 0.1, 1, 10...
@(private = "file")
float_step :: proc(span: f64) -> f64 {
	return math.pow(10, math.ceil(math.log10(span / SLIDER_STEPS_MAX)))
}

// The value as the slider writes it: as many decimals as its step has, its unit after it.
@(private = "file")
slider_format :: proc(d: config.Def) -> string {
	unit := d.unit != "" ? strings.concatenate({" ", d.unit}, context.temp_allocator) : ""
	decimals := 0
	if d.kind == .Float { decimals = max(0, int(-math.log10(float_step(d.max - d.min)) + 0.5)) }
	return fmt.tprintf("%%.%df%s", decimals, unit)
}

// A free field, its unit after it: Enter or leaving it applies the text; a refused one says why under the line.
@(private = "file")
field :: proc(p: ^Page, prefs: ^config.Prefs, o: Options, r: config.Ref, e: ^config.Entry, em: f32) {
	name := e.def.name
	f, ok := p.fields[name]
	if !ok {
		f = new(Field)
		p.fields[strings.clone(name)] = f
	}
	current := config.value_string(prefs, r)
	typing := f.box != 0 && ui.focus_key() == f.box
	if f.synced != current && !typing { ui.field_set(&f.text, current); delete(f.synced); f.synced = strings.clone(current) }
	number := e.def.kind != .String
	ui.next({width = ui.px(em * (number ? 9 : 15)), height = ui.px(math.round(em * CONTROL_H_EM))})
	ui.a11y({name = config.title_of(e.def)})
	res := ui.line_edit("###field", &f.text, "")
	f.box = res.box.key
	left := !res.focused && typing   // (the keyboard went elsewhere this frame)
	if res.committed || (left && ui.field_string(&f.text) != current) {
		err := apply(p, prefs, o, name, ui.field_string(&f.text))
		delete(f.error)
		f.error = err
		delete(f.synced); f.synced = ""
	}
	if res.cancelled { delete(f.synced); f.synced = ""; delete(f.error); f.error = "" }
	if number && e.def.unit != "" {
		ui.spacer(ui.px(em * 0.4))
		if ui.tags("weak") {
			ui.next({width = ui.text_size(0), height = ui.px(math.round(em * CONTROL_H_EM)), text_pad = 0, font_size = math.round(em * 0.86)})
			ui.label(fmt.tprintf("%s###unit", e.def.unit))
		}
	}
}

// Sets a preference from text. "" when it was set; else why not (owned), with what is allowed ("out of range: 1 to 64").
@(private)
apply :: proc(p: ^Page, prefs: ^config.Prefs, o: Options, name, text: string) -> string {
	err := config.set_from_string(prefs, name, text, .User)
	if err == .None {
		if o.changed != nil { o.changed(o.user, name) }
		return ""
	}
	msg := config.set_error_text(err)
	if r := config.ref_of(prefs, name); r != config.NO_REF {
		d := config.entry(prefs, r).def
		unit := d.unit != "" ? strings.concatenate({" ", d.unit}, context.temp_allocator) : ""
		num :: proc(v: f64, kind: config.Kind) -> string { return kind == .Int ? fmt.tprintf("%d", i64(v)) : fmt.tprintf("%g", v) }
		#partial switch err {
		case .Out_Of_Range: if d.bounded { msg = fmt.tprintf("%s: %s to %s%s", msg, num(d.min, d.kind), num(d.max, d.kind), unit) }
		case .Not_A_Choice: msg = fmt.tprintf("%s: %s", msg, strings.join(d.choices, ", ", context.temp_allocator))
		}
	}
	return strings.clone(msg)
}

@(private)
reset :: proc(p: ^Page, prefs: ^config.Prefs, o: Options, name: string) {
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
updater_under :: proc(o: Options, em: f32) {
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
		ui.next({height = ui.px(math.round(em * CONTROL_H_EM))})
		if ui.disabled(busy) { if ui.button("Check now###update_check").clicked { update.check_now(o.updater) } }
		if st.phase == .Available {
			ui.spacer(ui.px(em * 0.5))
			ui.next({height = ui.px(math.round(em * CONTROL_H_EM))})
			if ui.button(fmt.tprintf("Install %s###update_install", st.version)).clicked { update.install_now(o.updater) }
		}
		if st.phase == .Installed && o.restart != nil {
			ui.spacer(ui.px(em * 0.5))
			ui.next({height = ui.px(math.round(em * CONTROL_H_EM))})
			if ui.button("Restart now###update_restart").clicked { o.restart(o.user) }
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
	text: string
	#partial switch st.phase {
	case .Available:   text = fmt.tprintf("Install %s###update_badge", st.version)
	case .Downloading: text = fmt.tprintf("Downloading %s…###update_badge", st.version)
	case .Installed:   text = fmt.tprintf("Restart to update to %s###update_badge", st.version)
	case:              return false
	}
	ui.next_merge({width = ui.text_size(em * 0.6), radius = em * 0.35, font_size = math.round(em * 0.88), text_align = .Center})
	if st.phase == .Downloading {
		if ui.tags("weak") { ui.label(text) }
		return true
	}
	if ui.tags("accent_button") {
		if ui.button(text).clicked {
			if st.phase == .Available { update.install_now(u) } else if restart != nil { restart(user) }
		}
	}
	return true
}
