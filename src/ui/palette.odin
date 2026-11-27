package ui

// The command palette (src/md/features/palette.md): a field, and one ranked list of the items that sources give. One
// palette in every program: the same look, the same keys, the same prefixes.
//
//   ui.palette_memory_open(&app.palette, &app.ui, path)               once: the usage memory's file ("": in memory only)
//   ui.palette_add(&app.palette, &app.sessions)                       a source of the program's (a prefix of the table)
//   // each build, at its top:
//   ui.palette_commands(&app.palette, COMMANDS[:], disabled[:], {version = v})   the commands source and the views' moves
//   ui.palette_keys(&app.palette)                                     Ctrl+K, Ctrl+Shift+P open and close it
//   if c, ok := ui.palette_chosen(&app.palette); ok {                 the toolkit's sources act in it
//       if i, is := ui.palette_chosen_command(&app.palette, c); is { run(Cmd(i)) } else if c.source == &app.sessions { switch_to(c.id) }
//   }
//
// A source answers its question (Palette_Question) with palette_answer and a Palette_Answer it built (at once, or on a
// chore): the palette takes the answer as it is, without a copy. The palette ranks every answer together on a chore: the
// interface's thread never matches an item. An answer or a ranking for another serial (an older query, a former
// opening, a source removed) is dropped and freed.

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
// A ranking reads this many items of a source between two looks at whether a newer ranking replaced it: a stale one
// stops early, and does not hold a chore while the next letter's ranking waits.
PALETTE_RANK_CHUNK :: 2048

// The prefixes: a closed table of the toolkit. A prefix means the same thing in every program; a program fills one with a
// source, or leaves it empty.
Palette_Prefix :: enum u8 {
	None,       // the plain search: every source with `plain`, and every source without a prefix
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

// (read only: a Command made of them can be put in any table, none can change the keys of all)
@(private = "file", rodata) PALETTE_CHORDS := [2]Chord{{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}}

// The toolkit's command of the palette: Ctrl+K and Ctrl+Shift+P, a window command; no setting turns it off. The toolkit
// owns it whole: palette_keys reads its keys, the sheet of the keys lists it, so a program's table holds no line for it
// (a constant of its keys for a program's table was refused: two lines of one command, one in the program, one in the
// sheet). A program's menu line for it reads it at its build: menu_item(c.label, command_shortcut(c)). (Its label and
// group in English, translated where they show.)
palette_command :: proc() -> Command {
	return {label = "Command palette", group = "Window", icon = lucide.COMMAND, scope = .Window, keys = PALETTE_CHORDS[:]}
}

// An item of a source. Its strings live in its answer's arena (palette_answer_allocator), or are constants.
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
	// the act name of what it acts on ("setting:appearance.theme", "command:save"): Shift+Enter goes to the element
	// that states it (acts.odin), when a frame shows it or its source reaches it
	act:        string,
	disabled:   bool,       // greyed, listed last, not chosen
	stays:      bool,       // choosing it does not close the palette (a switch)
	runs:       bool,       // Enter opens its run mode (its source's runner): its control, or a command's form
}

// A source's answer: its items and the arena that holds them. The source builds it (on the interface's thread for an
// answer made at once, on a chore for one made later); palette_answer takes it whole, kept or dropped: no copy.
Palette_Answer :: struct {
	arena: virtual.Arena,
	items: []Palette_Item,   // in `arena`
}

// What an answer's items and strings are made in.
palette_answer_allocator :: proc(a: ^Palette_Answer) -> runtime.Allocator { return virtual.arena_allocator(&a.arena) }

// An item with its strings copied in `allocator` (an answer's): for a source whose items live in memory that can change.
palette_item_clone :: proc(it: Palette_Item, allocator: runtime.Allocator) -> Palette_Item {
	c := it
	c.id, c.title, c.detail = strings.clone(it.id, allocator), strings.clone(it.title, allocator), strings.clone(it.detail, allocator)
	c.icon, c.keys, c.group = strings.clone(it.icon, allocator), strings.clone(it.keys, allocator), strings.clone(it.group, allocator)
	c.last, c.completion, c.act = strings.clone(it.last, allocator), strings.clone(it.completion, allocator), strings.clone(it.act, allocator)
	c.tags = make([]string, len(it.tags), allocator)
	for t, k in it.tags { c.tags[k] = strings.clone(t, allocator) }
	return c
}

// What the palette asks a source. It holds a counted handle on the palette: the source ends each question exactly once,
// with palette_answer, palette_answer_error or palette_question_drop (a source that gives up), from any thread: off the
// palette's interface thread the end is posted there (a chore's `done` or its `lost`, a worker). After palette_destroy,
// or once its window is gone, an end finds no palette and only lets go of the handle and frees the answer.
Palette_Question :: struct {
	link:   ^Palette_Link,
	source: ^Palette_Source,
	serial: u64,
	prefix: Palette_Prefix,   // the prefix typed (None: the plain search): a source of two places tells them apart
	query:  string,           // the query after the prefix; valid during `read`: a source that answers later copies it
}

// The meaning of Ctrl+Enter and Alt+Enter for a source's items ("Open in a new tab"; "": what Enter does). Shift+Enter
// is go to in every source (Palette_Item.act).
Palette_Alternates :: struct {
	ctrl, alt: string,
}

// A choice: the source, the item's id, its index in the answer it came from (the commands source: its index in the
// table, palette_chosen_command), the modifiers of the Enter ({} plain Enter or a click), the query it was chosen for,
// without its prefix (an alias typed: classeur's Alt+Enter), and a command's arguments given in its form.
Palette_Choice :: struct {
	source:    ^Palette_Source,
	id:        string,     // the palette's: valid until the next choice
	index:     int,
	mods:      platform.Modifiers,
	query:     string,     // the palette's: valid until the next choice
	// a command's values (Command.arguments), in their order, as the settings file writes them (config.value_text):
	// the palette's, valid until the next choice (nil: it takes none)
	arguments: []string,
}

// A source of items. The program keeps it at a place that does not move while the palette has it (palette_add).
Palette_Source :: struct {
	name:       string,           // stable, in English: the usage memory's part ("command", "session")
	title:      string,           // "Sessions", in English: the hint row's and its "reading" row's, translated there
	prefix:     Palette_Prefix,   // None: in the plain search only (a chooser's source)
	plain:      bool,             // its items take part in a search without a prefix too (never a Secrets source)
	remember:   bool,             // its choices go to the usage memory (never a Secrets source)
	listed:     bool,             // its items are listed while nothing is typed and no prefix is (the commands)
	searches:   bool,             // it answers for the query: asked again at each one. Else once per version
	enter:      string,           // the word of Enter in the hint row, in English ("": "Choose")
	alternates: Palette_Alternates,
	// asks for the items, on the interface's thread, when the query (a searching source), the version or the language
	// changed. It ends the question (palette_answer) at once or later; it makes no system call.
	read:       proc(p: ^Command_Palette, src: ^Palette_Source, q: Palette_Question),
	// the mark of an item now (a switch on, the model in use): called for the rows built only
	mark:       proc(src: ^Palette_Source, id: string) -> bool,
	// the value an item has now, at its row's right ("Nord", "300 ms"; "": none): called for the rows built only
	value:      proc(src: ^Palette_Source, id: string) -> string,
	// whether item `id`'s act name can be shown though no frame shows it (the settings, closed); with `go`, shows its
	// place (go to then finds the element in a next build). nil: only what a frame shows is reached
	reach:      proc(p: ^Command_Palette, src: ^Palette_Source, id: string, go: bool) -> bool,
	// the run mode of its items that run (Palette_Item.runs): their control or their form (palette_run.odin)
	runner:     ^Palette_Runner,
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
	recorder: Keymap_Recorder,                 // Ctrl+Enter on a command: its key recorded (keymap.odin)
	memory:   ^Choice_Memory,                  // what the user chose: shared per file (palette_memory_open; nil: none yet)
	run:      Palette_Run,                     // the run mode: an item's control or a command's form (palette_run.odin)
	// the commands' forms: prefs_page's, which has the control table (palette_forms_use; none: a command with arguments
	// is chosen without them)
	forms:    Palette_Runner,
	// the system's families for a form's Font_Family argument: read once, on a chore, kept as long as the palette (a
	// run's own would be freed under its chore)
	families: Font_Families,
	// Shift+Enter on an item that can be reached: its source, id and act name (owned), gone to by palette_chosen
	go:       struct { source: ^Palette_Source, id, act: string, due: bool },
	// what a test reads: the questions asked, the rankings started, the answers and rankings dropped (another serial)
	asks, rankings, dropped: int,

	serial:     u64,              // changes at each query, each question, each open, each close, each removal
	link:       ^Palette_Link,    // what the questions and the chores' answers find the palette by
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
	sel_source: ^Palette_Source,  // the selected row's item, to find it in the next list: its source, its id, and
	sel_id:     string,           // (owned) whether it is a row of Recent (an item can be there and in its group)
	sel_recent: bool,
	sel_gen:    u64,              // counts the changes of the selected item

	// Enter while a ranking is in flight: its modifiers, and whether the person had moved the selection (the ranking
	// keeps it on its item: Enter takes that row; else the first row that acts)
	enter_wait:  Maybe(platform.Modifiers),
	enter_moved: bool,
	enter_ready: bool,                        // that ranking came: the view chooses
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
	place:    Palette_Prefix,
}

// What a ranking was asked for: a change of any of these ranks again.
@(private)
Palette_Ranked :: struct {
	valid:          bool,
	text:           string,   // (owned)
	generation:     u64,
	memory_version: u64,
}

// A source's answer, kept: immutable while a ranking reads it, freed by the last one that lets go of it.
@(private)
Palette_Snapshot :: struct {
	refs:     int,   // (atomic) the palette's and each ranking's
	arena:    virtual.Arena,   // the answer's, taken whole
	items:    []Palette_Item,
	source:   ^Palette_Source,   // (read on the interface's thread only)
	// the source's flags, copied: a chore reads them
	name, title: string,
	prefix:   Palette_Prefix,
	plain, remember, listed, searches, toolkit: bool,
	version:  u64,
	language: u32,
	query:    string,   // what it answered for (a searching source)
	place:    Palette_Prefix,   // and where that query was typed (a searching source: its prefix, or None)
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

// What the questions and the chores' answers find the palette by: `p` nil once it is destroyed (read on the interface's
// thread only). Counted: the palette's, each question's, each job's. `latest`: the serial of the ranking the palette
// waits for (atomic: a chore reads it). `thread` and `box`, set once: the interface's thread, and where an end of a
// question made on another thread is posted (the window's Task_Box, counted: a window gone refuses the post).
Palette_Link :: struct {
	p:      ^Command_Palette,
	refs:   int,
	latest: u64,
	thread: int,
	box:    ^Task_Box,
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
	sel_recent: bool,
	sel_gen:  u64,
	// made by the chore
	rows:        []Palette_Row,
	ranges:      []Fuzzy_Range,
	sel_row:     int,    // the selected item's row (-1: not in the list)
	first_acting: int,   // the first row that is not disabled (-1: none)
	icons:       bool,
	stale:       bool,   // a newer ranking replaced it: it stopped early
}

// Adds a source. A second add of the same source does nothing: a program may add its sources at each build. The
// program keeps it where it is while the palette has it.
palette_add :: proc(p: ^Command_Palette, src: ^Palette_Source) {
	if palette_has(p, src) { return }
	append(&p.sources, src)
	append(&p.states, Palette_Source_State{})
	p.generation += 1
}

// Whether the palette has the source (palette_add, not palette_remove since): what a program asks before it fills a
// source's fields once, instead of testing one of them.
palette_has :: proc(p: ^Command_Palette, src: ^Palette_Source) -> bool { return palette_source_index(p, src) >= 0 }

// Removes a source: its answer goes, its question goes stale, the ranking in flight (which reads it) is dropped, and
// the list is ranked again.
palette_remove :: proc(p: ^Command_Palette, src: ^Palette_Source) {
	i := palette_source_index(p, src)
	if i < 0 { return }
	palette_state_free(&p.states[i])
	ordered_remove(&p.sources, i)
	ordered_remove(&p.states, i)
	palette_shown_free(p)
	palette_rank_drop(p)
	p.ranked.valid = false
	p.serial += 1
	p.generation += 1
}

// Ends question `q` with the source's answer: the palette takes `a` whole (it is zero after), kept when `q` is the
// source's question in flight, else dropped and freed. On the palette's interface thread: true when it was kept. On
// another thread: posted to the interface's (kept or dropped at its next build), false.
palette_answer :: proc(q: Palette_Question, a: ^Palette_Answer) -> bool {
	if !palette_question_here(q) {
		palette_end_post(q, .Answer, a, "")
		return false
	}
	p, i, ok := palette_question_end(q)
	if !ok {
		virtual.arena_destroy(&a.arena)
		a^ = {}
		return false
	}
	st := &p.states[i]
	if st.snap != nil { palette_snapshot_release(st.snap) }
	st.snap = palette_snapshot_take(q.source, a, st.version, st.language, st.query, st.place)
	st.asked, st.reading, st.failed = 0, false, false
	delete(st.error, runtime.heap_allocator())
	st.error = ""
	p.generation += 1
	return true
}

// Ends question `q`: the source could not read (its own timeout, its own error). One weak row says it, "Sessions: could
// not read (message)". The same rules as palette_answer (`message` is copied).
palette_answer_error :: proc(q: Palette_Question, message: string) -> bool {
	if !palette_question_here(q) {
		palette_end_post(q, .Error, nil, message)
		return false
	}
	p, i, ok := palette_question_end(q)
	if !ok { return false }
	st := &p.states[i]
	st.asked, st.reading, st.failed = 0, false, true
	// (a source's state keeps its strings in the heap: it is freed wherever the source is removed, under any allocator)
	delete(st.error, runtime.heap_allocator())
	st.error = strings.clone(message, runtime.heap_allocator())
	return true
}

// Ends question `q` without an answer: a source that gives it up (a newer question came, its chore was cancelled). When
// it was the question in flight, the source no longer reads, and the palette asks it again at a next build. From any
// thread, as palette_answer.
palette_question_drop :: proc(q: Palette_Question) {
	if !palette_question_here(q) {
		palette_end_post(q, .Drop, nil, "")
		return
	}
	p, i, ok := palette_question_end(q)
	if !ok { return }
	p.states[i].asked, p.states[i].reading = 0, false
}

// Frees an answer that was never given to palette_answer (a source that built one, then gave its question up). It is
// zero after.
palette_answer_free :: proc(a: ^Palette_Answer) {
	virtual.arena_destroy(&a.arena)
	a^ = {}
}

// Opens the palette over the window being built (one open comes forward), `typed` in its field ("@": the sessions);
// `typed` given to an open palette replaces its field. Open over another window, it moves here, fresh.
palette_open :: proc(p: ^Command_Palette, typed := "") { palette_open_over(p, typed, gs()) }

// The window the palette was last over, while it is one of the program's windows; else the window being built. What
// follows a choice (the recorder of a key, the palette again after it or after an alias) shows there: the person is in
// that window, and palette_chosen runs in the program's window's build.
@(private)
palette_window :: proc(p: ^Command_Palette) -> ^State {
	for st in views().states { if st == p.owner { return st } }
	return gs()
}

// palette_open over window `over`, one of the windows of the program's Views.
@(private)
palette_open_over :: proc(p: ^Command_Palette, typed: string, over: ^State) {
	vs := views()
	if p.owner != over && view_is_open(vs, PALETTE_VIEW, palette_instance(p)) { palette_close(p) }
	if !view_registered(vs, PALETTE_VIEW) {
		view_register(vs, PALETTE_VIEW, palette_view, View_Options{
			title = "Commands", no_header = true, resizable = true, top = PALETTE_TOP, quick = true,
			width_em = PALETTE_WIDTH_EM, height_em = PALETTE_HEIGHT_EM, min_width_em = PALETTE_MIN_EM.x, min_height_em = PALETTE_MIN_EM.y,
		})
	}
	if !view_is_open(vs, PALETTE_VIEW, palette_instance(p)) {
		palette_forget(p)
		palette_shown_free(p)
		p.fresh, p.sel, p.sel_moved, p.reveal, p.owner = true, 0, false, true, over
		// (the sources' answers go to the window it is over: a link kept from another window, which may close, would
		// refuse them)
		if p.link != nil && p.link.box != task_box_of(p.owner) { palette_unlink(p) }
		p.ranked.valid = false
		delete(p.text)
		p.text, p.query, p.prefix = "", "", .None
		line_edit_set(&p.field, typed)
	} else if typed != "" {
		line_edit_set(&p.field, typed)
		p.fresh = true
	}
	view_open(vs, PALETTE_VIEW, p, palette_instance(p), owner = over)
	p.was_open = true
	if over != gs() { over.anim_busy = true }   // (it shows at that window's next build)
}

palette_is_open :: proc(p: ^Command_Palette) -> bool { return view_is_open(views(), PALETTE_VIEW, palette_instance(p)) }

palette_close :: proc(p: ^Command_Palette) {
	palette_run_close(p, true)   // (as Escape at each level: a value never kept is put back)
	view_close(views(), PALETTE_VIEW, palette_instance(p))
	palette_forget(p)
	p.was_open = false
}

// Opens it over the window being built, or closes it when it is open there: a program's button or menu line.
palette_toggle :: proc(p: ^Command_Palette, typed := "") {
	if palette_is_open(p) && p.owner == gs() { palette_close(p) } else { palette_open(p, typed) }
}

// The palette's keys (palette_command: Ctrl+K, Ctrl+Shift+P), pressed: it opens or closes. The one way a program reads
// them: once, at the top of the build, as any window command (its table has no line for the command: palette_command).
// The windows of the views this window owns read them too, for this palette (views_window_build).
palette_keys :: proc(p: ^Command_Palette) -> bool {
	gs().palette = p
	return palette_keys_read(p)
}

// The keys pressed in the window being built: the program's (palette_keys) or a view's (views_window_build).
@(private)
palette_keys_read :: proc(p: ^Command_Palette) -> bool {
	palette_follow_close(p)
	// (the recorder takes any chord, Ctrl+K too: its claim counts once it has the keyboard, this from its opening)
	if p.recorder.id != "" { return false }
	if !command_pressed(palette_command()) { return false }
	palette_toggle(p)
	return true
}

// The choice of the program's sources, taken once, in the build after it. Call it at each build, before the program's
// content: it runs the choices of the toolkit's sources (a setting flips, a view's move runs), a command's Ctrl+Enter
// and Alt+Enter (a key set, an alias made: keymap.odin) and Shift+Enter's go to, which return nothing; it makes the run
// mode's writes (a value changed, kept, put back: palette_run.odin), so the program's content shows them in the same
// frame as the palette; it opens the palette again when the recorder ended; and it follows a close the palette did not
// make (Escape, a click outside), whose questions go stale and whose run mode puts its value back.
palette_chosen :: proc(p: ^Command_Palette) -> (c: Palette_Choice, ok: bool) {
	palette_follow_close(p)
	palette_run_due(p)
	if p.go.due {
		p.go.due = false
		if palette_source_index(p, p.go.source) >= 0 && !act_go(p.go.act) && p.go.source.reach != nil {
			_ = p.go.source.reach(p, p.go.source, p.go.id, true)
		}
	}
	if p.recorder.id != "" {
		if _, ended := view_ended(views(), KEYMAP_RECORDER_VIEW, palette_instance(p)); ended {
			text := strings.clone(p.recorder.text, context.temp_allocator)
			keymap_recorder_free(&p.recorder)
			palette_open_over(p, text, palette_window(p))
		}
	}
	if p.act_due {
		p.act_due = false
		if src := p.chosen.source; src != nil && src.act != nil && palette_source_index(p, src) >= 0 { src.act(p, src, p.chosen) }
		return {}, false
	}
	if !p.has_choice { return {}, false }
	p.has_choice = false
	if palette_commands_alternate(p, p.chosen) { return {}, false }
	return p.chosen, true
}

// The index in the commands table (palette_commands) of a choice of the commands source.
palette_chosen_command :: proc(p: ^Command_Palette, c: Palette_Choice) -> (index: int, ok: bool) {
	if c.source == nil || c.source != &p.commands.source { return -1, false }
	return c.index, true
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

// Whether the list shown answers the question being asked: no source in its scope has a question in flight, and the
// ranking of their answers came (none in flight, made after the last answer). Its dialog waits for it as it opens.
@(private)
palette_answered :: proc(p: ^Command_Palette) -> bool {
	if p.shown == nil || p.pending != 0 || !p.ranked.valid || p.ranked.generation != p.generation { return false }
	for src, i in p.sources {
		if palette_in_scope(p.prefix, src.prefix, src.plain) && src.read != nil && p.states[i].asked != 0 { return false }
	}
	return true
}

// Whether the list shown was ranked for the field's text `text`, and no ranking is in flight: what a test waits for
// after it typed (the list on screen is the one of that text).
palette_ranked_for :: proc(p: ^Command_Palette, text: string) -> bool {
	return p.ranked.valid && p.ranked.text == text && p.pending == 0 && p.shown != nil
}

// The usage memory of the file at `path` (its state folder's palette_choices.txt; "": in memory only), read on the
// chores. One memory per file for the process (choice_memory_acquire): the palettes of a program's windows that give
// the same path share it, and its file holds every window's choices. The palette notes each choice of a source with
// `remember`; palette_destroy lets go of it (the last one writes it, the disk waited for). Once, before the first open.
palette_memory_open :: proc(p: ^Command_Palette, s: ^State, path: string, o := Choice_Memory_Options{}) {
	if p.memory != nil { choice_memory_release(p.memory) }
	p.memory = choice_memory_acquire(s, path, o)
}

// The palette's memory; one in memory only when the program gave no file.
@(private = "file")
palette_memory :: proc(p: ^Command_Palette) -> ^Choice_Memory {
	if p.memory == nil { p.memory = choice_memory_acquire(nil, "") }
	return p.memory
}

palette_destroy :: proc(p: ^Command_Palette) {
	line_edit_destroy(&p.field)
	palette_shown_free(p)
	for &st in p.states { palette_state_free(&st) }
	delete(p.states)
	delete(p.sources)
	// (no value put back: the program may have let go of its registry first)
	if p.run.level != .Closed && p.run.runner.close != nil { p.run.runner.close(p, &p.run) }
	palette_run_strings_free(&p.run)
	font_families_destroy(&p.families)
	palette_commands_free(&p.commands)
	keymap_recorder_free(&p.recorder)
	delete(p.go.id)
	delete(p.go.act)
	palette_arguments_free(&p.chosen)
	views_commands_destroy(&p.moves.vc)
	choice_memory_release(p.memory)
	palette_unlink(p)
	delete(p.text)
	delete(p.ranked.text)
	delete(p.sel_id)
	delete(p.chosen.id)
	delete(p.chosen.query)
	p^ = {}
}

// The view of each palette: its id, and the instance that is this palette.
PALETTE_VIEW :: "palette"

@(private)
palette_instance :: proc(p: ^Command_Palette) -> string { return fmt.tprintf("%x", uintptr(p)) }

////////////////////////////////
// Sources, questions, snapshots

@(private)
palette_source_index :: proc(p: ^Command_Palette, src: ^Palette_Source) -> int {
	for s, i in p.sources { if s == src { return i } }
	return -1
}

// (made in a build of the window the palette is over: its thread and its Task_Box are the link's for good)
@(private = "file")
palette_link_of :: proc(p: ^Command_Palette) -> ^Palette_Link {
	if p.link == nil {
		box := task_box_of(p.owner != nil ? p.owner : gs())
		sync.atomic_add(&box.refs, 1)
		p.link = new(Palette_Link, runtime.heap_allocator())
		p.link^ = {p = p, refs = 1, thread = sync.current_thread_id(), box = box}
	}
	return p.link
}

// The palette lets go of its link: the questions and rankings that hold it find no palette and drop their answers. The
// next question makes a link of the window the palette is over.
@(private = "file")
palette_unlink :: proc(p: ^Command_Palette) {
	if p.link == nil { return }
	p.link.p = nil
	sync.atomic_store(&p.link.latest, 0)
	palette_link_release(p.link)
	p.link = nil
}

@(private = "file")
palette_link_release :: proc(l: ^Palette_Link) {
	if sync.atomic_sub(&l.refs, 1) != 1 { return }
	if l.box != nil { task_box_release(l.box) }
	free(l, runtime.heap_allocator())
}

// Whether the question can be ended here: on the palette's interface thread (or it has no palette to end it on).
@(private = "file")
palette_question_here :: proc(q: Palette_Question) -> bool {
	return q.link == nil || q.link.thread == sync.current_thread_id()
}

// An end of a question made on another thread, on its way to the interface's.
@(private = "file")
Palette_End_Kind :: enum u8 { Answer, Error, Drop }

@(private = "file")
Palette_End :: struct {
	q:       Palette_Question,
	kind:    Palette_End_Kind,
	answer:  Palette_Answer,
	message: string,   // (heap)
}

// Posts the end to the link's window. A window gone (its box shut, its queue closed) refuses it: the handle is let go
// of and the answer freed here, so nothing is left behind at a program's end.
@(private = "file")
palette_end_post :: proc(q: Palette_Question, kind: Palette_End_Kind, a: ^Palette_Answer, message: string) {
	heap := runtime.heap_allocator()
	e := new(Palette_End, heap)
	e^ = {q = q, kind = kind, message = strings.clone(message, heap)}
	e.q.query = ""   // (the palette's string: it can be gone by then)
	if a != nil {
		e.answer = a^
		a^ = {}
	}
	b := q.link.box
	posted := false
	sync.lock(&b.lock)
	if b.s != nil { posted = post_state(b.s, palette_end_run, e) }
	sync.unlock(&b.lock)
	if !posted {
		palette_link_release(q.link)
		palette_end_free(e)
	}
}

// (on the interface's thread, at a build)
@(private = "file")
palette_end_run :: proc(d: rawptr, _: u64) {
	e := (^Palette_End)(d)
	switch e.kind {
	case .Answer: _ = palette_answer(e.q, &e.answer)
	case .Error:  _ = palette_answer_error(e.q, e.message)
	case .Drop:   palette_question_drop(e.q)
	}
	palette_end_free(e)
}

@(private = "file")
palette_end_free :: proc(e: ^Palette_End) {
	heap := runtime.heap_allocator()
	palette_answer_free(&e.answer)
	delete(e.message, heap)
	free(e, heap)
}

// Lets go of a question's handle; the palette and the source's state when it is the source's question in flight. On the
// interface's thread.
@(private = "file")
palette_question_end :: proc(q: Palette_Question) -> (p: ^Command_Palette, state: int, ok: bool) {
	if q.link == nil { return nil, -1, false }
	p = q.link.p
	palette_link_release(q.link)
	if p == nil { return nil, -1, false }
	state = palette_source_index(p, q.source)
	if state < 0 || q.serial == 0 || p.states[state].asked != q.serial {
		p.dropped += 1
		return nil, -1, false
	}
	return p, state, true
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

// Whether a source is asked and ranked for this prefix: its own. With none: the plain ones, and the ones without a prefix
// (the plain search is their only place: a chooser's); never a Secrets source.
@(private)
palette_in_scope :: proc(prefix, of: Palette_Prefix, plain: bool) -> bool {
	if prefix != .None { return of == prefix }
	return (plain || of == .None) && of != .Secrets
}

// The ranking in flight is not waited for any more: its answer will be dropped, and its chore stops at its next look.
@(private = "file")
palette_rank_drop :: proc(p: ^Command_Palette) {
	p.pending = 0
	if p.link != nil { sync.atomic_store(&p.link.latest, 0) }
	p.enter_wait, p.enter_ready, p.enter_moved = nil, false, false
}

// The questions still open go stale (an open, a close): their answers will be dropped.
@(private = "file")
palette_forget :: proc(p: ^Command_Palette) {
	p.serial += 1
	for &st in p.states { st.asked, st.reading, st.failed = 0, false, false }
	palette_rank_drop(p)
}

// A close that the palette did not make (Escape, a click outside, its window gone): its questions go stale.
@(private = "file")
palette_follow_close :: proc(p: ^Command_Palette) {
	if !p.was_open || build_of == nil { return }
	if !view_is_open(views(), PALETTE_VIEW, palette_instance(p)) {
		p.was_open = false
		palette_forget(p)
		palette_run_close(p, true)
	}
}

// Asks each source in the scope of the query whose answer is not for its version, the language or (a searching source)
// the query, and that is not asked that already.
@(private = "file")
palette_ask :: proc(p: ^Command_Palette) {
	language := i18n.version()
	link := palette_link_of(p)
	for src, i in p.sources {
		if !palette_in_scope(p.prefix, src.prefix, src.plain) || src.read == nil { continue }
		st := &p.states[i]
		// (a searching source answers for the query and the place it is typed in: its own prefix or the plain search)
		query := src.searches ? p.query : ""
		place := src.searches ? p.prefix : .None
		if s := st.snap; s != nil && s.version == src.version && s.language == language && s.query == query && s.place == place { continue }
		if (st.asked != 0 || st.failed) && st.version == src.version && st.language == language && st.query == query && st.place == place { continue }
		p.serial += 1
		st.asked, st.reading, st.failed, st.version, st.language, st.place = p.serial, true, false, src.version, language, place
		delete(st.query, runtime.heap_allocator())
		st.query = strings.clone(query, runtime.heap_allocator())
		p.asks += 1
		sync.atomic_add(&link.refs, 1)   // (the question's handle)
		src.read(p, src, {link = link, source = src, serial = st.asked, prefix = p.prefix, query = st.query})
	}
}

// An answer taken as a snapshot: its arena and items moved in, the source's flags copied beside them (a few strings).
@(private = "file")
palette_snapshot_take :: proc(src: ^Palette_Source, a: ^Palette_Answer, version: u64, language: u32, query: string, place: Palette_Prefix) -> ^Palette_Snapshot {
	snap := new(Palette_Snapshot, runtime.heap_allocator())
	snap.arena, snap.items = a.arena, a.items
	a^ = {}
	al := virtual.arena_allocator(&snap.arena)
	snap.refs, snap.source = 1, src
	snap.name, snap.title = strings.clone(src.name, al), strings.clone(src.title, al)
	snap.prefix, snap.plain, snap.listed, snap.searches, snap.toolkit = src.prefix, src.plain, src.listed, src.searches, src.toolkit
	snap.remember = src.remember && src.prefix != .Secrets
	if src.prefix == .Secrets { snap.plain = false }
	snap.version, snap.language, snap.query, snap.place = version, language, strings.clone(query, al), place
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
	delete(st.error, runtime.heap_allocator())
	delete(st.query, runtime.heap_allocator())
	st^ = {}
}

////////////////////////////////
// The ranking, on a chore

// Starts a ranking when the query, a snapshot, a source or the usage memory changed since the last one (a quiet build
// starts none). The list shown stays until its answer comes; the ranking it replaces stops at its next look.
@(private = "file")
palette_rank_start :: proc(p: ^Command_Palette) {
	memory := palette_memory(p)
	if p.ranked.valid && p.ranked.text == p.text && p.ranked.generation == p.generation && p.ranked.memory_version == memory.version { return }
	delete(p.ranked.text)
	p.ranked = {valid = true, text = strings.clone(p.text), generation = p.generation, memory_version = memory.version}
	link := palette_link_of(p)
	j := new(Palette_Job, runtime.heap_allocator())
	a := virtual.arena_allocator(&j.arena)
	p.serial += 1
	j.link, j.serial, j.prefix, j.query = link, p.serial, p.prefix, strings.clone(p.query, a)
	sync.atomic_add(&link.refs, 1)
	j.chooser = len(p.sources) == 1 && p.sources[0].prefix == .None
	snaps := make([dynamic]^Palette_Snapshot, a)
	j.first = {-1, -1}
	for src, i in p.sources {
		snap := p.states[i].snap
		if snap == nil || !palette_in_scope(p.prefix, src.prefix, src.plain) { continue }
		if src == &p.commands.source {
			// (an alias typed whole: its command first. Not a disabled one: it would be the row Enter cannot choose; the
			// item's id is compared, the snapshot can be older than the table)
			if f, id := palette_alias_first(p); f >= 0 && f < len(snap.items) && !snap.items[f].disabled && snap.items[f].id == id {
				j.first = {i32(len(snaps)), i32(f)}
			}
		}
		sync.atomic_add(&snap.refs, 1)
		append(&snaps, snap)
	}
	j.snaps = snaps[:]
	// (the memory's entries copied: at most CHOICE_MOST of them)
	j.memory.options = memory.options
	j.memory.entries = make(map[string]Choice, len(memory.entries), a)
	for k, e in memory.entries { j.memory.entries[strings.clone(k, a)] = e }
	j.now_ms = choice_now()
	j.sel_source, j.sel_id, j.sel_recent, j.sel_gen = p.sel_source, strings.clone(p.sel_id, a), p.sel_recent, p.sel_gen
	p.pending = j.serial
	sync.atomic_store(&link.latest, j.serial)
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

// (on the interface's thread, at a build) A ranking of another serial is dropped. The selection stays on its item;
// else it is the first row that acts.
@(private = "file")
palette_rank_done :: proc(d: rawptr, _: u64) {
	j := (^Palette_Job)(d)
	p := j.link.p
	if p == nil || j.stale || j.serial != p.pending {
		if p != nil { p.dropped += 1 }
		palette_job_free(j)
		return
	}
	palette_shown_free(p)
	p.shown, p.pending = j, 0
	sync.atomic_store(&j.link.latest, 0)
	n := len(j.rows)
	switch {
	case !p.sel_moved:           p.sel = -1
	case j.sel_gen == p.sel_gen: p.sel = j.sel_row
	case:                        p.sel = palette_row_of(p, p.sel_source, p.sel_id, p.sel_recent)   // (moved while it ranked)
	}
	if p.sel < 0 { p.sel, p.sel_moved = max(j.first_acting, 0), false }
	p.sel = clamp(p.sel, 0, max(n - 1, 0))
	if !p.sel_moved { palette_sel_note(p) }
	p.reveal = true
	if _, waits := p.enter_wait.?; waits { p.enter_ready = true }
}

// The row of an item in the list shown, a row of Recent or not as the selection was (-1: none). (After a move of the
// selection while a ranking was in flight only: else the chore found it.)
@(private = "file")
palette_row_of :: proc(p: ^Command_Palette, src: ^Palette_Source, id: string, recent: bool) -> int {
	if p.shown == nil || src == nil { return -1 }
	for r, i in p.shown.rows {
		snap := p.shown.snaps[r.snap]
		if r.recent == recent && snap.source == src && snap.items[r.item].id == id { return i }
	}
	return -1
}

// Whether a newer ranking replaced this one (a chore's look between two chunks).
@(private = "file")
palette_job_stale :: proc(j: ^Palette_Job) -> bool {
	if sync.atomic_load(&j.link.latest) == j.serial { return false }
	j.stale = true
	return true
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
	if j.stale { return }
	j.rows, j.ranges = rows[:], ranges[:]
	j.sel_row, j.first_acting = -1, -1
	for r, i in j.rows {
		snap := j.snaps[r.snap]
		it := &snap.items[r.item]
		if it.icon != "" { j.icons = true }
		if j.first_acting < 0 && !it.disabled { j.first_acting = i }
		if j.sel_row < 0 && r.recent == j.sel_recent && snap.source == j.sel_source && it.id == j.sel_id { j.sel_row = i }
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
		if palette_job_stale(j) { return }
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
// `first` before all. A source is read by chunks: between two, a ranking that a newer one replaced stops.
@(private = "file")
palette_list_ranked :: proc(j: ^Palette_Job, rows: ^[dynamic]Palette_Row, ranges: ^[dynamic]Fuzzy_Range) {
	Hit :: struct { at: [2]i32, score: f64, ranges: []Fuzzy_Range, disabled: bool }
	hits := make([dynamic]Hit, context.temp_allocator)
	first_ranges: []Fuzzy_Range
	for snap, si in j.snaps {
		b := Palette_Bonus{memory = &j.memory, name = snap.name, query = j.query, now_ms = j.now_ms}
		bonus: proc(it: ^Palette_Item, user: rawptr) -> f64
		if snap.remember { bonus = palette_item_bonus }
		// (the answer of a searching source to this very query: what it found stays; an older answer, shown until the
		// next one comes, keeps only what the matcher finds)
		matched: []bool
		if snap.searches && snap.query == j.query && snap.place == j.prefix { matched = make([]bool, len(snap.items), context.temp_allocator) }
		for lo := 0; lo < len(snap.items); lo += PALETTE_RANK_CHUNK {
			if palette_job_stale(j) { return }
			hi := min(lo + PALETTE_RANK_CHUNK, len(snap.items))
			for h in rank(j.query, snap.items[lo:hi], palette_item_entry, &b, bonus = bonus) {
				index := lo + h.index
				at := [2]i32{i32(si), i32(index)}
				if matched != nil { matched[index] = true }
				if at == j.first { first_ranges = h.ranges; continue }
				score := h.score
				if j.prefix == .None && !snap.toolkit { score -= PALETTE_OWN_PENALTY }
				append(&hits, Hit{at, score, h.ranges, snap.items[index].disabled})
			}
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
	recent := p.shown.rows[p.sel].recent
	if src == p.sel_source && id == p.sel_id && recent == p.sel_recent { return }
	delete(p.sel_id)
	p.sel_source, p.sel_id, p.sel_recent = src, strings.clone(id), recent
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
	// (Shift+Enter: go to, when its place can be shown; else it is Enter)
	mods := mods
	if mods == {.Shift} {
		if palette_reachable(p, src, it) {
			delete(p.go.id); delete(p.go.act)
			p.go = {source = src, id = strings.clone(it.id), act = strings.clone(it.act), due = true}
			view_end(v, 0)
			palette_forget(p)
			p.was_open = false
			return
		}
		mods = {}
	}
	// (Enter on an item that runs: its control or its form unfolds under it; the palette stays)
	opens := mods == {} && it.runs && src.runner != nil
	if snap.remember {
		memory := palette_memory(p)
		current := p.ranked.memory_version == memory.version
		choice_note(memory, strings.concatenate({snap.name, ":", it.id}, context.temp_allocator))
		// (a switch flipped or a control unfolded, the palette open: the list is not ranked again for the choice)
		if (it.stays || opens) && current { p.ranked.memory_version = memory.version }
	}
	if opens && palette_run_open(p, src, it) { return }
	delete(p.chosen.id)
	delete(p.chosen.query)
	palette_arguments_free(&p.chosen)
	index := int(r.item)
	// (a command's index in the table, by its id: the answer leaves the hidden commands out, so its rows are not the
	// table's. A command without an id, only in a table that fails command_ids_check: its row)
	if src == &p.commands.source && it.id != "" { index = p.commands.index[it.id] or_else -1 }
	p.chosen = {source = src, id = strings.clone(it.id), index = index, mods = mods, query = strings.clone(p.query)}
	if src.act != nil { p.act_due = true } else { p.has_choice = true }
	// (palette_chosen runs in the program's window's build: a choice made in a view's window wakes it)
	if root := style_root(gs()); root != gs() { root.anim_busy = true }
	if !it.stays {
		view_end(v, 0)
		palette_forget(p)
		p.was_open = false
	}
}

// Whether Shift+Enter goes to an item: it has an act name, and a frame of the program shows it or its source reaches it.
@(private = "file")
palette_reachable :: proc(p: ^Command_Palette, src: ^Palette_Source, it: Palette_Item) -> bool {
	if it.act == "" || it.disabled { return false }
	return act_shown(it.act) || (src.reach != nil && src.reach(p, src, it.id, false))
}

@(private = "file")
palette_arguments_free :: proc(c: ^Palette_Choice) {
	for a in c.arguments { delete(a) }
	delete(c.arguments)
	c.arguments = nil
}

// (palette_run_due) A form's last argument kept: its command chosen with the values (owned: the choice's now), the
// palette closed.
@(private)
palette_form_chosen :: proc(p: ^Command_Palette, src: ^Palette_Source, id: string, values: []string) {
	index := -1
	if src == &p.commands.source { index = p.commands.index[id] or_else -1 }
	delete(p.chosen.id)
	delete(p.chosen.query)
	palette_arguments_free(&p.chosen)
	p.chosen = {source = src, id = strings.clone(id), index = index, query = strings.clone(p.query), arguments = values}
	if src.act != nil { p.act_due = true } else { p.has_choice = true }
	view_close(views(), PALETTE_VIEW, palette_instance(p))
	palette_forget(p)
	p.was_open = false
}

// The palette's view: the search band, the list, the hint row. The keys are read before the field; the query is read
// after it, so that what a frame typed is the query its Enter chooses from.
@(private = "file")
palette_view :: proc(v: ^View, p: ^Command_Palette) {
	p.was_open = true
	em := font_size()
	if language := i18n.version(); language != p.language { p.language = language; p.generation += 1 }
	for src in p.sources { if src.poll != nil { src.poll(p, src) } }
	// (Enter waited for a ranking: it came. The row the person had moved to, kept on its item; else the first that acts)
	if p.enter_ready {
		mods := p.enter_wait.? or_else platform.Modifiers{}
		moved := p.enter_moved && p.sel_moved
		p.enter_wait, p.enter_ready, p.enter_moved = nil, false, false
		at := moved ? p.sel : (p.shown != nil ? p.shown.first_acting : -1)
		if at >= 0 { palette_choose(p, v, at, mods) }
		if !p.was_open { return }
	}
	n := palette_row_count(p)
	row_h := math.round(dense(em * PALETTE_ROW_EM))
	heading_h := em * PALETTE_HEADING_EM
	palette_run_follow(p)
	run := p.run.level != .Closed
	run_keys: Palette_Run_Keys
	if run {
		// (the run mode's keys, before the field: Enter and Escape are the palette's, the moves the control's)
		// (a page of the control: the palette's height less its field, its run row and its foot)
		run_keys = palette_run_keys(p, max(int(gs().modal_stack[len(gs().modal_stack) - 1].wh.y / row_h) - 5, 1))
	} else if n > 0 {
		page := max(int(palette_list_h(p) / row_h), 1)
		// (the palette's own keys, read before its field is built)
		if key_press_any(.Down) { palette_sel_move(p, 1, true) }
		if key_press_any(.Up) { palette_sel_move(p, -1, true) }
		if key_press_any(.Page_Down) { palette_sel_move(p, page, false) }
		if key_press_any(.Page_Up) { palette_sel_move(p, -page, false) }
	}
	if !run && key_press_any(.Tab) {
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
	band := Search_Band_Options{count = n, busy = reading}
	if run { band = {} }   // (the field is the control's: its filter or the value's text)
	res := search_band("palette_top", &p.field, band)
	// (in the run mode the field keeps the keyboard: a click on the control does not take Enter and Escape from it)
	if p.fresh || (run && focus_key() != res.box.key && !hotkey_recording() && gs().active_key[.Left] == 0) {
		set_focus(res.box.key)
		p.fresh = false
	}
	if res.cancelled && !run {   // (Escape in the field: the field takes it before the dialog)
		view_end(v, VIEW_CANCELLED)
		palette_forget(p)
		p.was_open = false
		return
	}
	enter: Maybe(platform.Modifiers)
	if res.committed && !run { enter = platform.Modifiers{} }
	// (Enter with a modifier: the source's alternate, or go to)
	if !run { for m in ([]platform.Modifiers{{.Ctrl}, {.Alt}, {.Shift}}) { if key_press_any(.Return, m) { enter = m } } }
	// The query after the field: the questions and the ranking it needs (in the run mode the field is not the query).
	if text := line_edit_string(&p.field); !run && (text != p.text || !p.ranked.valid) {
		delete(p.text)
		p.text = strings.clone(text)
		p.prefix, p.query = palette_parse(p, p.text)
		p.sel_moved = false
		p.serial += 1
	}
	palette_ask(p)
	palette_rank_start(p)
	// (its dialog shows with its rows: not before the first ranking of this question that saw every source's answer)
	if !palette_answered(p) { view_not_ready(v) }
	if mods, ok := enter.?; ok {
		// (a ranking in flight, for a new query, a late answer, a change of the memory: Enter chooses from it)
		if p.pending != 0 { p.enter_wait, p.enter_moved = mods, p.sel_moved } else { palette_choose(p, v, p.sel, mods) }
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
	if run {
		// (its row, then its control in the list's room: the palette keeps its height)
		next({width = fill(), height = px(avail), axis = .Y})
		if column(id = "###palette_run") { palette_run_build(p, run_keys, row_h, avail) }
		rest = 0
	} else {
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
			// (the first click of a double one acted: a row run, a run mode opened under the pointer)
			if sig.clicked && !sig.second_click { clicked = k }
		}
		if below > 0 { spacer(px(below)) }
		if n > 0 { palette_quiet_rows(p, row_h) }
	}
	}
	spacer(px(rest))
	if !chooser { palette_hint_row(p, foot_h) } else { spacer(px(foot_h)) }
	if hovered >= 0 && hovered != p.sel && !palette_row_disabled(p, hovered) {
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
	push_tags("menu_item", "nav")
	defer pop_tags()
	if sel { push_tags("selected") }
	defer if sel { pop_tags() }
	next({width = fill(), height = px(row_h), axis = .X, cross = .Center, radius = em * shape_of(.Row)})
	flags := Box_Flags{.Clickable, .Draw_Hot_Effects, .Row}
	if sel { flags += {.Draw_Background, .Chosen} }
	if it.disabled { flags += {.Disabled} }
	rb := build_box(flags, fmt.tprintf("###palette_%d_%d_%d", r.snap, r.item, k))
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
		// (the value in use, read for the rows built only, as the mark)
		if src := snap.source; src.value != nil {
			if value := src.value(src, it.id); value != "" {
				if tags("weak") {
					next({width = text_size(), height = pct(1), text_pad = 0})
					label(fmt.tprintf("%s###v", value))
					spacer(px(em * 0.6))
				}
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
// keys of the selected row. In a narrow palette the keys give their room first, cut with an ellipsis (strictness 0);
// the prefixes stay whole, and the foot clips what still does not fit.
@(private = "file")
palette_hint_row :: proc(p: ^Command_Palette, foot_h: f32) {
	em := font_size()
	next({width = fill(), height = px(foot_h), axis = .X, cross = .Center})
	if row(.Center, {.Draw_Side_Top, .Clip}, "###palette_foot") {
		spacer(px(em * 0.7))
		for x in Palette_Prefix {
			// (none in the run mode: the field is the control's, a prefix typed there means nothing)
			if x == .None || p.run.level != .Closed || (p.prefix != .None && x != p.prefix) { continue }
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
		if p.run.level != .Closed {
			if tags("weak") {
				next({width = text_size(0, 0), height = pct(1), font_size = em * 0.85})
				label(fmt.tprintf("%s###palette_keys", palette_run_hints(p)))
			}
		} else if src, _, ok := palette_selected(p); ok && src != nil {
			r := p.shown.rows[p.sel]
			it := p.shown.snaps[r.snap].items[r.item]
			enter := src.enter != "" ? src.enter : i18n.later("Choose")
			parts := make([dynamic]string, context.temp_allocator)
			append(&parts, fmt.tprintf("%s %s", chord_text({.Return, {}}), i18n.tr(enter)))
			alts := [2]string{src.alternates.ctrl, src.alternates.alt}
			mods := [2]platform.Modifiers{{.Ctrl}, {.Alt}}
			for a, i in alts { if a != "" { append(&parts, fmt.tprintf("%s %s", chord_text({.Return, mods[i]}), i18n.tr(a))) } }
			// (go to, only for an item whose place can be shown)
			if palette_reachable(p, src, it) { append(&parts, fmt.tprintf("%s %s", chord_text({.Return, {.Shift}}), i18n.tr("Go to"))) }
			if tags("weak") {
				next({width = text_size(0, 0), height = pct(1), font_size = em * 0.85})
				label(fmt.tprintf("%s###palette_keys", strings.join(parts[:], "   ", context.temp_allocator)))
			}
		}
		spacer(px(em * 1.4))   // (the corner's grip)
	}
}
