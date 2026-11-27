#+build linux
package fsx_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "gt:fsx"

// A name with no directory is in the current one, which is the directory to sync.
@(test)
a_durable_write_of_a_bare_name :: proc(t: ^testing.T) {
	name := fmt.tprintf("gui_toolkit_fsx_bare_%d", os.get_pid())
	defer fsx.delete_file(name)
	testing.expect(t, fsx.write_atomic(name, transmute([]byte)string("data"), {flush = true}))
}

// `durable` is a promise: a directory that could not be synced is said to be so, though the name did change.
@(test)
a_durable_replace_says_it_could_not_sync :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_durable")
	defer fsx.remove_tree(root)
	from := fmt.tprintf("%s/from", root)
	to := fmt.tprintf("%s/to", root)
	testing.expect(t, os.write_entire_file(from, transmute([]byte)string("data")) == nil)
	testing.expect(t, fsx.replace(from, to, true), "a directory that can be synced")
	testing.expect(t, os.write_entire_file(from, transmute([]byte)string("data")) == nil)
	// (written and searched, not read: it cannot be opened to sync; root ignores that)
	if posix.getuid() == 0 { return }
	dir := strings.clone_to_cstring(root, context.temp_allocator)
	testing.expect_value(t, posix.chmod(dir, {.IWUSR, .IXUSR}), posix.result.OK)
	defer posix.chmod(dir, {.IRUSR, .IWUSR, .IXUSR})
	testing.expect(t, !fsx.replace(from, to, true), "it is not on the disk")
}
// A private file is its user's from its creation: the temporary file is made 0600, and the rename keeps it.
@(test)
a_private_write_is_readable_by_its_user_only :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_private")
	defer fsx.remove_tree(root)
	path := fmt.tprintf("%s/secret", root)
	testing.expect(t, fsx.write_atomic(path, transmute([]byte)string("data"), {private = true}))
	st: posix.stat_t
	testing.expect(t, posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK, "written")
	testing.expect_value(t, st.st_mode & {.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}, posix.mode_t{})
}

// A private folder is made 0700 with its missing parents; one of this user's open to others is closed; a link at the name is
// refused, its target left as it was. (A folder of another user cannot be made without root: fstat's owner check stays
// untested here.)
@(test)
a_private_folder_is_its_user_s_alone :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_private_dir")
	defer fsx.remove_tree(root)
	mode_of :: proc(path: string) -> (posix.mode_t, bool) {
		st: posix.stat_t
		if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK { return {}, false }
		return st.st_mode, true
	}
	OTHERS :: posix.mode_t{.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}

	made := fmt.tprintf("%s/parent/made", root)
	testing.expect(t, fsx.private_dir(made), "made with its parent")
	if m, ok := mode_of(made); testing.expect(t, ok, "there") {
		testing.expect(t, posix.S_ISDIR(m), "a folder")
		testing.expect_value(t, m & OTHERS, posix.mode_t{})
	}
	testing.expect(t, fsx.private_dir(made), "already there and private")

	open := fmt.tprintf("%s/open", root)
	testing.expect(t, fsx.make_dirs(open))
	testing.expect_value(t, posix.chmod(strings.clone_to_cstring(open, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}), posix.result.OK)
	testing.expect(t, fsx.private_dir(open), "this user's: closed")
	if m, ok := mode_of(open); ok { testing.expect_value(t, m & OTHERS, posix.mode_t{}) }

	target := fmt.tprintf("%s/target", root)
	testing.expect(t, fsx.make_dirs(target))
	testing.expect_value(t, posix.chmod(strings.clone_to_cstring(target, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}), posix.result.OK)
	link := fmt.tprintf("%s/link", root)
	testing.expect_value(t, posix.symlink("target", strings.clone_to_cstring(link, context.temp_allocator)), posix.result.OK)
	testing.expect(t, !fsx.private_dir(link), "a link is refused")
	if m, ok := mode_of(target); ok { testing.expect(t, m & OTHERS != {}, "its target untouched") }
	testing.expect_value(t, fsx.path_kind(link), fsx.Path_Kind.Link)
}

// Linux marks no file hidden but by its name: one that starts with "." is; a link is a Link, not followed.
@(test)
read_folder_hides_dot_names_and_keeps_links :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_read_folder_linux")
	defer fsx.remove_tree(root)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/.dot", root), transmute([]byte)string("x")) == nil)
	testing.expect(t, fsx.make_dirs(fmt.tprintf("%s/sub", root)))
	link := strings.clone_to_cstring(fmt.tprintf("%s/link", root), context.temp_allocator)
	testing.expect_value(t, posix.symlink("sub", link), posix.result.OK)
	entries, err := fsx.read_folder(root)
	defer fsx.folder_entries_delete(entries)
	if !testing.expect_value(t, err, nil) { return }
	if d := folder_entry(entries, ".dot"); testing.expect(t, d != nil, "the dot file") { testing.expect(t, d.hidden, "hidden by its name") }
	if l := folder_entry(entries, "link"); testing.expect(t, l != nil, "the link") {
		testing.expect_value(t, l.kind, fsx.Path_Kind.Link)
		testing.expect(t, !l.hidden, "not hidden")
	}
}

@(test)
stat_follow_follows_links_and_reports_broken_ones :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_stat_follow")
	defer fsx.remove_tree(root)
	file := fmt.tprintf("%s/five.txt", root)
	dir := fmt.tprintf("%s/sub", root)
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string("12345")) == nil)
	testing.expect(t, fsx.make_dirs(dir))
	file_link := fmt.tprintf("%s/file_link", root)
	dir_link := fmt.tprintf("%s/dir_link", root)
	broken := fmt.tprintf("%s/broken", root)
	testing.expect_value(t, posix.symlink("five.txt", strings.clone_to_cstring(file_link, context.temp_allocator)), posix.result.OK)
	testing.expect_value(t, posix.symlink("sub", strings.clone_to_cstring(dir_link, context.temp_allocator)), posix.result.OK)
	testing.expect_value(t, posix.symlink("gone", strings.clone_to_cstring(broken, context.temp_allocator)), posix.result.OK)
	kind, size := fsx.stat_follow(file_link)
	testing.expect_value(t, kind, fsx.Path_Kind.File)
	testing.expect_value(t, size, 5)
	kind, size = fsx.stat_follow(dir_link)
	testing.expect_value(t, kind, fsx.Path_Kind.Directory)
	testing.expect_value(t, size, 0)
	kind, _ = fsx.stat_follow(broken)
	testing.expect_value(t, kind, fsx.Path_Kind.Absent)
	kind, _ = fsx.stat_follow(fmt.tprintf("%s/missing", root))
	testing.expect_value(t, kind, fsx.Path_Kind.Absent)
}

// A person's document (fsx.DOCUMENT) written through a chain of links: the file at its end is replaced, the links stay
// links, and the file keeps its mode (0640 here, not the 0644 of a new file) and its owner and group.
@(test)
a_document_keeps_its_mode_and_is_written_through_its_links :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_document")
	defer fsx.remove_tree(root)
	file := fmt.tprintf("%s/notes.txt", root)
	near := fmt.tprintf("%s/near", root)
	far := fmt.tprintf("%s/far", root)
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string("old")) == nil)
	c := proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) }
	testing.expect_value(t, posix.chmod(c(file), {.IRUSR, .IWUSR, .IRGRP}), posix.result.OK)
	testing.expect_value(t, posix.symlink("notes.txt", c(near)), posix.result.OK)   // (relative: from the link's folder)
	testing.expect_value(t, posix.symlink(c(near), c(far)), posix.result.OK)
	rep: fsx.Write_Report
	testing.expect(t, fsx.write_atomic(far, transmute([]byte)string("new"), fsx.DOCUMENT, &rep))
	testing.expect_value(t, rep.target, file)
	testing.expect(t, rep.existed && rep.kept, "written over, all it had kept")
	testing.expect(t, rep.flushed, "on the disk")
	testing.expect_value(t, rep.hard_links, 0)
	testing.expect_value(t, fsx.path_kind(far), fsx.Path_Kind.Link)
	testing.expect_value(t, fsx.path_kind(near), fsx.Path_Kind.Link)
	data, _ := os.read_entire_file(file, context.temp_allocator)
	testing.expect_value(t, string(data), "new")
	st: posix.stat_t
	testing.expect(t, posix.stat(c(file), &st) == .OK)
	testing.expect_value(t, st.st_mode & {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}, posix.mode_t{.IRUSR, .IWUSR, .IRGRP})
	testing.expect_value(t, st.st_uid, posix.getuid())
	// nothing left beside it
	entries, _ := os.read_all_directory_by_path(root, context.temp_allocator)
	testing.expect_value(t, len(entries), 3)

	// without `follow` the link itself is replaced by a file, as before
	testing.expect(t, fsx.write_atomic(far, transmute([]byte)string("plain")))
	testing.expect_value(t, fsx.path_kind(far), fsx.Path_Kind.File)
	data, _ = os.read_entire_file(file, context.temp_allocator)
	testing.expect_value(t, string(data), "new")
}

// A file of two names: the write is said to leave the other name on the old content (a rename makes a new file).
// `private` with `keep`: the owner and group kept, the mode 0600 whatever the file had.
@(test)
a_document_with_another_name_is_reported :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_hard_link")
	defer fsx.remove_tree(root)
	file := fmt.tprintf("%s/a", root)
	other := fmt.tprintf("%s/b", root)
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string("old")) == nil)
	c := proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) }
	testing.expect_value(t, posix.chmod(c(file), {.IRUSR, .IWUSR, .IRGRP, .IROTH}), posix.result.OK)
	testing.expect_value(t, posix.link(c(file), c(other)), posix.result.OK)
	rep: fsx.Write_Report
	testing.expect(t, fsx.write_atomic(file, transmute([]byte)string("new"), {flush = true, keep = true, private = true}, &rep))
	testing.expect_value(t, rep.hard_links, 1)
	data, _ := os.read_entire_file(other, context.temp_allocator)
	testing.expect_value(t, string(data), "old")
	st: posix.stat_t
	testing.expect(t, posix.stat(c(file), &st) == .OK)
	testing.expect_value(t, st.st_mode & {.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}, posix.mode_t{})
	testing.expect_value(t, int(st.st_nlink), 1)

	// a new document: nothing written over, the mode of a new file
	fresh := fmt.tprintf("%s/fresh", root)
	rep = {}
	testing.expect(t, fsx.write_atomic(fresh, transmute([]byte)string("x"), fsx.DOCUMENT, &rep))
	testing.expect(t, !rep.existed && !rep.kept, "a new file")
	testing.expect(t, posix.stat(c(fresh), &st) == .OK)
	testing.expect(t, .IRUSR in st.st_mode && .IWUSR in st.st_mode, "its user's")
}

// A chain of links that loops is refused, as the system refuses to open it: no link of the loop becomes a file.
@(test)
a_document_behind_a_loop_of_links_is_refused :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_link_loop")
	defer fsx.remove_tree(root)
	c := proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) }
	a, b, l := fmt.tprintf("%s/a", root), fmt.tprintf("%s/b", root), fmt.tprintf("%s/c", root)
	testing.expect_value(t, posix.symlink("b", c(a)), posix.result.OK)
	testing.expect_value(t, posix.symlink("c", c(b)), posix.result.OK)
	testing.expect_value(t, posix.symlink("a", c(l)), posix.result.OK)
	testing.expect(t, !fsx.write_atomic(a, transmute([]byte)string("new"), fsx.DOCUMENT), "refused")
	for p in ([]string{a, b, l}) { testing.expect_value(t, fsx.path_kind(p), fsx.Path_Kind.Link) }
	entries, _ := os.read_all_directory_by_path(root, context.temp_allocator)
	testing.expect_value(t, len(entries), 3)
}

// The temporary file is made new: a link planted at its name (or a file a crash left, of a wider mode) is not written
// through, and the document is never readable wider than its mode while it is written.
@(test)
a_link_at_the_temporary_name_is_not_written_through :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_planted")
	defer fsx.remove_tree(root)
	c := proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) }
	file, victim := fmt.tprintf("%s/doc", root), fmt.tprintf("%s/victim", root)
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string("old")) == nil)
	testing.expect(t, os.write_entire_file(victim, transmute([]byte)string("victim")) == nil)
	tmp := fmt.tprintf("%s.%d.%d.tmp", file, os.get_pid(), os.get_current_thread_id())
	testing.expect_value(t, posix.symlink(c(victim), c(tmp)), posix.result.OK)
	testing.expect(t, fsx.write_atomic(file, transmute([]byte)string("new"), fsx.DOCUMENT))
	data, _ := os.read_entire_file(victim, context.temp_allocator)
	testing.expect_value(t, string(data), "victim")
	data, _ = os.read_entire_file(file, context.temp_allocator)
	testing.expect_value(t, string(data), "new")
	testing.expect_value(t, fsx.path_kind(tmp), fsx.Path_Kind.Absent)
}
