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
	testing.expect(t, fsx.write_atomic(name, transmute([]byte)string("data"), flush = true))
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
	testing.expect(t, fsx.write_atomic(path, transmute([]byte)string("data"), private = true))
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
