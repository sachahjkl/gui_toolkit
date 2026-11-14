// The command palette (ui/palette.odin, src/md/features/palette.md): the tests that break its design on day one, and each
// kind of source (the commands, a program's own at once or later, one that searches, the views' moves). Synthetic input
// events and builds, without a window; the palette ranks on the chores, so a test builds frames until its ranking came,
// within SETTLE_BOUND.
package commands_test

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "../../src/font"
import i18n "../../src/i18n"
import "../../src/platform"
import "../../src/ui"

@(private = "file")
open :: proc(f: ^Fx) -> bool {
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { return false }
	ui.apply_palette(&f.theme, ui.palette_of("Midnight"))
	ui.init(&f.s, &f.fonts, &f.theme)
	f.base_font = id
	return true
}

@(private = "file")
close :: proc(f: ^Fx) {
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	font.destroy(&f.fonts)
}

@(private = "file")
frame :: proc(f: ^Fx, events: []platform.Event, r: ^Run) {
	ui.begin_build(&f.s, {
		window_size = WINDOW, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
	})
	run_build(r)
	ui.end_build()
	free_all(context.temp_allocator)
}

@(private = "file")
key :: proc(k: platform.Key, mods: platform.Modifiers = {}) -> platform.Event { return {kind = .Key_Press, key = k, mods = mods} }

@(private = "file")
typed :: proc(r: rune) -> platform.Event { return {kind = .Text, text = r} }

@(private = "file")
type_text :: proc(f: ^Fx, r: ^Run, text: string) {
	for c in text { frame(f, {typed(c)}, r) }
}

// Frames until no ranking is in flight (a source may still read), then one more: the view shows the list.
@(private = "file")
settle :: proc(t: ^testing.T, f: ^Fx, r: ^Run, loc := #caller_location) {
	start := time.tick_now()
	for {
		frame(f, nil, r)
		if r.pal.pending == 0 { break }
		if time.tick_since(start) > SETTLE_BOUND {
			testing.fail_now(t, "the palette's ranking did not come", loc)
		}
	}
	frame(f, nil, r)
}

// Frames until the palette is closed (Escape and a choice close it in the build after them).
@(private = "file")
settle_closed :: proc(t: ^testing.T, f: ^Fx, r: ^Run, loc := #caller_location) {
	start := time.tick_now()
	for r.pal.was_open || palette_open_now(f, r) {
		frame(f, nil, r)
		if time.tick_since(start) > SETTLE_BOUND { testing.fail_now(t, "the palette did not close", loc) }
	}
}

@(private = "file")
palette_open_now :: proc(f: ^Fx, r: ^Run) -> bool {
	ui.use(&f.s)
	return ui.palette_is_open(&r.pal)
}

// A box of the last build that shows `text` (nil: none).
@(private = "file")
find_text :: proc(f: ^Fx, text: string) -> ^ui.Box {
	walk :: proc(b: ^ui.Box, text: string) -> ^ui.Box {
		if b == nil { return nil }
		if b.text == text { return b }
		for c := b.first; c != nil; c = c.next { if r := walk(c, text); r != nil { return r } }
		return nil
	}
	return walk(f.s.root, text)
}

// The id of row `i` ("": none).
@(private = "file")
row_id :: proc(r: ^Run, i: int) -> string {
	_, id, _ := ui.palette_row(&r.pal, i)
	return id
}

// A source of the test's: its items given at once, or its questions kept for the test to answer.
@(private = "file")
Test_Source :: struct {
	src:       ui.Palette_Source,
	items:     []ui.Palette_Item,
	later:     bool,
	questions: [dynamic]Question,
	on:        bool,   // the switch of its items that stay
	acts:      int,
}

@(private = "file")
Question :: struct { serial: u64, query: string }

@(private = "file")
source_make :: proc(ts: ^Test_Source, name, title: string, prefix: ui.Palette_Prefix, items: []ui.Palette_Item, plain := false, later := false, searches := false) {
	ts.src = {name = name, title = title, prefix = prefix, plain = plain, remember = true, searches = searches, read = source_read, user = ts}
	ts.items, ts.later = items, later
}

@(private = "file")
source_free :: proc(ts: ^Test_Source) {
	for q in ts.questions { delete(q.query) }
	delete(ts.questions)
}

@(private = "file")
source_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	ts := (^Test_Source)(src.user)
	append(&ts.questions, Question{q.serial, strings.clone(q.query)})
	if !ts.later { ui.palette_answer(p, src, q.serial, ts.items) }
}

@(private = "file")
last_question :: proc(ts: ^Test_Source) -> Question {
	if len(ts.questions) == 0 { return {} }
	return ts.questions[len(ts.questions) - 1]
}

// What a test's build gives the palette, and what it chose.
@(private = "file")
Run :: struct {
	pal:      ui.Command_Palette,
	table:    []ui.Command,   // nil: no commands source
	disabled: []bool,
	opts:     ui.Palette_Commands_Options,
	sources:  [dynamic]^Test_Source,
	open_now: bool,
	typed:    string,
	chosen:   ui.Palette_Choice,
	choices:  int,
	extra:    proc(r: ^Run),   // the test's own part of the build (a view)
	user:     rawptr,
}

@(private = "file")
run_build :: proc(r: ^Run) {
	if r.table != nil { ui.palette_commands(&r.pal, r.table, r.disabled, r.opts) }
	for ts in r.sources { ui.palette_add(&r.pal, &ts.src) }
	if r.extra != nil { r.extra(r) }
	if r.open_now { r.open_now = false; ui.palette_open(&r.pal, r.typed) }
	if c, ok := ui.palette_chosen(&r.pal); ok { r.chosen, r.choices = c, r.choices + 1 }
}

@(private = "file")
run_free :: proc(r: ^Run) {
	ui.palette_destroy(&r.pal)
	delete(r.sources)
}

@(private = "file")
open_palette :: proc(t: ^testing.T, f: ^Fx, r: ^Run, typed := "", loc := #caller_location) {
	r.open_now, r.typed = true, typed
	settle(t, f, r, loc)
}

@(private = "file")
NEW_COMMANDS := [?]ui.Command{
	{label = "Notes", group = "File"},
	{label = "New folder", group = "File"},
	{label = "Open", group = "File"},
}

// 1. Type and Enter in one frame: the choice is the first item of the full query's ranking ("nf": New folder), not of
// the query the list on the screen was ranked for ("n": Notes).
@(test)
type_and_enter_in_one_frame :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Run{table = NEW_COMMANDS[:]}
	defer run_free(&r)
	open_palette(t, &f, &r)
	type_text(&f, &r, "n")
	settle(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "Notes")
	frame(&f, {typed('f'), key(.Return)}, &r)
	settle_closed(t, &f, &r)
	frame(&f, nil, &r)
	testing.expect_value(t, r.choices, 1)
	testing.expect_value(t, r.chosen.command, 1)
	testing.expect_value(t, r.chosen.id, "New folder")
}

// 2. A stale answer: an answer for "ab" once the query is "abc", or for a former opening, is dropped.
@(test)
a_stale_answer_is_dropped :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	items := []ui.Palette_Item{{id = "abc", title = "abc"}}
	paths: Test_Source
	source_make(&paths, "path", "Paths", .Paths, items, later = true, searches = true)
	defer source_free(&paths)
	r: Run
	append(&r.sources, &paths)
	defer run_free(&r)
	open_palette(t, &f, &r, "/")
	type_text(&f, &r, "ab")
	ab := last_question(&paths)
	testing.expect_value(t, ab.query, "ab")
	type_text(&f, &r, "c")
	abc := last_question(&paths)
	testing.expect_value(t, abc.query, "abc")
	dropped := r.pal.dropped
	testing.expect(t, !ui.palette_answer(&r.pal, &paths.src, ab.serial, items), "the answer for \"ab\" is dropped")
	testing.expect_value(t, r.pal.dropped, dropped + 1)
	testing.expect(t, ui.palette_answer(&r.pal, &paths.src, abc.serial, items), "the answer for \"abc\" is kept")
	settle(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "abc")
	// (closed and opened: the question of the former opening is stale)
	frame(&f, {key(.Escape)}, &r)
	settle_closed(t, &f, &r)
	open_palette(t, &f, &r, "/abd")
	testing.expect(t, !ui.palette_answer(&r.pal, &paths.src, abc.serial, items), "an answer of the former opening is dropped")
	testing.expect(t, ui.palette_answer(&r.pal, &paths.src, last_question(&paths).serial, items), "this opening's is kept")
}

// 3. A source that never answers: the palette says it reads, Up, Down and Escape work, and a later answer is dropped.
@(test)
a_source_that_never_answers :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	paths: Test_Source
	source_make(&paths, "path", "Paths", .Paths, nil, later = true, searches = true)
	defer source_free(&paths)
	r := Run{table = NEW_COMMANDS[:]}
	append(&r.sources, &paths)
	defer run_free(&r)
	open_palette(t, &f, &r, "/x")
	testing.expect(t, find_text(&f, "Paths: reading…") != nil, "it says the source reads")
	testing.expect(t, ui.palette_busy(&r.pal), "busy while it reads")
	frame(&f, {key(.Down)}, &r)
	frame(&f, {key(.Up)}, &r)
	frame(&f, {key(.Escape)}, &r)
	settle_closed(t, &f, &r)
	testing.expect(t, !ui.palette_answer(&r.pal, &paths.src, last_question(&paths).serial, {{id = "x", title = "x"}}), "a later answer is dropped")
}

// 4. A late answer above the selection: the selected item stays the same item.
@(test)
a_late_answer_keeps_the_selected_item :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	late: Test_Source
	source_make(&late, "closed", "Closed tabs", .Go_To, []ui.Palette_Item{{id = "a0", title = "Alpha"}, {id = "a1", title = "Apple"}}, later = true)
	defer source_free(&late)
	tabs: Test_Source
	source_make(&tabs, "tab", "Tabs", .Go_To, []ui.Palette_Item{{id = "b0", title = "Beta"}, {id = "b1", title = "Bravo"}, {id = "b2", title = "Brick"}})
	defer source_free(&tabs)
	r: Run
	append(&r.sources, &late, &tabs)   // (the late source first: its rows come above)
	defer run_free(&r)
	open_palette(t, &f, &r, "@")
	testing.expect_value(t, row_id(&r, 0), "b0")
	frame(&f, {key(.Down)}, &r)
	_, id, _ := ui.palette_selected(&r.pal)
	testing.expect_value(t, id, "b1")
	testing.expect(t, ui.palette_answer(&r.pal, &late.src, last_question(&late).serial, late.items), "the late answer")
	settle(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "a0")
	_, id, _ = ui.palette_selected(&r.pal)
	testing.expect_value(t, id, "b1")
}

// 5. A quiet build: with nothing changed, no source is asked and nothing is ranked.
@(test)
a_quiet_build_asks_and_ranks_nothing :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	tabs: Test_Source
	source_make(&tabs, "tab", "Tabs", .Go_To, []ui.Palette_Item{{id = "b0", title = "Beta"}}, plain = true)
	defer source_free(&tabs)
	r := Run{table = NEW_COMMANDS[:]}
	append(&r.sources, &tabs)
	defer run_free(&r)
	open_palette(t, &f, &r)
	type_text(&f, &r, "be")
	settle(t, &f, &r)
	asks, rankings := r.pal.asks, r.pal.rankings
	for _ in 0 ..< 5 { frame(&f, nil, &r) }
	testing.expect_value(t, r.pal.asks, asks)
	testing.expect_value(t, r.pal.rankings, rankings)
	type_text(&f, &r, "t")
	testing.expect_value(t, r.pal.rankings, rankings + 1)   // (a letter: one ranking; a source that lists is not asked again)
	testing.expect_value(t, r.pal.asks, asks)
}

@(private = "file") MANY_ITEMS :: 100_000

// 6. No ranking on the interface's thread: a source of 100 000 items; this thread matches none of them.
@(test)
the_interfaces_thread_matches_nothing :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	items := make([]ui.Palette_Item, MANY_ITEMS)
	defer delete(items)
	for &it, i in items {
		it.id = fmt.aprintf("i%d", i)
		it.title = fmt.aprintf("Item %d", i)
	}
	defer for it in items { delete(it.id); delete(it.title) }
	many: Test_Source
	source_make(&many, "item", "Items", .Go_To, items, plain = true)
	defer source_free(&many)
	r: Run
	append(&r.sources, &many)
	defer run_free(&r)
	before := ui.rank_matched()
	open_palette(t, &f, &r, "@")
	type_text(&f, &r, "item 99999")
	settle(t, &f, &r)
	testing.expect_value(t, ui.rank_matched(), before)
	testing.expect_value(t, row_id(&r, 0), "i99999")
}

// 7. A prefix without a source: "/home/x" in a palette without a Paths source is a plain search.
@(test)
a_prefix_without_a_source_is_text :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	table := []ui.Command{{label = "Notes"}, {label = "/home/x notes"}}
	r := Run{table = table}
	defer run_free(&r)
	open_palette(t, &f, &r, "/home/x")
	testing.expect_value(t, row_id(&r, 0), "/home/x notes")
}

@(private = "file")
FRENCH :: `language fr

en Close
fr Fermer

en Open
fr Ouvrir
`

// 8. The usage memory across languages: a choice made in English is first under Recent in French (its key is an id).
@(test)
the_memory_holds_across_languages :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	table := []ui.Command{{label = "Open", group = "File"}, {label = "Close", group = "File"}}
	r := Run{table = table}
	defer run_free(&r)
	open_palette(t, &f, &r)
	type_text(&f, &r, "close")
	settle(t, &f, &r)
	frame(&f, {key(.Return)}, &r)
	settle_closed(t, &f, &r)
	frame(&f, nil, &r)
	testing.expect_value(t, r.chosen.id, "Close")
	l, bad := i18n.load("fr", {{"fr", FRENCH}})
	defer { i18n.use(nil); i18n.destroy(l) }
	testing.expect_value(t, len(bad), 0)
	i18n.use(l)
	open_palette(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "Close")
	testing.expect(t, find_text(&f, "Fermer") != nil, "shown in French")
	testing.expect(t, find_text(&f, "Récents") != nil, "under Recent, in the toolkit's French")
}

// 9. A switch: Enter flips it, the palette stays open, its mark changes, the list is not ranked again.
@(test)
a_switch_flips_and_the_palette_stays :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	choose: Test_Source
	source_make(&choose, "option", "Options", .Choose, []ui.Palette_Item{{id = "wrap", title = "Wrap lines", stays = true}})
	defer source_free(&choose)
	choose.src.mark = proc(src: ^ui.Palette_Source, id: string) -> bool { return (^Test_Source)(src.user).on }
	choose.src.act = proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, c: ui.Palette_Choice) {
		ts := (^Test_Source)(src.user)
		ts.on, ts.acts = !ts.on, ts.acts + 1
	}
	r: Run
	append(&r.sources, &choose)
	defer run_free(&r)
	open_palette(t, &f, &r, "#")
	testing.expect(t, find_text(&f, ui.ICON_CHECK) == nil, "off: no mark")
	rankings := r.pal.rankings
	frame(&f, {key(.Return)}, &r)
	frame(&f, nil, &r)   // (the source acts in palette_chosen, at the next build)
	frame(&f, nil, &r)
	testing.expect_value(t, choose.acts, 1)
	testing.expect(t, choose.on, "flipped")
	testing.expect(t, palette_open_now(&f, &r), "the palette stays open")
	testing.expect(t, find_text(&f, ui.ICON_CHECK) != nil, "on: its mark")
	testing.expect_value(t, r.pal.rankings, rankings)
	testing.expect_value(t, r.choices, 0)   // (a source that acts returns nothing to the program)
}

// 10. One table of prefixes: a program's test lists its sources and compares them with the list it means. A chooser (one
// source, no prefix) has none.
@(test)
one_table_of_prefixes :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	sessions, models: Test_Source
	source_make(&sessions, "session", "Sessions", .Go_To, nil)
	source_make(&models, "model", "Models", .Choose, nil)
	defer { source_free(&sessions); source_free(&models) }
	r := Run{table = NEW_COMMANDS[:]}
	append(&r.sources, &sessions, &models)
	defer run_free(&r)
	frame(&f, nil, &r)
	got := ui.palette_prefixes(&r.pal)
	testing.expectf(t, slice.equal(got, []string{"> Commands", "@ Sessions", "# Models"}), "the prefixes: %v", got)

	nodes: Test_Source
	source_make(&nodes, "node", "Nodes", .None, []ui.Palette_Item{{id = "add", title = "Add"}, {id = "mix", title = "Mix"}})
	defer source_free(&nodes)
	chooser: Run
	append(&chooser.sources, &nodes)
	defer run_free(&chooser)
	open_palette(t, &f, &chooser)
	frame(&f, {key(.Return)}, &chooser)
	settle_closed(t, &f, &chooser)
	frame(&f, nil, &chooser)
	testing.expect_value(t, len(ui.palette_prefixes(&chooser.pal)), 0)
	open_palette(t, &f, &chooser)
	testing.expect(t, find_text(&f, "Recent") == nil, "a chooser has no Recent")
	testing.expect_value(t, row_id(&chooser, 0), "add")
}

@(private = "file")
SERVICE_COMMANDS := [?]ui.Command{
	{label = "Start", group = "Services", keys = {{.S, {.Ctrl}}}},
	{label = "Stop", group = "Services", tags = {"halt"}},
	{label = "Kill…", group = "Processes", keys = {{.Delete, {.Shift}}}},
}

// The commands source: its keys' texts, its ids, a disabled command greyed and listed last and never chosen, Enter
// with a modifier, `first`, the views' moves beside it.
@(test)
the_commands_source :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	disabled := []bool{true, false, false}
	r := Run{table = SERVICE_COMMANDS[:], disabled = disabled, opts = {names = {"service.start", "service.stop", "process.kill"}, keys = {"", "", "Ctrl+M, K"}}}
	defer run_free(&r)
	open_palette(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "service.stop")    // (Start, disabled, after Stop in their group)
	testing.expect_value(t, row_id(&r, 1), "service.start")
	testing.expect(t, find_text(&f, "Ctrl+M, K") != nil, "the program's text of the keys")
	testing.expect(t, find_text(&f, "Shift+Delete") == nil, "instead of its chord")
	type_text(&f, &r, "st")
	settle(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "service.stop")
	frame(&f, {key(.Down)}, &r)   // (the disabled row is not selected: the selection wraps to the first)
	frame(&f, {key(.Return, {.Ctrl})}, &r)
	settle_closed(t, &f, &r)
	frame(&f, nil, &r)
	testing.expect_value(t, r.chosen.command, 1)
	testing.expect_value(t, r.chosen.mods, platform.Modifiers{.Ctrl})
	// a word the label does not say: its tags; `first` before the best match
	r.opts.first = 2
	open_palette(t, &f, &r, "halt")
	testing.expect_value(t, row_id(&r, 0), "process.kill")
	testing.expect_value(t, row_id(&r, 1), "service.stop")
}

// A program's own source in the plain search: merged with the commands in one ranking, a few points behind at an equal
// score; under its prefix, alone.
@(test)
a_program_source_in_the_plain_search :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	tabs: Test_Source
	source_make(&tabs, "tab", "Tabs", .Go_To, []ui.Palette_Item{{id = "t1", title = "Open", detail = "https://example.org"}}, plain = true)
	defer source_free(&tabs)
	r := Run{table = NEW_COMMANDS[:]}
	append(&r.sources, &tabs)
	defer run_free(&r)
	open_palette(t, &f, &r, "open")
	src, id, _ := ui.palette_row(&r.pal, 0)
	testing.expect(t, src == &r.pal.commands.source && id == "Open", "the command typed whole first")
	src, id, _ = ui.palette_row(&r.pal, 1)
	testing.expect(t, src == &tabs.src && id == "t1", "then the tab of the same title")
	frame(&f, {key(.Escape)}, &r)
	settle_closed(t, &f, &r)
	open_palette(t, &f, &r, "@")
	testing.expect_value(t, ui.palette_row_count(&r.pal), 1)
	testing.expect(t, find_text(&f, "https://example.org") != nil, "its detail")
}

// A searching source answers from a chore: its rows come in a later build, a later query asks it again.
@(test)
a_searching_source_answers_later :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	paths: Test_Source
	source_make(&paths, "path", "Paths", .Paths, nil, later = true, searches = true)
	defer source_free(&paths)
	r: Run
	append(&r.sources, &paths)
	defer run_free(&r)
	open_palette(t, &f, &r, "/do")
	testing.expect_value(t, last_question(&paths).query, "do")
	// (the source found a folder whose name the matcher does not find: it stays, after every match)
	found := []ui.Palette_Item{{id = "/home/docs", title = "docs"}, {id = "/srv/archive", title = "archive", completion = "/srv/archive/"}}
	testing.expect(t, ui.palette_answer(&r.pal, &paths.src, last_question(&paths).serial, found), "kept")
	settle(t, &f, &r)
	testing.expect_value(t, ui.palette_row_count(&r.pal), 2)
	testing.expect_value(t, row_id(&r, 0), "/home/docs")
	frame(&f, {key(.Down)}, &r)
	frame(&f, {key(.Tab)}, &r)   // (Tab completes: the folder's path in the field)
	frame(&f, nil, &r)
	testing.expect_value(t, ui.line_edit_string(&r.pal.field), "/srv/archive/")
	testing.expect_value(t, last_question(&paths).query, "srv/archive/")
	asked := len(paths.questions)
	testing.expect(t, ui.palette_answer_error(&r.pal, &paths.src, last_question(&paths).serial, "no such folder"), "an error")
	settle(t, &f, &r)
	testing.expect(t, find_text(&f, "Paths: could not read (no such folder)") != nil, "it says so")
	testing.expect_value(t, len(paths.questions), asked)
}

@(private = "file")
files_view :: proc(v: ^ui.View, r: ^Run) {}

// The views' moves: a move of each open view, but the palette's own; the toolkit runs the one chosen.
@(test)
the_views_moves_source :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Run{table = NEW_COMMANDS[:]}
	defer run_free(&r)
	r.extra = proc(r: ^Run) {
		vs := ui.views()
		if !ui.view_registered(vs, "files") {
			ui.view_register(vs, "files", files_view, ui.View_Options{title = "Files"})
			ui.view_open(vs, "files", r)
		}
	}
	frame(&f, nil, &r)
	open_palette(t, &f, &r, ">close files")
	src, id, _ := ui.palette_row(&r.pal, 0)
	testing.expect(t, src == &r.pal.moves.source && strings.has_prefix(id, "files|"), "the move of the view")
	for i in 0 ..< ui.palette_row_count(&r.pal) { testing.expect(t, !strings.has_prefix(row_id(&r, i), "palette|"), "not the palette's own") }
	frame(&f, {key(.Return)}, &r)
	settle_closed(t, &f, &r)
	frame(&f, nil, &r)
	frame(&f, nil, &r)
	ui.use(&f.s)
	testing.expect(t, !ui.view_is_open(ui.state_views(&f.s), "files"), "the toolkit ran it")
	testing.expect_value(t, r.choices, 0)
}
