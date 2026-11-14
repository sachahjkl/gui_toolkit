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
	first:      Maybe(int),   // a command put first while something is typed (an alias typed whole: its command)
	// the table's version as the program counts its changes (labels, groups, tags, icons, `names`, `keys`); 0: the
	// palette keys on the table's address, and `disabled` is compared
	version:    u64,
	// what Ctrl+Enter, Alt+Enter and Shift+Enter do with a command (classeur: "Set a key", "Add an alias"): literals, or
	// as long-lived as the palette
	alternates: Palette_Alternates,
}

// The commands source: the program's table, `disabled`, and the options, copied but the table.
Palette_Commands :: struct {
	source:   Palette_Source,
	table:    []Command,   // the program's: valid while the palette is open
	disabled: [dynamic]bool,
	names:    []string,    // (owned)
	keys:     []string,    // (owned)
	first:    Maybe(int),
	version:  u64,
	sources:  [3]rawptr,   // the table's, `names`'s and `keys`'s addresses (version 0)
	count:    int,
	made:     bool,
}

// The views' moves of the window the palette is open over ("Float Files", "Dock Files to the right"): the toolkit runs
// them. The palette's own view is not listed.
Palette_Moves :: struct {
	source: Palette_Source,
	vc:     View_Commands,
}

// What the palette lists of the program's: its commands (the table, valid while the palette is open), those that cannot
// act now (`disabled[i]`; nil: none), and the options. The first call adds the commands source (`>`, plain, listed
// with nothing typed, remembered) and the views' moves source (`>`, plain). Call it when they change, or at each build:
// it copies only on a change. A command chosen comes back as Palette_Choice.command, its index in the table.
palette_commands :: proc(p: ^Command_Palette, table: []Command, disabled: []bool, o := Palette_Commands_Options{}) {
	c := &p.commands
	if c.source.read == nil {
		c.source = {
			name = "command", title = i18n.later("Commands"), prefix = .Commands, plain = true, remember = true, listed = true,
			enter = i18n.later("Run"), read = palette_commands_read, toolkit = true,
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
	same := c.made && o.version == c.version && len(table) == c.count && palette_maybe_eq(o.first, c.first) && len(disabled) == len(c.disabled)
	if same && o.version == 0 { same = c.sources == [3]rawptr{raw_data(table), raw_data(o.names), raw_data(o.keys)} }
	if same { for d, i in disabled { if d != c.disabled[i] { same = false; break } } }
	if same { return }
	resize(&c.disabled, len(disabled))
	copy(c.disabled[:], disabled)
	palette_strings_free(c.names)
	palette_strings_free(c.keys)
	c.names, c.keys = palette_strings_clone(o.names), palette_strings_clone(o.keys)
	c.first, c.version, c.count, c.made = o.first, o.version, len(table), true
	c.sources = {raw_data(table), raw_data(o.names), raw_data(o.keys)}
	c.source.version += 1
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
	c^ = {}
}

// The commands in the language in use (their English among their tags), each one's keys and whether it can act.
@(private = "file")
palette_commands_read :: proc(p: ^Command_Palette, src: ^Palette_Source, q: Palette_Question) {
	c := &p.commands
	items := make([]Palette_Item, len(c.table), context.temp_allocator)
	for cmd, i in c.table {
		label, group, tags := command_shown(cmd)
		id := i < len(c.names) && c.names[i] != "" ? c.names[i] : cmd.label
		keys := i < len(c.keys) ? c.keys[i] : command_shortcut(cmd)
		items[i] = {id = id, title = label, group = group, tags = tags, icon = cmd.icon, keys = keys, disabled = i < len(c.disabled) && c.disabled[i]}
	}
	palette_answer(p, src, q.serial, items)
}

// (at each build while open) The moves follow the views of the window the palette is over.
@(private = "file")
palette_moves_poll :: proc(p: ^Command_Palette, src: ^Palette_Source) {
	if views_commands_update(&p.moves.vc, views(), p.owner) { src.version += 1 }
}

// A move's id: its view, its instance, its act.
@(private = "file")
palette_move_id :: proc(a: View_Command) -> string { return fmt.tprintf("%s|%s|%v", a.id, a.instance, a.act) }

@(private = "file")
palette_moves_read :: proc(p: ^Command_Palette, src: ^Palette_Source, q: Palette_Question) {
	vc := &p.moves.vc
	items := make([dynamic]Palette_Item, 0, len(vc.commands), context.temp_allocator)
	for cmd, i in vc.commands {
		a := vc.acts[i]
		if a.id == PALETTE_VIEW { continue }   // (the palette does not move itself from its own list)
		append(&items, Palette_Item{id = palette_move_id(a), title = cmd.label, group = cmd.group, icon = cmd.icon})
	}
	palette_answer(p, src, q.serial, items[:])
}

@(private = "file")
palette_moves_act :: proc(p: ^Command_Palette, src: ^Palette_Source, c: Palette_Choice) {
	vc := &p.moves.vc
	for a in vc.acts {
		if palette_move_id(a) == c.id { views_command_run(views(), a); return }
	}
}
