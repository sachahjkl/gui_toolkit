// The logic of the file dialogs (platform/dialogs.odin): patterns, matching, filters from a web page's accept list, and
// the test hook that stands for the real dialogs (they need a person: never shown here), and what the system's dialog
// is told for a File_Dialog (file_dialog_call: options, type list, names, folder) without opening it.
//   odin test tests/dialogs -vet
package dialogs_test

import "base:runtime"
import "core:strings"
import "core:testing"
import win "core:sys/windows"
import "../../src/platform"

@(test)
patterns_are_normalized :: proc(t: ^testing.T) {
	p := platform.filter_patterns({name = "Images", patterns = {"*.png", "jpg", ".gif", " "}}, context.temp_allocator)
	testing.expect_value(t, p, "*.png;*.jpg;*.gif")
	testing.expect_value(t, platform.filter_patterns({name = "All"}, context.temp_allocator), "*.*")
	testing.expect_value(t, platform.filter_patterns({patterns = {"*"}}, context.temp_allocator), "*.*")
}

@(test)
names_match_case_insensitively :: proc(t: ^testing.T) {
	f := []platform.File_Filter{{name = "Text", patterns = {"*.txt", "*.md"}}}
	testing.expect(t, platform.filter_matches(f, "notes.TXT"))
	testing.expect(t, platform.filter_matches(f, "a.md"))
	testing.expect(t, !platform.filter_matches(f, "a.mdx"))
	testing.expect(t, !platform.filter_matches(f, "txt"))
	testing.expect(t, platform.filter_matches({}, "anything"))
	testing.expect(t, platform.filter_matches([]platform.File_Filter{{patterns = {"*.*"}}}, "x"))
}

@(test)
filters_from_a_web_accept_list :: proc(t: ^testing.T) {
	exts :: proc(mime: string) -> []string {
		@(static) png := [1]string{"png"}
		if mime == "image/png" { return png[:] }
		return nil
	}
	entries := []platform.Accept_Entry{
		{description = "Pictures", mime = "image/png", extensions = {".png", "apng"}},
		{mime = "image/png"},
		{mime = "application/x-unknown"},
	}
	fs := platform.filters_from_accept(entries, exts)
	defer platform.filters_destroy(fs)
	testing.expect_value(t, len(fs), 2)
	if len(fs) == 2 {
		testing.expect_value(t, fs[0].name, "Pictures")
		testing.expect_value(t, platform.filter_patterns(fs[0], context.temp_allocator), "*.png;*.apng")
		testing.expect_value(t, fs[1].name, "image/png")
		testing.expect_value(t, platform.filter_patterns(fs[1], context.temp_allocator), "*.png")
	}
}

@(test)
the_test_hook_answers_for_the_dialogs :: proc(t: ^testing.T) {
	platform.dialog_test_hook = proc(kind: int, d: platform.File_Dialog, allocator: runtime.Allocator) -> platform.Dialog_Result {
		if kind == platform.DIALOG_SAVE { return {status = .Cancelled} }
		paths := make([]string, 1, allocator)
		paths[0] = strings.clone(kind == platform.DIALOG_FOLDER ? "C:\\dir" : "C:\\dir\\a.txt", allocator)
		return {status = .Chosen, paths = paths}
	}
	defer platform.dialog_test_hook = nil
	r := platform.open_file_dialog({multiple = true})
	defer platform.dialog_result_destroy(&r)
	testing.expect_value(t, r.status, platform.Dialog_Status.Chosen)
	testing.expect_value(t, len(r.paths), 1)
	s := platform.save_file_dialog({suggested_name = "x.txt"})
	testing.expect_value(t, s.status, platform.Dialog_Status.Cancelled)
	f := platform.pick_folder_dialog({})
	defer platform.dialog_result_destroy(&f)
	testing.expect(t, len(f.paths) == 1 && f.paths[0] == "C:\\dir")
}

@(test)
an_open_dialog_call :: proc(t: ^testing.T) {
	filters := []platform.File_Filter{{name = "Images", patterns = {"png", "*.jpg"}}, {patterns = {".txt"}}}
	c := platform.file_dialog_call(platform.DIALOG_OPEN, {filters = filters, all_files = true, filter_index = 9, multiple = true, title = "Pick"})
	testing.expect_value(t, len(c.types), 3)
	if len(c.types) == 3 {
		testing.expect_value(t, c.types[0], platform.File_Dialog_Type{"Images", "*.png;*.jpg"})
		testing.expect_value(t, c.types[1], platform.File_Dialog_Type{"*.txt", "*.txt"})   // no name: its patterns
		testing.expect_value(t, c.types[2], platform.File_Dialog_Type{platform.ALL_FILES_NAME, platform.ALL_FILES_SPEC})
	}
	testing.expect_value(t, c.type_index, u32(3))   // a line past the list: the last one (1-based)
	testing.expect_value(t, c.title, "Pick")
	want: win.FILEOPENDIALOGOPTIONS = win.FOS_FORCEFILESYSTEM | win.FOS_PATHMUSTEXIST | win.FOS_FILEMUSTEXIST | win.FOS_ALLOWMULTISELECT
	testing.expect_value(t, c.set_options, want)
	testing.expect_value(t, c.clear_options, 0)
	testing.expect_value(t, c.file_name, "")
	single := platform.file_dialog_call(platform.DIALOG_OPEN, {filters = filters, filter_index = 1})
	testing.expect_value(t, single.set_options & win.FOS_ALLOWMULTISELECT, 0)
	testing.expect_value(t, len(single.types), 2)   // no "All files" line unless asked
	testing.expect_value(t, single.type_index, u32(2))
}

@(test)
a_save_dialog_call :: proc(t: ^testing.T) {
	c := platform.file_dialog_call(platform.DIALOG_SAVE, {suggested_name = "notes.txt", default_ext = ".txt"})
	testing.expect_value(t, c.file_name, "notes.txt")
	testing.expect_value(t, c.default_ext, "txt")   // the system wants it without the dot
	testing.expect_value(t, c.clear_options, win.FOS_OVERWRITEPROMPT)   // not asked: the system's default question is taken off
	testing.expect_value(t, c.set_options & (win.FOS_OVERWRITEPROMPT | win.FOS_FILEMUSTEXIST), 0)
	if testing.expect_value(t, len(c.types), 1) {   // no filter: one "All files" line
		testing.expect_value(t, c.types[0].spec, platform.ALL_FILES_SPEC)
	}
	testing.expect_value(t, c.type_index, u32(1))
	asked := platform.file_dialog_call(platform.DIALOG_SAVE, {overwrite_prompt = true})
	testing.expect_value(t, asked.set_options & win.FOS_OVERWRITEPROMPT, win.FOS_OVERWRITEPROMPT)
	testing.expect_value(t, asked.clear_options, 0)
}

@(test)
a_folder_dialog_call :: proc(t: ^testing.T) {
	c := platform.file_dialog_call(platform.DIALOG_FOLDER, {filters = {{name = "x", patterns = {"*.x"}}}, start_dir = "C:\\work", remember_id = "export", suggested_name = "ignored"})
	testing.expect_value(t, len(c.types), 0)   // a folder has no type list
	testing.expect_value(t, c.set_options & win.FOS_PICKFOLDERS, win.FOS_PICKFOLDERS)
	testing.expect_value(t, c.file_name, "")
	testing.expect_value(t, c.folder, "C:\\work")
	testing.expect(t, c.folder_forced, "an explicit folder wins over the one remembered")
	testing.expect(t, c.remember)
	again := platform.file_dialog_call(platform.DIALOG_OPEN, {remember_id = "export"})
	other := platform.file_dialog_call(platform.DIALOG_OPEN, {remember_id = "import"})
	testing.expect(t, again.client_guid == c.client_guid, "one id, one GUID")
	testing.expect(t, other.client_guid != c.client_guid, "two ids, two GUIDs")
	none := platform.file_dialog_call(platform.DIALOG_OPEN, {})
	testing.expect(t, !none.remember && none.folder == "")
	known := platform.file_dialog_call(platform.DIALOG_OPEN, {start_known = .Documents})
	testing.expect_value(t, known.folder, platform.known_folder_path(.Documents, context.temp_allocator))
	testing.expect(t, !known.folder_forced, "a known folder is only the default")
}