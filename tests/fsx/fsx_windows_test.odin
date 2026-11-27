#+build windows
package fsx_test

import "core:fmt"
import "core:os"
import win "core:sys/windows"
import "core:testing"
import "gt:fsx"

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

// A junction is a .Link to path_kind and a .Directory to stat_follow, with no heap allocation.
@(test)
stat_follow_follows_a_junction :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_stat_follow_windows")
	defer fsx.remove_tree(root)
	file := fmt.tprintf("%s\\five.txt", root)
	target := fmt.tprintf("%s\\real_dir", root)
	link := fmt.tprintf("%s\\junction_dir", root)
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string("12345")) == nil)
	testing.expect(t, fsx.make_dirs(target))
	state, out, errs, err := os.process_exec(os.Process_Desc{command = {"cmd.exe", "/c", "mklink", "/J", link, target}}, context.temp_allocator)
	if !testing.expectf(t, err == nil && state.exit_code == 0, "mklink /J %s %s: %v %v\n%s%s", link, target, err, state.exit_code, string(out), string(errs)) { return }
	testing.expect_value(t, fsx.path_kind(link), fsx.Path_Kind.Link)
	kind, size := fsx.stat_follow(link)
	testing.expect_value(t, kind, fsx.Path_Kind.Directory)
	testing.expect_value(t, size, 0)
	kind, size = fsx.stat_follow(file)
	testing.expect_value(t, kind, fsx.Path_Kind.File)
	testing.expect_value(t, size, 5)
	kind, _ = fsx.stat_follow(fmt.tprintf("%s\\missing", root))
	testing.expect_value(t, kind, fsx.Path_Kind.Absent)
}

// A person's document (fsx.DOCUMENT) written over a file keeps what MoveFileExW lost: its attributes (hidden here) and
// its creation time (ReplaceFileW). A second name of the file is reported: it keeps the old content.
@(test)
a_document_keeps_its_attributes_and_creation_time :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_document_windows")
	defer fsx.remove_tree(root)
	file := fmt.tprintf("%s\\notes.txt", root)
	other := fmt.tprintf("%s\\other.txt", root)
	wfile := win.utf8_to_wstring(file, context.temp_allocator)
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string("old")) == nil)
	testing.expect(t, bool(win.CreateHardLinkW(win.utf8_to_wstring(other, context.temp_allocator), wfile, nil)), "a second name")
	// (an old creation time: a new file would have now)
	created := win.FILETIME{dwLowDateTime = 0, dwHighDateTime = OLD_FILETIME_HIGH}
	if h := win.CreateFileW(wfile, win.FILE_WRITE_ATTRIBUTES, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil); testing.expect(t, h != win.INVALID_HANDLE_VALUE, "open") {
		testing.expect(t, bool(SetFileTime(h, &created, nil, nil)), "SetFileTime")
		win.CloseHandle(h)
	}
	testing.expect(t, bool(win.SetFileAttributesW(wfile, win.FILE_ATTRIBUTE_HIDDEN)), "hidden")
	rep: fsx.Write_Report
	testing.expect(t, fsx.write_atomic(file, transmute([]byte)string("new"), fsx.DOCUMENT, &rep))
	testing.expect(t, rep.existed && rep.kept, "written over, all it had kept")
	testing.expect(t, rep.flushed, "on the disk")
	testing.expect_value(t, rep.hard_links, 1)
	data, _ := os.read_entire_file(file, context.temp_allocator)
	testing.expect_value(t, string(data), "new")
	attrs := win.GetFileAttributesW(wfile)
	testing.expect(t, attrs != win.INVALID_FILE_ATTRIBUTES && attrs & win.FILE_ATTRIBUTE_HIDDEN != 0, "still hidden")
	info: win.WIN32_FILE_ATTRIBUTE_DATA
	testing.expect(t, bool(win.GetFileAttributesExW(wfile, win.GetFileExInfoStandard, &info)), "its times")
	testing.expect_value(t, info.ftCreationTime.dwHighDateTime, OLD_FILETIME_HIGH)
	data, _ = os.read_entire_file(other, context.temp_allocator)
	testing.expect_value(t, string(data), "old")
}
// (about 1985)
@(private = "file") OLD_FILETIME_HIGH :: 0x01A0_0000

foreign import kernel32_times "system:Kernel32.lib"
@(private = "file", default_calling_convention = "system")
foreign kernel32_times {
	SetFileTime :: proc(hFile: win.HANDLE, lpCreationTime, lpLastAccessTime, lpLastWriteTime: ^win.FILETIME) -> win.BOOL ---
}
