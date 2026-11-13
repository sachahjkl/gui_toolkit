package ui

// What the user chose in a palette or a picker, and when: each choice's count and last time, kept in a file. A choice
// weighs its count, halved every half-life since it was last made (frecency): what is chosen often and lately comes
// first. The palette reads it (Palette_Options.memory) for its "Recent" group and to raise a match; a list ranked with
// `rank` reads it in its bonus (choice_bonus). The program names each choice with a stable key ("tab.new",
// "pref:appearance.theme") and says when one is made (choice_note).
//
// The interface's thread never touches the file: the memory is read by a task (ui.task) after choice_memory_open, and
// written by a store.Writer (its own thread, atomic, once the changes rest).
//
//   ui.choice_memory_open(&app.choices, &app.ui, path)
//   if i, _ := ui.palette(&app.palette, COMMANDS[:], disabled[:], {memory = &app.choices, names = NAMES[:]}); i >= 0 {
//       ui.choice_note(&app.choices, NAMES[i])
//       run(Cmd(i))
//   }
//   ui.choice_memory_close(&app.choices)   // the program's end: the file is written when it returns

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "../fsx"
import store "../store"

// A choice's weight halves every this many days without being made again; the memory keeps at most this many choices
// (the lightest go first).
CHOICE_HALF_LIFE_DAYS :: 14
CHOICE_MOST :: 500
// What a choice's weight adds to a match's score while something is typed: its weight times CHOICE_BONUS_WEIGHT, never
// over CHOICE_BONUS_MOST (a good match still beats a frequent poor one).
CHOICE_BONUS_WEIGHT :: 6
CHOICE_BONUS_MOST :: 30
// The choices the "Recent" group lists at most.
CHOICE_RECENT_MOST :: 5
// The file's first line: another file is not read.
CHOICE_FILE_HEADER :: "gui_toolkit choices 1"
// The writer waits for the choices to rest this long, at most CHOICE_SAVE_MOST_MS.
@(private = "file") CHOICE_SAVE_WAIT_MS :: 1000
@(private = "file") CHOICE_SAVE_MOST_MS :: 5000

Choice :: struct {
	count:   int,
	last_ms: i64,   // the last time it was made, in milliseconds since 1970 (UTC)
}

Choice_Memory_Options :: struct {
	half_life_days: f64,   // 0: CHOICE_HALF_LIFE_DAYS
	most:           int,   // 0: CHOICE_MOST
}

// A program keeps it (zero: a memory in memory only, as in a test); its fields are read, not written.
Choice_Memory :: struct {
	entries: map[string]Choice,   // owned keys
	version: u64,                 // counts its changes (rank's `version`, with the program's own)
	loaded:  bool,                // the file was read (or there was none to read): choice_note writes it from then on
	options: Choice_Memory_Options,
	writer:  store.Writer,
	saving:  bool,                // a writer runs (a path was given)
	noted:   bool,                // a choice made before the file was read: written after it is merged
	read:    ^Choice_Read,        // the read under way
}

// The read's data, shared by the task and the memory: the last of them to let go frees it.
@(private)
Choice_Read :: struct {
	memory: ^Choice_Memory,   // nil once the memory was closed (both on the interface's thread)
	path:   string,
	data:   []byte,
	found:  bool,
	refs:   int,              // (atomic)
}

// Starts the memory of the file at `path`: it is read on the chores, merged on `s`'s thread at a next build (the
// choices made meanwhile are kept, counts added). `path` "": in memory only. Call it on the interface's thread.
choice_memory_open :: proc(m: ^Choice_Memory, s: ^State, path: string, o := Choice_Memory_Options{}) {
	m.options = o
	if m.entries == nil { m.entries = make(map[string]Choice, runtime.heap_allocator()) }
	if path == "" {
		m.loaded = true
		return
	}
	store.writer_open(&m.writer, path, wait_ms = CHOICE_SAVE_WAIT_MS, most_ms = CHOICE_SAVE_MOST_MS, allocator = runtime.heap_allocator())
	m.saving = true
	r := new(Choice_Read, runtime.heap_allocator())
	r^ = {memory = m, path = strings.clone(path, runtime.heap_allocator()), refs = 2}
	m.read = r
	task(s, choice_read_work, choice_read_done, r, choice_read_lost)
}

// Writes the choices now and waits for the disk: a program's end, a test.
choice_memory_flush :: proc(m: ^Choice_Memory) {
	if m.saving { store.writer_flush(&m.writer) }
}

// Writes what changed (it waits for the disk), ends the writer and frees the memory. It is zero after.
choice_memory_close :: proc(m: ^Choice_Memory) {
	if m.read != nil {
		m.read.memory = nil
		choice_read_release(m.read)
	}
	if m.saving { store.writer_close(&m.writer) }
	for k in m.entries { delete(k, runtime.heap_allocator()) }
	delete(m.entries)
	m^ = {}
}

// The choice `key` was made now (`now_ms` 0: the clock's time). Over the memory's most, the lightest choice goes (of
// equal weights, the oldest). A key with a line break is not kept (a line of the file).
choice_note :: proc(m: ^Choice_Memory, key: string, now_ms := i64(0)) {
	if key == "" || strings.index_any(key, "\r\n") >= 0 { return }
	if m.entries == nil { m.entries = make(map[string]Choice, runtime.heap_allocator()) }
	now := now_ms != 0 ? now_ms : choice_now()
	if e, ok := &m.entries[key]; ok {
		e.count += 1
		e.last_ms = now
	} else {
		m.entries[strings.clone(key, runtime.heap_allocator())] = {1, now}
	}
	choice_trim(m, key, now)
	m.version += 1
	if !m.loaded { m.noted = true; return }   // (written once the file is merged: a write now would lose it)
	choice_save(m)
}

// A choice's weight: its count, halved every half-life since it was last made (0: never made).
choice_weight :: proc(m: ^Choice_Memory, key: string, now_ms := i64(0)) -> f64 {
	e, ok := m.entries[key]
	if !ok || e.count <= 0 { return 0 }
	now := now_ms != 0 ? now_ms : choice_now()
	age_days := f64(max(now - e.last_ms, 0)) / 86_400_000
	return f64(e.count) * math.pow(0.5, age_days / max(choice_half_life(m), 1e-3))
}

// What a choice adds to a ranked item's score (rank's bonus, the palette's): with nothing typed, its weight (the list
// in the order of use); while something is typed, its weight times CHOICE_BONUS_WEIGHT, at most CHOICE_BONUS_MOST.
choice_bonus :: proc(m: ^Choice_Memory, key: string, query: string, now_ms := i64(0)) -> f64 {
	w := choice_weight(m, key, now_ms)
	if query == "" { return w }
	return min(w * CHOICE_BONUS_WEIGHT, CHOICE_BONUS_MOST)
}

// The indices in `keys` of the choices made, the heaviest first (equal weights: the order of `keys`), at most `most`.
choice_recent :: proc(m: ^Choice_Memory, keys: []string, most := CHOICE_RECENT_MOST, now_ms := i64(0), allocator := context.temp_allocator) -> []int {
	Weighed :: struct { index: int, weight: f64 }
	now := now_ms != 0 ? now_ms : choice_now()
	found := make([dynamic]Weighed, 0, len(m.entries), context.temp_allocator)
	for k, i in keys {
		if w := choice_weight(m, k, now); w > 0 { append(&found, Weighed{i, w}) }
	}
	slice.stable_sort_by(found[:], proc(a, b: Weighed) -> bool { return a.weight > b.weight })
	out := make([]int, min(len(found), max(most, 0)), allocator)
	for &o, i in out { o = found[i].index }
	return out
}

// The file's text: the header, then one line per choice, `count<tab>last_ms<tab>key`, in the keys' order (the same
// choices make the same file).
choice_memory_text :: proc(m: ^Choice_Memory, allocator := context.temp_allocator) -> string {
	keys := make([dynamic]string, 0, len(m.entries), context.temp_allocator)
	for k in m.entries { append(&keys, k) }
	slice.sort(keys[:])
	b := strings.builder_make(allocator)
	strings.write_string(&b, CHOICE_FILE_HEADER)
	strings.write_byte(&b, '\n')
	for k in keys {
		e := m.entries[k]
		fmt.sbprintf(&b, "%d\t%d\t%s\n", e.count, e.last_ms, k)
	}
	return strings.to_string(b)
}

// Adds the choices of a file's text to the memory: a choice it has already gets the file's count added, and the later
// of the two times. A line that does not read is skipped; a text with another first line adds nothing (false).
choice_memory_merge :: proc(m: ^Choice_Memory, text: string, now_ms := i64(0)) -> bool {
	if m.entries == nil { m.entries = make(map[string]Choice, runtime.heap_allocator()) }
	rest := strings.trim_prefix(text, "\uFEFF")
	first := true
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(raw, "\r")
		if first {
			first = false
			if line != CHOICE_FILE_HEADER { return false }
			continue
		}
		parts := strings.split_n(line, "\t", 3, context.temp_allocator)
		if len(parts) != 3 || parts[2] == "" { continue }
		count, count_ok := strconv.parse_int(parts[0], 10)
		last, last_ok := strconv.parse_i64(parts[1], 10)
		if !count_ok || !last_ok || count <= 0 { continue }
		if e, ok := &m.entries[parts[2]]; ok {
			e.count += count
			e.last_ms = max(e.last_ms, last)
		} else {
			m.entries[strings.clone(parts[2], runtime.heap_allocator())] = {count, last}
		}
	}
	if first { return false }
	choice_trim(m, "", now_ms != 0 ? now_ms : choice_now())
	m.version += 1
	return true
}

@(private = "file")
choice_half_life :: proc(m: ^Choice_Memory) -> f64 {
	return m.options.half_life_days > 0 ? m.options.half_life_days : CHOICE_HALF_LIFE_DAYS
}

@(private)
choice_now :: proc() -> i64 { return time.to_unix_nanoseconds(time.now()) / 1_000_000 }

// Over the most, the lightest choices go (of equal weights, the oldest); `keep`, the choice just made, stays.
@(private = "file")
choice_trim :: proc(m: ^Choice_Memory, keep: string, now: i64) {
	most := m.options.most > 0 ? m.options.most : CHOICE_MOST
	for len(m.entries) > most {
		victim := ""
		victim_weight := max(f64)
		victim_last := max(i64)
		for k, e in m.entries {
			if k == keep { continue }
			w := choice_weight(m, k, now)
			if w < victim_weight || (w == victim_weight && e.last_ms < victim_last) { victim, victim_weight, victim_last = k, w, e.last_ms }
		}
		if victim == "" { break }
		k, _ := delete_key(&m.entries, victim)
		delete(k, runtime.heap_allocator())
	}
}

@(private = "file")
choice_save :: proc(m: ^Choice_Memory) {
	if m.saving { store.writer_put(&m.writer, transmute([]byte)choice_memory_text(m)) }
}

// (on the chores)
@(private = "file")
choice_read_work :: proc(d: rawptr) {
	r := (^Choice_Read)(d)
	r.data, r.found = fsx.read_all(r.path, runtime.heap_allocator())
}

// (on the interface's thread, at a build)
@(private = "file")
choice_read_done :: proc(d: rawptr, _: u64) {
	r := (^Choice_Read)(d)
	if m := r.memory; m != nil {
		m.read = nil
		m.loaded = true
		if r.found { _ = choice_memory_merge(m, string(r.data)) }
		if m.noted { m.noted = false; choice_save(m) }
		choice_read_release(r)   // (the memory's share: it lets go of the read here)
	}
	choice_read_release(r)
}

@(private = "file")
choice_read_lost :: proc(d: rawptr) { choice_read_release((^Choice_Read)(d)) }

@(private = "file")
choice_read_release :: proc(r: ^Choice_Read) {
	if sync.atomic_sub(&r.refs, 1) != 1 { return }
	delete(r.path, runtime.heap_allocator())
	delete(r.data, runtime.heap_allocator())
	free(r, runtime.heap_allocator())
}
