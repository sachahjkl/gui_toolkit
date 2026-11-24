package prefs_page_test

// A program's standard files (prefs_page.program_files) and the start of its preferences (prefs_page.prefs_open): the
// paths in the config and state folders; in memory, none, so nothing is read (opencode native's tests); a test that keeps
// one file beside its own (classeur's <session>.prefs) reads it; the command line's --pref over the file, the rest given
// back, the problems of both.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import config "gt:config"
import prefs_page "gt:prefs_page"
import "gt:testkit"

@(private = "file")
FILES_DEFS := [?]config.Def{
	{name = "sample.count", description = "A count.", kind = .Int, default = {i = 3}},
	{name = "sample.word", description = "A word.", kind = .String, default = {s = "plain"}},
}

@(test)
the_files_are_in_the_program_s_folders :: proc(t: ^testing.T) {
	f := prefs_page.program_files("gt-files-test")
	defer prefs_page.program_files_destroy(&f)
	if f.config_dir == "" || f.state_dir == "" { return }   // (a machine with no user folders: nothing to check)
	check :: proc(t: ^testing.T, path, dir, name: string) {
		testing.expectf(t, filepath.dir(path) == dir, "%s in %s", path, dir)
		testing.expect_value(t, filepath.base(path), name)
	}
	check(t, f.prefs, f.config_dir, "prefs")
	check(t, f.themes, f.config_dir, "themes.txt")
	check(t, f.views, f.state_dir, "views.txt")
	check(t, f.palette_choices, f.state_dir, "palette_choices.txt")
	check(t, f.file_dialogs, f.state_dir, "file_dialogs.txt")
	testing.expect(t, strings.contains(f.config_dir, "gt-files-test"), "the program's own folder")
}

@(test)
in_memory_nothing_is_read_and_a_test_may_keep_one_file :: proc(t: ^testing.T) {
	m := prefs_page.program_files("gt-files-test", memory = true)
	defer prefs_page.program_files_destroy(&m)
	testing.expect(t, m.prefs == "" && m.themes == "" && m.views == "" && m.palette_choices == "" && m.file_dialogs == "", "no path")

	// opencode native's tests: no file, the defaults and the command line
	p: config.Prefs
	defer config.prefs_destroy(&p)
	rest, problems := prefs_page.prefs_open(&p, m, prefs_page.STANDARD_ALL, prefs_page.STANDARD_DEFAULTS, {FILES_DEFS[:]}, {"--pref", "sample.word=given", "file.txt"}, context.temp_allocator)
	testing.expect_value(t, config.int_of(&p, "sample.count"), 3)
	testing.expect_value(t, config.string_of(&p, "sample.word"), "given")
	testing.expect(t, config.ref_of(&p, prefs_page.THEME_PREF) != config.NO_REF, "the standard preferences")
	testing.expect(t, config.ref_of(&p, prefs_page.SEEN_VERSION_PREF) != config.NO_REF, "What's new's version")
	testing.expect_value(t, len(problems), 0)
	if testing.expect_value(t, len(rest), 1) { testing.expect_value(t, rest[0], "file.txt") }

	// classeur's tests: memory, but the preferences beside the session's file
	dir := testkit.temp_folder(t)
	session_prefs, _ := filepath.join({dir, "session.prefs"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(session_prefs, transmute([]byte)string(config.USER_MAGIC + "\nsample.count\t7\nsample.word\tfrom-file\na broken line\n")) == nil, "written")
	k := prefs_page.program_files("gt-files-test", memory = true)
	defer prefs_page.program_files_destroy(&k)
	k.prefs = strings.clone(session_prefs, k.allocator)
	q: config.Prefs
	defer config.prefs_destroy(&q)
	_, q_problems := prefs_page.prefs_open(&q, k, prefs_page.STANDARD_ALL + {.Rows}, prefs_page.STANDARD_DEFAULTS, {FILES_DEFS[:]}, {"--pref", "sample.word=over"}, context.temp_allocator)
	testing.expect_value(t, config.int_of(&q, "sample.count"), 7)
	testing.expect_value(t, config.string_of(&q, "sample.word"), "over")   // (the command line's over the file)
	testing.expect(t, len(q_problems) >= 1, "the file's broken line is said")
}
