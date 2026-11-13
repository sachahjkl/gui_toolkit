package ui

// A program's commands in one table: each one's name, its group and its keys. The same table gives:
//
//   command_pressed   the key handling: a command's keys, pressed this frame
//   chord_text        the text of a key in a menu's line ("Ctrl+Shift+P"); command_tip, a tooltip's ("Kill (Shift+Delete)");
//                     key_tip, a tooltip's for a control that is no command
//   palette           the command palette: a dialog the user resizes, that searches (fuzzy_words), every command with
//                     its keys, grouped
//   shortcuts_sheet   a dialog that lists every command's keys, grouped
//
// A program keeps its commands in a table of its own (an enum of its commands indexing an array of Command) and says
// each frame which ones can act now (the `disabled` of palette): one place names a command and its keys, and its menus,
// tooltips, palette and sheet all say the same.
//
//   COMMANDS := [Cmd]ui.Command{.Kill = {label = "Kill…", group = "Processes", keys = {{.Delete, {.Shift}}}}, ...}
//   if ui.command_pressed(COMMANDS[.Kill]) { kill() }
//   ui.menu_item(COMMANDS[.Kill].label, ui.command_shortcut(COMMANDS[.Kill]))
//   if ui.key_press(.K, {.Ctrl}) { ui.palette_open(&palette) }
//   if i, _ := ui.palette(&palette, COMMANDS[:], disabled[:]); i >= 0 { run(Cmd(i)) }

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "../draw"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"

// The palette's size at first, in em, and the least it is made; where its top is, a share of the window's height; a line's
// height and a group heading's, in em.
PALETTE_WIDTH_EM :: 34
PALETTE_HEIGHT_EM :: 26
PALETTE_MIN_EM :: Vec2{22, 10}
PALETTE_TOP :: 0.12
PALETTE_ROW_EM :: 2
PALETTE_HEADING_EM :: 1.9
// What a match of the group's letters (not the label's alone) loses against one of the label's.
PALETTE_GROUP_MATCH_PENALTY :: 100
// What a match of a tag (a word the label does not say) loses against one of the label's, less than one of the group's.
@(private = "file") PALETTE_TAG_MATCH_PENALTY :: 50
// The sheet's width, in em; its list's height at most, a share of the window's height.
SHEET_WIDTH_EM :: 34
SHEET_HEIGHT :: 0.7

// A key with its modifiers. The zero value is no key.
Chord :: struct {
	key:  platform.Key,
	mods: platform.Modifiers,
}

Command :: struct {
	label: string,     // "End task": the menu's, the palette's and the sheet's text
	group: string,     // "Processes": the palette's and the sheet's heading ("" none)
	// other words the palette finds it by, that its label does not say ("exit", "close" for Quit)
	tags:  []string,
	// its keys, as many as it has, the first one shown in menus and tooltips (a zero Chord among them: none). A table
	// built at run time keeps them in memory of its own, as its tags. The keys in effect are the table the program
	// passes: one the user rebinds is a copy of its constant table with these slices replaced.
	keys:  []Chord,
	icon:  string,     // a glyph of the state's icon_font (Lucide's): the palette's line shows it ("" none)
}

// "Ctrl+Shift+P", "Delete", "F5" ("" for no key), in the language in use ("Ctrl+Maj+P"): platform.key_text's words.
// Modifiers come first, in the order Ctrl, Shift, Alt.
chord_text :: proc(c: Chord, allocator := context.temp_allocator) -> string {
	return platform.key_text(platform.Hotkey{key = c.key, mods = c.mods}, allocator)
}

// A tooltip's text: what a control does and its key ("Settings (Ctrl+,)"), the key in the language in use; the label
// alone with no key. command_tip is the same for a command.
key_tip :: proc(label: string, c: Chord, allocator := context.temp_allocator) -> string {
	k := chord_text(c, context.temp_allocator)
	if k == "" { return strings.clone(label, allocator) }
	return fmt.aprintf("%s (%s)", label, k, allocator = allocator)
}

// The text of a command's first key, for a menu's line ("" when it has none).
command_shortcut :: proc(c: Command) -> string {
	for k in c.keys { if k.key != .None { return chord_text(k) } }
	return ""
}

// Whether the command has a key (the sheet lists it).
@(private = "file")
command_has_key :: proc(c: Command) -> bool {
	for k in c.keys { if k.key != .None { return true } }
	return false
}

// Every key of a command, apart by commas ("Ctrl+K, Ctrl+Shift+P").
command_keys_text :: proc(c: Command, allocator := context.temp_allocator) -> string {
	parts := make([dynamic]string, 0, len(c.keys), context.temp_allocator)
	for k in c.keys { if k.key != .None { append(&parts, chord_text(k)) } }
	return strings.join(parts[:], ", ", allocator)
}

// A tooltip's text: the label and its first key ("Kill (Shift+Delete)"), or the label alone; in the language in use.
command_tip :: proc(c: Command, allocator := context.temp_allocator) -> string {
	first: Chord
	for k in c.keys { if k.key != .None { first = k; break } }
	return key_tip(i18n.tr(c.label), first, allocator)
}

// A command as the palette and the sheet show it: its label and its group in the language in use (a program's table holds
// its English, marked with i18n.later), and the words a search finds it by: its tags, and its English label and group when
// they read otherwise (one who knows a command by its English finds it too). In English: the command's own strings.
@(private = "file")
command_shown :: proc(c: Command) -> (label, group: string, tags: []string) {
	label, group, tags = i18n.tr(c.label), i18n.tr(c.group), c.tags
	if raw_data(label) == raw_data(c.label) && raw_data(group) == raw_data(c.group) { return }
	all := make([]string, len(c.tags) + 2, context.temp_allocator)
	all[0], all[1] = c.label, c.group
	copy(all[2:], c.tags)
	return label, group, all
}

// Whether one of the command's keys was pressed this frame (the press is taken: nothing else sees it). A command that
// cannot act now (`disabled`) takes no key: the key stays for what else wants it.
command_pressed :: proc(c: Command, disabled := false) -> bool {
	if disabled { return false }
	for k in c.keys {
		if k.key != .None && key_press(k.key, k.mods) { return true }
	}
	return false
}

////////////////////////////////
// The palette

// The palette: a dialog at the top centre of the window (a modal of a `size`: its edges and its corner resize it), a field
// that searches what is typed, and the commands under it. The program keeps it between frames; `size` is the size the
// user gave it (in ems; {} the default), for the program to keep between starts.
Command_Palette :: struct {
	open:   bool,
	size:   Vec2,
	field:  Line_Edit,
	sel:    int,    // the line selected, among the commands listed
	fresh:  bool,   // opened this frame: the field takes the keyboard
	reveal: bool,   // the selected line is brought into view at the next build
	mouse:  Vec2,   // the pointer at the last build (a line takes the selection when the pointer moves over it)
	// the modifiers of the Enter that chose (Ctrl+Enter, Alt+Enter, Shift+Enter: what else the program does with the
	// command chosen; {} plain Enter or a click)
	chosen_mods: platform.Modifiers,
	search:      Fuzzy_Cache,   // the query and the commands folded, from one frame to the next (palette_entry_cached)
	// The list for the query, kept: made again only when what it depends on changes (palette_keep). A frame that changes
	// nothing builds the lines in view and walks no command.
	lines:    [dynamic]Palette_Line,
	ranges:   [dynamic]Fuzzy_Range,   // the lines' ranges, one after the other
	found:    int,                    // the lines that are commands (the count the strip shows)
	icons:    bool,                   // a command has an icon
	kept:     Palette_Key,            // what the list was made for (valid: it was)
	query:    string,                 // the query it was made for (owned)
	rankings: int,                    // how many times the list was made (a test reads it)
}

// What the palette's list depends on, apart from the query: the commands (their version, or their address while it is
// 0, and their count), the command put first, the memory of choices and its version, the language in use.
@(private)
Palette_Key :: struct {
	valid:          bool,
	commands:       rawptr,
	count:          int,
	version:        u64,
	names:          rawptr,
	first:          int,
	memory:         ^Choice_Memory,
	memory_version: u64,
	language:       u32,   // i18n.version
}

// A command's line: its index, the headings down to it (to place it), whether a heading is just above it (the recent
// choices' when `recent`, else its group's), and its ranges in Command_Palette.ranges.
@(private)
Palette_Line :: struct {
	index, headings:          int,
	heading, recent:          bool,
	range_first, range_count: int,
}

// The selected line: sunk in a well with a bar of the accent at its left, its text in the theme's own colour. A raised
// face of the accent (a button's) put the text, and what the search found in it, on a colour too close to theirs.
@(private)
palette_selected_draw :: proc(b: ^Box, _: rawptr, dc: ^draw.Context) {
	s := gs()
	p := px1()
	r := b.rect
	side := math.round(6 * scale())   // (off the dialog's sides)
	r.min.x += side
	r.max.x -= side
	well := color_from_tags(s, b.tags_key, "well")
	if machined() { machined_well(dc, r, 0, well) } else { draw.rect(dc, r, well) }
	bar := math.round(2 * scale())
	inset := math.round(r.max.y - r.min.y) * 0.25
	draw.rect(dc, {{r.min.x + 2 * p, r.min.y + inset}, {r.min.x + 2 * p + bar, r.max.y - inset}}, color_from_tags(s, b.tags_key, "accent"), bar * 0.5)
}

// What a program adds to its palette (every field optional).
Palette_Options :: struct {
	// what the user chose before (choices.odin), and each command's key in it (by index; "": not remembered): the
	// heaviest choices (choice_recent) a group of their own on top while nothing is typed, and a match raised by its
	// choice's weight (choice_bonus) while something is. The program notes each choice (choice_note).
	memory:       ^Choice_Memory,
	names:        []string,
	recent_title: string,      // the group of the choices' heading ("": "Recent")
	first:        Maybe(int),  // a command put first while something is typed (an alias typed whole: its command)
	keys:         []string,    // per command (by index): the text of its keys, as the program shows them ("Ctrl+M, T", one's own keys), instead of its first chord
	// the commands' version as the program counts their changes (labels, groups, tags, icons, `names`): the palette ranks
	// them again only when it, their count, the query, `first`, the memory's version or the language changes. 0: the
	// table and `names` do not change in place, and the palette keys on their addresses (a table built again each frame
	// gives a version)
	version:      u64,
	foot:         string,      // a line under the list (its keys' help)
}

// What a palette makes of `query` for one of its entries, best first: its label holds it whole or at the starts of its words
// (fuzzy_words), then with its tags (other words it is found by), then with its group; then the same with a slip or two in
// each word (fuzzy_typos), after every exact match. `ranges`: what lights in the label (none when the tags or the group
// found it). A program's own palette (sessions, settings and commands together) ranks its entries with it too: with a
// needle and entries folded once (fuzzy_cache_needle, palette_entry_cached), nothing is folded again for each frame.
palette_match :: proc{palette_match_strings, palette_match_folded}

palette_match_strings :: proc(query, label, group: string, tags: []string) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	return palette_match_folded(fuzzy_needle(query), palette_entry(label, group, tags))
}

palette_match_folded :: proc(needle: Fuzzy_Needle, e: Palette_Entry) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	if s, r, found := fuzzy_words(needle, e.label); found { return s, r, true }
	if e.with_tags.text != "" {
		if s, _, found := fuzzy_words(needle, e.with_tags); found { return s - PALETTE_TAG_MATCH_PENALTY, nil, true }
	}
	if e.with_group.text != "" {
		if s, _, found := fuzzy_words(needle, e.with_group); found { return s - PALETTE_GROUP_MATCH_PENALTY, nil, true }
	}
	if s, r, found := fuzzy_typos(needle, e.label); found { return s, r, true }
	if e.with_tags.text != "" {
		if s, _, found := fuzzy_typos(needle, e.with_tags); found { return s - PALETTE_TAG_MATCH_PENALTY, nil, true }
	}
	return 0, nil, false
}

// An entry of a palette as palette_match reads it: its label, the label with its tags, the label with its group and its
// tags, each folded.
Palette_Entry :: struct {
	label:      Fuzzy_Text,
	with_tags:  Fuzzy_Text,   // "<label> <tags>" ("": it has no tags)
	with_group: Fuzzy_Text,   // "<label> <group> <tags>" ("": it has no group)
}

palette_entry :: proc(label, group: string, tags: []string, allocator := context.temp_allocator) -> Palette_Entry {
	e := Palette_Entry{label = fuzzy_text(label, allocator)}
	joined := strings.join(tags, " ", allocator)
	if joined != "" { e.with_tags = fuzzy_text(fmt.aprintf("%s %s", label, joined, allocator = allocator), allocator) }
	if group != "" { e.with_group = fuzzy_text(fmt.aprintf("%s %s %s", label, group, joined, allocator = allocator), allocator) }
	return e
}

// palette_entry kept in `c` (it takes the cache's slots `first` to `first + 2`), folded again only when the label, the
// group or the tags changed.
palette_entry_cached :: proc(c: ^Fuzzy_Cache, first: int, label, group: string, tags: []string) -> Palette_Entry {
	// (the texts as parts, spaces between: compared with the slots as they are, joined only to be folded)
	joined := make([dynamic]string, 0, 2 * len(tags), context.temp_allocator)
	joined_len := 0
	for t, i in tags {
		if i > 0 { append(&joined, " ") }
		append(&joined, t)
		joined_len += (i > 0 ? 1 : 0) + len(t)
	}
	with_tags := make([dynamic]string, 0, 2 + len(joined), context.temp_allocator)
	with_group := make([dynamic]string, 0, 4 + len(joined), context.temp_allocator)
	if joined_len > 0 {
		append(&with_tags, label, " ")
		append(&with_tags, ..joined[:])
	}
	if group != "" {
		append(&with_group, label, " ", group, " ")
		append(&with_group, ..joined[:])
	}
	return {
		label      = fuzzy_cache_text(c, first, label),
		with_tags  = fuzzy_cache_text(c, first + 1, ..with_tags[:]),   // (none: the slot is emptied)
		with_group = fuzzy_cache_text(c, first + 2, ..with_group[:]),
	}
}

palette_destroy :: proc(p: ^Command_Palette) {
	line_edit_destroy(&p.field)
	fuzzy_cache_destroy(&p.search)
	delete(p.lines)
	delete(p.ranges)
	delete(p.query)
	p.lines, p.ranges, p.query, p.kept = nil, nil, "", {}
}

// Opens the palette, its field empty and its first command selected.
palette_open :: proc(p: ^Command_Palette) {
	p.open, p.fresh, p.sel, p.reveal = true, true, 0, true
	line_edit_clear(&p.field)
}

// The palette while it is open: every command, under its group's heading, with its keys. What is typed keeps the
// commands whose label (or label and group) holds it whole or in pieces that begin words (fuzzy_words), the best matches
// first (the headings go then; each line says its group); the first one is selected. Up, Down, Page Up, Page Down move
// the selection, Enter runs it, Escape closes the palette. A command that cannot act now (`disabled[i]` true; nil: none
// can) is greyed and is not chosen. Returns the index of the command chosen (-1: none), and `resized` when the user
// changed its size this frame (`p.size`: keep it). Enter with Ctrl, Alt or Shift chooses too: `p.chosen_mods` says which.
// `o`: the choices remembered, a command first, the keys' texts, a foot line, the commands' version (Palette_Options).
// The list is kept (palette_keep), and only the lines near the view are built.
palette :: proc(p: ^Command_Palette, commands: []Command, disabled: []bool = nil, o := Palette_Options{}) -> (chosen: int, resized: bool) {
	chosen = -1
	p.chosen_mods = {}
	if !p.open { return }
	em := font_size()
	query := strings.trim_space(line_edit_string(&p.field))
	palette_keep(p, commands, query, o)
	list := p.lines[:]
	n := len(list)
	can :: proc(disabled: []bool, i: int) -> bool { return i >= len(disabled) || !disabled[i] }
	row_h := math.round(dense(em * PALETTE_ROW_EM))
	heading_h := em * PALETTE_HEADING_EM
	if n > 0 {
		page := max(int(p_view_h(p) / row_h), 1)
		// (the palette's own keys, read before its dialog is built)
		if key_press_any(.Down) { p.sel = (p.sel + 1) % n; p.reveal = true }
		if key_press_any(.Up) { p.sel = (p.sel + n - 1) % n; p.reveal = true }
		if key_press_any(.Page_Down) { p.sel = min(p.sel + page, n - 1); p.reveal = true }
		if key_press_any(.Page_Up) { p.sel = max(p.sel - page, 0); p.reveal = true }
	}
	p.sel = clamp(p.sel, 0, max(n - 1, 0))
	mouse := mouse_pos()
	moved := abs(mouse.x - p.mouse.x) + abs(mouse.y - p.mouse.y) > 0.5
	p.mouse = mouse
	before := p.size
	if modal("palette", &p.open, {width_em = PALETTE_WIDTH_EM, height_em = PALETTE_HEIGHT_EM, min_width_em = PALETTE_MIN_EM.x, min_height_em = PALETTE_MIN_EM.y, size = &p.size, top = PALETTE_TOP}) {
		// (the strip, the gaps and the foot in whole pixels: the list's height is what is left, cut to whole lines below)
		top_h := math.round(dense(em * SEARCH_BAND_EM))   // (search_band's)
		gap_h := math.round(em * 0.3)
		foot_h := math.round(o.foot != "" ? dense(em * 2) : em * 0.4)
		res := search_band("palette_top", &p.field, {count = p.found})
		if p.fresh { set_focus(res.box.key); p.fresh = false }
		if res.changed { p.sel = 0; p.reveal = true }
		if res.cancelled { p.open = false }   // (Escape in the field: the field takes it before the dialog)
		if res.committed && n > 0 && list[p.sel].index >= 0 && can(disabled, list[p.sel].index) { chosen = list[p.sel].index }
		// (Enter with a modifier: the program's other use of the command chosen)
		for m in ([]platform.Modifiers{{.Ctrl}, {.Alt}, {.Shift}}) {
			if n > 0 && can(disabled, list[p.sel].index) && key_press_any(.Return, m) { chosen, p.chosen_mods = list[p.sel].index, m }
		}
		spacer(px(gap_h))
		// The list ends on a whole line: what a line short of it is left goes under the list, so that the foot never
		// cuts its last line in half.
		dialog := parent_box()
		inner := gs().modal_stack[len(gs().modal_stack) - 1].wh.y - 2 * border_inset(dialog)
		avail := max(inner - top_h - gap_h - foot_h, 0)
		rest := avail >= row_h ? avail - math.floor(avail / row_h) * row_h : 0
		next({width = fill(), height = fill()})
		if scroll_y("###palette_list") {
			lb := parent_box()
			view_h := lb.rect.max.y - lb.rect.min.y
			if p.reveal && view_h > row_h && n > 0 {   // (a search that keeps nothing: no line to show)
				top := heading_line_top(list, p.sel, row_h, heading_h)
				lb.view_target.y = view_reveal_offset(lb.view_target.y, top, top + row_h, view_h)
				p.reveal = false
			}
			if n == 0 {
				next({width = fill(), height = px(row_h), text_align = .Center})
				if tags("weak") { label(fmt.tprintf("%s###palette_none", i18n.tr("Nothing matches"))) }
			}
			// (a column of icons when a command has one and the state has an icon font)
			icons := p.icons && gs().icon_font != 0
			first, last, above, below := heading_lines_band(list, lb, row_h, heading_h)
			if above > 0 { spacer(px(above)) }
			for k in first ..< last {
				line := list[k]
				if line.index >= len(commands) { continue }   // (a table that shrank without a version: ranked again next frame)
				c := commands[line.index]
				if line.heading {
					heading := line.recent ? (o.recent_title != "" ? o.recent_title : i18n.tr("Recent")) : i18n.tr(c.group)
					if tags("weak") {
						next({width = fill(), height = px(heading_h), font_size = em * 0.9, text_pad = em * 0.7})
						build_box({.Draw_Text}, fmt.tprintf("%s###palette_h_%d", heading, k))
					}
				}
				c_label, c_group, _ := command_shown(c)
				text := c_label
				if query != "" && c_group != "" { text = fmt.tprintf("%s  ·  %s", c_label, c_group) }
				on := can(disabled, line.index)
				sel := k == p.sel
				push_tags("menu_item")
				if sel { push_tags("selected") }
				next({width = fill(), height = px(row_h), axis = .X, cross = .Center})
				flags := Box_Flags{.Clickable, .Draw_Hot_Effects}
				if !on { flags += {.Disabled} }
				rb := build_box(flags, fmt.tprintf("###palette_%d_%d", line.index, k))
				if sel { rb.custom = palette_selected_draw }
				a11y_default(rb, {role = .Menu_Item, name = text, selected = sel})
				rs := signal(rb)
				if rs.hovering && moved { p.sel = k }
				if rs.clicked && on { chosen = line.index }
				if parent(rb) {
					spacer(px(em * 0.7))
					if icons {
						if !sel { push_tags("weak") }
						next({width = px(em * 1.7), height = pct(1), font = gs().icon_font, font_size = em * 0.95, text_align = .Center, text_pad = 0})
						build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###i", c.icon))
						if !sel { pop_tags() }
						spacer(px(em * 0.5))
					}
					// (what the search found in the label lit; its tags, which the line does not show, light nothing)
					ranges := p.ranges[line.range_first:][:line.range_count]
					if query != "" && len(ranges) == 0 { ranges = word_ranges(c_label, query) }   // (found by its tags or group: its words that are in the label)
					next({width = fill(), text_pad = 0})
					tb := matched_label("###t", text, ranges)
					// (the palette as narrow as the person made it: a line it cuts says itself whole)
					if label_cut(tb, text) && hovered_for(rs) { if tooltip() { tooltip_text(text) } }
					keys := line.index < len(o.keys) ? o.keys[line.index] : command_shortcut(c)
					if keys != "" {
						if tags("weak") {
							next({width = text_size(), height = pct(1), text_pad = 0, font_size = em * 0.9})
							label(fmt.tprintf("%s###k", keys))
						}
					}
					// (clear of the scroll bar, along the list's right edge)
					bar_w, bar_m := scrollbar_size(em)
					spacer(px(em * 0.5 + bar_w + 2 * bar_m))
				}
				if sel { pop_tags() }
				pop_tags()
			}
			if below > 0 { spacer(px(below)) }
		}
		spacer(px(rest))
		if o.foot != "" {
			next({width = fill(), height = px(foot_h), axis = .X, cross = .Center})
			if row(.Center, {.Draw_Side_Top}, "###palette_foot") {
				spacer(px(em * 0.7))
				if tags("weak") {
					next({width = fill(), height = pct(1), font_size = em * 0.85})
					label(fmt.tprintf("%s###palette_foot_text", o.foot))
				}
				spacer(px(em * 1.4))   // (the corner's grip)
			}
		} else {
			spacer(px(foot_h))
		}
	}
	resized = p.size != before
	if chosen >= 0 { p.open = false }
	return
}

// The palette's list's height at the last build (0: not laid out yet).
@(private = "file")
p_view_h :: proc(p: ^Command_Palette) -> f32 {
	s := gs()
	b := box_from_key(key_from_string(key_from_string(s.root.key, "###modal_palette"), "###palette_list"))
	if b == nil { return 0 }
	return b.rect.max.y - b.rect.min.y
}

////////////////////////////////
// A list of lines under headings, built near its view only

// The top of line `k` in a list whose lines are `row_h` high, a heading of `heading_h` above some of them (`heading`;
// `headings`: the headings down to it, its own counted).
@(private = "file")
heading_line_top :: proc(lines: []$T, k: int, row_h, heading_h: f32) -> f32 {
	return f32(k) * row_h + f32(lines[k].headings) * heading_h
}

// The lines to build in the scroll box `view`: those that meet its view, where it is heading (a jump, a reveal), and a
// screen each side ([first, last)); `above` and `below`: the room of the lines not built. Two searches by halves: a
// frame does not walk the lines.
@(private = "file")
heading_lines_band :: proc(lines: []$T, view: ^Box, row_h, heading_h: f32) -> (first, last: int, above, below: f32) {
	n := len(lines)
	if n == 0 { return }
	view_h := view.rect.max.y - view.rect.min.y
	if view_h <= 0 { view_h = gs().window_size.y }   // (not laid out yet: a window's height of lines)
	lo := min(view.view_off.y, view.view_target.y) - view_h
	hi := max(view.view_off.y, view.view_target.y) + 2 * view_h
	// (the first line whose bottom is past lo; then the first whose heading starts at hi or past it)
	a, b := 0, n
	for a < b {
		m := (a + b) / 2
		if heading_line_top(lines, m, row_h, heading_h) + row_h <= lo { a = m + 1 } else { b = m }
	}
	first = a
	b = n
	for a < b {
		m := (a + b) / 2
		if heading_line_top(lines, m, row_h, heading_h) - (lines[m].heading ? heading_h : 0) < hi { a = m + 1 } else { b = m }
	}
	last = a
	total := heading_line_top(lines, n - 1, row_h, heading_h) + row_h
	above = first < n ? heading_line_top(lines, first, row_h, heading_h) - (lines[first].heading ? heading_h : 0) : total
	end := last > first ? heading_line_top(lines, last - 1, row_h, heading_h) + row_h : above
	below = total - end
	return
}

////////////////////////////////
// The palette's list

// Makes the list for `query` again when it, the commands or what else it depends on (Palette_Key) changed since the
// last; else keeps it. Every command is matched and ranked only here.
@(private = "file")
palette_keep :: proc(p: ^Command_Palette, commands: []Command, query: string, o: Palette_Options) {
	key := Palette_Key{
		valid = true, count = len(commands), version = o.version, first = -1,
		memory = o.memory, language = i18n.version(),
	}
	if o.version == 0 { key.commands, key.names = raw_data(commands), raw_data(o.names) }
	if f, ok := o.first.?; ok { key.first = f }
	if o.memory != nil { key.memory_version = o.memory.version }
	if key == p.kept && query == p.query { return }
	p.kept = key
	delete(p.query)
	p.query = strings.clone(query)
	p.rankings += 1
	palette_list(p, commands, query, o)
	p.found = len(p.lines)
	p.icons = false
	for c in commands { if c.icon != "" { p.icons = true; break } }
}

// The commands the palette lists for `query`, in p.lines: every one in the table's order (with no query; the recent ones
// first, under their heading), else the matches, the best first (the label's letters matter more than the group's),
// `o.first` before them.
// The query and each command are folded once, kept in `p.search` from one frame to the next.
@(private = "file")
palette_list :: proc(p: ^Command_Palette, commands: []Command, query: string, o: Palette_Options) {
	clear(&p.lines)
	clear(&p.ranges)
	remembered := o.memory != nil && len(o.names) > 0
	if query == "" {
		headings := 0
		recent := 0
		recent_choices: []int
		if remembered { recent_choices = choice_recent(o.memory, o.names) }
		for i in recent_choices {
			if i < 0 || i >= len(commands) { continue }
			if recent == 0 { headings += 1 }
			append(&p.lines, Palette_Line{index = i, headings = headings, heading = recent == 0, recent = true})
			recent += 1
		}
		group := ""
		for c, i in commands {
			heading := false
			if c.group != group || (recent > 0 && i == 0) {
				if c.group != "" { heading = true; headings += 1 }
				group = c.group
			}
			append(&p.lines, Palette_Line{index = i, headings = headings, heading = heading})
		}
		return
	}
	Ranked :: struct { index: int, score: f64, ranges: []Fuzzy_Range }
	ranked := make([dynamic]Ranked, 0, len(commands), context.temp_allocator)
	now := remembered ? choice_now() : 0
	needle := fuzzy_cache_needle(&p.search, query)
	first, has_first := o.first.?
	has_first = has_first && first >= 0 && first < len(commands)
	first_ranges: []Fuzzy_Range
	for c, i in commands {
		c_label, c_group, c_tags := command_shown(c)
		score, ranges, ok := palette_match(needle, palette_entry_cached(&p.search, 3 * i, c_label, c_group, c_tags))
		if ok {
			s := f64(score)
			if remembered && i < len(o.names) && o.names[i] != "" { s += choice_bonus(o.memory, o.names[i], query, now) }
			append(&ranked, Ranked{i, s, ranges})
		}
		if has_first && i == first { first_ranges = ranges }
	}
	fuzzy_cache_keep(&p.search, 3 * len(commands))
	slice.stable_sort_by(ranked[:], proc(a, b: Ranked) -> bool { return a.score > b.score })
	add :: proc(p: ^Command_Palette, index: int, ranges: []Fuzzy_Range) {
		append(&p.lines, Palette_Line{index = index, range_first = len(p.ranges), range_count = len(ranges)})
		append(&p.ranges, ..ranges)
	}
	if has_first { add(p, first, first_ranges) }
	for r in ranked {
		if has_first && r.index == first { continue }
		add(p, r.index, r.ranges)
	}
}

////////////////////////////////
// The sheet of the keys

// The sheet: the program keeps it between frames. `open` shows it; the rest is the list it keeps (its commands that have
// a key, made again only when the commands change).
Shortcuts_Sheet :: struct {
	open:     bool,
	lines:    [dynamic]Sheet_Line,
	kept:     Sheet_Key,
	listings: int,   // how many times the list was made (a test reads it)
}

// What the sheet's list depends on: the commands (their version, or their address while it is 0) and their count.
@(private)
Sheet_Key :: struct {
	valid:    bool,
	commands: rawptr,
	count:    int,
	version:  u64,
}

// A command that has a key: its index, the group headings down to it, whether its group's heading is just above it.
@(private)
Sheet_Line :: struct {
	index, headings: int,
	heading:         bool,
}

shortcuts_sheet_destroy :: proc(sheet: ^Shortcuts_Sheet) {
	delete(sheet.lines)
	sheet.lines, sheet.kept = nil, {}
}

// The dialog `id` while `sheet.open`: every command that has a key, under its group's heading, its keys at the right. It
// scrolls when it is taller than SHEET_HEIGHT of the window; Escape and the close button of its header close it.
// `title` "": "Keyboard shortcuts", in the language in use. `version`: the commands' version as the program counts
// their changes (their keys too: a table rebound in place gives one); 0: the table does not change in place. The list
// of the commands that have a key is kept, and only the lines near the view are built.
shortcuts_sheet :: proc(sheet: ^Shortcuts_Sheet, id: string, commands: []Command, title := "", version: u64 = 0) {
	s := gs()
	em := font_size()
	w := em * SHEET_WIDTH_EM
	key := Sheet_Key{valid = true, count = len(commands), version = version}
	if version == 0 { key.commands = raw_data(commands) }
	if sheet.open && key != sheet.kept {
		sheet.kept = key
		sheet.listings += 1
		sheet_list(sheet, commands)
	}
	if modal(id, &sheet.open, {width_em = SHEET_WIDTH_EM}) {
		if dialog_header("sheet_title", title != "" ? title : i18n.tr("Keyboard shortcuts"), {icon = lucide.KEYBOARD, icon_font = lucide_icons(), close = true}) {}
		sheet_body(sheet, commands, w, em, s.window_size.y)
	}
}

@(private = "file")
sheet_list :: proc(sheet: ^Shortcuts_Sheet, commands: []Command) {
	clear(&sheet.lines)
	group := ""
	headings := 0
	for c, i in commands {
		if !command_has_key(c) { continue }
		heading := c.group != group
		if heading { headings += 1 }
		group = c.group
		append(&sheet.lines, Sheet_Line{index = i, headings = headings, heading = heading})
	}
}

@(private = "file")
sheet_body :: proc(sheet: ^Shortcuts_Sheet, commands: []Command, w, em, window_h: f32) {
	pad := em * 1.2
	line_h := dense(em * 1.7)
	heading_h := em * 2.2   // (a gap of em * 0.5 and the heading)
	lines := sheet.lines[:]
	next({width = px(w), height = children_sum(), axis = .Y})
	if column(id = "###sheet") {
		spacer(px(em * 0.5))
		height := min(window_h * SHEET_HEIGHT, f32(len(lines)) * em * 2.2 + em * 6)
		next({width = px(w), height = px(height)})
		if scroll_y("###sheet_list") {
			first, last, above, below := heading_lines_band(lines, parent_box(), line_h, heading_h)
			if above > 0 { spacer(px(above)) }
			for line in lines[first:last] {
				if line.index >= len(commands) { continue }   // (a table that shrank without a version: listed again next frame)
				c := commands[line.index]
				if line.heading {
					spacer(px(em * 0.5))
					next({width = fill(), height = px(em * 1.7)})
					if row(.Center, {}, fmt.tprintf("###sheet_group_%d", line.index)) {
						spacer(px(pad))
						next({width = fill(), height = pct(1), text_pad = 0, fg = color("accent")})
						label(fmt.tprintf("%s###g", i18n.tr(c.group)))
					}
				}
				next({width = fill(), height = px(line_h)})
				if row(.Center, {}, fmt.tprintf("###sheet_line_%d", line.index)) {
					spacer(px(pad))
					next({width = fill(), height = pct(1), text_pad = 0})
					label(fmt.tprintf("%s###l", i18n.tr(c.label)))
					if tags("weak") {
						next({width = text_size(), height = pct(1), text_pad = 0})
						label(fmt.tprintf("%s###k", command_keys_text(c)))
					}
					spacer(px(pad))
				}
			}
			if below > 0 { spacer(px(below)) }
			spacer(px(em * 0.5))
		}
	}
}
