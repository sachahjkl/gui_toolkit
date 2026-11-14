#+build windows
package fsx_test

import "core:fmt"
import "core:os"
import win "core:sys/windows"
import "core:testing"
import "../../src/fsx"

// Windows marks a file hidden by its attribute, read with the folder: a hidden file is, a system file alone is not (as
// Explorer shows it), and a name that starts with "." is not either (the system's rule is the attribute).
@(test)
read_folder_reads_the_hidden_attribute :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_read_folder_windows")
	defer fsx.remove_tree(root)
	Made :: struct { name: string, attributes: win.DWORD }
	made := [?]Made{
		{"hidden.txt", win.FILE_ATTRIBUTE_HIDDEN},
		{"system.txt", win.FILE_ATTRIBUTE_SYSTEM},
		{".dot", win.FILE_ATTRIBUTE_NORMAL},
	}
	for m in made {
		path := fmt.tprintf("%s\\%s", root, m.name)
		testing.expect(t, os.write_entire_file(path, transmute([]byte)string("x")) == nil)
		testing.expect(t, bool(win.SetFileAttributesW(win.utf8_to_wstring(path, context.temp_allocator), m.attributes)), m.name)
	}
	hidden_dir := fmt.tprintf("%s\\hidden_dir", root)
	testing.expect(t, fsx.make_dirs(hidden_dir))
	testing.expect(t, bool(win.SetFileAttributesW(win.utf8_to_wstring(hidden_dir, context.temp_allocator), win.FILE_ATTRIBUTE_DIRECTORY | win.FILE_ATTRIBUTE_HIDDEN)))
	entries, err := fsx.read_folder(root)
	defer fsx.folder_entries_delete(entries)
	if !testing.expect_value(t, err, nil) { return }
	testing.expect_value(t, len(entries), 4)
	if e := folder_entry(entries, "hidden.txt"); testing.expect(t, e != nil, "the hidden file") { testing.expect(t, e.hidden, "hidden") }
	if e := folder_entry(entries, "system.txt"); testing.expect(t, e != nil, "the system file") { testing.expect(t, !e.hidden, "shown") }
	if e := folder_entry(entries, ".dot"); testing.expect(t, e != nil, "the dot file") { testing.expect(t, !e.hidden, "no attribute") }
	if e := folder_entry(entries, "hidden_dir"); testing.expect(t, e != nil, "the hidden folder") {
		testing.expect_value(t, e.kind, fsx.Path_Kind.Directory)
		testing.expect(t, e.hidden, "hidden")
	}
}
