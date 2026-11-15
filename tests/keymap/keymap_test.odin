// The person's own keys and aliases (ui/keymap.odin, src/md/features/keymap.md): the test that breaks the design on day
// one, sequences, conflicts, the stored texts, aliases and the recorder in the palette, entries of ids no table has.
// Synthetic input events and builds, without a window; the ui state of a build and the language in use are global: one
// test thread.
//   odin run tools/run_tests -- keymap   (on Linux it needs the native text backend: tools/tk build_native)
package keymap_test

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import config "gt:config"
import "gt:font"
import i18n "gt:i18n"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:ui"

WINDOW :: ui.Vec2{800, 600}
// How long a test waits at most for the palette's ranking, on the chores.
SETTLE_BOUND :: 5 * time.Second

Fx :: struct {
	fonts:     font.State,
	theme:     ui.Theme,
	s:         ui.State,
	base_font: font.Font_Id,
	clock:     f64,   // the state's clock (ui.set_clock): a sequence's deadline passes without waiting
}

@(private = "file")
open :: proc(f: ^Fx) -> bool {
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { return false }
	ui.apply_palette(&f.theme, ui.palette_of("Midnight"))
	ui.init(&f.s, &f.fonts, &f.theme)
	f.clock = 1000
	ui.set_clock(&f.s, &f.clock)
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
frame_on :: proc(f: ^Fx, s: ^ui.State, events: []platform.Event, body: proc(user: rawptr), user: rawptr) {
	ui.begin_build(s, {
		window_size = WINDOW, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
	})
	body(user)
	ui.end_build()
	free_all(context.temp_allocator)
	f.clock += 16
}

@(private = "file")
frame :: proc(f: ^Fx, events: []platform.Event, body: proc(user: rawptr), user: rawptr) { frame_on(f, &f.s, events, body, user) }

@(private = "file")
key :: proc(k: platform.Key, mods: platform.Modifiers = {}) -> platform.Event { return {kind = .Key_Press, key = k, mods = mods} }

@(private = "file")
typed :: proc(r: rune) -> platform.Event { return {kind = .Text, text = r} }

// A box of the last build of `s` that shows `text` (nil: none).
@(private = "file")
find_text :: proc(s: ^ui.State, text: string) -> ^ui.Box {
	walk :: proc(b: ^ui.Box, text: string) -> ^ui.Box {
		if b == nil { return nil }
		if b.text == text { return b }
		for c := b.first; c != nil; c = c.next { if r := walk(c, text); r != nil { return r } }
		return nil
	}
	return walk(s.root, text)
}

@(private = "file")
TABS := [?]ui.Command{
	{id = "tab_new", label = "New tab", group = "Tabs", keys = {{.T, {.Ctrl}}}},
	{id = "tab_close", label = "Close tab", group = "Tabs", keys = {{.W, {.Ctrl}}, {.F4, {.Ctrl}}}},
}

@(private = "file")
Tabs_Run :: struct {
	commands:  []ui.Command,
	pressed:   [4]bool,
	disabled:  [4]bool,
	other:     bool,   // what reads `other_key` after the commands got it
	other_key: ui.Chord,
	sheet:     ui.Shortcuts_Sheet,
	sheet_now: bool,
}

// (the commands first, as a program reads its keys before it builds its page)
@(private = "file")
build_tabs :: proc(user: rawptr) {
	r := (^Tabs_Run)(user)
	for c, i in r.commands { r.pressed[i] = ui.command_pressed(c, r.disabled[i]) }
	r.other = r.other_key.key != .None && ui.key_press(r.other_key.key, r.other_key.mods)
	if r.sheet_now { r.sheet_now = false; ui.shortcuts_sheet_open(&r.sheet, r.commands) }
}

// The test that breaks the design on day one (keymap.md): in French, New tab is set to Ctrl+W; the next start is in
// English, with an entry for an id no table has. Ctrl+W is New tab's and not Close tab's, Ctrl+F4 still closes, the menu
// and the sheet say so, and the stored text is the English one.
@(test)
a_key_set_in_french_holds_in_english :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	testing.expect_value(t, len(ui.command_ids_check(TABS[:])), 0)

	// the first run, in French: the key set as the palette's recorder does, written by the standard settings
	fr, bad := i18n.load("fr", nil)
	defer i18n.destroy(fr)
	testing.expect_value(t, len(bad), 0)
	i18n.use(fr)
	prefs := config.prefs_make()
	defer config.prefs_destroy(&prefs)
	prefs_page.standard_register(&prefs, {.Keys}, prefs_page.STANDARD_DEFAULTS, context.temp_allocator)
	first: ui.Keymap
	defer ui.keymap_destroy(&first)
	ui.keymap_known(&first, TABS[:])
	w: prefs_page.Standard_Watch
	prefs_page.standard_watch(&w, &prefs, &f.s, {keymap = &first})
	ui.keymap_bind(&first, "tab_new", {{{.W, {.Ctrl}}, {}}})
	stored := strings.clone(config.string_of(&prefs, prefs_page.KEYS_CUSTOM_PREF), context.temp_allocator)
	testing.expect_value(t, stored, "tab_new=Ctrl+W")
	prefs_page.standard_unwatch(&w)

	// the next start, in English, with a stale entry
	i18n.use(nil)
	km: ui.Keymap
	defer ui.keymap_destroy(&km)
	ui.keymap_known(&km, TABS[:])
	ui.keymap_read(&km, strings.concatenate({stored, ";gone=Ctrl+F4"}, context.temp_allocator), "")
	ui.keymap_use(&f.s, &km)
	r := Tabs_Run{commands = TABS[:]}
	defer ui.shortcuts_sheet_destroy(&r.sheet)
	frame(&f, {key(.W, {.Ctrl})}, build_tabs, &r)
	testing.expect(t, r.pressed[0] && !r.pressed[1], "Ctrl+W runs New tab, not Close tab")
	frame(&f, {key(.F4, {.Ctrl})}, build_tabs, &r)
	testing.expect(t, r.pressed[1], "Ctrl+F4 still closes the tab")
	frame(&f, {key(.T, {.Ctrl})}, build_tabs, &r)
	testing.expect(t, !r.pressed[0], "New tab's own Ctrl+T gave way to the person's key")

	ui.use(&f.s)
	testing.expect_value(t, ui.command_shortcut(TABS[1]), "Ctrl+F4")
	testing.expect_value(t, ui.command_keys_text(TABS[1]), "Ctrl+F4")
	testing.expect_value(t, ui.command_tip(TABS[0]), "New tab (Ctrl+W)")
	r.sheet_now = true
	for _ in 0 ..< 3 { frame(&f, nil, build_tabs, &r) }
	testing.expect(t, find_text(&f.s, "Ctrl+F4") != nil, "the sheet agrees with the menu: Close tab, Ctrl+F4")
	testing.expect(t, find_text(&f.s, "Ctrl+W / Ctrl+F4") == nil, "and not Ctrl+W")
	testing.expect(t, find_text(&f.s, "Ctrl+W") != nil && find_text(&f.s, "Ctrl+T") == nil, "New tab: the person's key alone")
	custom, _ := ui.keymap_texts(&km)
	testing.expect_value(t, custom, "gone=Ctrl+F4;tab_new=Ctrl+W")   // (the stale entry kept, inert)
}

// The keys are the settings' to write, whichever window watched last: a second window (a pin, an editor) that closes
// leaves them written. A key and an alias stored together are not read back half written. A view's own window reads
// its owner's keymap.
@(test)
the_keys_outlive_a_window :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	prefs := config.prefs_make()
	defer config.prefs_destroy(&prefs)
	prefs_page.standard_register(&prefs, {.Keys}, prefs_page.STANDARD_DEFAULTS, context.temp_allocator)
	km: ui.Keymap
	defer ui.keymap_destroy(&km)
	ui.keymap_known(&km, TABS[:])
	main, pin: prefs_page.Standard_Watch
	prefs_page.standard_watch(&main, &prefs, &f.s, {keymap = &km})
	defer prefs_page.standard_unwatch(&main)
	prefs_page.standard_watch(&pin, &prefs, &f.s, {keymap = &km})
	prefs_page.standard_unwatch(&pin)   // (the pin closes; the main window stays)

	ui.keymap_alias(&km, "nt", "tab_new")
	ui.keymap_bind(&km, "tab_new", {{{.W, {.Ctrl}}, {}}})
	testing.expect_value(t, config.string_of(&prefs, prefs_page.KEYS_CUSTOM_PREF), "tab_new=Ctrl+W")
	testing.expect_value(t, config.string_of(&prefs, prefs_page.KEYS_ALIASES_PREF), "nt=tab_new")
	testing.expect_value(t, ui.keymap_alias_command(&km, "nt"), "tab_new")

	view_window: ui.State
	view_window.style_owner = &f.s
	ui.keymap_use(&f.s, &km)
	ui.style_follow(&view_window, &f.s)
	testing.expect(t, view_window.keymap == &km, "a view's window reads its owner's keymap")
}

// A program fills its palette before its first window (papier's prefixes): no State, no keymap, no panic.
@(test)
a_palette_filled_before_any_window :: proc(t: ^testing.T) {
	p: ui.Command_Palette
	defer ui.palette_destroy(&p)
	ui.palette_commands(&p, TABS[:], nil)
	testing.expect(t, len(ui.palette_prefixes(&p)) > 0, "the commands' source is there")
}

@(private = "file")
SEQUENCE := [?]ui.Command{
	{id = "terminal", label = "Terminal", keys = {{.F7, {}}}},
	{id = "tab_new", label = "New tab", keys = {{.T, {.Ctrl}}}},
	{id = "find", label = "Find", keys = {{.M, {.Ctrl}}}},
}

// A sequence of two chords: the first sets the window's pending chord and shows it, the second completes it; any other
// press ends it and is taken, Escape too; the deadline ends it; a pending chord in one window is not completed in another.
@(test)
a_sequence_of_two_chords :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	km: ui.Keymap
	defer ui.keymap_destroy(&km)
	ui.keymap_known(&km, SEQUENCE[:])
	ui.keymap_bind(&km, "tab_new", {{{.M, {.Ctrl}}, {.T, {}}}})
	ui.keymap_use(&f.s, &km)
	r := Tabs_Run{commands = SEQUENCE[:]}

	frame(&f, {key(.M, {.Ctrl})}, build_tabs, &r)
	testing.expect(t, !r.pressed[1] && !r.pressed[2], "the first chord runs nothing: Find's own Ctrl+M is the sequence's")
	testing.expect(t, find_text(&f.s, "Ctrl+M, …") != nil, "the pending chord shows")
	testing.expect(t, ui.wake_ms(&f.s) > 0, "the window wakes at the deadline")
	frame(&f, {key(.T), typed('t')}, build_tabs, &r)
	testing.expect(t, r.pressed[1], "the second chord completes it")
	testing.expect(t, find_text(&f.s, "Ctrl+M, …") == nil, "the bubble goes")
	ui.use(&f.s)
	testing.expect_value(t, ui.command_shortcut(SEQUENCE[1]), "Ctrl+M, T")

	// another key ends it, taken: neither its command nor what reads it after gets it
	r.other_key = {.F7, {}}
	frame(&f, {key(.M, {.Ctrl})}, build_tabs, &r)
	frame(&f, {key(.F7)}, build_tabs, &r)
	testing.expect(t, !r.pressed[0] && !r.other, "F7 ended the sequence: taken")
	frame(&f, {key(.F7)}, build_tabs, &r)
	testing.expect(t, r.pressed[0], "then F7 is Terminal's again")

	// Escape ends it, and reaches nothing else
	r.other_key = {.Escape, {}}
	frame(&f, {key(.M, {.Ctrl})}, build_tabs, &r)
	frame(&f, {key(.Escape)}, build_tabs, &r)
	testing.expect(t, !r.other, "Escape ended it")
	testing.expect(t, find_text(&f.s, "Ctrl+M, …") == nil, "no bubble")

	// the deadline ends it
	r.other_key = {}
	frame(&f, {key(.M, {.Ctrl})}, build_tabs, &r)
	f.clock += ui.KEYMAP_SEQUENCE_MS + 10
	frame(&f, {key(.F7)}, build_tabs, &r)
	testing.expect(t, r.pressed[0], "past the deadline, F7 is Terminal's")

	// one window's pending chord is its own
	other: ui.State
	ui.init(&other, &f.fonts, &f.theme)
	defer ui.destroy(&other)
	ui.set_clock(&other, &f.clock)
	ui.keymap_use(&other, &km)
	frame(&f, {key(.M, {.Ctrl})}, build_tabs, &r)
	frame_on(&f, &other, {key(.T)}, build_tabs, &r)
	testing.expect(t, !r.pressed[1], "the other window has no pending chord")
	frame(&f, {key(.T)}, build_tabs, &r)
	testing.expect(t, r.pressed[1], "this one completes it")
}

// One key, one command: a binding of the same keys goes, a single chord that a new sequence starts with goes, a sequence
// that a new single chord starts goes; two sequences share their first chord. A person's key on a disabled command does
// nothing, and is not given back to the command whose own key it took.
@(test)
one_key_one_command :: proc(t: ^testing.T) {
	km: ui.Keymap
	defer ui.keymap_destroy(&km)
	ui.keymap_bind(&km, "a", {{{.M, {.Ctrl}}, {}}})
	ui.keymap_bind(&km, "b", {{{.M, {.Ctrl}}, {}}})
	custom, _ := ui.keymap_texts(&km)
	testing.expect_value(t, custom, "b=Ctrl+M")
	ui.keymap_bind(&km, "c", {{{.M, {.Ctrl}}, {.T, {}}}})
	custom, _ = ui.keymap_texts(&km)
	testing.expect_value(t, custom, "c=Ctrl+M, T")
	ui.keymap_bind(&km, "d", {{{.M, {.Ctrl}}, {.X, {}}}})
	custom, _ = ui.keymap_texts(&km)
	testing.expect_value(t, custom, "c=Ctrl+M, T;d=Ctrl+M, X")
	ui.keymap_bind(&km, "e", {{{.M, {.Ctrl}}, {}}})
	custom, _ = ui.keymap_texts(&km)
	testing.expect_value(t, custom, "e=Ctrl+M")
	ui.keymap_unbind(&km, "e")
	custom, _ = ui.keymap_texts(&km)
	testing.expect_value(t, custom, "")

	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	ui.keymap_known(&km, TABS[:])
	ui.keymap_bind(&km, "tab_new", {{{.W, {.Ctrl}}, {}}})
	ui.keymap_use(&f.s, &km)
	r := Tabs_Run{commands = TABS[:], disabled = {true, false, false, false}}
	frame(&f, {key(.W, {.Ctrl})}, build_tabs, &r)
	testing.expect(t, !r.pressed[0] && !r.pressed[1], "New tab cannot act: Ctrl+W does nothing, Close tab does not get it")
}

// The stored texts: English whatever the language in use, read back the same; a text written in French is not read; the
// texts sorted; a text equal to the last one read changes nothing.
@(test)
the_stored_texts_round_trip :: proc(t: ^testing.T) {
	cases := [?]ui.Binding{
		{{{.P, {.Ctrl, .Shift}}, {}}}, {{{.Num_Add, {.Ctrl}}, {}}}, {{{.Comma, {.Ctrl}}, {.T, {}}}},
		{{{.Page_Up, {.Shift}}, {}}}, {{{.Return, {.Alt}}, {}}}, {{{.F7, {}}, {}}}, {{{.M, {.Ctrl}}, {.Comma, {}}}},
	}
	for b in cases {
		text := ui.binding_store_text(b)
		back, ok := ui.binding_parse(text)
		testing.expectf(t, ok && back == b, "%q read back: %v", text, back)
	}
	testing.expect_value(t, ui.binding_store_text({{{.Comma, {.Ctrl}}, {.T, {}}}}), "Ctrl+,, T")
	testing.expect_value(t, ui.binding_store_text({{{.Num_Add, {.Ctrl}}, {}}}), "Ctrl+Num +")
	b, ok := ui.binding_parse("ctrl+shift+page up")
	testing.expect(t, ok && b == ui.Binding{{{.Page_Up, {.Ctrl, .Shift}}, {}}}, "a hand's case")

	fr, _ := i18n.load("fr", nil)
	defer { i18n.use(nil); i18n.destroy(fr) }
	i18n.use(fr)
	w := ui.Binding{{{.W, {.Ctrl, .Shift}}, {}}}
	testing.expect_value(t, ui.binding_text(w), "Ctrl+Maj+W")
	testing.expect_value(t, ui.binding_store_text(w), "Ctrl+Shift+W")
	_, read := ui.binding_parse("Ctrl+Maj+W")
	testing.expect(t, !read, "a modifier in French is not read")

	km: ui.Keymap
	defer ui.keymap_destroy(&km)
	ui.keymap_read(&km, "z_last=F7; tab_new=Ctrl+M, T;bad=Ctrl+Maj+W;Bad Id=F8;=F9", "nf=new_folder; GO =goto;x=Not An Id")
	custom, aliases := ui.keymap_texts(&km)
	testing.expect_value(t, custom, "tab_new=Ctrl+M, T;z_last=F7")
	testing.expect_value(t, aliases, "go=goto;nf=new_folder")
	version := km.version
	ui.keymap_read(&km, "z_last=F7; tab_new=Ctrl+M, T;bad=Ctrl+Maj+W;Bad Id=F8;=F9", "nf=new_folder; GO =goto;x=Not An Id")
	testing.expect_value(t, km.version, version)
}

// Ids: the empty, the malformed and the twice-in-a-table ones listed; one id in two tables is one command.
@(test)
the_ids_are_checked :: proc(t: ^testing.T) {
	bad := []ui.Command{{label = "A"}, {id = "Tab.New", label = "B"}, {id = "x", label = "C"}, {id = "x", label = "D"}, {id = "a b", label = "E"}}
	got := ui.command_ids_check(bad, TABS[:], TABS[:])
	testing.expectf(t, slice.equal(got, []string{"A: no id", `B: "Tab.New" is not an id`, `D: "x" twice`, `E: "a b" is not an id`}), "%v", got)
}

// An entry of an id no table has is kept, and takes no chord from anyone; once a table has that id, it takes its chord.
@(test)
an_unknown_id_is_inert :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	km: ui.Keymap
	defer ui.keymap_destroy(&km)
	ui.keymap_known(&km, TABS[:])
	ui.keymap_read(&km, "gone=Ctrl+W", "zz=gone")
	ui.keymap_use(&f.s, &km)
	r := Tabs_Run{commands = TABS[:]}
	frame(&f, {key(.W, {.Ctrl})}, build_tabs, &r)
	testing.expect(t, r.pressed[1], "Ctrl+W still closes the tab")
	ui.use(&f.s)
	testing.expect_value(t, ui.command_shortcut(TABS[1]), "Ctrl+W")
	testing.expect_value(t, ui.keymap_alias_command(&km, "zz"), "")
	custom, aliases := ui.keymap_texts(&km)
	testing.expect(t, custom == "gone=Ctrl+W" && aliases == "zz=gone", "kept in the texts")

	// a mode whose table has the id: its key acts from now on
	mode := [?]ui.Command{{id = "gone", label = "Gone", keys = {{.G, {.Ctrl}}}}}
	ui.keymap_known(&km, mode[:])
	both := [?]ui.Command{TABS[0], TABS[1], mode[0]}
	r.commands = both[:]
	frame(&f, {key(.W, {.Ctrl})}, build_tabs, &r)
	testing.expect(t, !r.pressed[1] && r.pressed[2], "Ctrl+W is the known command's")
	ui.use(&f.s)
	testing.expect_value(t, ui.command_shortcut(TABS[1]), "Ctrl+F4")
	testing.expect_value(t, ui.keymap_alias_command(&km, " ZZ "), "gone")
}

////////////////////////////////
// The palette

@(private = "file")
NEW_COMMANDS := [?]ui.Command{
	{id = "notes", label = "Notes", group = "File"},
	{id = "new_folder", label = "New folder", group = "File"},
	{id = "open", label = "Open", group = "File", keys = {{.O, {.Ctrl}}}},
}

@(private = "file")
Run :: struct {
	pal:     ui.Command_Palette,
	keymap:  ^ui.Keymap,
	open_now: bool,
	typed:   string,
	chosen:  ui.Palette_Choice,
	choices: int,
	saved:   [2]string,   // what the keymap's `changed` was given last (owned: run_free)
}

@(private = "file")
run_free :: proc(r: ^Run) {
	ui.palette_destroy(&r.pal)
	delete(r.saved[0])
	delete(r.saved[1])
}

@(private = "file")
run_build :: proc(user: rawptr) {
	r := (^Run)(user)
	ui.palette_commands(&r.pal, NEW_COMMANDS[:], nil)
	_ = ui.palette_keys(&r.pal)
	if r.open_now { r.open_now = false; ui.palette_open(&r.pal, r.typed) }
	if c, ok := ui.palette_chosen(&r.pal); ok { r.chosen, r.choices = c, r.choices + 1 }
}

// Frames until no ranking is in flight, then one more: the view shows the list.
@(private = "file")
settle :: proc(t: ^testing.T, f: ^Fx, r: ^Run, loc := #caller_location) {
	start := time.tick_now()
	for {
		frame(f, nil, run_build, r)
		if r.pal.pending == 0 { break }
		if time.tick_since(start) > SETTLE_BOUND { testing.fail_now(t, "the palette's ranking did not come", loc) }
	}
	frame(f, nil, run_build, r)
}

@(private = "file")
open_palette :: proc(t: ^testing.T, f: ^Fx, r: ^Run, typed := "", loc := #caller_location) {
	r.open_now, r.typed = true, typed
	settle(t, f, r, loc)
}

@(private = "file")
row_id :: proc(r: ^Run, i: int) -> string {
	_, id, _ := ui.palette_row(&r.pal, i)
	return id
}

@(private = "file")
palette_is_open :: proc(f: ^Fx, r: ^Run) -> bool {
	ui.use(&f.s)
	return ui.palette_is_open(&r.pal)
}

@(private = "file")
recorder_is_open :: proc(f: ^Fx, r: ^Run) -> bool {
	ui.use(&f.s)
	return ui.view_is_open(ui.state_views(&f.s), ui.KEYMAP_RECORDER_VIEW, fmt.tprintf("%x", uintptr(&r.pal)))
}

@(private = "file")
palette_keymap :: proc(r: ^Run, km: ^ui.Keymap) {
	km.user = r
	km.changed = proc(user: rawptr, custom, aliases: string) {
		r := (^Run)(user)
		delete(r.saved[0])
		delete(r.saved[1])
		r.saved = {strings.clone(custom), strings.clone(aliases)}
	}
	r.keymap = km
}

// An alias in the palette: typed whole, its command first, under `>` too; its first letters find it as a tag. Alt+Enter
// makes the letters typed an alias of the chosen command, and the palette opens again with them; the program sees no
// choice.
@(test)
aliases_in_the_palette :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	km: ui.Keymap
	defer ui.keymap_destroy(&km)
	ui.keymap_known(&km, NEW_COMMANDS[:])
	ui.keymap_alias(&km, "zq", "open")
	ui.keymap_use(&f.s, &km)
	r: Run
	defer run_free(&r)
	palette_keymap(&r, &km)
	open_palette(t, &f, &r, "zq")
	testing.expect_value(t, row_id(&r, 0), "open")
	frame(&f, {key(.Escape)}, run_build, &r)
	frame(&f, nil, run_build, &r)
	open_palette(t, &f, &r, ">zq")
	testing.expect_value(t, row_id(&r, 0), "open")
	frame(&f, {key(.Escape)}, run_build, &r)
	frame(&f, nil, run_build, &r)
	open_palette(t, &f, &r, "z")
	testing.expect_value(t, row_id(&r, 0), "open")   // (its alias, a tag: nothing else holds a z)
	frame(&f, {key(.Escape)}, run_build, &r)
	frame(&f, nil, run_build, &r)

	// Alt+Enter on Notes, "note" typed
	open_palette(t, &f, &r, "note")
	testing.expect_value(t, row_id(&r, 0), "notes")
	frame(&f, {key(.Return, {.Alt})}, run_build, &r)
	settle(t, &f, &r)
	testing.expect_value(t, ui.keymap_alias_command(&km, "note"), "notes")
	testing.expect_value(t, r.saved[1], "note=notes;zq=open")
	testing.expect(t, palette_is_open(&f, &r), "the palette opens again")
	testing.expect_value(t, ui.line_edit_string(&r.pal.field), "note")
	testing.expect_value(t, r.choices, 0)
}

// Ctrl+Enter on a command: the recorder takes any chord (Ctrl+K too: a value here, not the palette), two for a sequence;
// Enter keeps them, and the palette opens again with its text. Backspace first gives the command its own keys again.
@(test)
the_recorder_sets_a_key :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	km: ui.Keymap
	defer ui.keymap_destroy(&km)
	ui.keymap_known(&km, NEW_COMMANDS[:])
	ui.keymap_use(&f.s, &km)
	r: Run
	defer run_free(&r)
	palette_keymap(&r, &km)
	open_palette(t, &f, &r, "open")
	testing.expect(t, find_text(&f.s, "Ctrl+O") != nil, "its own key on its row")
	frame(&f, {key(.Return, {.Ctrl})}, run_build, &r)
	for _ in 0 ..< 4 { frame(&f, nil, run_build, &r) }
	testing.expect(t, recorder_is_open(&f, &r), "the recorder is open")
	testing.expect(t, !palette_is_open(&f, &r), "the palette closed")
	testing.expect_value(t, r.choices, 0)
	frame(&f, {key(.M, {.Ctrl})}, run_build, &r)
	frame(&f, {key(.K, {.Ctrl})}, run_build, &r)
	frame(&f, nil, run_build, &r)
	testing.expect(t, !palette_is_open(&f, &r), "Ctrl+K is recorded, it does not open the palette")
	testing.expect(t, find_text(&f.s, "Ctrl+M, Ctrl+K") != nil, "the keys pressed show")
	frame(&f, {key(.Return)}, run_build, &r)
	for _ in 0 ..< 3 { frame(&f, nil, run_build, &r) }
	testing.expect(t, !recorder_is_open(&f, &r), "Enter keeps them")
	testing.expect_value(t, r.saved[0], "open=Ctrl+M, Ctrl+K")
	settle(t, &f, &r)
	testing.expect(t, palette_is_open(&f, &r), "the palette opens again")
	testing.expect_value(t, ui.line_edit_string(&r.pal.field), "open")
	testing.expect(t, find_text(&f.s, "Ctrl+M, Ctrl+K") != nil, "the row shows the person's key")
	ui.use(&f.s)
	testing.expect_value(t, ui.command_shortcut(NEW_COMMANDS[2]), "Ctrl+M, Ctrl+K")

	// Backspace first: its own keys again
	frame(&f, {key(.Return, {.Ctrl})}, run_build, &r)
	for _ in 0 ..< 4 { frame(&f, nil, run_build, &r) }
	testing.expect(t, recorder_is_open(&f, &r), "the recorder again")
	frame(&f, {key(.Backspace)}, run_build, &r)
	for _ in 0 ..< 3 { frame(&f, nil, run_build, &r) }
	testing.expect_value(t, r.saved[0], "")
	ui.use(&f.s)
	testing.expect_value(t, ui.command_shortcut(NEW_COMMANDS[2]), "Ctrl+O")
}
