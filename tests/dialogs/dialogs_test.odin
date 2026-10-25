// The logic of the file dialogs (platform/dialogs.odin): patterns, matching, filters from a web page's accept list, and
// the test hook that stands for the real dialogs (they need a person: never shown here).
//   odin test tests/dialogs -vet
package dialogs_test

import "base:runtime"
import "core:strings"
import "core:testing"
import "../../platform"

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
		if kind == 1 { return {status = .Cancelled} }
		paths := make([]string, 1, allocator)
		paths[0] = strings.clone(kind == 2 ? "C:\\dir" : "C:\\dir\\a.txt", allocator)
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
