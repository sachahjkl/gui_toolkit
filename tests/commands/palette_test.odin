// The command palette (ui/palette.odin, src/md/features/palette.md): the tests that break its design on day one, and each
// kind of source (the commands, a program's own at once or later, one that searches, the views' moves). Synthetic input
// events and builds, without a window; the palette ranks on the chores, so a test builds frames until its ranking came,
// within SETTLE_BOUND.
package commands_test

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "gt:font"
import i18n "gt:i18n"
import "gt:platform"
import "gt:ui"

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

// Waits, with no frame, until the ranking in flight posted its answer: each frame moves the test's clock, and frames
// spun while the chore runs went past the dialog's wait (100 ms) on the Windows CI, which then showed it with no rows.
@(private = "file")
wait_answer :: proc(t: ^testing.T, f: ^Fx, r: ^Run) {
	start := time.tick_now()
	for ui.palette_busy(&r.pal) && !ui.posts_pending(&f.s) {
		if time.tick_since(start) > SETTLE_BOUND { testing.fail_now(t, "the ranking never answered") }
		time.sleep(time.Millisecond)
	}
}

@(private = "file")
frame :: proc(f: ^Fx, events: []platform.Event, r: ^Run) {
	dt := f.dt > 0 ? f.dt : 1.0 / 60
	if f.animate { f.clock += f64(dt) * 1000 }
	ui.begin_build(&f.s, {
		window_size = WINDOW, events = events, dt = dt, animations = f.animate, dpi_scale = 1, time_ms = f.clock,
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

// Frames until the palette dropped `n` answers or rankings.
@(private = "file")
settle_dropped :: proc(t: ^testing.T, f: ^Fx, r: ^Run, n: int, loc := #caller_location) {
	start := time.tick_now()
	for r.pal.dropped < n || r.pal.pending != 0 {
		frame(f, nil, r)
		if time.tick_since(start) > SETTLE_BOUND { testing.fail_now(t, "the stale answer or ranking did not come", loc) }
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

// The id of row `i` ("": none); the id selected.
@(private = "file")
row_id :: proc(r: ^Run, i: int) -> string {
	_, id, _ := ui.palette_row(&r.pal, i)
	return id
}

@(private = "file")
selected_id :: proc(r: ^Run) -> string {
	_, id, _ := ui.palette_selected(&r.pal)
	return id
}

// A source of the test's: its items given at once, or its questions kept for the test to answer. Each question is ended
// once: by an answer of the test's, or dropped by source_free.
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
Question :: struct {
	q:     ui.Palette_Question,
	query: string,   // (owned: the question's is the palette's)
	ended: bool,
}

@(private = "file")
source_make :: proc(ts: ^Test_Source, name, title: string, prefix: ui.Palette_Prefix, items: []ui.Palette_Item, plain := false, later := false, searches := false) {
	ts.src = {name = name, title = title, prefix = prefix, plain = plain, remember = true, searches = searches, read = source_read, user = ts}
	ts.items, ts.later = items, later
}

@(private = "file")
source_free :: proc(ts: ^Test_Source) {
	for &q in ts.questions {
		if !q.ended { ui.palette_question_drop(q.q) }
		delete(q.query)
	}
	delete(ts.questions)
}

@(private = "file")
source_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	ts := (^Test_Source)(src.user)
	append(&ts.questions, Question{q = q, query = strings.clone(q.query)})
	if !ts.later { answer(ts, len(ts.questions) - 1, ts.items) }
}

// An answer of `items`, their strings copied in its arena (the source's own memory).
@(private = "file")
answer_of :: proc(items: []ui.Palette_Item) -> ui.Palette_Answer {
	a: ui.Palette_Answer
	al := ui.palette_answer_allocator(&a)
	a.items = make([]ui.Palette_Item, len(items), al)
	for it, i in items { a.items[i] = ui.palette_item_clone(it, al) }
	return a
}

// Ends question `i` with `items`.
@(private = "file")
answer :: proc(ts: ^Test_Source, i: int, items: []ui.Palette_Item) -> bool {
	q := &ts.questions[i]
	assert(!q.ended, "a question is ended once")
	q.ended = true
	a := answer_of(items)
	return ui.palette_answer(q.q, &a)
}

@(private = "file")
answer_last :: proc(ts: ^Test_Source, items: []ui.Palette_Item) -> bool { return answer(ts, len(ts.questions) - 1, items) }

@(private = "file")
last_question :: proc(ts: ^Test_Source) -> Question {
	if len(ts.questions) == 0 { return {} }
	return ts.questions[len(ts.questions) - 1]
}

// The index of the question asked for `query` (-1: none).
@(private = "file")
question_for :: proc(ts: ^Test_Source, query: string) -> int {
	for q, i in ts.questions { if q.query == query { return i } }
	return -1
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
	keymap:   ^ui.Keymap,      // the person's keys and aliases (nil: none)
}

@(private = "file")
run_build :: proc(r: ^Run) {
	ui.keymap_use(ui.current_state(), r.keymap)
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

// The command chosen last (-1: none, or another source's).
@(private = "file")
chosen_command :: proc(r: ^Run) -> int {
	i, ok := ui.palette_chosen_command(&r.pal, r.chosen)
	return ok ? i : -1
}

@(private = "file")
open_palette :: proc(t: ^testing.T, f: ^Fx, r: ^Run, typed := "", loc := #caller_location) {
	r.open_now, r.typed = true, typed
	settle(t, f, r, loc)
}

@(private = "file")
NEW_COMMANDS := [?]ui.Command{
	{id = "notes", label = "Notes", group = "File"},
	{id = "new_folder", label = "New folder", group = "File"},
	{id = "open", label = "Open", group = "File"},
}

@(private = "file")
LATE_ITEMS := [?]ui.Palette_Item{{id = "a0", title = "Alpha"}, {id = "a1", title = "Apple"}}

@(private = "file")
TAB_ITEMS := [?]ui.Palette_Item{{id = "b0", title = "Beta"}, {id = "b1", title = "Bravo"}, {id = "b2", title = "Brick"}}

// Two sources under `@`: one that answers later (its rows come above), one at once.
@(private = "file")
late_and_tabs :: proc(r: ^Run, late, tabs: ^Test_Source) {
	source_make(late, "closed", "Closed tabs", .Go_To, LATE_ITEMS[:], later = true)
	source_make(tabs, "tab", "Tabs", .Go_To, TAB_ITEMS[:])
	append(&r.sources, late, tabs)
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
	testing.expect(t, ui.palette_ranked_for(&r.pal, "n"), "the list on screen is the one of \"n\"")
	testing.expect_value(t, row_id(&r, 0), "notes")
	frame(&f, {typed('f'), key(.Return)}, &r)
	testing.expect(t, !ui.palette_ranked_for(&r.pal, "nf"), "\"nf\" in flight")
	settle_closed(t, &f, &r)
	frame(&f, nil, &r)
	testing.expect_value(t, r.choices, 1)
	testing.expect_value(t, chosen_command(&r), 1)
	testing.expect_value(t, r.chosen.id, "new_folder")
	testing.expect_value(t, r.chosen.query, "nf")   // (the query it was chosen for)
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
	r: Run
	append(&r.sources, &paths)
	defer run_free(&r)
	defer source_free(&paths)   // (before the palette: its questions find it)
	open_palette(t, &f, &r, "/")
	type_text(&f, &r, "abc")
	ab, abc := question_for(&paths, "ab"), question_for(&paths, "abc")
	if !testing.expect(t, ab >= 0 && abc >= 0, "asked for \"ab\", then for \"abc\"") { return }
	dropped := r.pal.dropped
	testing.expect(t, !answer(&paths, ab, items), "the answer for \"ab\" is dropped")
	testing.expect_value(t, r.pal.dropped, dropped + 1)
	testing.expect(t, answer(&paths, abc, items), "the answer for \"abc\" is kept")
	settle(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "abc")
	// (closed and opened: the question of the former opening is stale)
	type_text(&f, &r, "x")
	abcx := question_for(&paths, "abcx")
	frame(&f, {key(.Escape)}, &r)
	settle_closed(t, &f, &r)
	open_palette(t, &f, &r, "/abd")
	if !testing.expect(t, abcx >= 0, "asked for \"abcx\"") { return }
	testing.expect(t, !answer(&paths, abcx, items), "an answer of the former opening is dropped")
	testing.expect(t, answer_last(&paths, items), "this opening's is kept")
}

// A stale ranking: one that a newer opening replaced comes back and is dropped (and freed).
@(test)
a_stale_ranking_is_dropped :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Run{table = NEW_COMMANDS[:]}
	defer run_free(&r)
	open_palette(t, &f, &r)
	dropped := r.pal.dropped
	frame(&f, {typed('n')}, &r)   // (a ranking in flight: its answer comes at a next build)
	testing.expect(t, r.pal.pending != 0, "in flight")
	ui.use(&f.s)
	ui.palette_close(&r.pal)
	settle_dropped(t, &f, &r, dropped + 1)
	testing.expect_value(t, r.pal.dropped, dropped + 1)
}

// 3. A source that never answers: the palette says it reads, Up and Down move among the rows of the other source of its
// prefix, Escape closes it, and a later answer is dropped.
@(test)
a_source_that_never_answers :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	paths: Test_Source
	source_make(&paths, "path", "Paths", .Paths, nil, later = true, searches = true)
	marks: Test_Source
	source_make(&marks, "mark", "Bookmarks", .Paths, []ui.Palette_Item{{id = "m1", title = "x one"}, {id = "m2", title = "x two"}})
	r := Run{table = NEW_COMMANDS[:]}
	append(&r.sources, &paths, &marks)
	defer run_free(&r)
	defer { source_free(&paths); source_free(&marks) }
	open_palette(t, &f, &r, "/x")
	testing.expect(t, find_text(&f, "Paths: reading…") != nil, "it says the source reads")
	testing.expect(t, ui.palette_busy(&r.pal), "busy while it reads")
	testing.expect_value(t, selected_id(&r), "m1")
	frame(&f, {key(.Down)}, &r)
	testing.expect_value(t, selected_id(&r), "m2")
	frame(&f, {key(.Up)}, &r)
	testing.expect_value(t, selected_id(&r), "m1")
	testing.expect(t, find_text(&f, "Paths: reading…") != nil, "still reading")
	frame(&f, {key(.Escape)}, &r)
	settle_closed(t, &f, &r)
	testing.expect(t, !answer_last(&paths, {{id = "x", title = "x"}}), "a later answer is dropped")
}

// 4. A late answer above the selection: the selected item stays the same item.
@(test)
a_late_answer_keeps_the_selected_item :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	late, tabs: Test_Source
	r: Run
	late_and_tabs(&r, &late, &tabs)
	defer run_free(&r)
	defer { source_free(&late); source_free(&tabs) }
	open_palette(t, &f, &r, "@")
	testing.expect_value(t, row_id(&r, 0), "b0")
	frame(&f, {key(.Down)}, &r)
	testing.expect_value(t, selected_id(&r), "b1")
	testing.expect(t, answer_last(&late, late.items), "the late answer")
	settle(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "a0")
	testing.expect_value(t, selected_id(&r), "b1")
}

// Enter while a ranking that no new query started is in flight (a late answer): it chooses the row the person moved to,
// kept on its item, not the first row.
@(test)
enter_after_a_move_chooses_the_moved_row :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	late, tabs: Test_Source
	r: Run
	late_and_tabs(&r, &late, &tabs)
	defer run_free(&r)
	defer { source_free(&late); source_free(&tabs) }
	open_palette(t, &f, &r, "@")
	frame(&f, {key(.Down)}, &r)
	testing.expect_value(t, selected_id(&r), "b1")
	testing.expect(t, answer_last(&late, late.items), "the late answer")
	frame(&f, {key(.Return)}, &r)   // (the late answer's ranking starts in this build: Enter waits for it)
	settle_closed(t, &f, &r)
	frame(&f, nil, &r)
	testing.expect_value(t, r.chosen.id, "b1")
}

// The selection moved while a ranking is in flight (the pointer, after the ranking started in that build): the new list
// finds that item (palette_row_of), not the one the ranking was started with.
@(test)
a_move_during_a_ranking_keeps_its_item :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	late, tabs: Test_Source
	r: Run
	late_and_tabs(&r, &late, &tabs)
	defer run_free(&r)
	defer { source_free(&late); source_free(&tabs) }
	open_palette(t, &f, &r, "@")
	testing.expect_value(t, selected_id(&r), "b0")
	brick := find_text(&f, "Brick")
	if !testing.expect(t, brick != nil, "Brick's row") { return }
	at := [2]f32{(brick.rect.min.x + brick.rect.max.x) * 0.5, (brick.rect.min.y + brick.rect.max.y) * 0.5}
	testing.expect(t, answer_last(&late, late.items), "the late answer")
	frame(&f, {{kind = .Mouse_Move, pos = at}}, &r)   // (the ranking starts, then the pointer selects Brick)
	testing.expect_value(t, selected_id(&r), "b2")
	settle(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "a0")
	testing.expect_value(t, selected_id(&r), "b2")
}

// A source removed while its question and a ranking that reads it are in flight: the ranking is dropped, the answer is
// dropped, and the list holds no row of it.
@(test)
a_source_removed_in_flight :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	late, tabs: Test_Source
	r: Run
	late_and_tabs(&r, &late, &tabs)
	defer run_free(&r)
	defer { source_free(&late); source_free(&tabs) }
	open_palette(t, &f, &r, "@")
	frame(&f, {typed('b')}, &r)   // (a ranking in flight that reads the tabs' snapshot)
	testing.expect(t, r.pal.pending != 0, "in flight")
	dropped := r.pal.dropped
	ui.palette_remove(&r.pal, &tabs.src)
	ordered_remove(&r.sources, 1)
	testing.expect_value(t, r.pal.pending, 0)
	ui.palette_remove(&r.pal, &late.src)
	ordered_remove(&r.sources, 0)
	testing.expect(t, !answer_last(&late, late.items), "the removed source's answer is dropped")
	settle_dropped(t, &f, &r, dropped + 2)   // (that answer, and the ranking)
	testing.expect_value(t, ui.palette_row_count(&r.pal), 0)
	frame(&f, nil, &r)   // (the view builds with no row of a removed source)
}

// 5. A quiet build: with nothing changed, no source is asked and nothing is ranked.
@(test)
a_quiet_build_asks_and_ranks_nothing :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	tabs: Test_Source
	source_make(&tabs, "tab", "Tabs", .Go_To, []ui.Palette_Item{{id = "b0", title = "Beta"}}, plain = true)
	r := Run{table = NEW_COMMANDS[:]}
	append(&r.sources, &tabs)
	defer run_free(&r)
	defer source_free(&tabs)
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

// 6. No ranking on the interface's thread: a source of 100 000 items, a letter at each frame; this thread matches none
// of them, and the last letter's ranking comes within the bound (the ones it replaces stop early).
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
	r: Run
	append(&r.sources, &many)
	defer run_free(&r)
	defer source_free(&many)
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
	table := []ui.Command{{id = "notes", label = "Notes"}, {id = "home_notes", label = "/home/x notes"}}
	r := Run{table = table}
	defer run_free(&r)
	open_palette(t, &f, &r, "/home/x")
	testing.expect_value(t, row_id(&r, 0), "home_notes")
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
	table := []ui.Command{{id = "open", label = "Open", group = "File"}, {id = "close", label = "Close", group = "File"}}
	r := Run{table = table}
	defer run_free(&r)
	open_palette(t, &f, &r)
	type_text(&f, &r, "close")
	settle(t, &f, &r)
	frame(&f, {key(.Return)}, &r)
	settle_closed(t, &f, &r)
	frame(&f, nil, &r)
	testing.expect_value(t, r.chosen.id, "close")
	l, bad := i18n.load("fr", {{"fr", FRENCH}})
	defer { i18n.use(nil); i18n.destroy(l) }
	testing.expect_value(t, len(bad), 0)
	i18n.use(l)
	open_palette(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "close")
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
	choose.src.mark = proc(src: ^ui.Palette_Source, id: string) -> bool { return (^Test_Source)(src.user).on }
	choose.src.act = proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, c: ui.Palette_Choice) {
		ts := (^Test_Source)(src.user)
		ts.on, ts.acts = !ts.on, ts.acts + 1
	}
	r: Run
	append(&r.sources, &choose)
	defer run_free(&r)
	defer source_free(&choose)
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
// source, no prefix, not marked plain: the plain search is its only place) has none, and no Recent.
@(test)
one_table_of_prefixes :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	sessions, models: Test_Source
	source_make(&sessions, "session", "Sessions", .Go_To, nil)
	source_make(&models, "model", "Models", .Choose, nil)
	r := Run{table = NEW_COMMANDS[:]}
	append(&r.sources, &sessions, &models)
	defer run_free(&r)
	defer { source_free(&sessions); source_free(&models) }
	frame(&f, nil, &r)
	got := ui.palette_prefixes(&r.pal)
	testing.expectf(t, slice.equal(got, []string{"> Commands", "@ Sessions", "# Models"}), "the prefixes: %v", got)

	nodes: Test_Source
	source_make(&nodes, "node", "Nodes", .None, []ui.Palette_Item{{id = "add", title = "Add"}, {id = "mix", title = "Mix"}})
	chooser: Run
	append(&chooser.sources, &nodes)
	defer run_free(&chooser)
	defer source_free(&nodes)
	open_palette(t, &f, &chooser)
	testing.expect_value(t, row_id(&chooser, 0), "add")
	frame(&f, {key(.Return)}, &chooser)
	settle_closed(t, &f, &chooser)
	frame(&f, nil, &chooser)
	testing.expect_value(t, chooser.chosen.id, "add")
	testing.expect_value(t, len(ui.palette_prefixes(&chooser.pal)), 0)
	open_palette(t, &f, &chooser)
	testing.expect(t, find_text(&f, "Recent") == nil, "a chooser has no Recent")
	testing.expect_value(t, row_id(&chooser, 0), "add")
}

// An open palette opened again with a prefix: the prefix is typed.
@(test)
opening_again_with_a_prefix_types_it :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	sessions: Test_Source
	source_make(&sessions, "session", "Sessions", .Go_To, []ui.Palette_Item{{id = "s1", title = "First session"}})
	r := Run{table = NEW_COMMANDS[:]}
	append(&r.sources, &sessions)
	defer run_free(&r)
	defer source_free(&sessions)
	open_palette(t, &f, &r)
	open_palette(t, &f, &r, "@")
	testing.expect_value(t, ui.line_edit_string(&r.pal.field), "@")
	testing.expect_value(t, row_id(&r, 0), "s1")
}

@(private = "file")
SERVICE_COMMANDS := [?]ui.Command{
	{id = "service.start", label = "Start", group = "Services", keys = {{.S, {.Ctrl}}}},
	{id = "service.stop", label = "Stop", group = "Services", tags = {"halt"}},
	{id = "process.kill", label = "Kill…", group = "Processes", keys = {{.Delete, {.Shift}}}},
}

// The commands source: its keys' texts, its ids, a disabled command greyed and listed last and never chosen, Enter
// with a modifier (the program's while no keymap is in use), an alias typed whole first.
@(test)
the_commands_source :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	disabled := []bool{true, false, false}
	r := Run{table = SERVICE_COMMANDS[:], disabled = disabled}
	defer run_free(&r)
	open_palette(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "service.stop")    // (Start, disabled, after Stop in their group)
	testing.expect_value(t, row_id(&r, 1), "service.start")
	testing.expect(t, find_text(&f, "Shift+Delete") != nil, "a command's key in effect")
	type_text(&f, &r, "st")
	settle(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "service.stop")
	frame(&f, {key(.Down)}, &r)   // (the disabled row is not selected: the selection wraps to the first)
	frame(&f, {key(.Return, {.Ctrl})}, &r)
	settle_closed(t, &f, &r)
	frame(&f, nil, &r)
	testing.expect_value(t, chosen_command(&r), 1)
	testing.expect_value(t, r.chosen.mods, platform.Modifiers{.Ctrl})
	// a word the label does not say: its tags; an alias typed whole before the best match (the keymap's version: no new
	// version of the table)
	km: ui.Keymap
	defer ui.keymap_destroy(&km)
	ui.keymap_known(&km, SERVICE_COMMANDS[:])
	ui.keymap_alias(&km, "Halt ", "process.kill")
	r.keymap = &km
	open_palette(t, &f, &r, "halt")
	testing.expect_value(t, row_id(&r, 0), "process.kill")
	testing.expect_value(t, row_id(&r, 1), "service.stop")
}

// The selection starts on the first row that acts, and the disabled command of an alias typed whole is not put first.
@(test)
the_selection_starts_on_a_row_that_acts :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	table := []ui.Command{{id = "alpha", label = "Alpha", group = "One"}, {id = "beta", label = "Beta", group = "Two"}}
	disabled := []bool{true, false}
	r := Run{table = table, disabled = disabled}
	defer run_free(&r)
	open_palette(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "alpha")   // (alone in its group: first, greyed)
	testing.expect_value(t, selected_id(&r), "beta")
	frame(&f, {key(.Escape)}, &r)
	settle_closed(t, &f, &r)
	km: ui.Keymap
	defer ui.keymap_destroy(&km)
	ui.keymap_known(&km, table)
	ui.keymap_alias(&km, "a", "alpha")
	r.keymap = &km
	open_palette(t, &f, &r, "a")
	testing.expect_value(t, row_id(&r, 0), "beta")
	testing.expect_value(t, selected_id(&r), "beta")
}

// A hidden command (Palette_Commands_Options.hidden) is not offered: not listed, not found, not in Recent, not put first
// by its alias. A command after it is chosen by its index in the table, not its row in the answer. Shown again, it is
// listed again: the version (here, the slice's address) reads the table again.
@(test)
a_hidden_command_is_not_offered :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Run{table = SERVICE_COMMANDS[:]}
	defer run_free(&r)
	// (Stop chosen first: the usage memory holds it, Recent would list it)
	open_palette(t, &f, &r, "stop")
	frame(&f, {key(.Return)}, &r)
	settle_closed(t, &f, &r)
	frame(&f, nil, &r)
	testing.expect_value(t, r.chosen.id, "service.stop")
	hidden := []bool{false, true, false}
	r.opts.hidden = hidden
	open_palette(t, &f, &r)
	for i in 0 ..< ui.palette_row_count(&r.pal) { testing.expect(t, row_id(&r, i) != "service.stop", "not listed, not in Recent") }
	testing.expect(t, find_text(&f, "Stop") == nil, "no row says it")
	frame(&f, {key(.Escape)}, &r)
	settle_closed(t, &f, &r)
	open_palette(t, &f, &r, "halt")   // (its tag)
	testing.expect_value(t, ui.palette_row_count(&r.pal), 0)
	frame(&f, {key(.Escape)}, &r)
	settle_closed(t, &f, &r)
	// an alias typed whole names it: nothing put first
	km: ui.Keymap
	defer ui.keymap_destroy(&km)
	ui.keymap_known(&km, SERVICE_COMMANDS[:])
	ui.keymap_alias(&km, "k", "service.stop")
	r.keymap = &km
	open_palette(t, &f, &r, "k")
	testing.expect_value(t, row_id(&r, 0), "process.kill")
	// the command after it: its index in the table (2), not its row in the answer (1)
	frame(&f, {key(.Return)}, &r)
	settle_closed(t, &f, &r)
	frame(&f, nil, &r)
	testing.expect_value(t, r.chosen.id, "process.kill")
	testing.expect_value(t, chosen_command(&r), 2)
	// shown again: listed again, first by its alias
	r.opts.hidden = nil
	open_palette(t, &f, &r, "k")
	testing.expect_value(t, row_id(&r, 0), "service.stop")
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
	r := Run{table = NEW_COMMANDS[:]}
	append(&r.sources, &tabs)
	defer run_free(&r)
	defer source_free(&tabs)
	open_palette(t, &f, &r, "open")
	src, id, _ := ui.palette_row(&r.pal, 0)
	testing.expect(t, src == &r.pal.commands.source && id == "open", "the command typed whole first")
	src, id, _ = ui.palette_row(&r.pal, 1)
	testing.expect(t, src == &tabs.src && id == "t1", "then the tab of the same title")
	frame(&f, {key(.Escape)}, &r)
	settle_closed(t, &f, &r)
	open_palette(t, &f, &r, "@")
	testing.expect_value(t, ui.palette_row_count(&r.pal), 1)
	testing.expect(t, find_text(&f, "https://example.org") != nil, "its detail")
}

// A searching source answers from a chore: its rows come in a later build, a later query asks it again, an error answers
// the question.
@(test)
a_searching_source_answers_later :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	paths: Test_Source
	source_make(&paths, "path", "Paths", .Paths, nil, later = true, searches = true)
	r: Run
	append(&r.sources, &paths)
	defer run_free(&r)
	defer source_free(&paths)
	open_palette(t, &f, &r, "/do")
	testing.expect_value(t, last_question(&paths).query, "do")
	// (the source found a folder whose name the matcher does not find: it stays, after every match)
	found := []ui.Palette_Item{{id = "/home/docs", title = "docs"}, {id = "/srv/archive", title = "archive", completion = "/srv/archive/"}}
	testing.expect(t, answer_last(&paths, found), "kept")
	settle(t, &f, &r)
	testing.expect_value(t, ui.palette_row_count(&r.pal), 2)
	testing.expect_value(t, row_id(&r, 0), "/home/docs")
	frame(&f, {key(.Down)}, &r)
	frame(&f, {key(.Tab)}, &r)   // (Tab completes: the folder's path in the field)
	frame(&f, nil, &r)
	testing.expect_value(t, ui.line_edit_string(&r.pal.field), "/srv/archive/")
	testing.expect_value(t, last_question(&paths).query, "srv/archive/")
	asked := len(paths.questions)
	last := &paths.questions[len(paths.questions) - 1]
	last.ended = true
	testing.expect(t, ui.palette_answer_error(last.q, "no such folder"), "an error")
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

@(private = "file")
TOGGLE_COMMANDS := [?]ui.Command{
	{id = "expand_tools", label = "Expand tools", group = "View", toggle = true},
	{id = "session.fork", label = "Fork the session", group = "Session"},
}

// A toggle command (Command.toggle): its mark is the program's state, read for the rows in view; chosen, the palette
// stays open, the program flips it, the mark follows and nothing is ranked again. A command's detail shows after its
// title, and is not searched.
@(test)
a_toggle_command_and_a_detail :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	on := false
	r := Run{table = TOGGLE_COMMANDS[:], opts = {
		details = {"", "Session · Fix the build"},
		checked = proc(user: rawptr, index: int) -> bool { return (^bool)(user)^ },
		user    = &on,
	}}
	defer run_free(&r)
	open_palette(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "expand_tools")
	testing.expect(t, find_text(&f, ui.ICON_CHECK) == nil, "off: no mark")
	testing.expect(t, find_text(&f, "Session · Fix the build") != nil, "the detail shows")
	rankings, asks := r.pal.rankings, r.pal.asks
	frame(&f, {key(.Return)}, &r)
	frame(&f, nil, &r)   // (the choice is read in the build after it)
	testing.expect_value(t, r.choices, 1)
	testing.expect_value(t, chosen_command(&r), 0)
	testing.expect(t, palette_open_now(&f, &r), "a toggle: the palette stays open")
	on = !on   // (the program flips it)
	frame(&f, nil, &r)
	testing.expect(t, find_text(&f, ui.ICON_CHECK) != nil, "on: its mark")
	// (no source read again, the views' moves neither: the palette's own view stepping its state lists no new move)
	testing.expect_value(t, r.pal.asks, asks)
	testing.expect_value(t, r.pal.rankings, rankings)
	// the detail is not searched: "fix" finds neither command
	open_palette(t, &f, &r, "fix")
	testing.expect_value(t, ui.palette_row_count(&r.pal), 0)
}

// What a chore ends: a question, with an answer of `items` or dropped.
@(private = "file")
Chore_End :: struct {
	q:     ui.Palette_Question,
	items: []ui.Palette_Item,
	drop:  bool,
	done:  bool,   // (atomic) the chore ended the question
}

@(private = "file")
chore_end :: proc(d: rawptr) {
	e := (^Chore_End)(d)
	if e.drop {
		ui.palette_question_drop(e.q)
	} else {
		a := answer_of(e.items)
		_ = ui.palette_answer(e.q, &a)   // (off the interface's thread: posted there)
	}
	sync.atomic_store(&e.done, true)
}

// A question ended on a chore (its answer, or its drop): posted to the interface's thread, applied at a build; once the
// palette is gone, an end only lets go of its handle.
@(test)
a_question_is_ended_from_a_chore :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	late: Test_Source
	source_make(&late, "closed", "Closed tabs", .Go_To, LATE_ITEMS[:], later = true)
	r: Run
	append(&r.sources, &late)
	defer source_free(&late)
	open_palette(t, &f, &r, "@")
	q := &late.questions[len(late.questions) - 1]
	q.ended = true
	answered := Chore_End{q = q.q, items = LATE_ITEMS[:]}
	ui.task(&f.s, chore_end, nil, &answered)
	start := time.tick_now()
	for ui.palette_row_count(&r.pal) == 0 || r.pal.pending != 0 {
		frame(&f, nil, &r)
		if time.tick_since(start) > SETTLE_BOUND { testing.fail_now(t, "the chore's answer did not come") }
	}
	testing.expect_value(t, row_id(&r, 0), "a0")
	// a drop from a chore: the source is asked again
	late.src.version += 1
	frame(&f, nil, &r)
	asks := r.pal.asks
	q = &late.questions[len(late.questions) - 1]
	q.ended = true
	dropped := Chore_End{q = q.q, drop = true}
	ui.task(&f.s, chore_end, nil, &dropped)
	start = time.tick_now()
	for r.pal.asks == asks {
		frame(&f, nil, &r)
		if time.tick_since(start) > SETTLE_BOUND { testing.fail_now(t, "the dropped question was not asked again") }
	}
	// the palette destroyed, a question still out: its end on a chore finds no palette
	q = &late.questions[len(late.questions) - 1]
	q.ended = true
	gone := Chore_End{q = q.q, items = LATE_ITEMS[:]}
	run_free(&r)
	ui.task(&f.s, chore_end, nil, &gone)
	start = time.tick_now()
	for !sync.atomic_load(&gone.done) {
		if time.tick_since(start) > SETTLE_BOUND { testing.fail_now(t, "the chore did not run") }
	}
	ui.drain_posts(&f.s)   // (its end posted: it finds no palette, lets go of the handle and frees the answer)
}

// palette_has says whether a source is added; a second add is nothing; an answer never given is freed.
@(test)
a_source_is_added_once :: proc(t: ^testing.T) {
	pal: ui.Command_Palette
	defer ui.palette_destroy(&pal)
	tabs: Test_Source
	source_make(&tabs, "tab", "Tabs", .Go_To, TAB_ITEMS[:])
	testing.expect(t, !ui.palette_has(&pal, &tabs.src), "not yet")
	ui.palette_add(&pal, &tabs.src)
	ui.palette_add(&pal, &tabs.src)
	testing.expect(t, ui.palette_has(&pal, &tabs.src), "added")
	testing.expect_value(t, len(ui.palette_prefixes(&pal)), 1)
	ui.palette_remove(&pal, &tabs.src)
	testing.expect(t, !ui.palette_has(&pal, &tabs.src), "removed")
	a := answer_of(TAB_ITEMS[:])
	ui.palette_answer_free(&a)
	testing.expect(t, a.items == nil, "freed: zero after")
}

// A question says where its query was typed: a source in two places (a prefix and the plain search) is asked again in
// the other place, for the same query.
@(test)
a_question_says_its_prefix :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	folders: Test_Source
	source_make(&folders, "folder", "Folders", .Paths, nil, plain = true, later = true, searches = true)
	r: Run
	append(&r.sources, &folders)
	defer run_free(&r)
	defer source_free(&folders)
	open_palette(t, &f, &r, "/do")
	q := last_question(&folders)
	testing.expect(t, q.query == "do" && q.q.prefix == .Paths, "under its prefix")
	open_palette(t, &f, &r, "do")   // (the field replaced: the plain search)
	q = last_question(&folders)
	testing.expect(t, q.query == "do" && q.q.prefix == .None, "asked again: the plain search")
}

// A box of the last build whose text holds `part` (nil: none).
@(private = "file")
find_part :: proc(f: ^Fx, part: string) -> ^ui.Box {
	walk :: proc(b: ^ui.Box, part: string) -> ^ui.Box {
		if b == nil { return nil }
		if strings.contains(b.text, part) { return b }
		for c := b.first; c != nil; c = c.next { if r := walk(c, part); r != nil { return r } }
		return nil
	}
	return walk(f.s.root, part)
}

// Go to (src/md/features/everything-palette.md, layer 3): a button that states its command's act name, far down a
// list, is reached by Shift+Enter on the command: scrolled into view, focused, lit, and the program sees no choice. A
// command that no element names offers no go to, and Shift+Enter on it is Enter.
@(test)
shift_enter_goes_to_a_command_s_button :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Run{table = SERVICE_COMMANDS[:]}
	defer run_free(&r)
	r.extra = proc(r: ^Run) {
		ui.next({width = ui.fill(), height = ui.px(200)})
		if ui.scroll_y("###far") {
			for i in 0 ..< 60 {
				ui.next({width = ui.fill(), height = ui.px(30)})
				ui.label(fmt.tprintf("Line %d###l%d", i, i))
			}
			b := ui.button("###stop", "Stop the service")
			ui.act_command(b.box, "service.stop")   // (the name "command:service.stop", as the commands source's item has it)
		}
	}
	open_palette(t, &f, &r, "stop")
	testing.expect_value(t, row_id(&r, 0), "service.stop")
	testing.expect(t, ui.act_shown("command:service.stop"), "its button shown in the last frame")
	testing.expect(t, find_part(&f, "Go to") != nil, "the hint row offers go to")
	frame(&f, {key(.Return, {.Shift})}, &r)
	settle_closed(t, &f, &r)
	for _ in 0 ..< 20 { frame(&f, nil, &r) }
	button := find_text(&f, "Stop the service")
	testing.expect(t, button != nil, "the button")
	if button != nil {
		lit := false
		for a := button; a != nil; a = a.parent { if a.key == f.s.act_light.key { lit = true } }
		testing.expect(t, lit, "lit")
		testing.expect_value(t, f.s.focus_key, f.s.act_light.key)
		testing.expect(t, button.rect.min.y >= 0 && button.rect.max.y <= 200 + 1, "scrolled into view")
	}
	testing.expect_value(t, r.choices, 0)
	// a command no element names: no go to; Shift+Enter is Enter
	open_palette(t, &f, &r, "kill")
	testing.expect_value(t, row_id(&r, 0), "process.kill")
	testing.expect(t, find_part(&f, "Go to") == nil, "no go to offered")
	frame(&f, {key(.Return, {.Shift})}, &r)
	settle_closed(t, &f, &r)
	frame(&f, nil, &r)
	testing.expect_value(t, chosen_command(&r), 2)
}

////////////////////////////////
// Its dialog's appearance (views.md 3.4, "A dialog that appears at once")

// How much of the palette's dialog shows in the last build: 0 unseen (or not built), 1 whole.
@(private = "file")
dialog_shown :: proc(f: ^Fx) -> f32 {
	if f.s.root == nil { return 0 }   // (no build yet)
	for c := f.s.root.first; c != nil; c = c.next {
		if .Press_Stop in c.flags && .Draw_Shadow in c.flags && c.last_build == f.s.build_index { return 1 - c.transparency }
	}
	return 0
}

// The dialog shows with its rows: its source answers four frames late, and no frame before the answer draws any of it;
// the first frame that draws it has the palette's first row, and that row's text is built.
@(test)
the_palette_shows_with_its_rows :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	f.animate = true
	late: Test_Source
	source_make(&late, "closed", "Closed tabs", .Go_To, LATE_ITEMS[:], plain = true, later = true)
	late.src.listed = true   // (its rows show while nothing is typed)
	r: Run
	append(&r.sources, &late)
	defer run_free(&r)
	defer source_free(&late)
	r.open_now = true
	for _ in 0 ..< 4 {
		frame(&f, nil, &r)
		testing.expectf(t, dialog_shown(&f) == 0, "unseen while its source has not answered: %v", dialog_shown(&f))
	}
	if !testing.expect(t, len(late.questions) == 1, "the source was asked") { return }
	testing.expect(t, answer_last(&late, LATE_ITEMS[:]), "the answer kept")
	// (frames spin faster than the ranking's chore: a clock of 1 ms a frame keeps the wait's bound, 100 ms, out of the test)
	f.dt = 0.001
	start := time.tick_now()
	for dialog_shown(&f) == 0 {
		wait_answer(t, &f, &r)
		frame(&f, nil, &r)
		if time.tick_since(start) > SETTLE_BOUND { testing.fail_now(t, "the palette never showed") }
	}
	testing.expect_value(t, row_id(&r, 0), "a0")
	testing.expect(t, find_text(&f, "Alpha") != nil, "the first row is built in the frame that first draws the dialog")
}

// A palette of a known size whose answers are there shows in the build where its ranking comes: no unseen build to measure
// it after that; and it shows something in that very build (its fade moved by that frame).
@(test)
a_palette_of_a_known_size_shows_at_once :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	f.animate = true
	f.dt = 0.001   // (frames spin faster than the ranking's chore: the wait's bound, 100 ms, stays out of the test)
	r := Run{table = NEW_COMMANDS[:]}
	defer run_free(&r)
	r.open_now = true
	start := time.tick_now()
	for {
		wait_answer(t, &f, &r)
		frame(&f, nil, &r)
		answered := r.pal.pending == 0 && r.pal.shown != nil
		if answered {
			testing.expectf(t, dialog_shown(&f) > 0, "shown in the build its answers came: %v", dialog_shown(&f))
			break
		}
		testing.expect_value(t, dialog_shown(&f), 0)
		if time.tick_since(start) > SETTLE_BOUND { testing.fail_now(t, "the palette's ranking did not come") }
	}
	testing.expect_value(t, row_id(&r, 0), "notes")
}

// A late frame (50 ms) moves the dialog's fade by MODAL_FADE_STEP_MAX_MS at most: what a 25 ms frame moves it.
@(test)
a_late_frame_moves_the_fade_by_a_bounded_step :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	f.animate = true
	f.dt = 0.001   // (as above: frames of 1 ms until the ranking comes)
	r := Run{table = NEW_COMMANDS[:]}
	defer run_free(&r)
	r.open_now = true
	start := time.tick_now()
	for dialog_shown(&f) == 0 {
		wait_answer(t, &f, &r)
		frame(&f, nil, &r)
		if time.tick_since(start) > SETTLE_BOUND { testing.fail_now(t, "the palette never showed") }
	}
	// (its first frame shown is one frame, 1 ms, into the quick fade, 70 ms)
	// (the fade's own curve: ui.tween along .In_Out)
	smooth :: proc(ms: f32) -> f32 { return ui.ease_at(.In_Out, ms / 70) }
	first := dialog_shown(&f)
	testing.expectf(t, abs(first - smooth(1)) < 1e-3, "one frame in: %v", first)
	f.dt = 0.050
	frame(&f, nil, &r)
	late := dialog_shown(&f)
	testing.expectf(t, abs(late - smooth(1 + 25)) < 1e-3, "a 50 ms frame moves it by 25 ms: %v, not %v", late, smooth(1 + 50))
}

// An item chosen multiple times appears once under Recent and is not repeated in the list underneath.
@(test)
recent_items_are_never_duplicated :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Run{table = COMMANDS[:]}
	defer run_free(&r)
	for _ in 0 ..< 3 {
		open_palette(t, &f, &r)
		type_text(&f, &r, "close")
		send(&f, &r, key_ev(.Return))
	}
	open_palette(t, &f, &r)
	testing.expect_value(t, row_id(&r, 0), "close")
	count := 0
	for i in 0 ..< row_count(&r) {
		if row_id(&r, i) == "close" { count += 1 }
	}
	testing.expect_value(t, count, 1)
}
