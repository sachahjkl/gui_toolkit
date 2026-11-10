package ui

// A program's commands in one table: each one's name, its group and its keys. The same table gives:
//
//   command_pressed   the key handling: a command's keys, pressed this frame
//   chord_text        the text of a key in a menu's line ("Ctrl+Shift+P"); command_tip, a tooltip's ("Kill (Shift+Delete)")
//   palette           the command palette: a menu that searches (fuzzy), every command with its keys, grouped
//   shortcuts_sheet   a dialog that lists every command's keys, grouped
//
// A program keeps its commands in a table of its own (an enum of its commands indexing an array of Command) and says
// each frame which ones can act now (the `enabled` of palette): one place names a command and its keys, and its menus,
// tooltips, palette and sheet all say the same.
//
//   COMMANDS := [Cmd]ui.Command{.Kill = {label = "Kill…", group = "Processes", keys = {{.Delete, {.Shift}}, {}}}, ...}
//   if ui.command_pressed(COMMANDS[.Kill]) { kill() }
//   ui.menu_item(COMMANDS[.Kill].label, ui.command_shortcut(COMMANDS[.Kill]))
//   if ui.key_press(.K, {.Ctrl}) { ui.palette_open(palette_key) }
//   if i := ui.palette(palette_key, COMMANDS[:], enabled[:]); i >= 0 { run(Cmd(i)) }

import "core:fmt"
import "core:slice"
import "core:strings"
import "../platform"

// The palette's width when none is given, in em; where its top is, a share of the window's height.
PALETTE_WIDTH_EM :: 32
PALETTE_TOP :: 0.12
// What a match of the group's letters (not the label's alone) loses against one of the label's.
PALETTE_GROUP_MATCH_PENALTY :: 100
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
	keys:  [2]Chord,   // its keys, the first one shown in menus and tooltips; {} none
}

// "Ctrl+Shift+P", "Delete", "F5" ("" for no key). Modifiers come first, in the order Ctrl, Shift, Alt.
chord_text :: proc(c: Chord, allocator := context.temp_allocator) -> string {
	if c.key == .None { return "" }
	b := strings.builder_make(allocator)
	if .Ctrl in c.mods { strings.write_string(&b, "Ctrl+") }
	if .Shift in c.mods { strings.write_string(&b, "Shift+") }
	if .Alt in c.mods { strings.write_string(&b, "Alt+") }
	strings.write_string(&b, key_name(c.key))
	return strings.to_string(b)
}

// A key's name as keyboards and menus print it.
key_name :: proc(k: platform.Key) -> string {
	#partial switch k {
	case .A ..= .Z:
		letters := KEY_LETTERS
		return letters[int(k) - int(platform.Key.A)]
	case .N0 ..= .N9:
		digits := KEY_DIGITS
		return digits[int(k) - int(platform.Key.N0)]
	case .F1 ..= .F12:
		functions := KEY_FUNCTIONS
		return functions[int(k) - int(platform.Key.F1)]
	case .Escape:     return "Esc"
	case .Return:     return "Enter"
	case .Tab:        return "Tab"
	case .Space:      return "Space"
	case .Backspace:  return "Backspace"
	case .Delete:     return "Delete"
	case .Insert:     return "Insert"
	case .Left:       return "Left"
	case .Right:      return "Right"
	case .Up:         return "Up"
	case .Down:       return "Down"
	case .Home:       return "Home"
	case .End:        return "End"
	case .Page_Up:    return "Page Up"
	case .Page_Down:  return "Page Down"
	case .Comma:      return ","
	case .Period:     return "."
	case .Slash:      return "/"
	case .Minus:      return "-"
	case .Equal:      return "="
	case .Menu:       return "Menu"
	case .Num_Add:    return "Num +"
	case .Num_Subtract: return "Num -"
	}
	return ""
}

@(private = "file")
KEY_LETTERS :: [26]string{"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"}
@(private = "file")
KEY_DIGITS :: [10]string{"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
@(private = "file")
KEY_FUNCTIONS :: [12]string{"F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"}

// The text of a command's first key, for a menu's line ("" when it has none).
command_shortcut :: proc(c: Command) -> string { return chord_text(c.keys[0]) }

// Every key of a command, apart by commas ("Ctrl+K, Ctrl+Shift+P").
command_keys_text :: proc(c: Command, allocator := context.temp_allocator) -> string {
	parts := make([dynamic]string, 0, len(c.keys), context.temp_allocator)
	for k in c.keys { if k.key != .None { append(&parts, chord_text(k)) } }
	return strings.join(parts[:], ", ", allocator)
}

// A tooltip's text: the label and its first key ("Kill (Shift+Delete)"), or the label alone.
command_tip :: proc(c: Command, allocator := context.temp_allocator) -> string {
	k := command_shortcut(c)
	if k == "" { return strings.clone(c.label, allocator) }
	return fmt.aprintf("%s (%s)", c.label, k, allocator = allocator)
}

// Whether one of the command's keys was pressed this frame (the press is taken: nothing else sees it). A command that
// cannot act now (`enabled` false) takes no key: the key stays for what else wants it.
command_pressed :: proc(c: Command, enabled := true) -> bool {
	if !enabled { return false }
	for k in c.keys {
		if k.key != .None && key_press(k.key, k.mods) { return true }
	}
	return false
}

////////////////////////////////
// The palette

// Opens the palette `key`: a menu at the top centre of the window that searches what is typed, its first command
// selected.
palette_open :: proc(key: Key, width_em: f32 = PALETTE_WIDTH_EM) {
	s := gs()
	w := font_size() * width_em
	ctx_menu_open(key, {max((s.window_size.x - w) * 0.5, 0), s.window_size.y * PALETTE_TOP}, from_keyboard = true, search = true)
}

// The palette `key` while it is open: every command, under its group's heading, with its keys. What is typed keeps the
// commands whose label and group have its letters in order, the best matches first (the headings go then; each line
// says its group); the first one is selected. A command that cannot act now (`enabled[i]` false; nil: all can) is
// greyed. Returns the index of the command chosen, -1 when none is.
palette :: proc(key: Key, commands: []Command, enabled: []bool = nil, width_em: f32 = PALETTE_WIDTH_EM) -> (chosen: int) {
	chosen = -1
	// (the block of ctx_menu is the menu: its items are built inside it)
	if ctx_menu(key, font_size() * width_em) { chosen = palette_items(commands, enabled) }
	return
}

@(private = "file")
palette_items :: proc(commands: []Command, enabled: []bool) -> (chosen: int) {
	chosen = -1
	lv, _ := menu_current()
	query := lv != nil ? menu_query(lv) : ""
	item :: proc(commands: []Command, enabled: []bool, i: int, searching: bool) -> bool {
		c := commands[i]
		text := c.label
		if searching && c.group != "" { text = fmt.tprintf("%s  ·  %s", c.label, c.group) }
		on := enabled == nil || (i < len(enabled) && enabled[i])
		return menu_item(fmt.tprintf("%s###palette_%d", text, i), command_shortcut(c), enabled = on).clicked
	}
	if query == "" {
		group := ""
		for c, i in commands {
			if c.group != group {
				if i > 0 { menu_separator() }
				if c.group != "" { menu_heading(c.group) }
			}
			group = c.group
			if item(commands, enabled, i, false) { chosen = i }
		}
		return
	}
	// a search: the best matches first (the label's letters matter more than the group's), then in the table's order
	Ranked :: struct { index, score: int }
	ranked := make([dynamic]Ranked, 0, len(commands), context.temp_allocator)
	for c, i in commands {
		if score, _, ok := fuzzy_score(query, c.label); ok {
			append(&ranked, Ranked{i, score})
		} else if score2, _, ok2 := fuzzy_score(query, fmt.tprintf("%s %s", c.label, c.group)); ok2 {
			append(&ranked, Ranked{i, score2 - PALETTE_GROUP_MATCH_PENALTY})
		}
	}
	slice.stable_sort_by(ranked[:], proc(a, b: Ranked) -> bool { return a.score > b.score })
	for r in ranked { if item(commands, enabled, r.index, true) { chosen = r.index } }
	return
}

////////////////////////////////
// The sheet of the keys

// The dialog `id` while `open`: every command that has a key, under its group's heading, its keys at the right. It
// scrolls when it is taller than SHEET_HEIGHT of the window; Escape and its Close button close it.
shortcuts_sheet :: proc(id: string, commands: []Command, open: ^bool, title := "Keyboard shortcuts", width_em: f32 = SHEET_WIDTH_EM) {
	s := gs()
	em := font_size()
	w := em * width_em
	if modal(id, w, open) { sheet_body(commands, open, title, w, em, s.window_size.y) }
}

@(private = "file")
sheet_body :: proc(commands: []Command, open: ^bool, title: string, w, em, window_h: f32) {
	pad := em * 1.2
	next({width = px(w), height = children_sum(), axis = .Y})
	if column(id = "###sheet") {
		spacer(px(pad * 0.8))
		next({width = px(w), height = children_sum()})
		if row(.Center, {}, "###sheet_title") {
			spacer(px(pad))
			next({width = fill(), height = px(em * 1.8), font_size = em * 1.2, text_pad = 0})
			label(fmt.tprintf("%s###sheet_title_text", title))
			spacer(px(pad))
		}
		spacer(px(em * 0.5))
		lines := 0
		for c in commands { if c.keys[0].key != .None { lines += 1 } }
		height := min(window_h * SHEET_HEIGHT, f32(lines) * em * 2.2 + em * 6)
		next({width = px(w), height = px(height)})
		if scroll_y("###sheet_list") {
			group := ""
			for c, i in commands {
				if c.keys[0].key == .None { continue }
				if c.group != group {
					group = c.group
					spacer(px(em * 0.5))
					next({width = fill(), height = px(em * 1.7)})
					if row(.Center, {}, fmt.tprintf("###sheet_group_%d", i)) {
						spacer(px(pad))
						next({width = fill(), height = pct(1), text_pad = 0, fg = color("accent")})
						label(fmt.tprintf("%s###g", group))
					}
				}
				next({width = fill(), height = px(dense(em * 1.7))})
				if row(.Center, {}, fmt.tprintf("###sheet_line_%d", i)) {
					spacer(px(pad))
					next({width = fill(), height = pct(1), text_pad = 0})
					label(fmt.tprintf("%s###l", c.label))
					if tags("weak") {
						next({width = text_size(), height = pct(1), text_pad = 0})
						label(fmt.tprintf("%s###k", command_keys_text(c)))
					}
					spacer(px(pad))
				}
			}
			spacer(px(em * 0.5))
		}
		hline(px(w))
		spacer(px(em * 0.6))
		next({width = px(w), height = children_sum()})
		if row(.Center, {}, "###sheet_foot") {
			spacer(fill())
			next({width = text_size(em * 1.2), height = px(dense(em * 2.1))})
			if button("Close###sheet_close").clicked { open^ = false }
			spacer(px(pad))
		}
		spacer(px(em * 0.6))
	}
}
