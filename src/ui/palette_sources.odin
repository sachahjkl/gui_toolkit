package ui

// The toolkit's sources of the palette that live in ui: the program's commands, and the views' moves. The settings'
// source is prefs_page's (palette_settings_add). src/md/features/palette.md, "The toolkit's sources".

import "core:fmt"
import "core:strings"
import i18n "../i18n"

// What the commands source takes beside the table.
Palette_Commands_Options :: struct {
	// each command's id, by index: its key in the usage memory ("command:<id>"). nil or "": its label as the table holds
	// it (English): the memory then holds across languages
	names:      []string,
	keys:       []string,     // each command's keys' text as the program shows them ("Ctrl+M, T", its user's own); nil: its first chord
	first:      Maybe(int),   // a command put first while something is typed (an alias typed whole: its command); not when disabled
	// the version of the table and of `disabled` as the program counts their changes (labels, groups, tags, icons,
	// `names`, `keys`, what can act). 0: neither changes in place; the palette knows them by their addresses
	version:    u64,
	// what Ctrl+Enter, Alt+Enter and Shift+Enter do with a command (classeur: "Set a key", "Add an alias"): literals, or
	// as long-lived as the palette
	alternates: Palette_Alternates,
	// each command's detail, by index ("Session · Fix the build": what it acts on), weak after its title; part of
	// `version` (a new detail, a new version). Shown, not searched: a detail shared by many commands would find them all
	details:    []string,
	// whether toggle command `index` (Command.toggle) is on now: read for the rows built only, at each build, so a flip
	// shows at once and ranks nothing again. nil: no mark. `user` is given to it
	checked:    proc(user: rawptr, index: int) -> bool,
	user:       rawptr,
}

// The commands source: the program's table, `disabled`, and the options, copied but the table.
Palette_Commands :: struct {
	source:   Palette_Source,
	table:    []Command,   // the program's: valid while the palette is open
	disabled: [dynamic]bool,
	names:    []string,    // (owned)
	keys:     []string,    // (owned)
	details:  []string,    // (owned)
	first:    Maybe(int),
	version:  u64,
	sources:  [5]rawptr,   // the addresses of the table, `disabled`, `names`, `keys` and `details` (version 0)
	count:    int,
	made:     bool,
	checked:  proc(user: rawptr, index: int) -> bool,
	user:     rawptr,
	index:    map[string]int,   // a command's index by its id (keys: `names`' or the table's labels): the mark's lookup
}

// The views' moves of the window the palette is open over ("Float Files", "Dock Files to the right"): the toolkit runs
// them. The palette's own view is not listed.
Palette_Moves :: struct {
	source: Palette_Source,
	vc:     View_Commands,
	listed: u64,   // a fingerprint of the moves listed (the palette's own left out) when the version last moved
}

// What the palette lists of the program's: its commands (the table, valid while the palette is open), those that cannot
// act now (`disabled[i]`; nil: none), and the options. The first call adds the commands source (`>`, plain, listed
// with nothing typed, remembered) and the views' moves source (`>`, plain). Call it at each build: it compares the
// version, the counts and the addresses only, and copies on a change. A command chosen: palette_chosen_command.
palette_commands :: proc(p: ^Command_Palette, table: []Command, disabled: []bool, o := Palette_Commands_Options{}) {
	c := &p.commands
	if c.source.read == nil {
		c.source = {
			name = "command", title = i18n.later("Commands"), prefix = .Commands, plain = true, remember = true, listed = true,
			enter = i18n.later("Run"), read = palette_commands_read, mark = palette_commands_mark, user = p, toolkit = true,
		}
		p.moves.source = {
			name = "move", title = i18n.later("Views"), prefix = .Commands, plain = true, enter = i18n.later("Run"),
			read = palette_moves_read, poll = palette_moves_poll, act = palette_moves_act, toolkit = true,
		}
		palette_add(p, &c.source)
		palette_add(p, &p.moves.source)
	}
	c.table = table
	c.source.alternates = o.alternates
	c.source.user = p
	c.checked, c.user = o.checked, o.user   // (read at each build: no version)
	addresses := [5]rawptr{raw_data(table), raw_data(disabled), raw_data(o.names), raw_data(o.keys), raw_data(o.details)}
	if c.made && o.version == c.version && len(table) == c.count && len(disabled) == len(c.disabled) && palette_maybe_eq(o.first, c.first) &&
		(o.version != 0 || addresses == c.sources) { return }
	resize(&c.disabled, len(disabled))
	copy(c.disabled[:], disabled)
	palette_strings_free(c.names)
	palette_strings_free(c.keys)
	palette_strings_free(c.details)
	c.names, c.keys, c.details = palette_strings_clone(o.names), palette_strings_clone(o.keys), palette_strings_clone(o.details)
	c.first, c.version, c.count, c.made, c.sources = o.first, o.version, len(table), true, addresses
	// (the ids' index, made on a change only: the mark of a row in view is one lookup)
	clear(&c.index)
	for cmd, i in table { c.index[palette_command_id(c, cmd, i)] = i }
	c.source.version += 1
}

// A command's id: its name, else its label as the table holds it.
@(private = "file")
palette_command_id :: proc(c: ^Palette_Commands, cmd: Command, i: int) -> string {
	return i < len(c.names) && c.names[i] != "" ? c.names[i] : cmd.label
}

// The mark of a toggle command in view: the program's `checked`.
@(private = "file")
palette_commands_mark :: proc(src: ^Palette_Source, id: string) -> bool {
	p := (^Command_Palette)(src.user)
	c := &p.commands
	if c.checked == nil { return false }
	i, ok := c.index[id]
	if !ok || i >= len(c.table) || !c.table[i].toggle { return false }
	return c.checked(c.user, i)
}

@(private = "file")
palette_maybe_eq :: proc(a, b: Maybe(int)) -> bool {
	x, has_x := a.?
	y, has_y := b.?
	return has_x == has_y && (!has_x || x == y)
}

@(private = "file")
palette_strings_clone :: proc(list: []string) -> []string {
	if list == nil { return nil }
	out := make([]string, len(list))
	for x, i in list { out[i] = strings.clone(x) }
	return out
}

@(private = "file")
palette_strings_free :: proc(list: []string) {
	for x in list { delete(x) }
	delete(list)
}

@(private)
palette_commands_free :: proc(c: ^Palette_Commands) {
	delete(c.disabled)
	palette_strings_free(c.names)
	palette_strings_free(c.keys)
	palette_strings_free(c.details)
	delete(c.index)
	c^ = {}
}

// The commands in the language in use (their English among their tags), each one's keys and whether it can act, in an
// answer of their own: the table can change once the palette closes, the answer stays.
@(private = "file")
palette_commands_read :: proc(p: ^Command_Palette, src: ^Palette_Source, q: Palette_Question) {
	c := &p.commands
	a: Palette_Answer
	al := palette_answer_allocator(&a)
	a.items = make([]Palette_Item, len(c.table), al)
	for cmd, i in c.table {
		label, group, tags := command_shown(cmd)
		keys := i < len(c.keys) ? c.keys[i] : command_shortcut(cmd)
		detail := i < len(c.details) ? c.details[i] : ""
		it := Palette_Item{
			id = palette_command_id(c, cmd, i), title = label, detail = detail, group = group, tags = tags, icon = cmd.icon, keys = keys,
			disabled = i < len(c.disabled) && c.disabled[i], stays = cmd.toggle,
		}
		a.items[i] = palette_item_clone(it, al)
	}
	palette_answer(q, &a)
}

// (at each build while open) The moves follow the views of the window the palette is over. The views' version moves
// with any view's step, the palette's own too (its opening, its first frame shown): the source is read again, and the
// list ranked again, only when the moves it lists changed (a toggle flipped with the palette open ranked once more).
@(private = "file")
palette_moves_poll :: proc(p: ^Command_Palette, src: ^Palette_Source) {
	m := &p.moves
	if !views_commands_update(&m.vc, views(), p.owner) { return }
	// (FNV-1a over what the source lists: one pass over the open views' moves, only when the views changed)
	h := u64(0xcbf29ce484222325)
	mix :: proc(h: ^u64, s: string) {
		for i in 0 ..< len(s) { h^ = (h^ ~ u64(s[i])) * 0x100000001b3 }
		h^ = (h^ ~ 0xff) * 0x100000001b3   // (a separator: "ab"+"c" is not "a"+"bc")
	}
	for cmd, i in m.vc.commands {
		a := m.vc.acts[i]
		if a.id == PALETTE_VIEW { continue }
		mix(&h, a.id); mix(&h, a.instance); mix(&h, cmd.label); mix(&h, cmd.group); mix(&h, cmd.icon)
		h = (h ~ u64(a.act)) * 0x100000001b3
	}
	if h == m.listed && src.version != 0 { return }
	m.listed = h
	src.version += 1
}

// A move's id: its view, its instance, its act.
@(private = "file")
palette_move_id :: proc(a: View_Command, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s|%s|%v", a.id, a.instance, a.act, allocator = allocator)
}

@(private = "file")
palette_moves_read :: proc(p: ^Command_Palette, src: ^Palette_Source, q: Palette_Question) {
	vc := &p.moves.vc
	a: Palette_Answer
	al := palette_answer_allocator(&a)
	items := make([dynamic]Palette_Item, 0, len(vc.commands), al)
	for cmd, i in vc.commands {
		m := vc.acts[i]
		if m.id == PALETTE_VIEW { continue }   // (the palette does not move itself from its own list)
		append(&items, palette_item_clone({id = palette_move_id(m), title = cmd.label, group = cmd.group, icon = cmd.icon}, al))
	}
	a.items = items[:]
	palette_answer(q, &a)
}

@(private = "file")
palette_moves_act :: proc(p: ^Command_Palette, src: ^Palette_Source, c: Palette_Choice) {
	vc := &p.moves.vc
	for m in vc.acts {
		if palette_move_id(m) == c.id { views_command_run(views(), m); return }
	}
}
