// The commands of a program (ui/commands.odin): their keys' texts, their keys, the palette and the sheet of the keys.
// Synthetic input events and builds, without a window; the ui state of a build is global: one test thread.
//   odin run tools/run_tests -- commands   (on Linux it needs the native text backend: tools/tk build_text)
package commands_test

import "core:slice"
import "core:testing"
import "../../src/font"
import lucide "../../src/lucide"
import "../../src/platform"
import "../../src/ui"

WINDOW :: ui.Vec2{800, 600}

Fx :: struct {
	fonts: font.State,
	theme: ui.Theme,
	s:     ui.State,
	base_font: font.Font_Id,
}

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
frame :: proc(f: ^Fx, events: []platform.Event, body: proc(f: ^Fx, user: rawptr), user: rawptr) {
	ui.begin_build(&f.s, {
		window_size = WINDOW, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
	})
	body(f, user)
	ui.end_build()
	free_all(context.temp_allocator)
}

@(private = "file")
key :: proc(k: platform.Key, mods: platform.Modifiers = {}) -> platform.Event { return {kind = .Key_Press, key = k, mods = mods} }

@(private = "file")
typed :: proc(r: rune) -> platform.Event { return {kind = .Text, text = r} }

@(private = "file")
PALETTE_COMMANDS := [?]ui.Command{
	{label = "End task", group = "Processes", keys = {{.Delete, {}}, {}}},
	{label = "Kill…", group = "Processes", keys = {{.Delete, {.Shift}}, {}}, tags = {"terminate", "force"}},
	{label = "Start", group = "Services", keys = {{.S, {.Ctrl}}, {}}},
	{label = "Command palette", group = "Window", keys = {{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}}},
}

Palette_Run :: struct {
	pal:     ui.Command_Palette,
	enabled: [len(PALETTE_COMMANDS)]bool,
	chosen:  int,
	mods:    platform.Modifiers,
	pressed: [len(PALETTE_COMMANDS)]bool,
	opts:    ui.Palette_Options,
}

@(private = "file")
build_palette :: proc(f: ^Fx, user: rawptr) {
	r := (^Palette_Run)(user)
	if i, _ := ui.palette(&r.pal, PALETTE_COMMANDS[:], r.enabled[:], r.opts); i >= 0 { r.chosen, r.mods = i, r.pal.chosen_mods }
}

@(private = "file")
build_command_keys :: proc(f: ^Fx, user: rawptr) {
	r := (^Palette_Run)(user)
	for c, i in PALETTE_COMMANDS { r.pressed[i] = ui.command_pressed(c, r.enabled[i]) }
}

@(test)
command_texts :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.chord_text({.P, {.Ctrl, .Shift}}), "Ctrl+Shift+P")
	testing.expect_value(t, ui.chord_text({.Delete, {.Shift}}), "Shift+Delete")
	testing.expect_value(t, ui.chord_text({.F5, {}}), "F5")
	testing.expect_value(t, ui.chord_text({.N3, {.Ctrl}}), "Ctrl+3")
	testing.expect_value(t, ui.chord_text({.Return, {.Alt}}), "Alt+Enter")
	testing.expect_value(t, ui.chord_text({.Escape, {}}), "Escape")
	testing.expect_value(t, ui.chord_text({}), "")
	testing.expect_value(t, ui.command_shortcut(PALETTE_COMMANDS[1]), "Shift+Delete")
	testing.expect_value(t, ui.command_keys_text(PALETTE_COMMANDS[3]), "Ctrl+K, Ctrl+Shift+P")
	testing.expect_value(t, ui.command_tip(PALETTE_COMMANDS[1]), "Kill… (Shift+Delete)")
	testing.expect_value(t, ui.command_tip({label = "Open"}), "Open")
}

@(test)
command_keys_and_palette :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Palette_Run{chosen = -1}
	defer ui.palette_destroy(&r.pal)
	r.enabled = {true, true, false, true}

	// a command's keys, and only when it can act
	frame(&f, {key(.Delete, {.Shift})}, build_command_keys, &r)
	testing.expect(t, !r.pressed[0] && r.pressed[1], "Shift+Delete is Kill's, not End task's")
	frame(&f, {key(.P, {.Ctrl, .Shift})}, build_command_keys, &r)
	testing.expect(t, r.pressed[3], "a command's second key")
	frame(&f, {key(.S, {.Ctrl})}, build_command_keys, &r)
	testing.expect(t, !r.pressed[2], "a command that cannot act takes no key")

	// the palette: typed letters keep the matches, Enter runs the first one that can act
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.palette_open(&(^Palette_Run)(user).pal) }, &r)
	frame(&f, nil, build_palette, &r)
	frame(&f, nil, build_palette, &r)
	panel := ui.box_from_key(ui.key_from_string(f.s.root.key, "###modal_palette"))
	testing.expect(t, panel != nil, "the palette is laid out")
	if panel != nil { testing.expect(t, abs((panel.rect.min.x + panel.rect.max.x) * 0.5 - WINDOW.x * 0.5) < 2, "at the window's centre") }
	testing.expect_value(t, r.pal.sel, 0)
	for c in "kil" { frame(&f, {typed(c)}, build_palette, &r) }
	frame(&f, nil, build_palette, &r)
	frame(&f, {key(.Return)}, build_palette, &r)
	testing.expect_value(t, r.chosen, 1)
	testing.expect(t, !r.pal.open, "choosing closes the palette")

	// a word the label does not say: its tags
	r.chosen = -1
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.palette_open(&(^Palette_Run)(user).pal) }, &r)
	frame(&f, nil, build_palette, &r)
	for c in "termin" { frame(&f, {typed(c)}, build_palette, &r) }
	frame(&f, nil, build_palette, &r)
	frame(&f, {key(.Return)}, build_palette, &r)
	testing.expect_value(t, r.chosen, 1)

	// the best match first: "c" is in the group of End task, Kill and Start (Processes, Services), and at the start of
	// Command palette's label: Command palette comes first, though it is last in the table
	r.chosen = -1
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.palette_open(&(^Palette_Run)(user).pal) }, &r)
	frame(&f, nil, build_palette, &r)
	frame(&f, {typed('c')}, build_palette, &r)
	frame(&f, nil, build_palette, &r)
	frame(&f, {key(.Return)}, build_palette, &r)
	testing.expect_value(t, r.chosen, 3)

	// what cannot act is not chosen: "start" matches only Start, which is greyed
	r.chosen = -1
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.palette_open(&(^Palette_Run)(user).pal) }, &r)
	frame(&f, nil, build_palette, &r)
	for c in "start" { frame(&f, {typed(c)}, build_palette, &r) }
	frame(&f, nil, build_palette, &r)
	frame(&f, {key(.Return)}, build_palette, &r)
	testing.expect_value(t, r.chosen, -1)
	frame(&f, {key(.Escape)}, build_palette, &r)
	frame(&f, nil, build_palette, &r)   // (a dialog takes Escape at the end of a build: it closes at the next)
	testing.expect(t, !r.pal.open, "Escape closes it")

	// a search that keeps nothing: the palette says so, and goes on
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.palette_open(&(^Palette_Run)(user).pal) }, &r)
	frame(&f, nil, build_palette, &r)
	for c in "zzqx" { frame(&f, {typed(c)}, build_palette, &r) }
	frame(&f, nil, build_palette, &r)
	frame(&f, {key(.Down)}, build_palette, &r)
	frame(&f, {key(.Return)}, build_palette, &r)
	testing.expect_value(t, r.chosen, -1)
	frame(&f, {key(.Escape)}, build_palette, &r)
	frame(&f, nil, build_palette, &r)

	// a size of the user's: the palette opens at it
	r.pal.size = {500, 300}
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.palette_open(&(^Palette_Run)(user).pal) }, &r)
	frame(&f, nil, build_palette, &r)
	frame(&f, nil, build_palette, &r)
	panel = ui.box_from_key(ui.key_from_string(f.s.root.key, "###modal_palette"))
	if testing.expect(t, panel != nil) { testing.expect_value(t, panel.rect.max.x - panel.rect.min.x, f32(500)) }
}

Sheet_Run :: struct { open: bool }

@(test)
shortcuts_sheet_lists_the_keys :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Sheet_Run{open = true}
	sheet :: proc(f: ^Fx, user: rawptr) { ui.shortcuts_sheet("keys", PALETTE_COMMANDS[:], &(^Sheet_Run)(user).open) }
	frame(&f, nil, sheet, &r)
	frame(&f, nil, sheet, &r)
	found := 0
	for _, b in f.s.boxes {
		if b == nil || b.last_build != f.s.build_index { continue }
		text := ui.box_text(b)
		if text == "Ctrl+K, Ctrl+Shift+P" || text == "Shift+Delete" { found += 1 }
	}
	testing.expect_value(t, found, 2)
	frame(&f, {key(.Escape)}, sheet, &r)
	frame(&f, nil, sheet, &r)   // (a dialog takes Escape at the end of a build: it closes at the next)
	testing.expect(t, !r.open, "Escape closes it")
}

// The palette's matching: the needle whole, or pieces that begin words; never letters scattered in a word.
@(test)
fuzzy_words_whole_or_at_words_starts :: proc(t: ^testing.T) {
	// whole: anywhere, at a word's start ranked above
	whole, ranges, ok := ui.fuzzy_words("prio", "Raise the priority")
	testing.expect(t, ok && len(ranges) == 1 && ranges[0] == {10, 14}, "whole, at its word")
	// pieces at words' starts, the words in order
	pieces, _, ok2 := ui.fuzzy_words("ks", "Keyboard shortcuts")
	testing.expect(t, ok2, "the words' first letters")
	testing.expect(t, whole > pieces, "the needle whole before pieces")
	_, ranges, ok = ui.fuzzy_words("endt", "End task")
	testing.expect(t, ok && len(ranges) == 2 && ranges[0] == {0, 3} && ranges[1] == {4, 5}, "a word's start, then the next word's")
	_, ranges, ok = ui.fuzzy_words("cp", "CommandPalette")
	testing.expect(t, ok && len(ranges) == 2, "a capital after a small letter begins a word")
	// letters scattered in a word: no match
	_, _, ok = ui.fuzzy_words("prio", "Previous section")
	testing.expect(t, !ok, "scattered letters do not match")
	_, _, ok = ui.fuzzy_words("sk", "Keyboard shortcuts")
	testing.expect(t, !ok, "the words out of order")
	// the start of the text ranks above a word's start; a shorter text above a longer one
	a, _, _ := ui.fuzzy_words("kill", "Kill…")
	b, _, _ := ui.fuzzy_words("kill", "Socket kill")
	testing.expect(t, a > b, "the start of the text first")
	// (the longest piece first, then shorter ones: "abc" in "ab x abc" is whole)
	_, ranges, ok = ui.fuzzy_words("abc", "ab-x abc")
	testing.expect(t, ok && len(ranges) == 1 && ranges[0] == {5, 8}, "whole when it is there")
	_, ranges, ok = ui.fuzzy_words("abx", "ab-x")
	testing.expect(t, ok && len(ranges) == 2, "pieces after a shorter first piece")
	s, r, ok3 := ui.fuzzy_words(" ", "anything")
	testing.expect(t, ok3 && s == 0 && r == nil, "an empty needle matches everything")
}

// The widgets' marks come from the toolkit's own icon font, whatever icon font the program sets (Lucide here): a menu's
// check is ICON_CHECK of widget_icons, not a "V" of the program's font.
@(test)
the_widgets_marks_are_the_toolkits :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	lucide_font, ok := font.load_embedded(&f.fonts, lucide.DATA)
	if !testing.expect(t, ok, "Lucide loads") { return }
	f.s.icon_font = lucide_font
	key := ui.Key(0x5e1ec7)
	build :: proc(f: ^Fx, user: rawptr) {
		key := (^ui.Key)(user)^
		if ui.ctx_menu(key) { ui.menu_item("Kept", checked = true) }
	}
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.ctx_menu_open((^ui.Key)(user)^, {10, 10}) }, &key)
	frame(&f, nil, build, &key)
	frame(&f, nil, build, &key)
	marks := ui.widget_icons()
	testing.expect(t, marks != 0 && marks != lucide_font, "a font of its own")
	found := false
	for _, b in f.s.boxes {
		if b == nil || b.last_build != f.s.build_index || ui.box_text(b) != ui.ICON_CHECK { continue }
		found = true
		testing.expect(t, b.font == marks, "the check is drawn in the toolkit's icon font")
	}
	testing.expect(t, found, "the checked item has its mark")
}

// Each word of a query where it is, in any case, every place, merged where they touch; a phrase as one.
@(test)
the_words_of_a_query_in_a_line :: proc(t: ^testing.T) {
	testing.expect(t, slice.equal(ui.word_ranges("Keep a Cache of the cached", "cache"), []ui.Fuzzy_Range{{7, 12}, {20, 25}}))
	testing.expect(t, slice.equal(ui.word_ranges("Max body size", "body max"), []ui.Fuzzy_Range{{0, 3}, {4, 8}}))
	testing.expect(t, slice.equal(ui.word_ranges("ab", "a b"), []ui.Fuzzy_Range{{0, 2}}), "touching: one")
	testing.expect(t, slice.equal(ui.word_ranges("Session 12 and Session 2", `"session 2"`), []ui.Fuzzy_Range{{15, 24}}), "a phrase")
	testing.expect_value(t, len(ui.word_ranges("text", "")), 0)
}

@(private = "file")
nothing :: proc(f: ^Fx, user: rawptr) {}

// A key held: from its press to its release, by its own events; none once the user left the window.
@(test)
a_key_is_held_from_its_press_to_its_release :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f)) { return }
	defer close(&f)
	frame(&f, {}, nothing, nil)
	testing.expect(t, !ui.key_held(.Ctrl), "nothing held at first")
	frame(&f, {key(.Ctrl)}, nothing, nil)
	testing.expect(t, ui.key_held(.Ctrl), "Ctrl pressed: held")
	frame(&f, {}, nothing, nil)
	testing.expect(t, ui.key_held(.Ctrl), "still held, with no event")
	frame(&f, {{kind = .Key_Release, key = .Ctrl, mods = {.Ctrl}}}, nothing, nil)
	testing.expect(t, !ui.key_held(.Ctrl), "released, though its event says Ctrl (the modifiers' state before it)")
	frame(&f, {key(.Ctrl)}, nothing, nil)
	frame(&f, {{kind = .Frame_Press}}, nothing, nil)
	testing.expect(t, !ui.key_held(.Ctrl), "the window left: none held")
}

// A program's additions: the recent commands on top under their heading, a command first while searching, the keys'
// texts of its own, a foot line, Enter with a modifier.
@(test)
palette_options :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Palette_Run{chosen = -1}
	defer ui.palette_destroy(&r.pal)
	r.enabled = {true, true, true, true}
	recent := []int{2}
	keys := []string{"", "", "Ctrl+M, T", ""}
	r.opts = {recent = recent, keys = keys, foot = "Enter: run   Ctrl+Enter: its keys"}
	// nothing typed: the recent one first, selected; Enter runs it
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.palette_open(&(^Palette_Run)(user).pal) }, &r)
	frame(&f, nil, build_palette, &r)
	frame(&f, nil, build_palette, &r)
	testing.expect(t, find_text(&f, "Recent") != nil, "the recent group's heading")
	testing.expect(t, find_text(&f, "Ctrl+M, T") != nil, "the program's text of the keys")
	testing.expect(t, find_text(&f, "Ctrl+S") == nil, "instead of its chord")
	testing.expect(t, find_text(&f, "Enter: run   Ctrl+Enter: its keys") != nil, "the foot line")
	frame(&f, {key(.Return)}, build_palette, &r)
	testing.expect_value(t, r.chosen, 2)
	testing.expect_value(t, r.mods, platform.Modifiers{})
	// letters typed: `first` before the best match; Ctrl+Enter chooses it with Ctrl
	r.chosen = -1
	r.opts.first = 0
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.palette_open(&(^Palette_Run)(user).pal) }, &r)
	frame(&f, nil, build_palette, &r)
	for c in "ki" { frame(&f, {typed(c)}, build_palette, &r) }
	frame(&f, nil, build_palette, &r)
	frame(&f, {key(.Return, {.Ctrl})}, build_palette, &r)
	testing.expect_value(t, r.chosen, 0)
	testing.expect_value(t, r.mods, platform.Modifiers{.Ctrl})
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

// A word typed with a slip still finds its word: a letter for another, one missing, two swapped; its beginning too. Too many
// slips for its length find nothing, and two words of the needle are two words of the text.
@(test)
fuzzy_typos_forgive_a_slip :: proc(t: ^testing.T) {
	score, ranges, ok := ui.fuzzy_typos("Qestart pencode native", "Restart opencode native")
	testing.expect(t, ok, "a letter for another, one missing")
	testing.expect_value(t, len(ranges), 3)
	if len(ranges) == 3 {
		testing.expect_value(t, ranges[0], ui.Fuzzy_Range{0, 7})
		testing.expect_value(t, ranges[1], ui.Fuzzy_Range{8, 16})
	}
	exact, _, _ := ui.fuzzy_typos("restart opencode", "Restart opencode native")
	testing.expect(t, exact > score, "no slip ranks higher")
	_, _, swapped := ui.fuzzy_typos("rsetart", "Restart opencode native")
	testing.expect(t, swapped, "two letters swapped")
	_, _, begun := ui.fuzzy_typos("restr", "Restart opencode native")
	testing.expect(t, begun, "a word's beginning, with a slip")
	_, _, prio := ui.fuzzy_typos("prio", "Previous section")
	testing.expect(t, !prio, "two slips in four letters: no")
	_, _, short := ui.fuzzy_typos("qui", "Quit")
	testing.expect(t, short, "a short word, whole at its beginning")
	_, _, short_slip := ui.fuzzy_typos("qit", "Quit")
	testing.expect(t, !short_slip, "a short word has no slip")
	_, _, twice := ui.fuzzy_typos("open open", "Restart opencode native")
	testing.expect(t, !twice, "two words of the needle, two words of the text")
}
