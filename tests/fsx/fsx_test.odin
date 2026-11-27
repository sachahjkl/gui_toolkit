// Moved here with the file helpers it covers (was Wren's src/base/base_test.odin, remove_tree over temp_dir).
//   odin test tests/fsx -collection:gt=src -vet
package fsx_test

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import base "gt:base"
import "gt:fsx"

// The smaller file of two (read_all_never_gives_a_part).
SIZE_SHORT :: 4096
// Enough reads to fall between a stat and a read many times over.
READS :: 20000

fresh_dir :: proc(name: string) -> string {
	// (joined by the system's separator: a path given to cmd.exe holds no "/", which its commands read as a switch)
	root := fsx.path_join(fsx.temp_dir(context.temp_allocator), name, allocator = context.temp_allocator)
	fsx.remove_tree(root)
	fsx.make_dirs(root)
	return root
}

@(test)
remove_tree_removes_a_directory_with_everything_in_it :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/gui_toolkit_fsx_remove_tree", fsx.temp_dir(context.temp_allocator))
	fsx.remove_tree(root)
	testing.expect(t, fsx.remove_tree(root), "an absent path: nothing to do")
	deep := fmt.tprintf("%s/a/b/c", root)
	testing.expect(t, os.make_directory_all(deep) == nil, "the tree is made")
	for name in ([]string{"x.txt", "a/y.txt", "a/b/z.txt", "a/b/c/w.txt"}) {
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), transmute([]byte)string("data")) == nil, "a file is written")
	}
	testing.expect(t, fsx.remove_tree(root), "removed")
	testing.expect(t, !os.exists(root), "nothing is left")
	file := fmt.tprintf("%s.txt", root)
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string("x")) == nil)
	testing.expect(t, fsx.remove_tree(file) && !os.exists(file), "a single file too")
}

// Another writer's temporary file, or whatever else has a name next to the file, is not this write's.
@(test)
a_write_leaves_the_name_next_to_it_alone :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_tmp_name")
	defer fsx.remove_tree(root)
	path := fmt.tprintf("%s/file", root)
	theirs := fmt.tprintf("%s.tmp", path)
	testing.expect(t, os.write_entire_file(theirs, transmute([]byte)string("theirs")) == nil)
	testing.expect(t, fsx.write_atomic(path, transmute([]byte)string("mine")))
	data, ok := fsx.read_all(theirs, context.temp_allocator)
	testing.expect(t, ok && string(data) == "theirs", "the other file is as it was")
	data, ok = fsx.read_all(path, context.temp_allocator)
	testing.expect(t, ok && string(data) == "mine")
}

// A write that fails leaves the file and nothing else.
@(test)
a_failed_write_leaves_no_temporary_file :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_failed_write")
	defer fsx.remove_tree(root)
	path := fmt.tprintf("%s/dir", root)
	testing.expect(t, os.make_directory_all(path) == nil)   // (what a file cannot replace)
	testing.expect(t, !fsx.write_atomic(path, transmute([]byte)string("mine")))
	testing.expect_value(t, len(fsx.list_files(root)), 0)
}

// A file written in parts: the target keeps its old content until the commit, then has every part in order; no part
// file stays beside it.
@(test)
a_writer_commits_its_parts_over_the_target :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_writer_commit")
	defer fsx.remove_tree(root)
	path := fmt.tprintf("%s/download.bin", root)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("old")) == nil)
	w: fsx.Writer
	if !testing.expect(t, fsx.writer_open(&w, path)) { return }
	testing.expect(t, fsx.writer_append(&w, transmute([]byte)string("first, ")))
	testing.expect(t, fsx.writer_append(&w, nil), "an empty part")
	testing.expect(t, fsx.writer_append(&w, transmute([]byte)string("second")))
	testing.expect_value(t, w.written, 13)
	data, ok := fsx.read_all(path, context.temp_allocator)
	testing.expect(t, ok && string(data) == "old", "the target as it was until the commit")
	testing.expect_value(t, len(fsx.list_files(root)), 2)   // (the target and its part file)
	testing.expect(t, fsx.writer_commit(&w, flush = true))
	data, ok = fsx.read_all(path, context.temp_allocator)
	testing.expect(t, ok && string(data) == "first, second")
	files := fsx.list_files(root)
	testing.expect(t, len(files) == 1 && files[0].name == "download.bin", "no part file left")
	testing.expect_value(t, w, fsx.Writer{})
	testing.expect(t, !fsx.writer_append(&w, transmute([]byte)string("x")), "a committed writer takes nothing")
	testing.expect(t, !fsx.writer_commit(&w))
	fsx.writer_abort(&w)   // (nothing: it holds nothing)
	data, ok = fsx.read_all(path, context.temp_allocator)
	testing.expect(t, ok && string(data) == "first, second")

	// a target that did not exist is made
	fresh := fmt.tprintf("%s/new.bin", root)
	if !testing.expect(t, fsx.writer_open(&w, fresh)) { return }
	testing.expect(t, fsx.writer_append(&w, transmute([]byte)string("made")))
	testing.expect(t, fsx.writer_commit(&w))
	data, ok = fsx.read_all(fresh, context.temp_allocator)
	testing.expect(t, ok && string(data) == "made")
}

// An abort leaves the target as it was and nothing beside it; a writer in a missing folder does not open.
@(test)
a_writer_aborted_leaves_the_target_alone :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_writer_abort")
	defer fsx.remove_tree(root)
	path := fmt.tprintf("%s/download.bin", root)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("old")) == nil)
	w: fsx.Writer
	if !testing.expect(t, fsx.writer_open(&w, path)) { return }
	testing.expect(t, fsx.writer_append(&w, transmute([]byte)string("half of it")))
	fsx.writer_abort(&w)
	fsx.writer_abort(&w)   // (twice: nothing more)
	data, ok := fsx.read_all(path, context.temp_allocator)
	testing.expect(t, ok && string(data) == "old")
	files := fsx.list_files(root)
	testing.expect(t, len(files) == 1 && files[0].name == "download.bin", "no part file left")
	// a target that never was stays absent
	absent := fmt.tprintf("%s/absent.bin", root)
	if testing.expect(t, fsx.writer_open(&w, absent)) {
		fsx.writer_abort(&w)
		testing.expect_value(t, fsx.path_kind(absent), fsx.Path_Kind.Absent)
	}
	testing.expect(t, !fsx.writer_open(&w, fmt.tprintf("%s/missing/x.bin", root)), "a folder that is not there")
	testing.expect_value(t, w, fsx.Writer{})
	testing.expect_value(t, len(fsx.list_files(root)), 1)
}

// Another thread removes a writer's temporary file while the writer still holds it open (the program's end, a
// download waiting for data): the remove succeeds, and once the writer closes, no part is left. On Windows the file
// was opened without sharing its deletion, and the part stayed (opencode native's the_end_removes_the_temps).
@(test)
a_writer_s_temp_is_removed_from_another_thread :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_writer_remove")
	defer fsx.remove_tree(root)
	path := fmt.tprintf("%s/download.bin", root)
	w: fsx.Writer
	if !testing.expect(t, fsx.writer_open(&w, path)) { return }
	testing.expect(t, fsx.writer_append(&w, transmute([]byte)string("the first part")))
	Remove :: struct { temp: string, ok: bool }
	r := Remove{temp = w.temp}
	th := thread.create_and_start_with_poly_data(&r, proc(r: ^Remove) { r.ok = fsx.delete_file(r.temp) })
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, r.ok, "the remove from another thread succeeds while the writer holds the file")
	fsx.writer_abort(&w)
	testing.expect_value(t, len(fsx.list_files(root)), 0)
	testing.expect_value(t, fsx.path_kind(path), fsx.Path_Kind.Absent)
}

@(private = "file")
Rewriter :: struct { path: string, stop: bool }

// Rewrites the file with one letter or twice as many of another, for read_all to meet in the middle of its read.
@(private = "file")
rewrite :: proc(r: ^Rewriter) {
	short := make([]byte, SIZE_SHORT)
	long := make([]byte, 2 * SIZE_SHORT)
	defer { delete(short); delete(long) }
	for &b in short { b = 'a' }
	for &b in long { b = 'b' }
	// every file at one time, as a coarse clock gives two writes close together (Windows' last write time): the name's
	// size and time cannot tell one file from the next
	at := time.unix(1_700_000_000, 0)
	for !sync.atomic_load(&r.stop) {
		fsx.write_atomic(r.path, short)
		_ = os.change_times(r.path, at, at)
		fsx.write_atomic(r.path, long)
		_ = os.change_times(r.path, at, at)
	}
}

// read_all gives a file as it was at some moment, or nothing: never the start of a larger one that took its place.
@(test)
read_all_never_gives_a_part :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_read_all")
	defer fsx.remove_tree(root)
	r := Rewriter{path = fmt.tprintf("%s/file", root)}
	first := make([]byte, SIZE_SHORT)
	defer delete(first)
	for &b in first { b = 'a' }
	testing.expect(t, fsx.write_atomic(r.path, first))
	th := thread.create_and_start_with_poly_data(&r, rewrite)
	for _ in 0 ..< READS {
		data, ok := fsx.read_all(r.path)
		if !ok { continue }
		whole := len(data) == SIZE_SHORT && data[0] == 'a' || len(data) == 2 * SIZE_SHORT && data[0] == 'b'
		testing.expectf(t, whole, "%d bytes of %c", len(data), data[0])
		delete(data)
		if !whole { break }
	}
	sync.atomic_store(&r.stop, true)
	thread.join(th)
	thread.destroy(th)
}

// The entry of `entries` named `name` (nil: none).
folder_entry :: proc(entries: []fsx.Folder_Entry, name: string) -> ^fsx.Folder_Entry {
	for &e in entries { if e.name == name { return &e } }
	return nil
}

// A folder's entries, each once, "." and ".." left out: a file with its size and time, a folder, neither hidden.
@(test)
read_folder_gives_each_entry_once :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_read_folder")
	defer fsx.remove_tree(root)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/file.txt", root), transmute([]byte)string("abc")) == nil)
	testing.expect(t, fsx.make_dirs(fmt.tprintf("%s/sub", root)))
	entries, err := fsx.read_folder(root)
	defer fsx.folder_entries_delete(entries)
	if !testing.expect_value(t, err, nil) { return }
	testing.expect_value(t, len(entries), 2)
	if f := folder_entry(entries, "file.txt"); testing.expect(t, f != nil, "the file") {
		testing.expect_value(t, f.kind, fsx.Path_Kind.File)
		testing.expect_value(t, f.size, 3)
		testing.expect(t, f.modified > 0, "its last write")
		testing.expect(t, !f.hidden, "not hidden")
	}
	if d := folder_entry(entries, "sub"); testing.expect(t, d != nil, "the folder") {
		testing.expect_value(t, d.kind, fsx.Path_Kind.Directory)
		testing.expect(t, !d.hidden, "not hidden")
	}
	_, missing := fsx.read_folder(fmt.tprintf("%s/none", root))
	testing.expect_value(t, missing, os.General_Error.Not_Exist)
}

// A folder made twice: the second call finds it and says so (Odin's make_directory_all says Exist then).
@(test)
a_folder_made_again_is_there :: proc(t: ^testing.T) {
	root := fmt.tprintf("build/fsx_make_dirs_%d", os.get_pid())
	defer fsx.remove_tree(root)
	dir := fmt.tprintf("%s/a/b", root)
	testing.expect(t, fsx.make_dirs(dir), "made")
	testing.expect(t, fsx.make_dirs(dir), "already there")
}

// The temporary folder is asked from an interface's thread (a menu that writes a file to open): it waits on nothing
// there. On Windows its long form was read on the disk before main, and is kept. With the check (a debug build), a
// blocking call would be counted on that thread.
@(test)
the_temporary_folder_blocks_no_interface_thread :: proc(t: ^testing.T) {
	Ask :: struct { before, after: int, dir: string }
	ask: Ask
	th := thread.create_and_start_with_poly_data(&ask, proc(a: ^Ask) {
		base.interface_thread_mark()
		a.before = base.blocking_count_here()
		a.dir = fsx.temp_dir(context.temp_allocator)
		_ = fsx.temp_dir(context.temp_allocator)
		a.after = base.blocking_count_here()
		a.dir = len(a.dir) > 0 ? "named" : ""
	})
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, ask.dir, "named")
	testing.expect_value(t, ask.after - ask.before, 0)
}
