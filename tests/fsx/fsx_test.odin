// Moved here with the file helpers it covers (was Wren's src/base/base_test.odin, remove_tree over temp_dir).
//   odin test tests/fsx -vet
package fsx_test

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "../../fsx"

// The smaller file of two (read_all_never_gives_a_part).
SIZE_SHORT :: 4096
// Enough reads to fall between a stat and a read many times over.
READS :: 20000

fresh_dir :: proc(name: string) -> string {
	root := fmt.tprintf("%s/%s", fsx.temp_dir(context.temp_allocator), name)
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

@(private = "file")
Rewriter :: struct { path: string, stop: bool }

// Rewrites the file with one letter or twice as many of another, for read_all to meet between its stat and its read.
@(private = "file")
rewrite :: proc(r: ^Rewriter) {
	short := make([]byte, SIZE_SHORT)
	long := make([]byte, 2 * SIZE_SHORT)
	defer { delete(short); delete(long) }
	for &b in short { b = 'a' }
	for &b in long { b = 'b' }
	for !sync.atomic_load(&r.stop) {
		fsx.write_atomic(r.path, short)
		fsx.write_atomic(r.path, long)
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
