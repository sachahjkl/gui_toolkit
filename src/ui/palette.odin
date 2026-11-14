package ui

// The command palette (src/md/features/palette.md): a field, and one ranked list of the items that sources give. One
// palette in every program: the same look, the same keys, the same prefixes.
//
//   ui.palette_memory_open(&app.palette, &app.ui, path)               once: the usage memory's file ("": in memory only)
//   ui.palette_commands(&app.palette, COMMANDS[:], disabled[:], {})   when the table or `disabled` change: the commands
//                                                                     source and the views' moves source
//   ui.palette_add(&app.palette, &app.sessions)                       a source of the program's (a prefix of the table)
//   if ui.command_pressed(ui.PALETTE_COMMAND) { ui.palette_toggle(&app.palette) }   Ctrl+K, Ctrl+Shift+P
//   if c, ok := ui.palette_chosen(&app.palette); ok {                 each frame: the toolkit's sources act in it
//       if c.command >= 0 { run(Cmd(c.command)) } else if c.source == &app.sessions { switch_to(c.id) }
//   }
//
// A source answers its question (Palette_Question) with palette_answer, at once from the program's memory or later
// from a chore's answer. The palette ranks every answer together on a chore: the interface's thread never matches an
// item. An answer or a ranking for another serial (an older query, a former opening) is dropped.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"

// The palette's size at first, in em, and the least it is made; where its top is, a share of the window's height; a
// row's height and a heading's, in em.
PALETTE_WIDTH_EM :: 34
PALETTE_HEIGHT_EM :: 26
PALETTE_MIN_EM :: Vec2{22, 10}
PALETTE_TOP :: 0.12
PALETTE_ROW_EM :: 2
PALETTE_HEADING_EM :: 1.9
// What a match of the group's letters (not the label's alone) loses against one of the label's.
PALETTE_GROUP_MATCH_PENALTY :: 100
// In a plain search, what an item of a program's own source loses against the toolkit's sources at an equal score: a
// command typed whole beats a page whose title holds the same word.
PALETTE_OWN_PENALTY :: 5
// What an item that a searching source found, and the matcher does not find, loses: after every match, the last text's
// too. It stays: the source knew something (a page's content, a path's folder).
PALETTE_FOUND_PENALTY :: 200_000

// The prefixes: a closed table of the toolkit. A prefix means the same thing in every program; a program fills one with a
// source, or leaves it empty.
Palette_Prefix :: enum u8 {
	None,       // the plain search: every source with `plain`
	Commands,   // '>' what the program does
	Go_To,      // '@' the things of the program that one opens or switches to
	Paths,      // '/' files, folders and addresses
	Choose,     // '#' one among alternatives, the one in use marked
	Settings,   // ':' the settings
	Secrets,    // '$' entries of a vault: never plain, never remembered, no detail shown
}

// The character of a prefix (0: None).
palette_prefix_char :: proc(x: Palette_Prefix) -> u8 {
	switch x {
	case .None:     return 0
	case .Commands: return '>'
	case .Go_To:    return '@'
	case .Paths:    return '/'
	case .Choose:   return '#'
	case .Settings: return ':'
	case .Secrets:  return '$'
	}
	return 0
}

// The name of a prefix, in English ("Commands", "Go to"): the hint row's when several sources share it.
palette_prefix_name :: proc(x: Palette_Prefix) -> string {
	switch x {
	case .None:     return ""
	case .Commands: return i18n.later("Commands")
	case .Go_To:    return i18n.later("Go to")
	case .Paths:    return i18n.later("Paths")
	case .Choose:   return i18n.later("Choose")
	case .Settings: return i18n.later("Settings")
	case .Secrets:  return i18n.later("Secrets")
	}
	return ""
}

// The toolkit's command of the palette: Ctrl+K and Ctrl+Shift+P, a window command. A program puts it in its table (its
// menus and its sheet show it) and calls palette_toggle on its press; no setting turns it off.
// (its label and group in English, translated where they show: a global's initializer is a constant, no i18n.later)
PALETTE_COMMAND := Command{
	label = "Command palette", group = "Window", icon = lucide.COMMAND, scope = .Window,
	keys = {{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}},
}

// An item of a source. Its strings are copied by palette_answer.
Palette_Item :: struct {
	id:         string,     // stable in its source, never a title: the usage memory's key and the choice's
	title:      string,     // what the row says and the query lights, in the language in use
	detail:     string,     // weak, after the title (an address, a folder); a Secrets source's is not shown
	icon:       string,     // a glyph of the state's icon_font ("" none)
	keys:       string,     // the text of its keys ("Ctrl+S")
	group:      string,     // its heading with nothing typed, said after the title while something is
	tags:       []string,   // other words it is found by
	last:       string,     // a text that finds it when nothing else does (a setting's name): nothing lit
	completion: string,     // what Tab puts in the field (a folder's path, prefix included)
	disabled:   bool,       // greyed, listed last, not chosen
	stays:      bool,       // choosing it does not close the palette (a switch)
}

// What the palette asks a source: its serial (palette_answer gives it back) and the query, after the prefix.
Palette_Question :: struct {
	serial: u64,
	query:  string,   // valid during the call: a source that answers later copies it
}

// The meaning of Enter with a modifier for a source's items ("Open in a new tab"; "": what Enter does).
Palette_Alternates :: struct {
	ctrl, alt, shift: string,
}

// A choice: the source, the item's id, its index in the answer it came from, and the modifiers of the Enter ({} plain
// Enter or a click). `command`: the index in the commands table (palette_commands), -1 for another source.
Palette_Choice :: struct {
	source:  ^Palette_Source,
	id:      string,   // the palette's: valid until the next choice
	index:   int,
	command: int,
	mods:    platform.Modifiers,
}

// A source of items. The program keeps it at a place that does not move while the palette has it (palette_add).
Palette_Source :: struct {
	name:       string,           // stable, in English: the usage memory's part ("command", "session")
	title:      string,           // "Sessions", in English: the hint row's and its "reading" row's, translated there
	prefix:     Palette_Prefix,
	plain:      bool,             // its items take part in a search without a prefix (never a Secrets source)
	remember:   bool,             // its choices go to the usage memory (never a Secrets source)
	listed:     bool,             // its items are listed while nothing is typed and no prefix is (the commands)
	searches:   bool,             // it answers for the query: asked again at each one. Else once per version
	enter:      string,           // the word of Enter in the hint row, in English ("": "Choose")
	alternates: Palette_Alternates,
	// asks for the items, on the interface's thread, when the query (a searching source), the version or the language
	// changed: answer with palette_answer, at once or from a chore's answer. It makes no system call.
	read:       proc(p: ^Command_Palette, src: ^Palette_Source, q: Palette_Question),
	// the mark of an item now (a switch on, the model in use): called for the rows built only
	mark:       proc(src: ^Palette_Source, id: string) -> bool,
	// what choosing an item does, run by palette_chosen; nil: the choice is the program's (palette_chosen returns it)
	act:        proc(p: ^Command_Palette, src: ^Palette_Source, c: Palette_Choice),
	// called at each build while the palette is open, before its version is read (a source that follows the views)
	poll:       proc(p: ^Command_Palette, src: ^Palette_Source),
	user:       rawptr,
	version:    u64,              // the program bumps it when the items change
	toolkit:    bool,             // the toolkit's sources (commands, moves, settings): no penalty in a plain search
}

// The palette. The program keeps it between frames, at a place that does not move while it is open.
Command_Palette :: struct {
	field:    Line_Edit,
	sources:  [dynamic]^Palette_Source,
	states:   [dynamic]Palette_Source_State,   // one per source, in its order
	commands: Palette_Commands,                // palette_commands's source
	moves:    Palette_Moves,                   // the views' moves, beside the commands
	memory:   Choice_Memory,                   // what the user chose (palette_memory_open)
	// what a test reads: the questions asked, the rankings started, the answers dropped (another serial)
	asks, rankings, dropped: int,

	serial:     u64,              // changes at each query, each question, each open and each close
	link:       ^Palette_Link,    // what the chores' answers find the palette by
	shown:      ^Palette_Job,     // the list in view: the last ranking that came (nil: none yet)
	pending:    u64,              // the serial of the ranking in flight (0: none)
	ranked:     Palette_Ranked,   // what the last ranking was asked for
	generation: u64,              // counts the changes of the snapshots and of the sources
	language:   u32,
	text:       string,           // the field's text the palette last read (owned)
	prefix:     Palette_Prefix,   // the prefix typed, of `text`
	query:      string,           // `text` after the prefix (a slice of it)

	sel:        int,              // the row selected
	sel_moved:  bool,             // the person moved the selection since the query changed: it follows its item
	sel_source: ^Palette_Source,  // the selected row's item, to find it in the next list
	sel_id:     string,           // (owned)
	sel_gen:    u64,              // counts the changes of the selected item

	enter_wait:  Maybe(platform.Modifiers),   // Enter while the ranking of the last query is in flight
	enter_ready: bool,                        // that ranking came: the view chooses its first row
	chosen:      Palette_Choice,              // the program's choice, until palette_chosen takes it
	has_choice:  bool,
	act_due:     bool,                        // a choice of a source with `act`, run by palette_chosen

	owner:    ^State,   // the window it is open over
	fresh:    bool,     // opened: the field takes the keyboard
	reveal:   bool,     // the selected row is brought into view at the next build
	was_open: bool,
	mouse:    Vec2,
	list_key: Key,
}

// Per source: its answer kept, and the question in flight.
@(private)
Palette_Source_State :: struct {
	snap:     ^Palette_Snapshot,
	asked:    u64,      // the serial of the question in flight (0: none)
	reading:  bool,
	error:    string,   // its last read's error (owned; "": none)
	failed:   bool,     // the last question was answered with that error: not asked again for the same one
	// what the last question is for
	version:  u64,
	language: u32,
	query:    string,   // (owned)
}

// What a ranking was asked for: a change of any of these ranks again.
@(private)
Palette_Ranked :: struct {
	valid:          bool,
	text:           string,   // (owned)
	generation:     u64,
	memory_version: u64,
}

// A source's answer, copied: immutable while a ranking reads it, freed by the last one that lets go of it.
@(private)
Palette_Snapshot :: struct {
	refs:     int,   // (atomic) the palette's and each ranking's
	arena:    virtual.Arena,
	items:    []Palette_Item,
	source:   ^Palette_Source,   // (read on the interface's thread only)
	// the source's flags, copied: a chore reads them
	name, title: string,
	prefix:   Palette_Prefix,
	plain, remember, listed, searches, toolkit: bool,
	version:  u64,
	language: u32,
	query:    string,   // what it answered for (a searching source)
}

// A row of a list: an item of a snapshot, the headings down to it, whether a heading is just above it (the recent
// choices' when `recent`, else `group`), its ranges in the job's.
@(private)
Palette_Row :: struct {
	snap, item:               i32,
	headings:                 int,
	heading, recent:          bool,
	group:                    string,
	range_first, range_count: int,
}

// What a chore's answer finds the palette by: nil once it is destroyed. Counted: the palette's and each job's.
@(private)
Palette_Link :: struct {
	p:    ^Command_Palette,
	refs: int,
}

// A ranking: what it reads (asked on the interface's thread), what it makes (on a chore).
@(private)
Palette_Job :: struct {
	link:     ^Palette_Link,
	serial:   u64,
	arena:    virtual.Arena,
	query:    string,
	prefix:   Palette_Prefix,
	chooser:  bool,
	snaps:    []^Palette_Snapshot,
	memory:   Choice_Memory,   // a copy of the entries: the chore reads it while a choice changes the palette's
	now_ms:   i64,
	first:    [2]i32,          // (snapshot, item) put first while something is typed ({-1, -1}: none)
	sel_source: ^Palette_Source,
	sel_id:   string,
	sel_gen:  u64,
	// made by the chore
	rows:     []Palette_Row,
	ranges:   []Fuzzy_Range,
	sel_row:  int,
	icons:    bool,
}

// Adds a source (once). The program keeps it where it is while the palette has it.
palette_add :: proc(p: ^Command_Palette, src: ^Palette_Source) {
	if palette_source_index(p, src) >= 0 { return }
	append(&p.sources, src)
	append(&p.states, Palette_Source_State{})
	p.generation += 1
}

// Removes a source: its answer goes, and the list is ranked again.
palette_remove :: proc(p: ^Command_Palette, src: ^Palette_Source) {
	i := palette_source_index(p, src)
	if i < 0 { return }
	palette_state_free(&p.states[i])
	ordered_remove(&p.sources, i)
	ordered_remove(&p.states, i)
	palette_shown_free(p)
	p.generation += 1
}

// The answer of `src` to its question `serial`: its items, copied (the caller frees its own after the call). An answer
// for another serial (an older query, a former opening) is dropped: false. Call it on the interface's thread.
palette_answer :: proc(p: ^Command_Palette, src: ^Palette_Source, serial: u64, items: []Palette_Item) -> bool {
	i := palette_source_index(p, src)
	if i < 0 || serial == 0 || p.states[i].asked != serial {
		p.dropped += 1
		return false
	}
	st := &p.states[i]
	if st.snap != nil { palette_snapshot_release(st.snap) }
	st.snap = palette_snapshot_make(src, items, st.version, st.language, st.query)
	st.asked, st.reading, st.failed = 0, false, false
	delete(st.error)
	st.error = ""
	p.generation += 1
	return true
}

// The source could not read (its own timeout, its own error): one weak row says it, "Sessions: could not read
// (message)". The same serial rule as palette_answer.
palette_answer_error :: proc(p: ^Command_Palette, src: ^Palette_Source, serial: u64, message: string) -> bool {
	i := palette_source_index(p, src)
	if i < 0 || serial == 0 || p.states[i].asked != serial {
		p.dropped += 1
		return false
	}
	st := &p.states[i]
	st.asked, st.reading, st.failed = 0, false, true
	delete(st.error)
	st.error = strings.clone(message)
	return true
}

// Opens the palette over the window being built (one open comes forward), `typed` in its field ("@": the sessions).
palette_open :: proc(p: ^Command_Palette, typed := "") {
	vs := views()
	if !view_registered(vs, PALETTE_VIEW) {
		view_register(vs, PALETTE_VIEW, palette_view, View_Options{
			title = "Commands", no_header = true, resizable = true, top = PALETTE_TOP,
			width_em = PALETTE_WIDTH_EM, height_em = PALETTE_HEIGHT_EM, min_width_em = PALETTE_MIN_EM.x, min_height_em = PALETTE_MIN_EM.y,
		})
	}
	if !view_is_open(vs, PALETTE_VIEW, palette_instance(p)) {
		palette_forget(p)
		palette_shown_free(p)
		p.fresh, p.sel, p.sel_moved, p.reveal, p.owner = true, 0, false, true, gs()
		p.ranked.valid = false
		delete(p.text)
		p.text, p.query, p.prefix = "", "", .None
		line_edit_set(&p.field, typed)
	}
	view_open(vs, PALETTE_VIEW, p, palette_instance(p))
	p.was_open = true
}

palette_is_open :: proc(p: ^Command_Palette) -> bool { return view_is_open(views(), PALETTE_VIEW, palette_instance(p)) }

palette_close :: proc(p: ^Command_Palette) {
	view_close(views(), PALETTE_VIEW, palette_instance(p))
	palette_forget(p)
	p.was_open = false
}

// Ctrl+K again closes it.
palette_toggle :: proc(p: ^Command_Palette, typed := "") {
	if palette_is_open(p) { palette_close(p) } else { palette_open(p, typed) }
}

// PALETTE_COMMAND's keys, pressed: the palette opens or closes. For a program that does not list the command in its own
// table; read it once at the top of the build, as any window command.
palette_keys :: proc(p: ^Command_Palette) -> bool {
	palette_follow_close(p)
	if !command_pressed(PALETTE_COMMAND) { return false }
	palette_toggle(p)
	return true
}

// The choice of the program's sources, taken once, in the build after it. Call it at each build: it runs the choices of
// the toolkit's sources (a setting flips or shows its page, a view's move runs), which return nothing.
palette_chosen :: proc(p: ^Command_Palette) -> (c: Palette_Choice, ok: bool) {
	palette_follow_close(p)
	if p.act_due {
		p.act_due = false
		if src := p.chosen.source; src != nil && src.act != nil && palette_source_index(p, src) >= 0 { src.act(p, src, p.chosen) }
		return {}, false
	}
	if !p.has_choice { return {}, false }
	p.has_choice = false
	return p.chosen, true
}

// The prefixes the program has, each with its name, in the table's order: "> Commands", "@ Sessions" (the source's title
// when one source holds the prefix, else the prefix's name; in English). A program's test compares it with the list it
// means.
palette_prefixes :: proc(p: ^Command_Palette, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for x in Palette_Prefix {
		if x == .None { continue }
		if name := palette_prefix_title(p, x); name != "" {
			append(&out, fmt.aprintf("%c %s", rune(palette_prefix_char(x)), name, allocator = allocator))
		}
	}
	return out[:]
}

// A ranking is in flight, or a source of the query's reads: what a test waits for.
palette_busy :: proc(p: ^Command_Palette) -> bool {
	if p.pending != 0 { return true }
	for st in p.states { if st.reading { return true } }
	return false
}

// The rows of the list in view; the source and the id of row `i`.
palette_row_count :: proc(p: ^Command_Palette) -> int { return p.shown != nil ? len(p.shown.rows) : 0 }

palette_row :: proc(p: ^Command_Palette, i: int) -> (src: ^Palette_Source, id: string, ok: bool) {
	if p.shown == nil || i < 0 || i >= len(p.shown.rows) { return nil, "", false }
	r := p.shown.rows[i]
	snap := p.shown.snaps[r.snap]
	return snap.source, snap.items[r.item].id, true
}

// The row selected (ok false: none).
palette_selected :: proc(p: ^Command_Palette) -> (src: ^Palette_Source, id: string, ok: bool) { return palette_row(p, p.sel) }

// Starts the usage memory of the file at `path` (its state folder's palette_choices.txt; "": in memory only), read on the
// chores. The palette owns it and notes each choice of a source with `remember`.
palette_memory_open :: proc(p: ^Command_Palette, s: ^State, path: string, o := Choice_Memory_Options{}) {
	choice_memory_open(&p.memory, s, path, o)
}

palette_destroy :: proc(p: ^Command_Palette) {
	line_edit_destroy(&p.field)
	palette_shown_free(p)
	for &st in p.states { palette_state_free(&st) }
	delete(p.states)
	delete(p.sources)
	palette_commands_free(&p.commands)
	views_commands_destroy(&p.moves.vc)
	choice_memory_close(&p.memory)
	if p.link != nil {
		p.link.p = nil
		palette_link_release(p.link)
	}
	delete(p.text)
	delete(p.ranked.text)
	delete(p.sel_id)
	delete(p.chosen.id)
	p^ = {}
}

// The view of each palette: its id, and the instance that is this palette.
PALETTE_VIEW :: "palette"

@(private = "file")
palette_instance :: proc(p: ^Command_Palette) -> string { return fmt.tprintf("%x", uintptr(p)) }

////////////////////////////////
// Sources, questions, snapshots

@(private)
palette_source_index :: proc(p: ^Command_Palette, src: ^Palette_Source) -> int {
	for s, i in p.sources { if s == src { return i } }
	return -1
}

// The hint row's name of a prefix: its one source's title, the prefix's name when several hold it, "" when none does.
@(private = "file")
palette_prefix_title :: proc(p: ^Command_Palette, x: Palette_Prefix) -> string {
	found: ^Palette_Source
	for s in p.sources {
		if s.prefix != x { continue }
		if found != nil { return palette_prefix_name(x) }
		found = s
	}
	return found != nil ? found.title : ""
}

// Whether a prefix has a source: a character without one is text.
@(private = "file")
palette_prefix_held :: proc(p: ^Command_Palette, x: Palette_Prefix) -> bool {
	for s in p.sources { if s.prefix == x { return true } }
	return false
}

// The prefix of a field's text (its first character after the leading spaces, when a source holds it) and the query
// after it, the spaces around dropped.
@(private)
palette_parse :: proc(p: ^Command_Palette, text: string) -> (prefix: Palette_Prefix, query: string) {
	t := strings.trim_left_space(text)
	if len(t) > 0 {
		for x in Palette_Prefix {
			if x == .None || t[0] != palette_prefix_char(x) || !palette_prefix_held(p, x) { continue }
			return x, strings.trim_space(t[1:])
		}
	}
	return .None, strings.trim_space(text)
}

// Whether a source is asked and ranked for this prefix: its own; with none, the plain ones (never a Secrets source).
@(private)
palette_in_scope :: proc(prefix, of: Palette_Prefix, plain: bool) -> bool {
	if prefix != .None { return of == prefix }
	return plain && of != .Secrets
}

// The questions still open go stale (an open, a close): their answers will be dropped.
@(private = "file")
palette_forget :: proc(p: ^Command_Palette) {
	p.serial += 1
	for &st in p.states { st.asked, st.reading, st.failed = 0, false, false }
	p.pending = 0
	p.enter_wait, p.enter_ready = nil, false
}

// A close that the palette did not make (Escape, a click outside, its window gone): its questions go stale.
@(private = "file")
palette_follow_close :: proc(p: ^Command_Palette) {
	if !p.was_open || build_of == nil { return }
	if !view_is_open(views(), PALETTE_VIEW, palette_instance(p)) {
		p.was_open = false
		palette_forget(p)
	}
}

// Asks each source in the scope of the query whose answer is not for its version, the language or (a searching source)
// the query, and that is not asked that already.
@(private = "file")
palette_ask :: proc(p: ^Command_Palette) {
	language := i18n.version()
	for src, i in p.sources {
		if !palette_in_scope(p.prefix, src.prefix, src.plain) || src.read == nil { continue }
		st := &p.states[i]
		query := src.searches ? p.query : ""
		if s := st.snap; s != nil && s.version == src.version && s.language == language && s.query == query { continue }
		if (st.asked != 0 || st.failed) && st.version == src.version && st.language == language && st.query == query { continue }
		p.serial += 1
		st.asked, st.reading, st.failed, st.version, st.language = p.serial, true, false, src.version, language
		delete(st.query)
		st.query = strings.clone(query)
		p.asks += 1
		src.read(p, src, {serial = st.asked, query = st.query})
	}
}

@(private = "file")
palette_snapshot_make :: proc(src: ^Palette_Source, items: []Palette_Item, version: u64, language: u32, query: string) -> ^Palette_Snapshot {
	snap := new(Palette_Snapshot, runtime.heap_allocator())
	a := virtual.arena_allocator(&snap.arena)
	snap.refs, snap.source = 1, src
	snap.name, snap.title = strings.clone(src.name, a), strings.clone(src.title, a)
	snap.prefix, snap.plain, snap.listed, snap.searches, snap.toolkit = src.prefix, src.plain, src.listed, src.searches, src.toolkit
	snap.remember = src.remember && src.prefix != .Secrets
	if src.prefix == .Secrets { snap.plain = false }
	snap.version, snap.language, snap.query = version, language, strings.clone(query, a)
	snap.items = make([]Palette_Item, len(items), a)
	for it, i in items {
		c := it
		c.id, c.title, c.detail = strings.clone(it.id, a), strings.clone(it.title, a), strings.clone(it.detail, a)
		c.icon, c.keys, c.group = strings.clone(it.icon, a), strings.clone(it.keys, a), strings.clone(it.group, a)
		c.last, c.completion = strings.clone(it.last, a), strings.clone(it.completion, a)
		c.tags = make([]string, len(it.tags), a)
		for t, k in it.tags { c.tags[k] = strings.clone(t, a) }
		snap.items[i] = c
	}
	return snap
}

@(private = "file")
palette_snapshot_release :: proc(snap: ^Palette_Snapshot) {
	if sync.atomic_sub(&snap.refs, 1) != 1 { return }
	virtual.arena_destroy(&snap.arena)
	free(snap, runtime.heap_allocator())
}

@(private = "file")
palette_state_free :: proc(st: ^Palette_Source_State) {
	if st.snap != nil { palette_snapshot_release(st.snap) }
	delete(st.error)
	delete(st.query)
	st^ = {}
}

@(private = "file")
palette_link_release :: proc(l: ^Palette_Link) {
	if sync.atomic_sub(&l.refs, 1) == 1 { free(l, runtime.heap_allocator()) }
}

////////////////////////////////
// The ranking, on a chore

// Starts a ranking when the query, a snapshot, a source or the usage memory changed since the last one (a quiet build
// starts none). The list shown stays until its answer comes.
@(private = "file")
palette_rank_start :: proc(p: ^Command_Palette) {
	if p.ranked.valid && p.ranked.text == p.text && p.ranked.generation == p.generation && p.ranked.memory_version == p.memory.version { return }
	delete(p.ranked.text)
	p.ranked = {valid = true, text = strings.clone(p.text), generation = p.generation, memory_version = p.memory.version}
	if p.link == nil {
		p.link = new(Palette_Link, runtime.heap_allocator())
		p.link^ = {p = p, refs = 1}
	}
	j := new(Palette_Job, runtime.heap_allocator())
	a := virtual.arena_allocator(&j.arena)
	p.serial += 1
	j.link, j.serial, j.prefix, j.query = p.link, p.serial, p.prefix, strings.clone(p.query, a)
	sync.atomic_add(&p.link.refs, 1)
	j.chooser = len(p.sources) == 1 && p.sources[0].prefix == .None
	snaps := make([dynamic]^Palette_Snapshot, a)
	j.first = {-1, -1}
	for src, i in p.sources {
		snap := p.states[i].snap
		if snap == nil || !palette_in_scope(p.prefix, src.prefix, src.plain) { continue }
		if src == &p.commands.source {
			if f, ok := p.commands.first.?; ok && f >= 0 && f < len(snap.items) { j.first = {i32(len(snaps)), i32(f)} }
		}
		sync.atomic_add(&snap.refs, 1)
		append(&snaps, snap)
	}
	j.snaps = snaps[:]
	// (the memory's entries copied: at most CHOICE_MOST of them)
	j.memory.options = p.memory.options
	j.memory.entries = make(map[string]Choice, len(p.memory.entries), a)
	for k, e in p.memory.entries { j.memory.entries[strings.clone(k, a)] = e }
	j.now_ms = choice_now()
	j.sel_source, j.sel_id, j.sel_gen = p.sel_source, strings.clone(p.sel_id, a), p.sel_gen
	p.pending = j.serial
	p.rankings += 1
	task(p.owner != nil ? p.owner : gs(), palette_rank_work, palette_rank_done, j, palette_job_free)
}

@(private = "file")
palette_job_free :: proc(d: rawptr) {
	j := (^Palette_Job)(d)
	for snap in j.snaps { palette_snapshot_release(snap) }
	palette_link_release(j.link)
	virtual.arena_destroy(&j.arena)
	free(j, runtime.heap_allocator())
}

@(private = "file")
palette_shown_free :: proc(p: ^Command_Palette) {
	if p.shown != nil { palette_job_free(p.shown) }
	p.shown = nil
}

// (on the interface's thread, at a build) A ranking of another serial is dropped. The selection stays on its item.
@(private = "file")
palette_rank_done :: proc(d: rawptr, _: u64) {
	j := (^Palette_Job)(d)
	p := j.link.p
	if p == nil || j.serial != p.pending {
		if p != nil { p.dropped += 1 }
		palette_job_free(j)
		return
	}
	palette_shown_free(p)
	p.shown, p.pending = j, 0
	n := len(j.rows)
	switch {
	case !p.sel_moved:           p.sel = 0
	case j.sel_gen == p.sel_gen: p.sel = j.sel_row
	case:                        p.sel = palette_row_of(p, p.sel_source, p.sel_id)
	}
	if p.sel < 0 { p.sel, p.sel_moved = 0, false }
	p.sel = clamp(p.sel, 0, max(n - 1, 0))
	if !p.sel_moved { palette_sel_note(p) }
	p.reveal = true
	if _, waits := p.enter_wait.?; waits { p.enter_ready = true }
}

// The row of an item in the list shown (-1: none). (After a move of the selection while a ranking was in flight only.)
@(private = "file")
palette_row_of :: proc(p: ^Command_Palette, src: ^Palette_Source, id: string) -> int {
	if p.shown == nil || src == nil { return -1 }
	for r, i in p.shown.rows {
		snap := p.shown.snaps[r.snap]
		if snap.source == src && snap.items[r.item].id == id { return i }
	}
	return -1
}

// (on a chore) The rows for the query: with nothing typed, the recent choices then the listed items in their groups,
// the disabled last in each; else one ranked list, the disabled last.
@(private = "file")
palette_rank_work :: proc(d: rawptr) {
	j := (^Palette_Job)(d)
	scratch: virtual.Arena
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	a := virtual.arena_allocator(&j.arena)
	rows := make([dynamic]Palette_Row, a)
	ranges := make([dynamic]Fuzzy_Range, a)
	if j.query == "" {
		palette_list_empty(j, &rows)
	} else {
		palette_list_ranked(j, &rows, &ranges)
	}
	j.rows, j.ranges = rows[:], ranges[:]
	j.sel_row = -1
	for r, i in j.rows {
		snap := j.snaps[r.snap]
		it := &snap.items[r.item]
		if it.icon != "" { j.icons = true }
		if j.sel_row < 0 && !r.recent && snap.source == j.sel_source && it.id == j.sel_id { j.sel_row = i }
	}
}

// With nothing typed. No prefix: Recent (the heaviest choices among the plain sources' items), then the items of the
// listed sources (the commands). A prefix: Recent among its sources, then all their items. A chooser: its items alone.
@(private = "file")
palette_list_empty :: proc(j: ^Palette_Job, rows: ^[dynamic]Palette_Row) {
	headings := 0
	if !j.chooser {
		for h, i in palette_recent(j) {
			if i == 0 { headings += 1 }
			append(rows, Palette_Row{snap = h[0], item = h[1], headings = headings, heading = i == 0, recent = true})
		}
	}
	recent := len(rows^) > 0
	listed := 0
	for snap in j.snaps { if j.prefix != .None || j.chooser || snap.listed { listed += 1 } }
	group := ""
	for snap, si in j.snaps {
		if !(j.prefix != .None || j.chooser || snap.listed) { continue }
		items := snap.items
		i := 0
		for i < len(items) {
			g := items[i].group
			k := i
			for k < len(items) && items[k].group == g { k += 1 }
			shown := g != "" ? g : (listed > 1 ? snap.title : "")
			heading := shown != "" && (shown != group || recent)
			recent = false
			group = shown
			if heading { headings += 1 }
			// (the disabled last in their group: a person learns they exist, the ones that act come first)
			for pass in 0 ..< 2 {
				for x in i ..< k {
					if items[x].disabled != (pass == 1) { continue }
					append(rows, Palette_Row{snap = i32(si), item = i32(x), headings = headings, heading = heading, group = shown})
					heading = false
				}
			}
			i = k
		}
	}
}

// The heaviest choices among the items of the sources that remember (at most CHOICE_RECENT_MOST): only the items present
// in an answer, so a session deleted since is not listed.
@(private = "file")
palette_recent :: proc(j: ^Palette_Job) -> [][2]i32 {
	if len(j.memory.entries) == 0 { return nil }
	Weighed :: struct { at: [2]i32, weight: f64 }
	found := make([dynamic]Weighed, context.temp_allocator)
	for snap, si in j.snaps {
		if !snap.remember { continue }
		head := strings.concatenate({snap.name, ":"}, context.temp_allocator)
		wanted := make(map[string]f64, 16, context.temp_allocator)
		for k in j.memory.entries {
			if strings.has_prefix(k, head) { wanted[k[len(head):]] = choice_weight(&j.memory, k, j.now_ms) }
		}
		if len(wanted) == 0 { continue }
		for it, ii in snap.items {
			if w, ok := wanted[it.id]; ok && w > 0 && !it.disabled { append(&found, Weighed{{i32(si), i32(ii)}, w}) }
		}
	}
	slice.stable_sort_by(found[:], proc(a, b: Weighed) -> bool { return a.weight > b.weight })
	out := make([][2]i32, min(len(found), CHOICE_RECENT_MOST), context.temp_allocator)
	for &o, i in out { o = found[i].at }
	return out
}

// What the bonus of an item reads: the memory, the source's name, the query.
@(private = "file")
Palette_Bonus :: struct {
	memory: ^Choice_Memory,
	name:   string,
	query:  string,
	now_ms: i64,
}

@(private = "file")
palette_item_entry :: proc(it: ^Palette_Item, _: rawptr) -> Rank_Entry {
	return {label = it.title, group = it.group, tags = it.tags, last = it.last}
}

@(private = "file")
palette_item_bonus :: proc(it: ^Palette_Item, user: rawptr) -> f64 {
	b := (^Palette_Bonus)(user)
	return choice_bonus(b.memory, strings.concatenate({b.name, ":", it.id}, context.temp_allocator), b.query, b.now_ms)
}

// Something typed: every source in scope ranked with the same matcher (rank_palette) and the usage memory's bonus, merged
// in one list; a program's own source a few points behind in a plain search; the disabled after the others; the commands'
// `first` before all.
@(private = "file")
palette_list_ranked :: proc(j: ^Palette_Job, rows: ^[dynamic]Palette_Row, ranges: ^[dynamic]Fuzzy_Range) {
	Hit :: struct { at: [2]i32, score: f64, ranges: []Fuzzy_Range, disabled: bool }
	hits := make([dynamic]Hit, context.temp_allocator)
	first_ranges: []Fuzzy_Range
	for snap, si in j.snaps {
		b := Palette_Bonus{memory = &j.memory, name = snap.name, query = j.query, now_ms = j.now_ms}
		bonus: proc(it: ^Palette_Item, user: rawptr) -> f64
		if snap.remember { bonus = palette_item_bonus }
		found := rank(j.query, snap.items, palette_item_entry, &b, bonus = bonus)
		// (the answer of a searching source to this very query: what it found stays; an older answer, shown until the
		// next one comes, keeps only what the matcher finds)
		matched: []bool
		if snap.searches && snap.query == j.query { matched = make([]bool, len(snap.items), context.temp_allocator) }
		for h in found {
			at := [2]i32{i32(si), i32(h.index)}
			if matched != nil { matched[h.index] = true }
			if at == j.first { first_ranges = h.ranges; continue }
			score := h.score
			if j.prefix == .None && !snap.toolkit { score -= PALETTE_OWN_PENALTY }
			append(&hits, Hit{at, score, h.ranges, snap.items[h.index].disabled})
		}
		// (what the source found and the matcher does not: it stays, after every match, in the source's order)
		for m, i in matched {
			at := [2]i32{i32(si), i32(i)}
			if m || at == j.first { continue }
			append(&hits, Hit{at, -PALETTE_FOUND_PENALTY, nil, snap.items[i].disabled})
		}
	}
	slice.stable_sort_by(hits[:], proc(a, b: Hit) -> bool {
		if a.disabled != b.disabled { return !a.disabled }
		return a.score > b.score
	})
	add :: proc(rows: ^[dynamic]Palette_Row, ranges: ^[dynamic]Fuzzy_Range, at: [2]i32, r: []Fuzzy_Range) {
		append(rows, Palette_Row{snap = at[0], item = at[1], range_first = len(ranges^), range_count = len(r)})
		append(ranges, ..r)
	}
	if j.first[0] >= 0 { add(rows, ranges, j.first, first_ranges) }
	for h in hits { add(rows, ranges, h.at, h.ranges) }
}

////////////////////////////////
// The view

// The selection's item noted: the next list keeps it selected.
@(private = "file")
palette_sel_note :: proc(p: ^Command_Palette) {
	src, id, ok := palette_row(p, p.sel)
	if !ok { return }
	if src == p.sel_source && id == p.sel_id { return }
	delete(p.sel_id)
	p.sel_source, p.sel_id = src, strings.clone(id)
	p.sel_gen += 1
}

// Moves the selection by `step` rows (wrapping when `wrap`), over the disabled ones.
@(private = "file")
palette_sel_move :: proc(p: ^Command_Palette, step: int, wrap: bool) {
	n := palette_row_count(p)
	if n == 0 { return }
	at := p.sel
	step := step
	for _ in 0 ..< n {
		next := at + step
		if wrap { next = (next % n + n) % n } else { next = clamp(next, 0, n - 1) }
		if next == at { break }
		at = next
		if !palette_row_disabled(p, at) { break }
		if !wrap { step = step > 0 ? 1 : -1 }   // (a page that ends on a disabled row: the next one that acts)
	}
	if palette_row_disabled(p, at) { return }
	p.sel, p.sel_moved, p.reveal = at, true, true
	palette_sel_note(p)
}

@(private = "file")
palette_row_disabled :: proc(p: ^Command_Palette, i: int) -> bool {
	r := p.shown.rows[i]
	return p.shown.snaps[r.snap].items[r.item].disabled
}

// Chooses row `i`: noted in the usage memory, then the toolkit's source acts (palette_chosen runs it) or the choice is
// the program's. The palette closes, but for an item that stays (a switch).
@(private = "file")
palette_choose :: proc(p: ^Command_Palette, v: ^View, i: int, mods: platform.Modifiers) {
	if p.shown == nil || i < 0 || i >= len(p.shown.rows) || palette_row_disabled(p, i) { return }
	r := p.shown.rows[i]
	snap := p.shown.snaps[r.snap]
	it := snap.items[r.item]
	src := snap.source
	if palette_source_index(p, src) < 0 { return }
	if snap.remember {
		current := p.ranked.memory_version == p.memory.version
		choice_note(&p.memory, strings.concatenate({snap.name, ":", it.id}, context.temp_allocator))
		// (a switch flipped, the palette open: its mark follows, the list is not ranked again for the choice)
		if it.stays && current { p.ranked.memory_version = p.memory.version }
	}
	delete(p.chosen.id)
	p.chosen = {source = src, id = strings.clone(it.id), index = int(r.item), command = src == &p.commands.source ? int(r.item) : -1, mods = mods}
	if src.act != nil { p.act_due = true } else { p.has_choice = true }
	if !it.stays {
		view_end(v, 0)
		palette_forget(p)
		p.was_open = false
	}
}

// The palette's view: the search band, the list, the hint row. The keys are read before the field; the query is read
// after it, so that what a frame typed is the query its Enter chooses from.
@(private = "file")
palette_view :: proc(v: ^View, p: ^Command_Palette) {
	p.was_open = true
	em := font_size()
	if language := i18n.version(); language != p.language { p.language = language; p.generation += 1 }
	for src in p.sources { if src.poll != nil { src.poll(p, src) } }
	// (Enter waited for the ranking of its query: it came)
	if p.enter_ready {
		mods := p.enter_wait.? or_else platform.Modifiers{}
		p.enter_wait, p.enter_ready = nil, false
		first := -1
		for k in 0 ..< palette_row_count(p) { if !palette_row_disabled(p, k) { first = k; break } }
		if first >= 0 { palette_choose(p, v, first, mods) }
		if !p.was_open { return }
	}
	n := palette_row_count(p)
	row_h := math.round(dense(em * PALETTE_ROW_EM))
	heading_h := em * PALETTE_HEADING_EM
	if n > 0 {
		page := max(int(palette_list_h(p) / row_h), 1)
		// (the palette's own keys, read before its field is built)
		if key_press_any(.Down) { palette_sel_move(p, 1, true) }
		if key_press_any(.Up) { palette_sel_move(p, -1, true) }
		if key_press_any(.Page_Down) { palette_sel_move(p, page, false) }
		if key_press_any(.Page_Up) { palette_sel_move(p, -page, false) }
	}
	if key_press_any(.Tab) {
		if src, _, ok := palette_selected(p); ok && src != nil {
			r := p.shown.rows[p.sel]
			if c := p.shown.snaps[r.snap].items[r.item].completion; c != "" { line_edit_set(&p.field, c) }
		}
	}
	p.sel = clamp(p.sel, 0, max(n - 1, 0))
	mouse := mouse_pos()
	moved := abs(mouse.x - p.mouse.x) + abs(mouse.y - p.mouse.y) > 0.5
	p.mouse = mouse
	chooser := len(p.sources) == 1 && p.sources[0].prefix == .None
	top_h := math.round(dense(em * SEARCH_BAND_EM))   // (search_band's)
	gap_h := math.round(em * 0.3)
	foot_h := chooser ? math.round(em * 0.4) : math.round(dense(em * 2))
	// (a source that reads, not the ranking: that one comes in a frame, and the count would flicker at each key)
	reading := false
	for st in p.states { if st.reading { reading = true } }
	res := search_band("palette_top", &p.field, {count = n, busy = reading})
	if p.fresh { set_focus(res.box.key); p.fresh = false }
	if res.cancelled {   // (Escape in the field: the field takes it before the dialog)
		view_end(v, VIEW_CANCELLED)
		palette_forget(p)
		p.was_open = false
		return
	}
	enter: Maybe(platform.Modifiers)
	if res.committed { enter = platform.Modifiers{} }
	// (Enter with a modifier: the source's alternate)
	for m in ([]platform.Modifiers{{.Ctrl}, {.Alt}, {.Shift}}) { if key_press_any(.Return, m) { enter = m } }
	// The query after the field: the questions and the ranking it needs.
	if text := line_edit_string(&p.field); text != p.text || !p.ranked.valid {
		delete(p.text)
		p.text = strings.clone(text)
		p.prefix, p.query = palette_parse(p, p.text)
		p.sel_moved = false
		p.serial += 1
	}
	palette_ask(p)
	palette_rank_start(p)
	if mods, ok := enter.?; ok {
		if p.pending != 0 { p.enter_wait = mods } else { palette_choose(p, v, p.sel, mods) }
		if !p.was_open { return }
	}
	spacer(px(gap_h))
	// The list ends on a whole row: what a row short of it is left goes under the list, so that the foot never cuts its
	// last row in half.
	dialog := parent_box()
	inner := gs().modal_stack[len(gs().modal_stack) - 1].wh.y - 2 * border_inset(dialog)
	avail := max(inner - top_h - gap_h - foot_h, 0)
	rest := avail >= row_h ? avail - math.floor(avail / row_h) * row_h : 0
	clicked, hovered := -1, -1
	next({width = fill(), height = fill()})
	if scroll_y("###palette_list") {
		lb := parent_box()
		p.list_key = lb.key
		view_h := lb.rect.max.y - lb.rect.min.y
		rows: []Palette_Row
		if p.shown != nil { rows = p.shown.rows }
		if p.reveal && view_h > row_h && n > 0 {
			top := heading_line_top(rows, p.sel, row_h, heading_h)
			lb.view_target.y = view_reveal_offset(lb.view_target.y, top, top + row_h, view_h)
			p.reveal = false
		}
		if n == 0 { palette_quiet_rows(p, row_h) }
		icons := p.shown != nil && p.shown.icons && gs().icon_font != 0
		first, last, above, below := heading_lines_band(rows, lb, row_h, heading_h)
		if above > 0 { spacer(px(above)) }
		for k in first ..< last {
			r := rows[k]
			snap := p.shown.snaps[r.snap]
			it := snap.items[r.item]
			if r.heading {
				heading := r.recent ? i18n.tr("Recent") : r.group
				if tags("weak") {
					next({width = fill(), height = px(heading_h), font_size = em * 0.9, text_pad = em * 0.7})
					build_box({.Draw_Text}, fmt.tprintf("%s###palette_h_%d", heading, k))
				}
			}
			sig := palette_row_build(p, snap, it, r, k, row_h, icons, k == p.sel)
			if sig.hovering && moved { hovered = k }
			if sig.clicked { clicked = k }
		}
		if below > 0 { spacer(px(below)) }
		if n > 0 { palette_quiet_rows(p, row_h) }
	}
	spacer(px(rest))
	if !chooser { palette_hint_row(p, foot_h) } else { spacer(px(foot_h)) }
	if hovered >= 0 && hovered != p.sel {
		p.sel, p.sel_moved = hovered, true
		palette_sel_note(p)
	}
	if clicked >= 0 { palette_choose(p, v, clicked, {}) }
}

// The palette's list's height at the last build (0: not laid out yet).
@(private = "file")
palette_list_h :: proc(p: ^Command_Palette) -> f32 {
	b := box_from_key(p.list_key)
	if b == nil || p.list_key == 0 { return 0 }
	return b.rect.max.y - b.rect.min.y
}

// One row, the same for every source: the icon, the title with what the query lit (and its group while something is
// typed), the detail, the mark, the keys.
@(private = "file")
palette_row_build :: proc(p: ^Command_Palette, snap: ^Palette_Snapshot, it: Palette_Item, r: Palette_Row, k: int, row_h: f32, icons, sel: bool) -> Signal {
	em := font_size()
	text := it.title
	if p.query != "" {
		if g := it.group != "" ? it.group : i18n.tr(snap.title); g != "" { text = fmt.tprintf("%s  ·  %s", it.title, g) }
	}
	push_tags("menu_item")
	defer pop_tags()
	if sel { push_tags("selected") }
	defer if sel { pop_tags() }
	next({width = fill(), height = px(row_h), axis = .X, cross = .Center})
	flags := Box_Flags{.Clickable, .Draw_Hot_Effects}
	if it.disabled { flags += {.Disabled} }
	rb := build_box(flags, fmt.tprintf("###palette_%d_%d_%d", r.snap, r.item, k))
	if sel { rb.custom = palette_selected_draw }
	a11y_default(rb, {role = .Menu_Item, name = text, selected = sel})
	rs := signal(rb)
	if parent(rb) {
		spacer(px(em * 0.7))
		if icons {
			if !sel { push_tags("weak") }
			next({width = px(em * 1.7), height = pct(1), font = gs().icon_font, font_size = em * 0.95, text_align = .Center, text_pad = 0})
			build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###i", it.icon))
			if !sel { pop_tags() }
			spacer(px(em * 0.5))
		}
		// (what the query found in the title lit; tags, which the row does not show, light nothing)
		ranges := p.shown.ranges[r.range_first:][:r.range_count]
		if p.query != "" && len(ranges) == 0 { ranges = word_ranges(it.title, p.query) }
		next({width = fill(), text_pad = 0})
		tb := matched_label("###t", text, ranges)
		if label_cut(tb, text) && hovered_for(rs) { if tooltip() { tooltip_text(text) } }
		if it.detail != "" && snap.prefix != .Secrets {
			if tags("weak") {
				next({width = text_size(), height = pct(1), text_pad = 0, font_size = em * 0.9})
				label(fmt.tprintf("%s###d", it.detail))
				spacer(px(em * 0.6))
			}
		}
		if src := snap.source; src.mark != nil && src.mark(src, it.id) {
			next({width = px(em * 1.4), height = pct(1), font = widget_icons(), font_size = em * 0.9, text_align = .Center, text_pad = 0})
			build_box({.Draw_Text, .No_Text_Trunc}, ICON_CHECK + "###m")
		}
		if it.keys != "" {
			if tags("weak") {
				next({width = text_size(), height = pct(1), text_pad = 0, font_size = em * 0.9})
				label(fmt.tprintf("%s###k", it.keys))
			}
		}
		spacer(px(em * 0.5))   // (the scroll bar keeps its own room: the layout of the list)
	}
	return rs
}

// The weak rows that are no items: the sources in scope still reading ("Sessions: reading…") or that could not read,
// and "Nothing matches" when the list is empty and none reads.
@(private = "file")
palette_quiet_rows :: proc(p: ^Command_Palette, row_h: f32) {
	reading := false
	for src, i in p.sources {
		if !palette_in_scope(p.prefix, src.prefix, src.plain) { continue }
		st := p.states[i]
		line := ""
		switch {
		case st.reading && p.prefix != .None: line = fmt.tprintf(i18n.tr("%s: reading…"), i18n.tr(src.title)); reading = true
		case st.reading:                      reading = true   // (the plain search: the band's count says it)
		case st.error != "":                  line = fmt.tprintf(i18n.tr("%s: could not read (%s)"), i18n.tr(src.title), st.error)
		}
		if line == "" { continue }
		next({width = fill(), height = px(row_h), text_align = .Center})
		if tags("weak") { label(fmt.tprintf("%s###palette_quiet_%d", line, i)) }
	}
	if palette_row_count(p) == 0 && !reading && p.pending == 0 && p.shown != nil {
		next({width = fill(), height = px(row_h), text_align = .Center})
		if tags("weak") { label(fmt.tprintf("%s###palette_none", i18n.tr("Nothing matches"))) }
	}
}

// The foot: the prefixes the program has (a click types one; while one is typed, that one alone), and at the right the
// keys of the selected row.
@(private = "file")
palette_hint_row :: proc(p: ^Command_Palette, foot_h: f32) {
	em := font_size()
	next({width = fill(), height = px(foot_h), axis = .X, cross = .Center})
	if row(.Center, {.Draw_Side_Top}, "###palette_foot") {
		spacer(px(em * 0.7))
		for x in Palette_Prefix {
			if x == .None || (p.prefix != .None && x != p.prefix) { continue }
			name := palette_prefix_title(p, x)
			if name == "" { continue }
			text := fmt.tprintf("%c %s", rune(palette_prefix_char(x)), i18n.tr(name))
			if tags("weak") {
				next({width = text_size(), height = pct(1), font_size = em * 0.85, text_pad = em * 0.35})
				b := build_box({.Clickable, .Draw_Text, .Draw_Hot_Effects}, fmt.tprintf("%s###palette_prefix_%v", text, x))
				if signal(b).clicked {
					line_edit_set(&p.field, fmt.tprintf("%c", rune(palette_prefix_char(x))))
					p.fresh = true
				}
			}
		}
		spacer(fill())
		if src, _, ok := palette_selected(p); ok && src != nil {
			enter := src.enter != "" ? src.enter : i18n.later("Choose")
			parts := make([dynamic]string, context.temp_allocator)
			append(&parts, fmt.tprintf("%s %s", chord_text({.Return, {}}), i18n.tr(enter)))
			alts := [3]string{src.alternates.ctrl, src.alternates.alt, src.alternates.shift}
			mods := [3]platform.Modifiers{{.Ctrl}, {.Alt}, {.Shift}}
			for a, i in alts { if a != "" { append(&parts, fmt.tprintf("%s %s", chord_text({.Return, mods[i]}), i18n.tr(a))) } }
			if tags("weak") {
				next({width = text_size(), height = pct(1), font_size = em * 0.85})
				label(fmt.tprintf("%s###palette_keys", strings.join(parts[:], "   ", context.temp_allocator)))
			}
		}
		spacer(px(em * 1.4))   // (the corner's grip)
	}
}
