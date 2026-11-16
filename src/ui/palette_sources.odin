package ui

// The toolkit's sources of the palette that live in ui: the program's commands, and the views' moves. The settings'
// source is prefs_page's (palette_settings_add). src/md/features/palette.md, "The toolkit's sources".

import "core:fmt"
import "core:strings"
import config "../config"
import i18n "../i18n"

// What the commands source takes beside the table. A command's id is its key in the usage memory ("command:<id>"); its
// keys shown are the keys in effect, the person's (keymap.odin); an alias typed whole puts its command first.
Palette_Commands_Options :: struct {
	// the version of the table and of `disabled` as the program counts their changes (ids, labels, groups, tags, icons,
	// keys, what can act). 0: neither changes in place; the palette knows them by their addresses. A change of the keymap
	// needs none: the source follows its version
	version:    u64,
	// the values a String argument without its own choices may take, and their labels (English, i18n.later), for
	// command `index` (Command.arguments); nil, nil: a free field. Read when its form opens
	choices:    proc(user: rawptr, index: int, argument: string) -> (labels, values: []string),
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
	details:  []string,    // (owned)
	version:  u64,
	sources:  [3]rawptr,   // the addresses of the table, `disabled` and `details` (version 0)
	count:    int,
	made:     bool,
	checked:  proc(user: rawptr, index: int) -> bool,
	choices:  proc(user: rawptr, index: int, argument: string) -> (labels, values: []string),
	user:     rawptr,
	index:    map[string]int,   // a command's index by its id: the mark's and the alias's lookup
	// the keymap of the window it was given in (keymap_use) and its version when the items were made: the keys shown,
	// the aliases as tags and the alternates follow it
	keymap:   ^Keymap,
	keymap_version: u64,
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
	km := state_keymap()   // (nil before any window: a program may fill its palette first; a later call reads it)
	c.source.alternates = {}
	if km != nil { c.source.alternates.ctrl, c.source.alternates.alt = i18n.later("Set a key"), i18n.later("Make the letters its alias") }
	c.source.user = p
	// (a command with arguments opens its form with the forms runner: prefs_page's, which has the control table)
	c.source.runner = p.forms.open != nil ? &p.forms : nil
	c.checked, c.choices, c.user = o.checked, o.choices, o.user   // (read at each build or each form: no version)
	keymap_version := km != nil ? km.version : 0
	addresses := [3]rawptr{raw_data(table), raw_data(disabled), raw_data(o.details)}
	if c.made && o.version == c.version && len(table) == c.count && len(disabled) == len(c.disabled) && km == c.keymap &&
		keymap_version == c.keymap_version && (o.version != 0 || addresses == c.sources) { return }
	resize(&c.disabled, len(disabled))
	copy(c.disabled[:], disabled)
	palette_strings_free(c.details)
	c.details = palette_strings_clone(o.details)
	c.version, c.count, c.made, c.sources = o.version, len(table), true, addresses
	c.keymap, c.keymap_version = km, keymap_version
	// (the ids' index, made on a change only: the mark of a row in view and an alias typed are one lookup)
	clear(&c.index)
	for cmd, i in table { c.index[cmd.id] = i }
	c.source.version += 1
}

// The arguments of the command `id` of the commands source, and its index in the table (-1, nil: none): what a forms
// runner opens (prefs_page.palette_forms_use).
palette_command_arguments :: proc(p: ^Command_Palette, id: string) -> (index: int, arguments: []config.Def) {
	c := &p.commands
	i, ok := c.index[id]
	if !ok || i >= len(c.table) { return -1, nil }
	return i, c.table[i].arguments
}

// The choices the program gives a String argument of command `index` (Palette_Commands_Options.choices): their labels
// (English) and values; nil, nil: none.
palette_command_choices :: proc(p: ^Command_Palette, index: int, argument: string) -> (labels, values: []string) {
	c := &p.commands
	if c.choices == nil { return nil, nil }
	return c.choices(c.user, index, argument)
}

// The command an alias typed whole names, by its index in the table (-1: none). The query is the palette's, its prefix
// left out: `>nf` and `nf` both name the alias "nf".
@(private)
palette_alias_first :: proc(p: ^Command_Palette) -> int {
	c := &p.commands
	if c.keymap == nil || p.query == "" { return -1 }
	id := keymap_alias_command(c.keymap, p.query)
	if id == "" { return -1 }
	return c.index[id] or_else -1
}

// A choice of the commands source with Ctrl or Alt, the toolkit's in every program while a keymap is in use: Ctrl+Enter
// records a key for the command (the recorder; the palette opens again at its end), Alt+Enter makes the query its alias
// and opens the palette again with its text. True: it was one, done; the program does not see it.
@(private)
palette_commands_alternate :: proc(p: ^Command_Palette, ch: Palette_Choice) -> bool {
	c := &p.commands
	if ch.source != &c.source || c.keymap == nil || ch.id == "" { return false }
	switch ch.mods {
	case {.Ctrl}:
		if i, ok := c.index[ch.id]; ok && i < len(c.table) { keymap_recorder_open(p, ch.id, c.table[i].label) }
		return true
	case {.Alt}:
		keymap_alias(c.keymap, ch.query, ch.id)
		palette_open_over(p, strings.clone(line_edit_string(&p.field), context.temp_allocator), palette_window(p))
		return true
	}
	return false
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
	palette_strings_free(c.details)
	delete(c.index)
	c^ = {}
}

// The commands in the language in use (their English and their aliases among their tags), each one's first key in effect
// and whether it can act, in an answer of their own: the table can change once the palette closes, the answer stays.
@(private = "file")
palette_commands_read :: proc(p: ^Command_Palette, src: ^Palette_Source, q: Palette_Question) {
	c := &p.commands
	a: Palette_Answer
	al := palette_answer_allocator(&a)
	a.items = make([]Palette_Item, len(c.table), al)
	// (the aliases by their command: one pass over them, not one per command)
	aliases: map[string][dynamic]string
	if c.keymap != nil && len(c.keymap.aliases) > 0 {
		aliases = make(map[string][dynamic]string, len(c.keymap.aliases), context.temp_allocator)
		for alias, id in c.keymap.aliases {
			list := aliases[id] or_else make([dynamic]string, context.temp_allocator)
			append(&list, alias)
			aliases[id] = list
		}
	}
	for cmd, i in c.table {
		label, group, tags := command_shown(cmd)
		if own, has := aliases[cmd.id]; has && cmd.id != "" {
			all := make([]string, len(tags) + len(own), context.temp_allocator)
			copy(all, tags)
			copy(all[len(tags):], own[:])
			tags = all
		}
		detail := i < len(c.details) ? c.details[i] : ""
		it := Palette_Item{
			id = cmd.id, title = label, detail = detail, group = group, tags = tags, icon = cmd.icon, keys = keys_first_text(c.keymap, cmd),
			disabled = i < len(c.disabled) && c.disabled[i], stays = cmd.toggle, runs = len(cmd.arguments) > 0,
			act = cmd.id != "" ? fmt.tprintf("command:%s", cmd.id) : "",
		}
		a.items[i] = palette_item_clone(it, al)
	}
	palette_answer(q, &a)
}

// (at each build while open) The moves follow the views of the program's window the palette is over: over a view's own
// window, those of the window it follows (style_root), which owns that view. The views' version moves with any view's
// step, the palette's own too (its opening, its first frame shown): the source is read again, and the list ranked again,
// only when the moves it lists changed (a toggle flipped with the palette open ranked once more).
@(private = "file")
palette_moves_poll :: proc(p: ^Command_Palette, src: ^Palette_Source) {
	m := &p.moves
	if !views_commands_update(&m.vc, views(), p.owner != nil ? style_root(p.owner) : nil) { return }
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
