package ui

// The person's own keys and aliases (src/md/features/keymap.md): a key, or a sequence of two, set for any command in
// place of its own keys; an alias, letters typed in the palette that find a command. One keymap per program, which each
// window's state reads (keymap_use); every reader of keys reads through it (command_pressed, command_shortcut,
// command_tip, command_keys_text, the sheet, the palette).
//
//   ui.keymap_use(&app.ui, &app.keymap)                 once per window
//   ui.keymap_known(&app.keymap, COMMANDS[:])           the ids that exist: before the first command_pressed
//   ui.keymap_read(&app.keymap, custom, aliases)        the stored texts (prefs_page.standard_watch does it, and writes them)
//
// In the palette, Ctrl+Enter on a command opens the recorder (KEYMAP_RECORDER_VIEW), Alt+Enter makes the letters typed
// its alias (palette_sources.odin). The stored texts, ids sorted, chords in English:
//
//   keys.custom   "tab_new=Ctrl+M, T;terminal=F7"
//   keys.aliases  "nf=new_folder;go=goto_popup"

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "../ascii"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"

// A command's keys set by the person: one chord, or two in a row (the second's key .None: one chord).
Binding :: struct {
	chords: [2]Chord,
}

// How long a sequence's first chord waits for its second: a constant, one feel in every program.
KEYMAP_SEQUENCE_MS :: 1500

// The view that records a command's key (Ctrl+Enter on a command of the palette).
KEYMAP_RECORDER_VIEW :: "keys"

// The person's keys and aliases. The program keeps it, one per process, at a place that does not move while a window
// reads it (keymap_use), and frees it with keymap_destroy. Its maps and strings are made in the allocator of its first
// change.
Keymap :: struct {
	bindings:  map[string]Binding,   // id -> its binding (keys owned)
	aliases:   map[string]string,    // alias -> id (both owned)
	known:     map[string]bool,      // the ids of the program's tables (keymap_known; keys owned)
	// chord -> the id that holds it: each known binding's first chord. Made again when `bindings` or `known` changes,
	// never in a frame: a key's read is a lookup in it
	taken:     map[Chord]string,
	version:   u64,                  // moves at each change of the bindings, the aliases or the known ids
	// called after each change made through the API (the palette's recorder and aliases): the two texts to store
	// (keymap_texts). prefs_page.standard_watch sets it to write keys.custom and keys.aliases
	changed:   proc(user: rawptr, custom, aliases: string),
	user:      rawptr,
	// the texts last read or written (owned): a text the keymap wrote itself comes back as a change of the file, and is
	// not read again
	custom_text, aliases_text: string,
	allocator: runtime.Allocator,
}

// This window's state reads `km`: its commands' keys, its sheet and its palette follow the person's keys. Once per
// window (the windows of a program share one keymap, as they share the settings file). nil: the commands' own keys.
keymap_use :: proc(s: ^State, km: ^Keymap) { s.keymap = km }

keymap_destroy :: proc(km: ^Keymap) {
	context.allocator = keymap_allocator(km)
	for id in km.bindings { delete(id) }
	delete(km.bindings)
	for a, id in km.aliases { delete(a); delete(id) }
	delete(km.aliases)
	for id in km.known { delete(id) }
	delete(km.known)
	delete(km.taken)
	delete(km.custom_text)
	delete(km.aliases_text)
	km^ = {}
}

@(private = "file")
keymap_allocator :: proc(km: ^Keymap) -> runtime.Allocator {
	if km.allocator.procedure == nil { km.allocator = context.allocator }
	return km.allocator
}

// The ids of `table` exist: a person's binding on one of them takes its chord from now on. Call it for each table
// before its first command_pressed (else a person's key takes no chord in the first frames, and a command's own key acts
// once), and again at each version of a table made at run time. An id once known stays known.
keymap_known :: proc(km: ^Keymap, table: []Command) {
	context.allocator = keymap_allocator(km)
	added := false
	for c in table {
		if c.id == "" || c.id in km.known { continue }
		km.known[strings.clone(c.id)] = true
		added = true
	}
	if added { keymap_changed_inside(km) }
}

// The stored texts into the keymap: `custom` ("tab_new=Ctrl+M, T;terminal=F7") and `aliases` ("nf=new_folder"). A text
// equal to the one the keymap last read or wrote is not read again. An entry it cannot read (a translated modifier, a
// key it does not know, a malformed id) is left out; an entry of an id no table has is kept, inert.
keymap_read :: proc(km: ^Keymap, custom, aliases: string) {
	context.allocator = keymap_allocator(km)
	read := false
	if custom != km.custom_text {
		for id in km.bindings { delete(id) }
		clear(&km.bindings)
		for item in strings.split(custom, ";", context.temp_allocator) {
			id, _, keys := strings.partition(item, "=")
			id = strings.trim_space(id)
			b, ok := binding_parse(keys)
			if !ok || !command_id_valid(id) { continue }
			if id in km.bindings { km.bindings[id] = b } else { km.bindings[strings.clone(id)] = b }
		}
		delete(km.custom_text)
		km.custom_text = strings.clone(custom)
		read = true
	}
	if aliases != km.aliases_text {
		for a, id in km.aliases { delete(a); delete(id) }
		clear(&km.aliases)
		for item in strings.split(aliases, ";", context.temp_allocator) {
			alias, _, id := strings.partition(item, "=")
			alias = alias_fold(alias)
			id = strings.trim_space(id)
			if alias == "" || !command_id_valid(id) { continue }
			keymap_alias_set(km, alias, id)
		}
		delete(km.aliases_text)
		km.aliases_text = strings.clone(aliases)
		read = true
	}
	if read { keymap_changed_inside(km) }
}

// The two texts to store, in the order of the ids, sorted (the aliases by their id, then their letters): the file does
// not change at each save because of a map's order. Unknown ids are written too: they stay until the person removes them.
keymap_texts :: proc(km: ^Keymap, allocator := context.temp_allocator) -> (custom, aliases: string) {
	ids := make([dynamic]string, 0, len(km.bindings), context.temp_allocator)
	for id in km.bindings { append(&ids, id) }
	slice.sort(ids[:])
	b := strings.builder_make(allocator)
	for id, i in ids {
		if i > 0 { strings.write_byte(&b, ';') }
		fmt.sbprintf(&b, "%s=%s", id, binding_store_text(km.bindings[id]))
	}
	Pair :: struct { alias, id: string }
	pairs := make([dynamic]Pair, 0, len(km.aliases), context.temp_allocator)
	for a, id in km.aliases { append(&pairs, Pair{a, id}) }
	slice.sort_by(pairs[:], proc(x, y: Pair) -> bool { return x.id != y.id ? x.id < y.id : x.alias < y.alias })
	a := strings.builder_make(allocator)
	for p, i in pairs {
		if i > 0 { strings.write_byte(&a, ';') }
		fmt.sbprintf(&a, "%s=%s", p.alias, p.id)
	}
	return strings.to_string(b), strings.to_string(a)
}

// Command `id` acts on `b` in place of its own keys. One key, one command: a binding with the same keys goes, and so
// does a single chord that is the first of the new sequence, or a sequence whose first chord is the new single one (a
// prefix of a sequence is no key of its own).
keymap_bind :: proc(km: ^Keymap, id: string, b: Binding) {
	if !command_id_valid(id) || b.chords[0].key == .None { return }
	context.allocator = keymap_allocator(km)
	b := b
	if b.chords[1].key == .None { b.chords[1] = {} }
	sequence := b.chords[1].key != .None
	gone := make([dynamic]string, context.temp_allocator)
	for other, ob in km.bindings {
		if other == id { continue }
		single := ob.chords[1].key == .None
		same_first := ob.chords[0] == b.chords[0]
		if ob == b || (same_first && sequence && single) || (same_first && !sequence && !single) { append(&gone, other) }
	}
	for other in gone {
		key, _ := delete_key(&km.bindings, other)
		delete(key)
	}
	if id in km.bindings { km.bindings[id] = b } else { km.bindings[strings.clone(id)] = b }
	keymap_save(km)
}

// Command `id` back to its own keys.
keymap_unbind :: proc(km: ^Keymap, id: string) {
	if id not_in km.bindings { return }
	context.allocator = keymap_allocator(km)
	key, _ := delete_key(&km.bindings, id)
	delete(key)
	keymap_save(km)
}

// `alias` (trimmed, in lower case) finds command `id` in the palette: typed whole, the command comes first; its first
// letters find it as a tag. A former alias with the same letters moves to `id`. An alias holds no ';' nor '=' (the stored
// text's separators).
keymap_alias :: proc(km: ^Keymap, alias, id: string) {
	a := alias_fold(alias)
	if a == "" || !command_id_valid(id) || strings.contains_any(a, ";=") { return }
	context.allocator = keymap_allocator(km)
	keymap_alias_set(km, a, id)
	keymap_save(km)
}

// The command an alias names, `text` compared trimmed and in lower case ("": none, or an id no table has).
keymap_alias_command :: proc(km: ^Keymap, text: string) -> string {
	if km == nil || len(km.aliases) == 0 { return "" }
	id, ok := km.aliases[alias_fold(text)]
	return ok && id in km.known ? id : ""
}

// An alias as it is kept and compared: trimmed, in lower case. By Unicode: a person types it ("éd" for "Éditer").
@(private = "file")
alias_fold :: proc(text: string) -> string {
	return strings.to_lower(strings.trim_space(text), context.temp_allocator)
}

@(private = "file")
keymap_alias_set :: proc(km: ^Keymap, alias, id: string) {
	if old, ok := km.aliases[alias]; ok {
		delete(old)
		km.aliases[alias] = strings.clone(id)
	} else {
		km.aliases[strings.clone(alias)] = strings.clone(id)
	}
}

// A change made through the API: the texts written, the program told.
@(private = "file")
keymap_save :: proc(km: ^Keymap) {
	custom, aliases := keymap_texts(km)
	delete(km.custom_text)
	delete(km.aliases_text)
	km.custom_text, km.aliases_text = strings.clone(custom), strings.clone(aliases)
	keymap_changed_inside(km)
	if km.changed != nil { km.changed(km.user, km.custom_text, km.aliases_text) }
}

// `taken` made again, and the version moved: every reader of the keys lists again.
@(private = "file")
keymap_changed_inside :: proc(km: ^Keymap) {
	clear(&km.taken)
	for id, b in km.bindings {
		if id in km.known { km.taken[b.chords[0]] = id }
	}
	km.version += 1
}

////////////////////////////////
// Texts

// "Ctrl+M, T", in the language in use (chord_text): what a person reads.
binding_text :: proc(b: Binding, allocator := context.temp_allocator) -> string {
	if b.chords[1].key == .None { return chord_text(b.chords[0], allocator) }
	return fmt.aprintf("%s, %s", chord_text(b.chords[0]), chord_text(b.chords[1]), allocator = allocator)
}

// "Ctrl+M, T", in English whatever the language in use (platform.key_english): what keys.custom stores, read back by
// binding_parse.
binding_store_text :: proc(b: Binding, allocator := context.temp_allocator) -> string {
	if b.chords[1].key == .None { return chord_store_text(b.chords[0], allocator) }
	return fmt.aprintf("%s, %s", chord_store_text(b.chords[0]), chord_store_text(b.chords[1]), allocator = allocator)
}

@(private = "file")
chord_store_text :: proc(c: Chord, allocator := context.temp_allocator) -> string {
	if c.key == .None { return "" }
	return fmt.aprintf("%s%s%s%s", .Ctrl in c.mods ? "Ctrl+" : "", .Shift in c.mods ? "Shift+" : "", .Alt in c.mods ? "Alt+" : "",
		platform.key_english(c.key), allocator = allocator)
}

// binding_store_text's form back to a binding: one chord, or two apart by ", " (a lone ',' is a key: "Ctrl+,"). The
// modifiers Ctrl, Shift and Alt in any order, the case ignored. ok = false: a word it does not know (a translated one).
binding_parse :: proc(text: string) -> (b: Binding, ok: bool) {
	t := strings.trim_space(text)
	if t == "" { return }
	chords := strings.split(t, ", ", context.temp_allocator)
	if len(chords) > 2 { return }
	for c, i in chords { b.chords[i] = chord_parse(c) or_return }
	return b, true
}

@(private = "file")
chord_parse :: proc(text: string) -> (c: Chord, ok: bool) {
	t := strings.trim_space(text)
	// (the key's name at the end, the longest that fits: "Num +" holds a '+', as "Ctrl++" would)
	best := 0
	for k in platform.Key {
		if k == .Shift || k == .Ctrl || k == .Alt { continue }   // (a modifier is no chord's key)
		name := platform.key_english(k)
		if name == "" || len(name) <= best || len(name) > len(t) || !ascii.equal_fold(t[len(t) - len(name):], name) { continue }
		rest := t[:len(t) - len(name)]
		if rest != "" && !strings.has_suffix(rest, "+") { continue }
		best, c.key = len(name), k
	}
	if c.key == .None { return {}, false }
	rest := strings.trim_suffix(t[:len(t) - best], "+")
	if rest == "" { return c, true }
	for p in strings.split(rest, "+", context.temp_allocator) {
		w := strings.trim_space(p)
		switch {
		case ascii.equal_fold(w, "ctrl"):  c.mods += {.Ctrl}
		case ascii.equal_fold(w, "shift"): c.mods += {.Shift}
		case ascii.equal_fold(w, "alt"):   c.mods += {.Alt}
		case:                              return {}, false
		}
	}
	return c, true
}

////////////////////////////////
// Ids

// Whether `id` is a command's id: lower case letters, digits, '.', '_' and '-', not empty. It holds no '=', ';', ',' nor
// space: the stored texts' separators.
@(private)
command_id_valid :: proc(id: string) -> bool {
	if id == "" { return false }
	for i in 0 ..< len(id) {
		ch := id[i]
		if !((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '.' || ch == '_' || ch == '-') { return false }
	}
	return true
}

// The ids of `tables` that are wrong, one line each, "<label>: <what>" (the label as the table holds it): an empty id
// ("no id"), a malformed one ("\"Tab.New\" is not an id"), one twice in a table ("\"tab_new\" twice"). One id in two
// tables is one command (the same "copy" in an editor and in a history): it is not listed. A program's test expects
// none, as command_typing_keys lists the typing keys.
command_ids_check :: proc(tables: ..[]Command) -> []string {
	allocator := context.temp_allocator
	out := make([dynamic]string, allocator)
	for table in tables {
		seen := make(map[string]bool, len(table), context.temp_allocator)
		for c in table {
			switch {
			case c.id == "":               append(&out, fmt.aprintf("%s: no id", c.label, allocator = allocator))
			case !command_id_valid(c.id):  append(&out, fmt.aprintf("%s: %q is not an id", c.label, c.id, allocator = allocator))
			case c.id in seen:             append(&out, fmt.aprintf("%s: %q twice", c.label, c.id, allocator = allocator))
			}
			seen[c.id] = true
		}
	}
	return out[:]
}

////////////////////////////////
// The keys in effect

// The keymap of the state in use (nil: none, or no state).
@(private)
state_keymap :: proc() -> ^Keymap { return current != nil ? current.keymap : nil }

// The person's binding of `c`, when its id is known and has one. A command without an id (the palette's) has none: its
// keys are read only.
@(private)
command_bound :: proc(km: ^Keymap, c: Command) -> (b: Binding, ok: bool) {
	if km == nil || c.id == "" || c.id not_in km.known { return }
	return km.bindings[c.id]
}

// Whether own key `k` of `c` is taken by another command's binding: a person's key wins over a command's own key.
@(private)
chord_taken :: proc(km: ^Keymap, c: Command, k: Chord) -> bool {
	if km == nil || c.id == "" || len(km.taken) == 0 { return false }
	other, ok := km.taken[k]
	return ok && other != c.id
}

// The keys in effect of `c` in the state in use: the person's binding, else each own key that no other command's
// binding took.
command_keys_in_effect :: proc(c: Command, allocator := context.temp_allocator) -> []Binding {
	return keys_in_effect(state_keymap(), c, allocator)
}

@(private)
keys_in_effect :: proc(km: ^Keymap, c: Command, allocator := context.temp_allocator) -> []Binding {
	if b, ok := command_bound(km, c); ok {
		out := make([]Binding, 1, allocator)
		out[0] = b
		return out
	}
	out := make([dynamic]Binding, 0, len(c.keys), allocator)
	for k in c.keys {
		if k.key != .None && !chord_taken(km, c, k) { append(&out, Binding{{k, {}}}) }
	}
	return out[:]
}

// The first key in effect's text ("" none).
@(private)
keys_first_text :: proc(km: ^Keymap, c: Command, allocator := context.temp_allocator) -> string {
	if b, ok := command_bound(km, c); ok { return binding_text(b, allocator) }
	for k in c.keys {
		if k.key != .None && !chord_taken(km, c, k) { return chord_text(k, allocator) }
	}
	return ""
}

// Every key in effect, " / " between them ("Ctrl+K / Ctrl+Shift+P"; a sequence "Ctrl+M, T").
@(private)
keys_all_text :: proc(km: ^Keymap, c: Command, allocator := context.temp_allocator) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for b in keys_in_effect(km, c) { append(&parts, binding_text(b)) }
	return strings.join(parts[:], " / ", allocator)
}

////////////////////////////////
// Reading a sequence

// Whether binding `b` of a command of `scope` was pressed: a single chord as any; a sequence's first chord sets the
// window's pending chord (and is no press of the command), its second completes it.
@(private)
binding_pressed :: proc(s: ^State, b: Binding, scope: Command_Scope) -> bool {
	first, second := b.chords[0], b.chords[1]
	if second.key == .None { return chord_pressed(first, scope) }
	if s.key_pending.key != .None {
		// (the second press was taken at the build's start: the rules of a key are checked on it now. The typing rule
		// is not: the person started a sequence, the next key is the sequence's)
		if s.key_pending != first || !s.key_second_taken || s.key_second != second { return false }
		if !chord_ready(s, second, scope, typing = false) { return false }
		s.key_pending, s.key_second, s.key_second_taken = {}, {}, false
		return true
	}
	if chord_pressed(first, scope) {
		s.key_pending, s.key_pending_until = first, build_now_ms() + KEYMAP_SEQUENCE_MS
		wake_within(s, KEYMAP_SEQUENCE_MS + WAKE_MARGIN_MS)
	}
	return false
}

// At a build's start: a pending chord lapses at its deadline; else the build's first key press is taken out of the
// events, whatever it is (a modifier alone is none): it completes a sequence, or ends it. A person who started a
// sequence did not mean that key alone, Escape included.
@(private)
keymap_begin_build :: proc(s: ^State) {
	s.key_second, s.key_second_taken = {}, false
	if s.key_pending.key == .None { return }
	if s.time_ms >= s.key_pending_until {
		s.key_pending = {}
		return
	}
	for e, i in s.events.list {
		if s.events.consumed[i] || e.kind != .Key_Press || (e.key == .None && e.char == 0) { continue }
		if e.key == .Shift || e.key == .Ctrl || e.key == .Alt { continue }
		s.events.consumed[i] = true
		s.key_second, s.key_second_taken = Chord{e.key, e.mods}, true
		// (the character it types is no field's either)
		if command_key_types_text(s.key_second) && len(s.typed) > 0 { ordered_remove(&s.typed, 0) }
		return
	}
}

// At a build's end, every reader past: the press taken ends the pending chord, completed or not. A chord still pending
// shows in a bubble at the bottom centre of the window, "Ctrl+M, …", and the window wakes at its deadline.
@(private)
keymap_end_build :: proc(s: ^State) {
	if s.key_second_taken { s.key_pending = {} }
	s.key_second, s.key_second_taken = {}, false
	if s.key_pending.key == .None { return }
	wake_within(s, max(int(s.key_pending_until - s.time_ms), 0) + WAKE_MARGIN_MS)
	em := font_size()
	h := math.round(dense(em * 2.2))
	push_parent(s.root)
	push_tags("floating")
	s.next_mod.fixed_x, s.next_mod.fixed_y = 0, s.window_size.y - h - em * 2.5
	s.next_mod.fixed_w, s.next_mod.fixed_h = s.window_size.x, h
	set_next_axis(.X, .Center)
	if parent(build_box({}, "###keymap_pending_row")) {
		spacer(fill())
		next({width = text_size(em * 1.2), height = pct(1), radius = em * 0.6, text_align = .Center})
		b := build_box({.Draw_Background, .Draw_Border, .Draw_Shadow, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s, …###keymap_pending", chord_text(s.key_pending)))
		a11y_default(b, {role = .Status, name = box_text(b), live = .Polite})
		spacer(fill())
	}
	pop_tags()
	pop_parent()
}

////////////////////////////////
// The recorder (Ctrl+Enter on a command of the palette)

// What the recorder records: the command, the chords pressed so far, and the palette's text to give back at its end.
Keymap_Recorder :: struct {
	id, label: string,   // (owned) the command's id and its label as the table holds it ("": no recording)
	chords:    [2]Chord,
	count:     int,
	text:      string,   // (owned) the palette's field when Ctrl+Enter chose
}

@(private)
keymap_recorder_free :: proc(r: ^Keymap_Recorder) {
	delete(r.id)
	delete(r.label)
	delete(r.text)
	r^ = {}
}

// Opens the recorder for command `id` of the palette's commands source (the palette closed, its text kept).
@(private)
keymap_recorder_open :: proc(p: ^Command_Palette, id, label: string) {
	r := &p.recorder
	keymap_recorder_free(r)
	r.id, r.label, r.text = strings.clone(id), strings.clone(label), strings.clone(line_edit_string(&p.field))
	vs := views()
	if !view_registered(vs, KEYMAP_RECORDER_VIEW) {
		view_register(vs, KEYMAP_RECORDER_VIEW, keymap_recorder_view, View_Options{title = i18n.later("Keys of a command"), icon = lucide.KEYBOARD, width_em = 30})
	}
	view_open(vs, KEYMAP_RECORDER_VIEW, p, palette_instance(p))
}

// Whether a binding's first chord is one of the palette's: those are read only (palette_command), so a person's key on
// one would never act.
@(private = "file")
binding_is_the_palettes :: proc(b: Binding) -> bool {
	for k in palette_command().keys { if b.chords[0] == k { return true } }
	return false
}

// The recorder: what is pressed is taken (two chords for a sequence), every chord claimed (Ctrl+K is a value here).
// Enter keeps them, Escape gives up, Backspace before any chord gives the command its own keys again. The palette opens
// again at its end (palette_chosen).
@(private = "file")
keymap_recorder_view :: proc(v: ^View, p: ^Command_Palette) {
	r := &p.recorder
	km := p.commands.keymap
	if r.id == "" || km == nil {
		view_end(v, VIEW_CANCELLED)
		return
	}
	em := font_size()
	view_title(v, fmt.tprintf(i18n.tr("Keys for %s"), text_shown(i18n.tr(r.label))))
	keep, cancel, own := false, false, false
	if hk, ok := key_take(); ok && hk.key != .None {   // (a key named only by its character is no command's)
		switch {
		case hk.key == .Escape && hk.mods == {}:                 cancel = true
		case hk.key == .Return && hk.mods == {} && r.count > 0:  keep = true
		case hk.key == .Backspace && hk.mods == {} && r.count == 0: own = true
		case:
			if r.count == 2 { r.count, r.chords = 0, {} }
			r.chords[r.count] = Chord{hk.key, hk.mods}
			r.count += 1
		}
	}
	b := Binding{r.chords}
	palettes := r.count > 0 && binding_is_the_palettes(b)
	if dialog_body("keymap_rec_body") {
		if tags("weak") {
			next({width = fill()})
			paragraph(fmt.tprintf("%s###keymap_rec_help", i18n.tr("Press the keys: two for a sequence. Enter keeps them, Escape gives up, Backspace first gives the command its own keys again.")))
		}
		spacer(px(em * 0.8))
		next({width = fill(), height = px(dense(em * 2.6)), axis = .X, cross = .Center})
		keys := build_box({.Focusable}, "###keymap_rec_keys")
		// (the recorder has the keyboard and claims every chord: the window's commands, the palette's too, wait)
		if focus_key() != keys.key { set_focus(keys.key) }
		keys_claim(keys.key)
		if parent(keys) {
			spacer(fill())
			kbd(r.count == 0 ? i18n.tr("Press the keys…") : binding_text(b))
			spacer(fill())
		}
		note := ""
		switch {
		case palettes: note = i18n.tr("This key opens the command palette.")
		case r.count > 0 && command_key_types_text(r.chords[0]): note = i18n.tr("This key does nothing while you type in a field.")
		}
		if note != "" {
			spacer(px(em * 0.4))
			if tags("weak") {
				next({width = fill(), text_align = .Center})
				paragraph(fmt.tprintf("%s###keymap_rec_note", note))
			}
		}
	}
	if dialog_buttons("keymap_rec_buttons") {
		next({width = text_size(em * 1.2), height = px(dense(em * 2.2))})
		if button("keymap_rec_cancel", i18n.tr("Cancel")).clicked { cancel = true }
		next({width = text_size(em * 1.2), height = px(dense(em * 2.2))})
		if button("keymap_rec_keep", key_tip(i18n.tr("Keep"), {.Return, {}}), o = {intent = .Primary, disabled = r.count == 0 || palettes}).clicked { keep = true }
	}
	switch {
	case keep && r.count > 0 && !palettes:
		keymap_bind(km, r.id, b)
		view_end(v, 0)
	case own:
		keymap_unbind(km, r.id)
		view_end(v, 0)
	case cancel:
		view_end(v, VIEW_CANCELLED)
	}
}
