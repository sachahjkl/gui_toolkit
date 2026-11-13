// The memory of choices (ui/choices.odin): their weight, the recent ones, the bonus, the file, read and written off the
// interface's thread.
package commands_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "../../src/font"
import "../../src/fsx"
import "../../src/ui"

@(private = "file") DAY_MS :: 86_400_000
@(private = "file") T0 :: i64(1_800_000_000_000)
@(private = "file") LOAD_WAIT :: 5 * time.Second

// A choice weighs its count, halved every half-life since it was last made.
@(test)
a_choice_weighs_its_count_halved_by_its_age :: proc(t: ^testing.T) {
	m: ui.Choice_Memory
	defer ui.choice_memory_close(&m)
	testing.expect_value(t, ui.choice_weight(&m, "tab.new", T0), 0)
	ui.choice_note(&m, "tab.new", T0)
	ui.choice_note(&m, "tab.new", T0)
	testing.expect_value(t, ui.choice_weight(&m, "tab.new", T0), 2)
	testing.expect_value(t, ui.choice_weight(&m, "tab.new", T0 + ui.CHOICE_HALF_LIFE_DAYS * DAY_MS), 1)
	m.options.half_life_days = 1
	testing.expect_value(t, ui.choice_weight(&m, "tab.new", T0 + 2 * DAY_MS), 0.5)
	ui.choice_note(&m, "line\nbreak", T0)
	ui.choice_note(&m, "", T0)
	testing.expect_value(t, len(m.entries), 1)
}

// The recent ones: the heaviest first, at most `most`; the bonus: the weight with nothing typed, bounded while typing.
@(test)
recent_choices_and_their_bonus :: proc(t: ^testing.T) {
	m: ui.Choice_Memory
	defer ui.choice_memory_close(&m)
	ui.choice_note(&m, "b", T0 - 60 * DAY_MS)   // (old: lighter than one recent choice)
	ui.choice_note(&m, "b", T0 - 60 * DAY_MS)
	ui.choice_note(&m, "c", T0)
	ui.choice_note(&m, "d", T0)
	ui.choice_note(&m, "d", T0)
	keys := []string{"a", "b", "c", "d"}
	recent := ui.choice_recent(&m, keys, now_ms = T0)
	testing.expect_value(t, len(recent), 3)
	if len(recent) == 3 { testing.expect(t, recent[0] == 3 && recent[1] == 2 && recent[2] == 1, "d, c, then the old b") }
	testing.expect_value(t, len(ui.choice_recent(&m, keys, most = 1, now_ms = T0)), 1)
	testing.expect_value(t, ui.choice_bonus(&m, "d", "", T0), 2)
	testing.expect_value(t, ui.choice_bonus(&m, "d", "x", T0), 2 * ui.CHOICE_BONUS_WEIGHT)
	for _ in 0 ..< 10 { ui.choice_note(&m, "d", T0) }
	testing.expect_value(t, ui.choice_bonus(&m, "d", "x", T0), ui.CHOICE_BONUS_MOST)
}

// Over its most, the lightest choice goes, never the one just made.
@(test)
the_memory_forgets_the_lightest :: proc(t: ^testing.T) {
	m: ui.Choice_Memory
	defer ui.choice_memory_close(&m)
	m.options.most = 2
	ui.choice_note(&m, "a", T0)
	ui.choice_note(&m, "a", T0)
	ui.choice_note(&m, "b", T0)
	ui.choice_note(&m, "c", T0)
	testing.expect(t, "a" in m.entries && "c" in m.entries && "b" not_in m.entries, "b, the lightest, went")
}

// The file's text reads back; a choice in both adds its counts; another file adds nothing.
@(test)
the_memorys_text :: proc(t: ^testing.T) {
	m: ui.Choice_Memory
	defer ui.choice_memory_close(&m)
	ui.choice_note(&m, "pref:appearance.theme", T0)
	ui.choice_note(&m, "tab.new", T0 + 5)
	text := ui.choice_memory_text(&m)
	testing.expect_value(t, text, fmt.tprintf("%s\n1\t%d\tpref:appearance.theme\n1\t%d\ttab.new\n", ui.CHOICE_FILE_HEADER, T0, T0 + 5))
	n: ui.Choice_Memory
	defer ui.choice_memory_close(&n)
	ui.choice_note(&n, "tab.new", T0 + 9)
	testing.expect(t, ui.choice_memory_merge(&n, strings.concatenate({text, "x\ty\tbad line\n"}, context.temp_allocator), T0))
	testing.expect_value(t, n.entries["tab.new"], ui.Choice{2, T0 + 9})
	testing.expect_value(t, n.entries["pref:appearance.theme"], ui.Choice{1, T0})
	testing.expect_value(t, len(n.entries), 2)
	testing.expect(t, !ui.choice_memory_merge(&n, "another file\n1\t2\tx\n", T0), "another file")
	testing.expect_value(t, len(n.entries), 2)
}

@(private = "file")
Memory_Fx :: struct {
	fonts: font.State,
	theme: ui.Theme,
	s:     ui.State,
}

// Until the memory read its file (the task's result drained on the interface's thread, as a build does).
@(private = "file")
wait_loaded :: proc(fx: ^Memory_Fx, m: ^ui.Choice_Memory) -> bool {
	began := time.tick_now()
	for !m.loaded && time.tick_since(began) < LOAD_WAIT {
		ui.drain_posts(&fx.s)
		time.sleep(time.Millisecond)
	}
	return m.loaded
}

// The file is read off the interface's thread; a choice made before it came is kept and added; the file is written
// by the writer, and a memory opened again reads it.
@(test)
the_memory_reads_and_writes_its_file :: proc(t: ^testing.T) {
	fx := new(Memory_Fx)
	defer free(fx)
	font.init(&fx.fonts)
	defer font.destroy(&fx.fonts)
	ui.init(&fx.s, &fx.fonts, &fx.theme)
	defer ui.destroy(&fx.s)
	root := fmt.tprintf("%s/gui_toolkit_choices_%d", fsx.temp_dir(context.temp_allocator), os.get_pid())
	fsx.make_dirs(root)
	path := fmt.tprintf("%s/choices.txt", root)
	testing.expect(t, fsx.write_atomic(path, transmute([]byte)fmt.tprintf("%s\n3\t%d\tkill\n", ui.CHOICE_FILE_HEADER, T0)))

	m: ui.Choice_Memory
	ui.choice_memory_open(&m, &fx.s, path)
	ui.choice_note(&m, "kill", T0 + 1)   // (before the file came)
	testing.expect(t, wait_loaded(fx, &m), "the file was read")
	testing.expect_value(t, m.entries["kill"], ui.Choice{4, T0 + 1})
	ui.choice_memory_close(&m)   // (written when it returns)
	data, _ := fsx.read_all(path, context.temp_allocator)
	testing.expect_value(t, string(data), fmt.tprintf("%s\n4\t%d\tkill\n", ui.CHOICE_FILE_HEADER, T0 + 1))

	again: ui.Choice_Memory
	ui.choice_memory_open(&again, &fx.s, path)
	testing.expect(t, wait_loaded(fx, &again), "read again")
	testing.expect_value(t, again.entries["kill"], ui.Choice{4, T0 + 1})
	ui.choice_memory_close(&again)

	// closed before its file came: the read's result touches nothing
	gone: ui.Choice_Memory
	ui.choice_memory_open(&gone, &fx.s, path)
	ui.choice_memory_close(&gone)
	began := time.tick_now()
	for time.tick_since(began) < 100 * time.Millisecond { ui.drain_posts(&fx.s); time.sleep(time.Millisecond) }
	testing.expect_value(t, len(gone.entries), 0)
	_ = os.remove_all(root)
}
