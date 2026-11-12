// The store package: a file of keys and values read once, kept in memory, written later on its worker, atomically.
//   odin test tests/store -vet
package store_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../../src/fsx"
import store "../../src/store"

// Long enough that a write cannot come by itself while a test looks: only flush and close write.
WAIT_LONG_MS :: 60_000

fresh_dir :: proc(name: string) -> string {
	root := fmt.tprintf("%s/%s_%d", fsx.temp_dir(context.temp_allocator), name, os.get_pid())
	fsx.remove_tree(root)
	fsx.make_dirs(root)
	return root
}

file_text :: proc(path: string) -> string {
	data, ok := fsx.read_all(path, context.temp_allocator)
	return ok ? string(data) : "<none>"
}

// The files a program has now load as they are: "key=value" lines, a byte-order mark, CRLF ends, a key twice (the first
// stays), a line with no separator (skipped), a value holding the separator. Written back, they keep their order.
@(test)
an_existing_file_loads_and_writes_back_the_same_way :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_store_load")
	defer fsx.remove_tree(root)
	path := fmt.tprintf("%s/settings.txt", root)
	testing.expect(t, fsx.write_atomic(path, transmute([]byte)string("\uFEFFsetup=installed\r\nserver=Home=1\nno separator\nsetup=other\n\nlast=ses_1\n")))
	s: store.Store
	testing.expect(t, store.open(&s, path, '=', wait_ms = WAIT_LONG_MS, most_ms = WAIT_LONG_MS), "read")
	defer store.close(&s)
	v, ok := store.get(&s, "setup")
	testing.expect(t, ok && v == "installed", "the first of a key twice")
	v, ok = store.get(&s, "server")
	testing.expect_value(t, v, "Home=1")
	_, ok = store.get(&s, "no separator")
	testing.expect(t, !ok, "a line with no separator is no entry")
	testing.expect_value(t, store.count(&s), 3)
	testing.expect(t, store.set(&s, "server", "Work"))
	testing.expect(t, store.set(&s, "zoom", "1.1"))
	store.remove(&s, "setup")
	store.flush(&s)
	testing.expect_value(t, file_text(path), "server=Work\nlast=ses_1\nzoom=1.1\n")
	k := store.keys(&s)
	testing.expect(t, len(k) == 3 && k[0] == "server" && k[1] == "last" && k[2] == "zoom", "the order of the file, a new key at its end")
}

// A key or a value the line cannot hold is refused, and nothing changes: what is read back is what was set.
@(test)
what_a_line_cannot_hold_is_refused :: proc(t: ^testing.T) {
	s: store.Store
	testing.expect(t, !store.set(&s, "", "x"), "an empty key")
	testing.expect(t, !store.set(&s, "a\tb", "x"), "the separator in a key")
	testing.expect(t, !store.set(&s, "a", "x\ny"), "a line break in a value")
	testing.expect(t, !store.set(&s, "a\r", "x"), "a line break in a key")
	testing.expect(t, store.set(&s, "a", "x\ty"), "the separator in a value: the key ends at the first")
	testing.expect_value(t, store.count(&s), 1)
	store.close(&s)
}

// A zero Store is in memory only: no path, no worker, every procedure works.
@(test)
a_zero_store_is_in_memory :: proc(t: ^testing.T) {
	s: store.Store
	testing.expect(t, store.set(&s, "a", "1"))
	testing.expect(t, store.set(&s, "b", "2"))
	testing.expect(t, store.set(&s, "a", "3"))
	store.flush(&s)
	l := store.list(&s)
	testing.expect(t, len(l) == 2 && l[0].key == "a" && l[0].value == "3" && l[1].key == "b", "set again: same place")
	store.replace(&s, {{"c", "1"}, {"c", "2"}, {"", "x"}})
	l = store.list(&s)
	testing.expect(t, len(l) == 1 && l[0].value == "1", "replace: the first of a key twice, no empty key")
	store.close(&s)
	testing.expect_value(t, store.count(&s), 0)
}

// A set does not write: the file waits for the changes to rest. Flush writes it now; so does close.
@(test)
writes_wait_for_the_rest_flush_and_close_write :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_store_wait")
	defer fsx.remove_tree(root)
	path := fmt.tprintf("%s/deeper/zooms.txt", root)   // (its folder is made by the first write)
	s: store.Store
	testing.expect(t, !store.open(&s, path, wait_ms = WAIT_LONG_MS, most_ms = WAIT_LONG_MS), "no file yet")
	testing.expect(t, store.set(&s, "a", "1.5"))
	testing.expect_value(t, file_text(path), "<none>")
	store.flush(&s)
	testing.expect_value(t, file_text(path), "a\t1.5\n")
	store.remove(&s, "a")
	store.close(&s)
	testing.expect_value(t, file_text(path), "")
	left := fsx.list_files(fmt.tprintf("%s/deeper", root))
	testing.expect_value(t, len(left), 1)   // (no temporary file left behind)
}

// With a short rest, the worker writes on its own.
@(test)
the_worker_writes_once_the_changes_rest :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_store_rest")
	defer fsx.remove_tree(root)
	path := fmt.tprintf("%s/usage.txt", root)
	s: store.Store
	store.open(&s, path, wait_ms = 10, most_ms = 50)
	defer store.close(&s)
	store.set(&s, "1:ses", "2.000000\t1700000000000.000000")
	started := time.tick_now()
	for file_text(path) == "<none>" && time.tick_since(started) < 5 * time.Second { time.sleep(5 * time.Millisecond) }
	testing.expect_value(t, file_text(path), "1:ses\t2.000000\t1700000000000.000000\n")
}

// The design's breaking point: one thread changes every value without end while the worker writes and another thread reads
// the file. Every read is a whole file, every key in it, never a part; the last flush has the last values.
@(test)
a_reader_never_sees_a_part :: proc(t: ^testing.T) {
	KEYS :: 40
	ROUNDS :: 300
	root := fresh_dir("gui_toolkit_store_race")
	defer fsx.remove_tree(root)
	path := fmt.tprintf("%s/race.txt", root)
	s: store.Store
	store.open(&s, path, wait_ms = 0, most_ms = 0)
	for k in 0 ..< KEYS { store.set(&s, fmt.tprintf("key%d", k), "0") }
	store.flush(&s)

	Race :: struct { s: ^store.Store, done: bool }
	race := Race{s = &s}
	setter := thread.create_and_start_with_data(&race, proc(data: rawptr) {
		r := (^Race)(data)
		for round in 1 ..= ROUNDS {
			for k in 0 ..< KEYS { store.set(r.s, fmt.tprintf("key%d", k), fmt.tprintf("%d", round)) }
			free_all(context.temp_allocator)
		}
		sync.atomic_store(&r.done, true)
	})
	reads, parts := 0, 0
	for {
		done := sync.atomic_load(&race.done)   // (read once more after the end: at least one read)
		if data, ok := fsx.read_all(path, context.temp_allocator); ok {
			reads += 1
			if strings.count(string(data), "\n") != KEYS || !strings.has_suffix(string(data), "\n") { parts += 1 }
		}
		if done { break }
	}
	thread.join(setter)
	thread.destroy(setter)
	store.flush(&s)
	testing.expect_value(t, parts, 0)
	testing.expect(t, reads > 0, "the file was read while it changed")
	v, _ := store.get(&s, "key0")
	testing.expect_value(t, v, fmt.tprintf("%d", ROUNDS))
	text := file_text(path)
	testing.expect(t, strings.has_prefix(text, fmt.tprintf("key0\t%d\n", ROUNDS)), "the last values on the disk")
	store.close(&s)
}

// A Writer writes the last content put, on its worker; close writes what is pending.
@(test)
a_writer_writes_the_last_content :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_store_writer")
	defer fsx.remove_tree(root)
	path := fmt.tprintf("%s/drafts.json", root)
	w: store.Writer
	store.writer_open(&w, path, wait_ms = WAIT_LONG_MS, most_ms = WAIT_LONG_MS)
	store.writer_put(&w, transmute([]byte)string(`{"a":"1"}`))
	store.writer_put(&w, transmute([]byte)string(`{"a":"2"}`))
	testing.expect_value(t, file_text(path), "<none>")
	store.writer_flush(&w)
	testing.expect_value(t, file_text(path), `{"a":"2"}`)
	store.writer_put(&w, transmute([]byte)string(`{}`))
	store.writer_close(&w)
	testing.expect_value(t, file_text(path), `{}`)
}

// A write that fails is said, on the worker, with the file's path.
@(test)
a_failed_write_is_said :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_store_failed")
	defer fsx.remove_tree(root)
	// (a folder where the file goes: it cannot be replaced by a file)
	path := fmt.tprintf("%s/taken", root)
	fsx.make_dirs(fmt.tprintf("%s/inside", path))
	Said :: struct { calls: int }
	said: Said
	s: store.Store
	store.open(&s, path, wait_ms = WAIT_LONG_MS, on_failed = proc(user: rawptr, _: string) {
		sync.atomic_add(&(^Said)(user).calls, 1)
	}, user = &said)
	store.set(&s, "a", "1")
	store.flush(&s)
	testing.expect_value(t, sync.atomic_load(&said.calls), 1)
	store.close(&s)
}
