// The commands of a program (ui/commands.odin): their keys' texts, their keys, the palette and the sheet of the keys.
// Synthetic input events and builds, without a window; the ui state of a build is global: one test thread.
//   odin run tools/run_tests -- commands   (on Linux it needs the native text backend: tools/tk build_text)
package commands_test

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:mem"
import "core:testing"
import "core:time"
import "gt:font"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"

WINDOW :: ui.Vec2{800, 600}
// How long a test waits at most for the palette's ranking, on the chores.
SETTLE_BOUND :: 5 * time.Second

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
	{label = "End task", group = "Processes", keys = {{.Delete, {}}}},
	{label = "Kill…", group = "Processes", keys = {{.Delete, {.Shift}}}, tags = {"terminate", "force"}},
	{label = "Start", group = "Services", keys = {{.S, {.Ctrl}}}},
	{label = "Command palette", group = "Window", keys = {{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}}},
}

@(private = "file")
Keys_Pressed :: struct {
	disabled: [len(PALETTE_COMMANDS)]bool,
	pressed:  [len(PALETTE_COMMANDS)]bool,
}

@(private = "file")
build_command_keys :: proc(f: ^Fx, user: rawptr) {
	r := (^Keys_Pressed)(user)
	for c, i in PALETTE_COMMANDS { r.pressed[i] = ui.command_pressed(c, r.disabled[i]) }
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
	testing.expect_value(t, ui.key_tip("Settings", {.Comma, {.Ctrl}}), "Settings (Ctrl+,)")
	testing.expect_value(t, ui.key_tip("Open the folder", {}), "Open the folder")
}

// A command's keys, and only when it can act. (The palette's tests: palette_test.odin.)
@(test)
command_keys :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Keys_Pressed
	r.disabled = {false, false, true, false}
	frame(&f, {key(.Delete, {.Shift})}, build_command_keys, &r)
	testing.expect(t, !r.pressed[0] && r.pressed[1], "Shift+Delete is Kill's, not End task's")
	frame(&f, {key(.P, {.Ctrl, .Shift})}, build_command_keys, &r)
	testing.expect(t, r.pressed[3], "a command's second key")
	frame(&f, {key(.S, {.Ctrl})}, build_command_keys, &r)
	testing.expect(t, !r.pressed[2], "a command that cannot act takes no key")
}

Sheet_Run :: struct { sheet: ui.Shortcuts_Sheet, opened: bool }

@(test)
shortcuts_sheet_lists_the_keys :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Sheet_Run
	defer ui.shortcuts_sheet_destroy(&r.sheet)
	sheet :: proc(f: ^Fx, user: rawptr) {
		r := (^Sheet_Run)(user)
		// (the table without the palette's line: the sheet adds the toolkit's command itself)
		if !r.opened { r.opened = true; ui.shortcuts_sheet_open(&r.sheet, PALETTE_COMMANDS[:3]) }
	}
	frame(&f, nil, sheet, &r)
	frame(&f, nil, sheet, &r)
	found, palettes := 0, 0
	for _, b in f.s.boxes {
		if b == nil || b.last_build != f.s.build_index { continue }
		text := ui.box_text(b)
		if text == "Ctrl+K, Ctrl+Shift+P" || text == "Shift+Delete" { found += 1 }
		if text == "Command palette" { palettes += 1 }
	}
	testing.expect_value(t, found, 2)
	testing.expect_value(t, palettes, 1)   // (once: the toolkit's line)
	frame(&f, {key(.Escape)}, sheet, &r)
	frame(&f, nil, sheet, &r)   // (a dialog takes Escape at the end of a build: it closes at the next)
	testing.expect(t, !ui.shortcuts_sheet_is_open(&r.sheet), "Escape closes it")
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
	key := "kept_menu"
	build :: proc(f: ^Fx, user: rawptr) {
		key := (^string)(user)^
		if ui.menu(key) { ui.menu_item("Kept", checked = true) }
	}
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.menu_open((^string)(user)^, ui.Vec2{10, 10}) }, &key)
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

// The search for slips runs on every item the exact search left, at each search of a palette: a text it does not find costs
// no allocation, one it finds only its ranges; a range ends where the word's letters do, accents and all.
@(test)
fuzzy_typos_allocate_only_what_they_find :: proc(t: ^testing.T) {
	needle := ui.fuzzy_needle("frmae pacnig", context.allocator)
	defer free_all(context.temp_allocator)
	miss := ui.fuzzy_text("Restart opencode native and its server", context.allocator)
	hit := ui.fuzzy_text("Frame pacing of the window", context.allocator)
	accented := ui.fuzzy_text("Réglages du thème", context.allocator)
	needle_accented := ui.fuzzy_needle("thme", context.allocator)
	defer { delete(needle.words); delete(needle.word_runes); delete(miss.low); delete(hit.low); delete(accented.low); delete(needle_accented.words); delete(needle_accented.word_runes) }
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.temp_allocator = mem.tracking_allocator(&track)
		_, _, ok := ui.fuzzy_typos(needle, miss, context.allocator)
		testing.expect(t, !ok, "not there")
		testing.expect_value(t, track.total_allocation_count, 0)
		_, ranges, found := ui.fuzzy_typos(needle, hit, context.allocator)
		testing.expect(t, found, "two words, a slip each")
		testing.expect_value(t, track.total_allocation_count, 1)
		if testing.expect_value(t, len(ranges), 2) {
			testing.expect_value(t, ranges[0], ui.Fuzzy_Range{0, 5})
			testing.expect_value(t, ranges[1], ui.Fuzzy_Range{6, 12})
		}
		_, theme, in_theme := ui.fuzzy_typos(needle_accented, accented, context.allocator)
		testing.expect(t, in_theme, "a letter missing")
		if testing.expect_value(t, len(theme), 1) { testing.expect_value(t, theme[0], ui.Fuzzy_Range{13, 19}) }
		free_all(context.allocator)
	}
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

// One entry of a palette: its label first, then its tags, then its group, then with slips; what lights is in the label.
@(test)
a_palette_entry_is_found_by_its_label_its_tags_or_a_slip :: proc(t: ^testing.T) {
	tags := []string{"exit", "close"}
	label, _, ok := ui.palette_match("quit", "Quit", "General", tags)
	testing.expect(t, ok, "its label")
	tag, tr, ok2 := ui.palette_match("exit", "Quit", "General", tags)
	testing.expect(t, ok2 && tr == nil, "its tags, nothing lit")
	testing.expect(t, label > tag, "the label before its tags")
	slip, sr, ok3 := ui.palette_match("Qestart pencode", "Restart opencode native", "General", nil)
	testing.expect(t, ok3 && len(sr) == 2, "a slip, the words lit")
	testing.expect(t, tag > slip, "an exact match before a slip")
	_, _, none := ui.palette_match("zebra", "Quit", "General", tags)
	testing.expect(t, !none, "nothing")
}

// A ranked list: the hits alone, the best first, equal scores in the list's order; a skipped item never; the last text finds
// what nothing else does, lighting nothing; a bonus lifts a hit; an empty query keeps the list as it is.
@(test)
a_list_is_ranked_best_first :: proc(t: ^testing.T) {
	Item :: struct { label, key: string, skip: bool, boost: f64 }
	items := []Item{
		{label = "Previous section"},
		{label = "Raise the priority"},
		{label = "Priority", skip = true},
		{label = "System title", key = "appearance.prio"},
		{label = "Lower the priority"},
	}
	entry :: proc(it: ^Item, _: rawptr) -> ui.Rank_Entry { return {label = it.label, last = it.key, skip = it.skip} }
	index :: proc(hits: []ui.Rank_Hit) -> []int {
		out := make([]int, len(hits), context.temp_allocator)
		for h, i in hits { out[i] = h.index }
		return out
	}
	hits := ui.rank("prio", items, entry)
	testing.expect(t, slice.equal(index(hits), []int{1, 4, 3}), "the label's hits in order, then the key's")
	testing.expect(t, len(hits) == 3 && hits[2].ranges == nil && len(hits[0].ranges) > 0, "the key lights nothing")
	testing.expect(t, hits[0].score == hits[1].score, "equal scores keep the list's order")
	items[4].boost = 1
	boosted := ui.rank("prio", items, entry, bonus = proc(it: ^Item, _: rawptr) -> f64 { return it.boost })
	testing.expect(t, slice.equal(index(boosted), []int{4, 1, 3}), "a bonus lifts a hit")
	testing.expect(t, slice.equal(index(ui.rank("", items, entry)), []int{0, 1, 3, 4}), "an empty query: every item but the skipped one, in order")
	fuzzy := ui.rank("cs5", []Item{{label = "gpt-5"}, {label = "claude-sonnet-5"}}, entry, match = ui.rank_fuzzy)
	testing.expect(t, slice.equal(index(fuzzy), []int{1}), "rank_fuzzy: letters scattered")
	Model :: struct { name, provider: string }
	models := []Model{{"claude", "Anthropic"}, {"gpt", "OpenAI"}}
	by_group := ui.rank("anth", models, proc(m: ^Model, _: rawptr) -> ui.Rank_Entry { return {label = m.name, group = m.provider} }, match = ui.rank_fuzzy)
	testing.expect(t, slice.equal(index(by_group), []int{0}), "rank_fuzzy reads the group after the label")
}

// A list ranked each frame with a cache: what did not change is not folded again, what changed is, and a shorter list
// lets go of the slots it no longer uses; the hits are those of a rank without a cache.
@(test)
a_ranked_list_folds_once :: proc(t: ^testing.T) {
	Item :: struct { label: string }
	entry :: proc(it: ^Item, _: rawptr) -> ui.Rank_Entry { return {label = it.label} }
	index :: proc(hits: []ui.Rank_Hit) -> []int {
		out := make([]int, len(hits), context.temp_allocator)
		for h, i in hits { out[i] = h.index }
		return out
	}
	cache: ui.Fuzzy_Cache
	defer ui.fuzzy_cache_destroy(&cache)
	items := []Item{{"Fork the session"}, {"Rename the session"}, {"Quit"}}
	first := ui.rank("ses", items, entry, cache = &cache)
	testing.expect(t, slice.equal(index(first), index(ui.rank("ses", items, entry))), "the same hits as without a cache")
	folded := raw_data(cache.texts[0].low)
	// (the same texts again, in other strings: the frame builds its list anew)
	again := []Item{{strings.clone("Fork the session", context.temp_allocator)}, {"Rename the session"}, {"Quit"}}
	testing.expect(t, slice.equal(index(ui.rank("sess", again, entry, cache = &cache)), []int{0, 1}), "a new query, the same hits")
	testing.expect(t, raw_data(cache.texts[0].low) == folded, "a text that did not change is not folded again")
	again[0].label = "Quit the session"
	testing.expect(t, slice.contains(index(ui.rank("quit", again, entry, cache = &cache)), 0), "a changed text is folded again")
	ui.rank("quit", again[:1], entry, cache = &cache)
	testing.expect(t, len(cache.texts) <= 4, "a shorter list lets go of the slots it no longer uses")
}

// A list ranked at each frame while neither its query nor its items change (a palette at rest) reads no item: the hits of the
// same query and version are kept, theirs to keep past the frame's memory; another version or query ranks again.
@(test)
rank_keeps_its_hits_while_nothing_changes :: proc(t: ^testing.T) {
	Item :: struct { label: string }
	items := []Item{{"Fork the session"}, {"Rename the session"}, {"Quit"}}
	reads := 0
	entry :: proc(it: ^Item, user: rawptr) -> ui.Rank_Entry { (^int)(user)^ += 1; return {label = it.label} }
	cache: ui.Fuzzy_Cache
	defer ui.fuzzy_cache_destroy(&cache)
	first := ui.rank("sesion", items, entry, &reads, cache = &cache, version = 7)
	testing.expect_value(t, len(first), 2)
	testing.expect_value(t, reads, 3)
	free_all(context.temp_allocator)
	kept := ui.rank("sesion", items, entry, &reads, cache = &cache, version = 7)
	testing.expect_value(t, reads, 3)
	if testing.expect_value(t, len(kept), 2) { testing.expect(t, len(kept[0].ranges) > 0 && kept[0].ranges[0][1] > kept[0].ranges[0][0], "their ranges kept too") }
	ui.rank("sesion", items, entry, &reads, cache = &cache, version = 8)
	testing.expect_value(t, reads, 6)
	ui.rank("quit", items, entry, &reads, cache = &cache, version = 8)
	testing.expect_value(t, reads, 9)
	ui.rank("quit", items, entry, &reads, cache = &cache)
	ui.rank("quit", items, entry, &reads, cache = &cache)
	testing.expect_value(t, reads, 15)   // (no version: ranked each time)
}

// A box's corners as drawn: its radius times the rounding (a custom draw's too: the palette's strip meets its dialog's
// corners), none in the edged finish, its own when it is part of its shape.
@(test)
a_box_is_drawn_with_the_rounding :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f)) { return }
	defer close(&f)
	ui.set_rounding(&f.s, 0.25)
	b := ui.Box{radius = 16}
	ui.use(&f.s)
	testing.expect_value(t, ui.box_drawn_radius(&f.s, &b), 4)
	b.radius = 10   // (2.5 px: a blob outside a 1 px edge's corner, not a curve)
	testing.expect_value(t, ui.box_drawn_radius(&f.s, &b), 0)
	b.flags += {.Fixed_Radius}
	testing.expect_value(t, ui.box_drawn_radius(&f.s, &b), 10)
}

// A box in a rounded corner of a box around it takes that corner (a title bar's background in a dialog's corner), also
// laid against that box's border; one that does not reach the corner keeps its own.
@(test)
a_box_takes_the_corner_it_fills :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f)) { return }
	defer close(&f)
	ui.use(&f.s)
	dialog := ui.Box{radius = 12, rect = {{0, 0}, {200, 100}}}
	column := ui.Box{rect = {{0, 0}, {200, 100}}, parent = &dialog}
	title := ui.Box{rect = {{0, 0}, {200, 30}}, parent = &column}
	radii := ui.box_drawn_radii(&f.s, &title)
	testing.expect(t, radii[int(ui.Corner.Top_Left)] == 12 && radii[int(ui.Corner.Top_Right)] == 12, "its top corners, the dialog's (through the column)")
	testing.expect(t, radii[int(ui.Corner.Bottom_Left)] == 0 && radii[int(ui.Corner.Bottom_Right)] == 0, "its bottom ones in the middle: its own")
	inner := ui.Box{rect = {{4, 4}, {196, 30}}, parent = &column}
	testing.expect_value(t, ui.box_drawn_radii(&f.s, &inner)[int(ui.Corner.Top_Left)], 0)

	// against a bordered box's border (a menu's search field): that corner, concentric, even over a rounding of its own
	menu := ui.Box{radius = 12, rect = {{0, 0}, {200, 300}}, flags = {.Draw_Border}}
	field := ui.Box{radius = 6, rect = {{1, 1}, {199, 36}}, parent = &menu}
	got := ui.box_drawn_radii(&f.s, &field)
	testing.expect(t, got[int(ui.Corner.Top_Left)] == 11 && got[int(ui.Corner.Top_Right)] == 11, "its top corners, the menu's less its border")
	testing.expect(t, got[int(ui.Corner.Bottom_Left)] == 6, "its bottom ones in the middle: its own")
	away := ui.Box{rect = {{4, 4}, {196, 36}}, parent = &menu}
	testing.expect_value(t, ui.box_drawn_radii(&f.s, &away)[int(ui.Corner.Top_Left)], 0)
}

// A text as wide as it measures (a tooltip's box) stays one line: its glyphs' advances added one by one, without their
// kerning, go past that width, and the last letter went to a line of its own.
@(test)
a_text_as_wide_as_it_measures_stays_one_line :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f)) { return }
	defer close(&f)
	ui.use(&f.s)
	for text in ([]string{"C:/code/project_0", "AVATAR WAVE To Yo", "Tyrannosaurus.", "LT. AVA TYPO"}) {
		w := font.text_width(&f.fonts, f.base_font, 15, text)
		lines := ui.wrap_lines(f.base_font, 15, text, w)
		testing.expectf(t, len(lines) == 1, "%q at its own width (%v): %d lines", text, w, len(lines))
	}
}

// A matched label in a row taller than its line sits where a label does, centred across: in a table's row the name the
// filter lit showed at the row's top while the label beside it was centred. Their "H", found, is on the same rows.
@(test)
a_matched_label_is_centred_as_a_label :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f)) { return }
	defer close(&f)
	body :: proc(f: ^Fx, user: rawptr) {
		ui.next({fixed_x = 10, fixed_y = 10, width = ui.px(300), height = ui.px(48), axis = .X, cross = .Center})
		if ui.row(id = "###r") {
			ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
			ui.label("Hp###l")
			ui.spacer(ui.px(20))
			ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
			ui.matched_label("###m", "Hp", {{1, 2}})
		}
		ui.find("H")
	}
	for _ in 0 ..< 3 { frame(&f, nil, body, nil) }
	ms := ui.find_matches()
	if !testing.expect_value(t, len(ms), 2) { return }
	a, b := ms[0].rect, ms[1].rect
	testing.expectf(t, a.min.x != b.min.x, "one in each (%v, %v)", a, b)
	testing.expectf(t, abs(a.min.y - b.min.y) <= 1 && abs(a.max.y - b.max.y) <= 1, "on the same rows: %v and %v", a, b)
}

// A command has as many keys as it needs (Reload: F5, Ctrl+R, Ctrl+Shift+R); a zero chord among them is none.
@(test)
a_command_has_any_number_of_keys :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	Run :: struct { pressed: [3]bool }
	r: Run
	reload := ui.Command{label = "Reload", keys = {{.F5, {}}, {.R, {.Ctrl}}, {.R, {.Ctrl, .Shift}}}}
	testing.expect_value(t, ui.command_keys_text(reload), "F5, Ctrl+R, Ctrl+Shift+R")
	testing.expect_value(t, ui.command_shortcut(reload), "F5")
	testing.expect_value(t, ui.command_shortcut({label = "Rename", keys = {{}, {.F2, {}}}}), "F2")
	testing.expect_value(t, ui.command_shortcut({label = "Open"}), "")
	presses := [3]platform.Event{key(.F5), key(.R, {.Ctrl}), key(.R, {.Ctrl, .Shift})}
	for e, i in presses {
		frame(&f, {e}, proc(f: ^Fx, user: rawptr) {
			c := ui.Command{label = "Reload", keys = {{.F5, {}}, {.R, {.Ctrl}}, {.R, {.Ctrl, .Shift}}}}
			r := (^Run)(user)
			for &p in r.pressed { if !p { p = ui.command_pressed(c); break } }
		}, &r)
		testing.expectf(t, r.pressed[i], "key %d of three", i)
	}
}

@(private = "file")
TYPING_COMMANDS := [?]ui.Command{
	{label = "Rectangle", keys = {{.R, {}}}},
	{label = "Add a step…", keys = {{.A, {.Shift}}, {.N, {.Ctrl}}}},
	{label = "Remove", keys = {{.Delete, {.Shift}}}},
}

@(private = "file")
Typing_Run :: struct {
	field:   ui.Line_Edit,
	pressed: [len(TYPING_COMMANDS)]bool,
	focus:   bool,   // give the field the keyboard in this build
}

// (the commands first, as a program reads its keys before its fields)
@(private = "file")
build_typing :: proc(f: ^Fx, user: rawptr) {
	r := (^Typing_Run)(user)
	for c, i in TYPING_COMMANDS { r.pressed[i] = ui.command_pressed(c) }
	res := ui.line_edit("###typing_field", &r.field)
	if r.focus { ui.set_focus(res.box.key); r.focus = false }
}

// A key that types text is a command's while no text field has the keyboard, and the field's while one has it: the
// command does not run and the field gets the character. A key that types nothing stays the command's.
@(test)
a_key_that_types_text_is_the_fields :: proc(t: ^testing.T) {
	testing.expect(t, ui.command_key_types_text({.R, {}}), "a letter")
	testing.expect(t, ui.command_key_types_text({.D, {.Shift}}), "a capital letter")
	testing.expect(t, ui.command_key_types_text({.N1, {}}), "a digit")
	testing.expect(t, ui.command_key_types_text({.Space, {}}), "Space")
	testing.expect(t, ui.command_key_types_text({.Backspace, {}}), "Backspace edits the field")
	testing.expect(t, ui.command_key_types_text({.Slash, {.Shift}}), "a punctuation mark")
	testing.expect(t, ui.command_key_types_text({.Num_Add, {}}), "keypad +")
	testing.expect(t, !ui.command_key_types_text({.D, {.Ctrl}}), "Ctrl types nothing")
	testing.expect(t, !ui.command_key_types_text({.D, {.Alt, .Shift}}), "Alt types nothing")
	testing.expect(t, !ui.command_key_types_text({.Delete, {.Shift}}), "Shift+Delete types nothing")
	testing.expect(t, !ui.command_key_types_text({.F2, {}}), "a function key")
	testing.expect(t, !ui.command_key_types_text({.Return, {}}), "Enter")
	testing.expect(t, !ui.command_key_types_text({.Tab, {.Shift}}), "Shift+Tab")
	testing.expect(t, !ui.command_key_types_text({.Menu, {}}), "the Menu key")
	testing.expect(t, !ui.command_key_types_text({}), "no key")

	got := ui.command_typing_keys(TYPING_COMMANDS[:])
	testing.expectf(t, slice.equal(got, []string{"Rectangle: R", "Add a step…: Shift+A"}), "the table's typing keys: %v", got)
	testing.expect_value(t, len(ui.command_typing_keys(PALETTE_COMMANDS[:])), 0)

	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Typing_Run
	defer ui.line_edit_destroy(&r.field)

	frame(&f, nil, build_typing, &r)
	frame(&f, {key(.R), typed('r')}, build_typing, &r)
	testing.expect(t, r.pressed[0], "no field has the keyboard: R is the command's")

	r.focus = true
	frame(&f, nil, build_typing, &r)
	frame(&f, nil, build_typing, &r)
	frame(&f, {key(.A, {.Shift}), typed('A'), key(.R), typed('r')}, build_typing, &r)
	testing.expect(t, !r.pressed[0] && !r.pressed[1], "the field has the keyboard: R and Shift+A are its own")
	testing.expect_value(t, ui.line_edit_string(&r.field), "Ar")
	frame(&f, {key(.N, {.Ctrl})}, build_typing, &r)
	testing.expect(t, r.pressed[1], "Ctrl+N, the same command's other key, types nothing: the command's")
	frame(&f, {key(.Delete, {.Shift})}, build_typing, &r)
	testing.expect(t, r.pressed[2], "Shift+Delete types nothing: the command's, read before the field")
}

@(private = "file")
WINDOW_COMMANDS := [?]ui.Command{
	{label = "Command palette", group = "Window", keys = {{.K, {.Ctrl}}}, scope = .Window},
	{label = "Keyboard shortcuts", group = "Window", keys = {{.F1, {}}}, scope = .Window},
	{label = "New", group = "File", keys = {{.N, {.Ctrl}}}},
}

@(private = "file")
Window_Run :: struct {
	field:   ui.Line_Edit,
	pal:     ui.Command_Palette,
	pressed: [len(WINDOW_COMMANDS)]bool,
	f2:      bool,   // F2, read alone as a window command's chord (chord_pressed)
	focus:   bool,   // give the field the keyboard in this build
	claim:   bool,   // the field claims every chord but F1 (keys_claim)
	show:    bool,   // open the palette (a view shown as a dialog) in this build
}

// (the commands first, as a program reads its keys before it builds its page)
@(private = "file")
build_window :: proc(f: ^Fx, user: rawptr) {
	r := (^Window_Run)(user)
	for c, i in WINDOW_COMMANDS { r.pressed[i] = ui.command_pressed(c) }
	r.f2 = ui.chord_pressed({.F2, {}}, .Window)
	res := ui.line_edit("###window_field", &r.field)
	if r.focus { ui.set_focus(res.box.key); r.focus = false }
	if r.claim { ui.keys_claim(res.box.key, ui.Chord{.F1, {}}) }
	ui.palette_commands(&r.pal, WINDOW_COMMANDS[:], nil)
	if r.show { ui.palette_open(&r.pal); r.show = false }
}

// A window command's key works whatever has the keyboard: a text field, and from behind a view shown as a dialog, where
// a page command's key does not reach. A widget that claims the chords keeps them, but the ones it lets through.
@(test)
a_window_command_works_whatever_has_the_keyboard :: proc(t: ^testing.T) {
	testing.expect_value(t, len(ui.command_window_typing_keys(WINDOW_COMMANDS[:])), 0)
	typing := [?]ui.Command{{label = "Help", keys = {{.Slash, {.Shift}}}, scope = .Window}, {label = "Tool", keys = {{.R, {}}}}}
	got := ui.command_window_typing_keys(typing[:])
	testing.expectf(t, slice.equal(got, []string{"Help: Shift+Slash"}), "a window command's typing key, a page's not: %v", got)

	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Window_Run
	defer ui.line_edit_destroy(&r.field)
	defer ui.palette_destroy(&r.pal)

	r.focus = true
	frame(&f, nil, build_window, &r)
	frame(&f, nil, build_window, &r)
	frame(&f, {key(.K, {.Ctrl})}, build_window, &r)
	testing.expect(t, r.pressed[0], "the field has the keyboard: Ctrl+K is the palette's")
	frame(&f, {key(.F1)}, build_window, &r)
	testing.expect(t, r.pressed[1], "and F1 the sheet's")

	r.show = true
	frame(&f, nil, build_window, &r)
	frame(&f, nil, build_window, &r)
	testing.expect(t, ui.palette_is_open(&r.pal), "the palette, a dialog, is open")
	frame(&f, {key(.N, {.Ctrl})}, build_window, &r)
	testing.expect(t, !r.pressed[2], "a page command's key stops at the dialog")
	frame(&f, {key(.F1)}, build_window, &r)
	testing.expect(t, r.pressed[1], "a window command's key does not")
	frame(&f, {key(.F2)}, build_window, &r)
	testing.expect(t, r.f2, "nor a window command's chord read alone (a program's own table)")
	ui.palette_close(&r.pal)
	frame(&f, nil, build_window, &r)
	frame(&f, nil, build_window, &r)

	r.focus, r.claim = true, true
	frame(&f, nil, build_window, &r)
	frame(&f, nil, build_window, &r)
	frame(&f, {key(.K, {.Ctrl})}, build_window, &r)
	testing.expect(t, !r.pressed[0], "the field claims the chords: Ctrl+K is its own")
	frame(&f, {key(.F1)}, build_window, &r)
	testing.expect(t, r.pressed[1], "but F1, which it lets through")
	r.claim = false
	frame(&f, nil, build_window, &r)
	frame(&f, {key(.K, {.Ctrl})}, build_window, &r)
	testing.expect(t, r.pressed[0], "no claim at this build nor the last: Ctrl+K is the palette's again")
}

@(private = "file")
Keys_Run :: struct {
	commands: []ui.Command,
	pressed:  [len(PALETTE_COMMANDS)]bool,
	other:    bool,   // Ctrl+K reached what reads it after the commands
	pal:      ui.Command_Palette,
	sheet:    ui.Shortcuts_Sheet,
	show:     bool,   // open the palette and the sheet in the next build
}

@(private = "file")
build_keys_in_effect :: proc(f: ^Fx, user: rawptr) {
	r := (^Keys_Run)(user)
	for c, i in r.commands { r.pressed[i] = ui.command_pressed(c) }
	r.other = ui.key_press(.K, {.Ctrl})
	ui.palette_commands(&r.pal, r.commands, nil)
	if r.show {
		r.show = false
		ui.palette_open(&r.pal)
		ui.shortcuts_sheet_open(&r.sheet, r.commands)
	}
}

// The keys in effect are the table the program passes: a copy of its constant table with a key turned off (Ctrl+K, by a
// setting) or rebound. Every reader (the keys, the menus' text, the palette, the sheet) follows it; the constant table
// stays; a key turned off is left to what else reads it.
@(test)
the_keys_in_effect_are_the_table_passed :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	commands := PALETTE_COMMANDS
	commands[3].keys = commands[3].keys[1:]          // "Ctrl+K opens the palette" off
	commands[2].keys = []ui.Chord{{.F3, {}}}         // Start rebound to F3
	r := Keys_Run{commands = commands[:]}
	defer ui.palette_destroy(&r.pal)
	defer ui.shortcuts_sheet_destroy(&r.sheet)
	testing.expect_value(t, len(PALETTE_COMMANDS[3].keys), 2)
	testing.expect_value(t, ui.command_shortcut(PALETTE_COMMANDS[2]), "Ctrl+S")
	testing.expect_value(t, ui.command_shortcut(commands[2]), "F3")
	testing.expect_value(t, ui.command_keys_text(commands[3]), "Ctrl+Shift+P")

	frame(&f, {key(.K, {.Ctrl})}, build_keys_in_effect, &r)
	testing.expect(t, !r.pressed[3], "Ctrl+K turned off: not the palette's")
	testing.expect(t, r.other, "Ctrl+K left to what reads it after")
	frame(&f, {key(.P, {.Ctrl, .Shift})}, build_keys_in_effect, &r)
	testing.expect(t, r.pressed[3], "its other key still acts")
	frame(&f, {key(.S, {.Ctrl})}, build_keys_in_effect, &r)
	testing.expect(t, !r.pressed[2], "Start's old key no longer acts")
	frame(&f, {key(.F3)}, build_keys_in_effect, &r)
	testing.expect(t, r.pressed[2], "its new key does")

	r.show = true
	frame(&f, nil, build_keys_in_effect, &r)
	// (the palette ranks on the chores: its list comes in a later build)
	deadline := time.tick_now()
	for ui.palette_is_open(&r.pal) && (ui.palette_busy(&r.pal) || ui.palette_row_count(&r.pal) == 0) && time.tick_since(deadline) < SETTLE_BOUND {
		frame(&f, nil, build_keys_in_effect, &r)
	}
	frame(&f, nil, build_keys_in_effect, &r)
	testing.expect(t, find_text(&f, "F3") != nil, "the palette and the sheet show the new key")
	testing.expect(t, find_text(&f, "Ctrl+S") == nil, "and not the old one")
	testing.expect(t, find_text(&f, "Ctrl+K") == nil, "nor the key turned off")
}

@(private = "file") MANY :: 2000

@(private = "file")
Many_Run :: struct {
	commands:  [MANY]ui.Command,
	sheet:     ui.Shortcuts_Sheet,
	sheet_now: bool,   // open the sheet in the next build
}

@(private = "file")
build_many :: proc(f: ^Fx, user: rawptr) {
	r := (^Many_Run)(user)
	if r.sheet_now { r.sheet_now = false; ui.shortcuts_sheet_open(&r.sheet, r.commands[:]) }
}

// The boxes of the last build whose text begins with `prefix`.
@(private = "file")
built_with_prefix :: proc(f: ^Fx, prefix: string) -> int {
	n := 0
	for _, b in f.s.boxes {
		if b != nil && b.last_build == f.s.build_index && strings.has_prefix(ui.box_text(b), prefix) { n += 1 }
	}
	return n
}

// The sheet lists its commands that have a key once, and of 2000 lines builds only those near its view.
@(test)
the_sheet_lists_once_and_builds_near_its_view :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := new(Many_Run)
	defer free(r)
	for &c, i in r.commands {
		c = {label = fmt.aprintf("Command %d", i), group = fmt.aprintf("Group %d", i / 100), keys = {{.F2, {}}}}
	}
	defer for c in r.commands { delete(c.label); delete(c.group) }
	defer ui.shortcuts_sheet_destroy(&r.sheet)
	r.sheet_now = true
	for _ in 0 ..< 4 { frame(&f, nil, build_many, r) }
	testing.expect_value(t, r.sheet.listings, 1)
	testing.expect(t, find_text(&f, "Command 0") != nil && find_text(&f, "Command 1999") == nil, "the sheet's first lines, not its last")
	testing.expectf(t, built_with_prefix(&f, "Command ") < 200, "the sheet's lines near the view only: %d", built_with_prefix(&f, "Command "))
}
