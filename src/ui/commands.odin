package ui

// A program's commands in one table: each one's id, its name, its group and its keys. The same table gives:
//
//   command_pressed   the key handling: a command's keys in effect (the person's, keymap.odin), pressed this frame
//   chord_text        the text of a key in a menu's line ("Ctrl+Shift+P"); command_tip, a tooltip's ("Kill (Shift+Delete)");
//                     key_tip, a tooltip's for a control that is no command
//   palette_commands  the commands source of the command palette (palette.odin)
//   shortcuts_sheet_open   a view that lists every command's keys, grouped; shortcuts_sheet_set gives it a new table
//   command_key_types_text, command_typing_keys   a key that types text: not a command's while a text field has the
//                     keyboard; a program's test lists the ones its tables hold (src/md/features/commands.md)
//   Command.scope .Window, keys_claim   a window command's keys work whatever has the focus and whatever the page; a
//                     widget that owns every chord (a terminal, a shortcut recorder) claims them while it has the keyboard
//
// A program keeps its commands in a table of its own (an enum of its commands indexing an array of Command) and says
// which ones can act now (the `disabled` of palette_commands): one place names a command and its keys, and its menus,
// tooltips, palette and sheet all say the same. The person's keys and aliases (keymap.odin) change what they say and
// read, not the table. A program's test checks its tables with command_ids_check.
//
//   COMMANDS := [Cmd]ui.Command{.Kill = {id = "kill", label = "Kill…", group = "Processes", keys = {{.Delete, {.Shift}}}}, ...}
//   if ui.command_pressed(COMMANDS[.Kill]) { kill() }
//   ui.menu_item(COMMANDS[.Kill].label, ui.command_shortcut(COMMANDS[.Kill]))
//   ui.palette_commands(&palette, COMMANDS[:], disabled[:], {version = v})   at each build: compares v only
//   if c, ok := ui.palette_chosen(&palette); ok { if i, is := ui.palette_chosen_command(&palette, c); is { run(Cmd(i)) } }

import "core:fmt"
import "core:slice"
import "core:strings"
import config "../config"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"

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

// The keys of a program's zoom commands, the same in every program. Ctrl++ is Ctrl+Shift+= where + is on the = key's
// shifted level (AZERTY, QWERTY): a chord matches its mods exactly, so both are listed, and the keypad's.
@(rodata) ZOOM_IN_KEYS := [?]Chord{{.Equal, {.Ctrl}}, {.Equal, {.Ctrl, .Shift}}, {.Num_Add, {.Ctrl}}}
@(rodata) ZOOM_OUT_KEYS := [?]Chord{{.Minus, {.Ctrl}}, {.Num_Subtract, {.Ctrl}}}
@(rodata) ZOOM_RESET_KEYS := [?]Chord{{.N0, {.Ctrl}}}

Command :: struct {
	// "end_task": its name for good, whatever its label and the language (lower case letters, digits, '.', '_', '-').
	// The person's key and alias for it, and the palette's memory of it ("command:<id>"), are stored by it. One id in two
	// tables is one command. Every command of a table has one (command_ids_check); the toolkit's palette command has none
	id:    string,
	label: string,     // "End task": the menu's, the palette's and the sheet's text
	group: string,     // "Processes": the palette's and the sheet's heading ("" none)
	// other words the palette finds it by, that its label does not say ("exit", "close" for Quit)
	tags:  []string,
	// its own keys, as many as it has, the first one in effect shown in menus and tooltips (a zero Chord among them:
	// none). A table built at run time keeps them in memory of its own, as its tags. The person's binding replaces them
	// all; a person's key on another command takes that one chord from it (command_keys_in_effect)
	keys:  []Chord,
	icon:  string,     // a glyph of the state's icon_font (Lucide's): the palette's line shows it ("" none)
	scope: Command_Scope,
	// a switch (Expand tools, Follow the output): it is on or off. Its menu line shows its check (menu_item's `checked`,
	// the program's state), the palette its mark (Palette_Commands_Options.checked) and stays open when it is chosen,
	// as a setting's switch does. What it is, constant; whether it is on, the program's at each read
	toggle: bool,
	// what it takes, each a value as a setting is (its name, storage, value kind, unit, choices, bounds, default): Enter
	// in the palette opens its form, each argument with the control of its value, and the choice gives the values
	// (Palette_Choice.arguments). A closed list the program fills: Palette_Commands_Options.choices; a start that follows
	// the program's state: Palette_Commands_Options.initial; a button that opens the form: palette_open_form
	arguments: []config.Def,
}

// Where a command's keys work (src/md/features/commands.md, "Window commands").
Command_Scope :: enum u8 {
	// The page's: its keys reach it as any key does: not from behind a dialog, not from a view's body that does not have
	// the focus.
	Page,
	// The window's (the palette, the keyboard shortcuts, the settings, close, quit): command_pressed takes its keys
	// whatever has the focus (a field, a list, a docked or floating view) and whatever the page, over a view shown as a
	// dialog too. Two things still keep a chord from it: a key that types text while a text field has the keyboard, and a
	// widget that claims the chords (keys_claim: a terminal, a shortcut recorder).
	Window,
}

// The chords a widget keeps while it has the keyboard (keys_claim): its box, and the chords it lets through.
KEYS_CLAIM_PASS_MAX :: 8
@(private)
Keys_Claim :: struct {
	owner: Key,
	pass:  [KEYS_CLAIM_PASS_MAX]Chord,
	count: int,
}

// A widget that has the keyboard and owns every chord (a terminal's grid, a shortcut recorder, an editor with its own
// use of Ctrl+K...) says so while it is built, at each build: command_pressed then takes none of the chords, a window
// command's neither, while `owner` has the keyboard, but the ones of `pass` (at most KEYS_CLAIM_PASS_MAX: the key that
// hides a terminal works from inside it). The claim of the last build counts too: a program reads its commands before it
// builds the widget. A claim of a box that does not have the keyboard is no claim. The caller names its reason in a comment.
keys_claim :: proc(owner: Key, pass: ..Chord) {
	s := gs()
	if owner == 0 || owner != s.focus_key { return }
	c := Keys_Claim{owner = owner}
	for p in pass {
		if c.count == KEYS_CLAIM_PASS_MAX { break }
		c.pass[c.count] = p
		c.count += 1
	}
	s.keys_claim_next = c
}

// Whether the widget that has the keyboard claimed `k` (keys_claim, in this build or the last).
@(private)
keys_claimed :: proc(s: ^State, k: Chord) -> bool {
	for c in ([]^Keys_Claim{&s.keys_claim_next, &s.keys_claim}) {
		if c.owner == 0 || c.owner != s.focus_key { continue }
		passed := false
		for p in c.pass[:c.count] { if p == k { passed = true; break } }
		if !passed { return true }
	}
	return false
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

// The text of a command's first key in effect (command_keys_in_effect), for a menu's line ("" when it has none): the
// person's, else its own.
command_shortcut :: proc(c: Command) -> string { return keys_first_text(state_keymap(), c) }

// Every key in effect of a command, " / " between them ("Ctrl+K / Ctrl+Shift+P"); a sequence reads "Ctrl+M, T".
command_keys_text :: proc(c: Command, allocator := context.temp_allocator) -> string {
	return keys_all_text(state_keymap(), c, allocator)
}

// A tooltip's text: the label and its first key in effect ("Kill (Shift+Delete)"), or the label alone; in the language
// in use.
command_tip :: proc(c: Command, allocator := context.temp_allocator) -> string {
	label := i18n.tr(c.label)
	k := keys_first_text(state_keymap(), c)
	if k == "" { return strings.clone(label, allocator) }
	return fmt.aprintf("%s (%s)", label, k, allocator = allocator)
}

// A command as the palette and the sheet show it: its label and its group in the language in use (a program's table holds
// its English, marked with i18n.later), and the words a search finds it by: its tags, and its English label and group when
// they read otherwise (one who knows a command by its English finds it too). In English: the command's own strings.
@(private)
command_shown :: proc(c: Command) -> (label, group: string, tags: []string) {
	label, group, tags = i18n.tr(c.label), i18n.tr(c.group), c.tags
	if raw_data(label) == raw_data(c.label) && raw_data(group) == raw_data(c.group) { return }
	all := make([]string, len(c.tags) + 2, context.temp_allocator)
	all[0], all[1] = c.label, c.group
	copy(all[2:], c.tags)
	return label, group, all
}

// Whether one of the command's keys in effect was pressed this frame (the press is taken: nothing else sees it). With a
// keymap (keymap_use): the person's binding alone when the command has one (a sequence: its second chord after its
// first), else each own key that no other command's binding took. A command that cannot act now (`disabled`) takes no
// key: the key stays for what else wants it, but a person's key on it is still taken from the others. A key that types
// text (command_key_types_text) is not taken while a text field has the keyboard: the character is the field's; nor a
// chord that the widget with the keyboard claims (keys_claim). A window command (scope .Window) takes its keys from
// behind a dialog and from a view's body without the focus too (src/md/features/commands.md). While a sequence's first
// chord is pending, no single chord acts. Its cost: a few map lookups per own key.
command_pressed :: proc(c: Command, disabled := false) -> bool {
	if disabled { return false }
	s := gs()
	km := s.keymap
	if b, ok := command_bound(km, c); ok { return binding_pressed(s, b, c.scope) }
	for k in c.keys {
		if chord_taken(km, c, k) { continue }
		if chord_pressed(k, c.scope) { return true }
	}
	return false
}

// Whether chord `k` of a command of `scope` was pressed this frame (the press is taken), by command_pressed's rules: a
// program that reads its keys with its own table reads each chord with it. Nothing while a sequence's first chord is
// pending: the next press is the sequence's.
chord_pressed :: proc(k: Chord, scope := Command_Scope.Page) -> bool {
	s := gs()
	if s.key_pending.key != .None || !chord_ready(s, k, scope) { return false }
	return key_press_any(k.key, k.mods)
}

// Whether a press of chord `k` would reach a command of `scope` now: the typing rule (`typing`), a widget's claim, a
// selection's copy, and the holds of a page command (a dialog, a view's body without the focus: key_press's).
@(private)
chord_ready :: proc(s: ^State, k: Chord, scope: Command_Scope, typing := true) -> bool {
	if k.key == .None { return false }
	if typing && command_key_types_text(k) && s.focus_key != 0 {
		if b := s.boxes[s.focus_key] or_else nil; b != nil && is_text_field(b) { return false }
	}
	if keys_claimed(s, k) { return false }
	// (text selected by the last press: its copy, read at the end of the build, takes the chord: text-selection.md)
	if (k == Chord{.C, {.Ctrl}} || k == Chord{.Insert, {.Ctrl}}) && selection_takes_copy(s) { return false }
	if scope == .Page && (keys_held_by_dialog(s) || keys_held_from_view(s)) { return false }
	return true
}

// The window commands of `commands` (scope .Window) whose keys a text field keeps (command_key_types_text), one line
// each, "<label>: <key>" as command_typing_keys says them. A program's test expects none: a window command's key that
// types text does nothing while a field has the keyboard, and then the command does not work everywhere.
command_window_typing_keys :: proc(commands: []Command, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for c in commands {
		if c.scope != .Window { continue }
		for line in command_typing_keys([]Command{c}, allocator) { append(&out, line) }
	}
	return out[:]
}

// Whether `c` types text in a field: a letter, a digit, a punctuation mark, Space, Backspace or keypad + and -, with no
// modifier or with Shift alone. Ctrl or Alt with any key, and the keys that type nothing (F1 to F12, Escape, Enter, Tab,
// Delete, Insert, the arrows, Home, End, Page Up, Page Down, Menu, Print) with any modifier, are false. No key: false.
command_key_types_text :: proc(c: Chord) -> bool {
	if c.mods - {.Shift} != {} { return false }
	#partial switch c.key {
	case .A ..= .Z, .N0 ..= .N9, .Space, .Backspace, .Comma, .Period, .Slash, .Minus, .Equal, .Num_Add, .Num_Subtract:
		return true
	}
	return false
}

// Every key of `commands` that types text (command_key_types_text), one line each: "<label>: <key>" ("Rectangle: R",
// "Add a step…: Shift+A"), the label as the table holds it and the key by its name in platform.Key ("N1", "Space"):
// the same text in every language. A program's test compares the lines with the ones it means: none when a field of
// its window always has the keyboard.
command_typing_keys :: proc(commands: []Command, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for c in commands {
		for k in c.keys {
			if !command_key_types_text(k) { continue }
			append(&out, fmt.aprintf("%s: %s%v", c.label, (.Shift in k.mods) ? "Shift+" : "", k.key, allocator = allocator))
		}
	}
	return out[:]
}

////////////////////////////////
// The palette's matcher (palette.odin)

// What a palette makes of `query` for one of its entries, best first: its label holds it whole or at the starts of its words
// (fuzzy_words), then with its tags (other words it is found by), then with its group; then the same with a slip or two in
// each word (fuzzy_typos), after every exact match. `ranges`: what lights in the label (none when the tags or the group
// found it). The palette ranks with it (rank_palette); a list of a program's own (a picker) too: with a needle and
// entries folded once (fuzzy_cache_needle, palette_entry_cached), nothing is folded again for each frame.
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

////////////////////////////////
// A list of lines under headings, built near its view only

// The top of line `k` in a list whose lines are `row_h` high, a heading of `heading_h` above some of them (`heading`;
// `headings`: the headings down to it, its own counted).
@(private)
heading_line_top :: proc(lines: []$T, k: int, row_h, heading_h: f32) -> f32 {
	return f32(k) * row_h + f32(lines[k].headings) * heading_h
}

// The lines to build in the scroll box `view`: those that meet its view, where it is heading (a jump, a reveal), and a
// screen each side ([first, last)); `above` and `below`: the room of the lines not built. Two searches by halves: a
// frame does not walk the lines.
@(private)
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
// The sheet of the keys

// The sheet: the program keeps it between frames, at a place that does not move while it is open. It keeps the list of
// its commands that have a key, made again only when the commands change.
Shortcuts_Sheet :: struct {
	entries:  [dynamic]Sheet_Entry,
	kept:     Sheet_Key,
	listings: int,            // how many times the list was made (a test reads it)
	commands: []Command,      // shortcuts_sheet_set's: the program's table, valid while the sheet is open
	extra:    []Sheet_Line,   // shortcuts_sheet_set's: the lines that are no command, valid while the sheet is open
	hidden:   []bool,         // shortcuts_sheet_set's: the commands not listed, by index (the palette's `hidden`)
	version:  u64,
}

// A line of the sheet that is no command: a key a widget owns (Up in a composer's history, a middle click). `keys` is
// written in English as a program's table writes keys ("Up / Down", "Esc, Esc", "Ctrl+Enter"): the sheet names each key
// in the language in use as it names a command's (platform.key_text); a word that names no key ("Middle click") stays
// as written, so a program translates such a word itself. `group` and `label` are translated as a command's (i18n.tr).
Sheet_Line :: struct {
	group, keys, label: string,
}

// What the sheet's list depends on: the commands and the extra lines (their version, or their address while it is 0),
// their counts, and the keymap's version (a person's key given or taken lists a command or not).
@(private)
Sheet_Key :: struct {
	valid:    bool,
	commands: rawptr,
	count:    int,
	extra:    rawptr,
	extra_count: int,
	hidden:   rawptr,
	hidden_count: int,
	version:  u64,
	keymap:   ^Keymap,
	keymap_version: u64,
}

// A line of the sheet: a command that has a key (`extra` false: its index, the palette's command at len(commands)) or an
// extra line (its index in `extra`); the group headings down to it, whether its group's heading is just above it.
@(private)
Sheet_Entry :: struct {
	index, headings: int,
	heading, extra:  bool,
}

shortcuts_sheet_destroy :: proc(sheet: ^Shortcuts_Sheet) {
	delete(sheet.entries)
	sheet.entries, sheet.kept = nil, {}
}

// The view of each sheet: its id, and the instance that is this sheet.
SHORTCUTS_VIEW :: "shortcuts"
@(private = "file")
sheet_instance :: proc(sheet: ^Shortcuts_Sheet) -> string { return fmt.tprintf("%x", uintptr(sheet)) }

// Opens the sheet (a view, home Dialog): every command of `commands` that has a key in effect (command_keys_in_effect),
// under its group's heading, its keys at the right (a person's in the accent), and the palette's command
// (palette_command) after them. The list is made again when the keymap's version moves. It scrolls when it is taller than SHEET_HEIGHT of the window; Escape and the close cross close it.
// `title` "": "Keyboard shortcuts", in the language in use. `version`: the commands' version as the program counts
// their changes (their keys too: a table rebound in place gives one); 0: the table does not change in place. The list
// of the commands that have a key is kept, and only the lines near the view are built. One open takes these commands.
// `extra`: lines that are no command (a widget's keys), each after the last command of its group, or under its own
// heading after them all when no command of its group has a key; `version` counts their changes too. `hidden`: by
// index, the commands that do not exist in this state, not listed (the palette's Palette_Commands_Options.hidden, the
// same slice); `version` counts its changes too.
shortcuts_sheet_open :: proc(sheet: ^Shortcuts_Sheet, commands: []Command, title := "", version: u64 = 0, extra: []Sheet_Line = nil, hidden: []bool = nil) {
	vs := views()
	if !view_registered(vs, SHORTCUTS_VIEW) {
		view_register(vs, SHORTCUTS_VIEW, sheet_view, View_Options{title = "Keyboard shortcuts", width_em = SHEET_WIDTH_EM, quick = true})
	}
	shortcuts_sheet_set(sheet, commands, version, extra, hidden)
	r := view_open_raw(vs, SHORTCUTS_VIEW, sheet, typeid_of(Shortcuts_Sheet), sheet_instance(sheet), nil)
	delete(r.title, r.allocator)
	r.title = strings.clone(title, r.allocator)
	r.icon = lucide.KEYBOARD
}

// Gives the sheet another table and other extra lines, open or not, without opening or closing it: a program that
// makes its table again (another language, a table rebound) hands the new one over, and an open sheet lists it at its
// next build. `version`, `extra` and `hidden` as shortcuts_sheet_open's: a table rebuilt in place takes another version.
shortcuts_sheet_set :: proc(sheet: ^Shortcuts_Sheet, commands: []Command, version: u64 = 0, extra: []Sheet_Line = nil, hidden: []bool = nil) {
	sheet.commands, sheet.extra, sheet.hidden, sheet.version = commands, extra, hidden, version
}

shortcuts_sheet_is_open :: proc(sheet: ^Shortcuts_Sheet) -> bool { return view_is_open(views(), SHORTCUTS_VIEW, sheet_instance(sheet)) }

shortcuts_sheet_close :: proc(sheet: ^Shortcuts_Sheet) { view_close(views(), SHORTCUTS_VIEW, sheet_instance(sheet)) }

@(private = "file")
sheet_view :: proc(v: ^View, sheet: ^Shortcuts_Sheet) {
	s := gs()
	em := font_size()
	w := em * SHEET_WIDTH_EM
	key := Sheet_Key{valid = true, count = len(sheet.commands), extra_count = len(sheet.extra), hidden_count = len(sheet.hidden), version = sheet.version, keymap = s.keymap}
	if s.keymap != nil { key.keymap_version = s.keymap.version }
	if sheet.version == 0 { key.commands, key.extra, key.hidden = raw_data(sheet.commands), raw_data(sheet.extra), raw_data(sheet.hidden) }
	if key != sheet.kept {
		sheet.kept = key
		sheet.listings += 1
		sheet_list(sheet, sheet.commands, sheet.extra, sheet.hidden, s.keymap)
	}
	sheet_body(sheet, sheet.commands, sheet.extra, s.keymap, w, em, s.window_size.y)
}

// The commands the sheet lists: the program's, then the toolkit's palette command (index len(commands)): the sheet
// lists it itself, as palette_keys reads its keys, so no program's table holds a line for it.
@(private = "file")
sheet_command :: proc(commands: []Command, i: int) -> Command {
	return i < len(commands) ? commands[i] : palette_command()
}

// (the commands that have a key in effect: one whose own keys others took, and that has no key of the person's, is not
// listed; one with an alias and no key neither: the sheet is about keys)
// (each group once, where its first command stands, its commands in the table's order: a table that interleaves its
// groups, as the palette's does by meaning, would show a heading twice)
// (an extra line goes after the last listed command of its group; a group no listed command has gets its own heading
// after all the commands)
@(private = "file")
sheet_list :: proc(sheet: ^Shortcuts_Sheet, commands: []Command, extra: []Sheet_Line, hidden: []bool, km: ^Keymap) {
	clear(&sheet.entries)
	Listed :: struct { rank, i: int }
	listed := make([dynamic]Listed, 0, len(commands) + 1, context.temp_allocator)
	rank_of := make(map[string]int, context.temp_allocator)
	last_of := make(map[string]int, context.temp_allocator)
	for i in 0 ..= len(commands) {
		if i < len(hidden) && i < len(commands) && hidden[i] { continue }
		c := sheet_command(commands, i)
		if keys_first_text(km, c) == "" { continue }
		if c.group not_in rank_of { rank_of[c.group] = len(rank_of) }
		append(&listed, Listed{rank_of[c.group], i})
		last_of[c.group] = i
	}
	slice.sort_by(listed[:], proc(a, b: Listed) -> bool { return a.rank < b.rank || (a.rank == b.rank && a.i < b.i) })
	extras_of := make(map[int][dynamic]int, context.temp_allocator)   // a command's index: the extra lines after it
	alone := make([dynamic]int, 0, len(extra), context.temp_allocator)
	for x, k in extra {
		if i, ok := last_of[x.group]; ok {
			if i not_in extras_of { extras_of[i] = make([dynamic]int, context.temp_allocator) }
			append(&extras_of[i], k)
		} else {
			append(&alone, k)
		}
	}
	group := ""
	headings := 0
	add :: proc(sheet: ^Shortcuts_Sheet, group: ^string, headings: ^int, g: string, index: int, extra: bool) {
		heading := g != group^
		if heading { headings^ += 1 }
		group^ = g
		append(&sheet.entries, Sheet_Entry{index = index, headings = headings^, heading = heading, extra = extra})
	}
	for l in listed {
		i := l.i
		add(sheet, &group, &headings, sheet_command(commands, i).group, i, false)
		if xs, ok := extras_of[i]; ok { for k in xs { add(sheet, &group, &headings, extra[k].group, k, true) } }
	}
	for k in alone { add(sheet, &group, &headings, extra[k].group, k, true) }
}

@(private = "file")
sheet_body :: proc(sheet: ^Shortcuts_Sheet, commands: []Command, extra: []Sheet_Line, km: ^Keymap, w, em, window_h: f32) {
	pad := em * 1.2
	line_h := dense(em * 1.7)
	heading_h := em * 2.2   // (a gap of em * 0.5 and the heading)
	lines := sheet.entries[:]
	next({width = px(w), height = children_sum(), axis = .Y})
	if column(id = "###sheet") {
		spacer(px(em * 0.5))
		height := min(window_h * SHEET_HEIGHT, f32(len(lines)) * em * 2.2 + em * 6)
		next({width = px(w), height = px(height)})
		if scroll_y("###sheet_list") {
			first, last, above, below := heading_lines_band(lines, parent_box(), line_h, heading_h)
			if above > 0 { spacer(px(above)) }
			for line in lines[first:last] {
				// (a table that shrank without a version: listed again next frame)
				if line.extra ? line.index >= len(extra) : line.index > len(commands) { continue }
				group, text, keys: string
				own: bool
				if line.extra {
					x := extra[line.index]
					group, text, keys = x.group, x.label, platform.key_text(x.keys)
				} else {
					c := sheet_command(commands, line.index)
					group, text, keys = c.group, c.label, keys_all_text(km, c)
					_, own = command_bound(km, c)
				}
				// (an extra line's ids apart from the commands': the same index is two lines)
				kind := line.extra ? "x" : ""
				if line.heading {
					spacer(px(em * 0.5))
					next({width = fill(), height = px(em * 1.7)})
					if row(.Center, {}, fmt.tprintf("###sheet_group_%s%d", kind, line.index)) {
						spacer(px(pad))
						next({width = fill(), height = pct(1), text_pad = 0, fg = color("accent")})
						label(fmt.tprintf("%s###g", i18n.tr(group)))
					}
				}
				next({width = fill(), height = px(line_h)})
				if row(.Center, {}, fmt.tprintf("###sheet_line_%s%d", kind, line.index)) {
					spacer(px(pad))
					next({width = fill(), height = pct(1), text_pad = 0})
					label(fmt.tprintf("%s###l", i18n.tr(text)))
					// (a person's key in the accent: the sheet says which keys are one's own)
					if own {
						next({width = text_size(), height = pct(1), text_pad = 0, fg = color("accent")})
						label(fmt.tprintf("%s###k", keys))
					} else if tags("weak") {
						next({width = text_size(), height = pct(1), text_pad = 0})
						label(fmt.tprintf("%s###k", keys))
					}
					spacer(px(pad))
				}
			}
			if below > 0 { spacer(px(below)) }
			spacer(px(em * 0.5))
		}
	}
}
