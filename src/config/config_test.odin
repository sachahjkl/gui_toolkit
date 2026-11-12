package tk_config

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../fsx"

@(private = "file")
DEFS := [?]Def{
	{name = "net.max_conns", description = "Connections per host", kind = .Int, default = {i = 6}, bounded = true, min = 1, max = 64},
	{name = "net.max_body", description = "Largest response", kind = .Int, default = {i = 256 << 20}, bytes = true, unit = "bytes", bounded = true, min = 0, max = 1 << 40},
	{name = "net.enabled", description = "Network on", kind = .Bool, default = {b = true}},
	{name = "net.agent", description = "UA", kind = .String, default = {s = "wb/1"}},
	{name = "ui.scale", description = "Scale", kind = .Float, default = {f = 1.0}, bounded = true, min = 0.5, max = 3},
	{name = "ui.mode", description = "Mode", kind = .String, default = {s = "auto"}, choices = {"auto", "dark", "light"}, restart = true},
}

// What a program does on one thread: the text, then the file.
@(private = "file")
save :: proc(p: ^Prefs, path: string) -> bool { return write_user_file(path, serialize_user(p, context.temp_allocator)) }

@(private = "file")
Seen :: struct { names: [dynamic]string, calls: int }

@(private = "file")
observer :: proc(user: rawptr, name: string, p: ^Prefs) {
	s := (^Seen)(user)
	s.calls += 1
	append(&s.names, name)
}

@(test)
defaults_and_typed_reads :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	testing.expect_value(t, int_of(&p, "net.max_conns"), 6)
	testing.expect_value(t, bool_of(&p, "net.enabled"), true)
	testing.expect_value(t, string_of(&p, "net.agent"), "wb/1")
	testing.expect_value(t, float_of(&p, "ui.scale"), 1.0)
	testing.expect_value(t, entry(&p, ref_of(&p, "net.max_conns")).def.category, "net")
	testing.expect(t, ref_of(&p, "nope") == NO_REF)
	register(&p, DEFS[:])   // idempotent
	testing.expect_value(t, len(p.entries), 6)
}

@(test)
validation :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "12", .User), Set_Error.None)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 12)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "0", .User), Set_Error.Out_Of_Range)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "65", .User), Set_Error.Out_Of_Range)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "abc", .User), Set_Error.Bad_Type)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "1_0", .User), Set_Error.None)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 10)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 10, )
	testing.expect_value(t, set_from_string(&p, "net.max_body", "64M", .User), Set_Error.None)
	testing.expect_value(t, int_of(&p, "net.max_body"), 64 << 20)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "4K", .User), Set_Error.Bad_Type)   // suffixes only for byte prefs
	testing.expect_value(t, set_from_string(&p, "net.enabled", "off", .User), Set_Error.None)
	testing.expect_value(t, bool_of(&p, "net.enabled"), false)
	testing.expect_value(t, set_from_string(&p, "net.enabled", "maybe", .User), Set_Error.Bad_Type)
	testing.expect_value(t, set_from_string(&p, "ui.scale", "2.5", .User), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "ui.scale", "9", .User), Set_Error.Out_Of_Range)
	testing.expect_value(t, set_from_string(&p, "ui.scale", "nan", .User), Set_Error.Bad_Type)
	testing.expect_value(t, set_from_string(&p, "ui.mode", "dark", .User), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "ui.mode", "neon", .User), Set_Error.Not_A_Choice)
	testing.expect_value(t, set_from_string(&p, "net.agent", "  spaced  ", .User), Set_Error.None)
	testing.expect_value(t, string_of(&p, "net.agent"), "  spaced  ")
	testing.expect_value(t, set_from_string(&p, "no.such", "1", .User), Set_Error.Unknown)
}

@(test)
layers_and_locks :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	set_from_string(&p, "net.max_conns", "8", .User)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "16", .Command_Line), Set_Error.None)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 16)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "3", .User), Set_Error.Locked)   // the command line wins this run
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "20", .Policy), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "5", .Command_Line), Set_Error.Locked)
	testing.expect_value(t, reset(&p, "net.max_conns"), Set_Error.Locked)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 20)

	// reset returns a user value to its default
	set_from_string(&p, "net.agent", "mine", .User)
	testing.expect(t, !is_default(&p, ref_of(&p, "net.agent")))
	testing.expect_value(t, reset(&p, "net.agent"), Set_Error.None)
	testing.expect_value(t, string_of(&p, "net.agent"), "wb/1")
	testing.expect(t, is_default(&p, ref_of(&p, "net.agent")))
}

@(test)
observers_by_prefix :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	s: Seen
	defer delete(s.names)
	id := watch(&p, "net.", observer, &s)
	set_from_string(&p, "net.max_conns", "7", .User)
	set_from_string(&p, "ui.scale", "2", .User)             // other prefix: not observed
	set_from_string(&p, "net.max_conns", "7", .User)         // same value: no notification
	set_from_string(&p, "net.agent", "x", .User)
	testing.expect_value(t, s.calls, 2)
	testing.expect_value(t, s.names[0], "net.max_conns")
	unwatch(&p, id)
	set_from_string(&p, "net.agent", "y", .User)
	testing.expect_value(t, s.calls, 2)
}

@(test)
command_line :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	args := []string{"https://example.com", "--pref", "net.max_conns=32", "--pref=net.agent=cli/9", "--other", "--pref", "bad", "--pref", "net.max_conns=999"}
	register(&p, DEFS[:])
	rest, errors := apply_args(&p, args)
	defer delete(rest)
	defer delete(errors)
	for e in errors { delete(e) }
	testing.expect_value(t, int_of(&p, "net.max_conns"), 32)   // the out-of-range second value was refused
	testing.expect_value(t, string_of(&p, "net.agent"), "cli/9")
	testing.expect_value(t, len(rest), 2)                       // the shell's own arguments are returned
	testing.expect_value(t, len(errors), 2)                     // "bad" and the out-of-range value
}

@(test)
values_set_before_registration_apply_later :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	// profile file and command line are read before the subsystems register their definitions
	set_from_string(&p, "net.max_conns", "9", .User)
	set_from_string(&p, "net.max_conns", "30", .Command_Line)
	set_from_string(&p, "net.agent", "pre", .User)
	register(&p, DEFS[:])
	testing.expect_value(t, int_of(&p, "net.max_conns"), 30)   // the higher layer wins
	testing.expect_value(t, string_of(&p, "net.agent"), "pre")
	testing.expect_value(t, entry(&p, ref_of(&p, "net.agent")).source, Source.User)
}

@(test)
user_text_of_registered_and_unregistered :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	set_from_string(&p, "old.gone", "https://x.test/?q=%s", .User)   // no longer registered: read once to migrate it
	register(&p, DEFS[:])
	s, ok := user_text(&p, "old.gone")
	testing.expect(t, ok && s == "https://x.test/?q=%s", "an unregistered user value")
	_, ok = user_text(&p, "net.agent")
	testing.expect(t, !ok, "a default is no user value")
	set_from_string(&p, "net.agent", "mine", .User)
	set_from_string(&p, "net.agent", "cli", .Command_Line)
	s, ok = user_text(&p, "net.agent")
	testing.expect(t, ok && s == "mine", "the user's value under a command line one")
	_, ok = user_text(&p, "never.seen")
	testing.expect(t, !ok)
}

@(test)
persistence :: proc(t: ^testing.T) {
	path := "build/prefs_test.txt"
	defer os.remove(path)
	{
		p := prefs_make()
		defer prefs_destroy(&p)
		register(&p, DEFS[:])
		set_from_string(&p, "net.max_conns", "11", .User)
		set_from_string(&p, "net.agent", "tab\tand\nnewline\\", .User)
		set_from_string(&p, "ui.scale", "2", .Command_Line)        // not persisted
		set_from_string(&p, "future.pref", "kept", .User)           // unknown now: must survive a round trip
		testing.expect(t, save(&p, path))
	}
	p := prefs_make()
	defer prefs_destroy(&p)
	n, problems := load_file(&p, path, .User)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, n, 3)
	register(&p, DEFS[:])
	testing.expect_value(t, int_of(&p, "net.max_conns"), 11)
	testing.expect_value(t, string_of(&p, "net.agent"), "tab\tand\nnewline\\")
	testing.expect_value(t, float_of(&p, "ui.scale"), 1.0)
	// only user changes are written
	testing.expect(t, save(&p, path))
	q := prefs_make()
	defer prefs_destroy(&q)
	load_file(&q, path, .User)
	register(&q, DEFS[:])
	testing.expect_value(t, int_of(&q, "net.max_conns"), 11)

	_, probs := load_file(&q, "build/does_not_exist.txt", .User)
	testing.expect_value(t, len(probs), 0)   // a missing file is not an error
}

@(test)
policy_file_locks :: proc(t: ^testing.T) {
	path := "build/policy_test.txt"
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("wbpolicy 1\nnet.max_conns\t3\n# comment\nui.mode\tbogus\n") ) == nil)
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	n, problems := load_file(&p, path, .Policy)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, len(problems), 1)   // "bogus" is not a choice
	testing.expect_value(t, int_of(&p, "net.max_conns"), 3)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "5", .User), Set_Error.Locked)
	testing.expect(t, is_locked(&p, ref_of(&p, "net.max_conns")))
}

// A run with --pref (or under a policy) keeps the user's own value in the profile file; a user change made meanwhile
// is kept too; reset leaves the command line's value for this run.
@(test)
higher_layers_keep_the_user_value :: proc(t: ^testing.T) {
	dir := os.get_env("TEMP", context.temp_allocator)
	path := fmt.tprintf("%s\\wb_config_layers_test.txt", dir)
	defer os.remove(path)
	_ = os.write_entire_file(path, transmute([]byte)string("\xEF\xBB\xBFwbprefs 1\nnet.max_conns\t5\nui.scale\t2\n"))
	p := prefs_make()
	defer prefs_destroy(&p)
	args := []string{"--pref", "net.max_conns=7"}
	rest, errs := apply_args(&p, args)
	delete(rest); delete(errs)
	applied, _ := load_file(&p, path, .User)
	testing.expect_value(t, applied, 2)   // the byte-order mark is not part of the magic
	register(&p, DEFS[:])
	testing.expect_value(t, int_of(&p, "net.max_conns"), 7)
	testing.expect(t, save(&p, path))
	q := prefs_make()
	defer prefs_destroy(&q)
	register(&q, DEFS[:])
	load_file(&q, path, .User)
	testing.expect_value(t, int_of(&q, "net.max_conns"), 5)
	testing.expect_value(t, float_of(&q, "ui.scale"), 2.0)
	// a change by the user while the command line decides: refused for this run, kept for the next
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "9", .User), Set_Error.Locked)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 7)
	testing.expect(t, save(&p, path))
	r := prefs_make()
	defer prefs_destroy(&r)
	register(&r, DEFS[:])
	load_file(&r, path, .User)
	testing.expect_value(t, int_of(&r, "net.max_conns"), 9)
	// reset: the user value goes, the command line's stays
	testing.expect_value(t, reset(&p, "net.max_conns"), Set_Error.None)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 7)
	testing.expect(t, save(&p, path))
	s := prefs_make()
	defer prefs_destroy(&s)
	register(&s, DEFS[:])
	load_file(&s, path, .User)
	testing.expect_value(t, int_of(&s, "net.max_conns"), 6)
	// K / M / G that overflow are out of range, not wrapped
	_, e := parse_value(DEFS[1], "17179869185G")
	testing.expect_value(t, e, Set_Error.Out_Of_Range)
}

@(private = "file")
Locked_Seen :: struct { locked: bool, calls: int }

// A default is no layer that can be set: it does not go over what the user chose.
@(test)
a_default_decides_nothing_over_a_layer :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	set_from_string(&p, "net.max_conns", "8", .User)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "3", .Default), Set_Error.Locked)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 8)
	testing.expect_value(t, entry(&p, ref_of(&p, "net.max_conns")).source, Source.User)
}

// What a policy refuses, it refuses whole: the user's value under it is not lost to a reset that answers `.Locked`.
@(test)
a_refused_reset_keeps_the_user_value :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	set_from_string(&p, "net.max_conns", "8", .User)
	set_from_string(&p, "net.max_conns", "3", .Policy)
	written := p.user_version
	testing.expect_value(t, reset(&p, "net.max_conns"), Set_Error.Locked)
	s, ok := user_text(&p, "net.max_conns")
	testing.expect(t, ok && s == "8", "the user's value is still there")
	testing.expect_value(t, p.user_version, written)   // nothing changed
}

// An observer of a policy value sees it locked.
@(test)
an_observer_sees_a_policy_value_locked :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	seen: Locked_Seen
	watch(&p, "net.", proc(user: rawptr, name: string, p: ^Prefs) {
		s := (^Locked_Seen)(user)
		s.calls += 1
		s.locked = is_locked(p, ref_of(p, name))
	}, &seen)
	set_from_string(&p, "net.max_conns", "3", .Policy)
	testing.expect_value(t, seen.calls, 1)
	testing.expect(t, seen.locked)
}

// A value the definition refuses is the user's all the same: this version does not take it, the next may, and a save is no
// reason to lose it.
@(test)
a_refused_value_waiting_stays_in_the_profile :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/wb_config_refused_test.txt", fsx.temp_dir(context.temp_allocator))
	defer os.remove(path)
	p := prefs_make()
	defer prefs_destroy(&p)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "999", .User), Set_Error.Unknown)
	testing.expect_value(t, register(&p, DEFS[:]), 1)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 6)
	testing.expect(t, is_default(&p, ref_of(&p, "net.max_conns")))
	testing.expect(t, save(&p, path))
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, strings.contains(string(data), "net.max_conns\t999\n"), "the line is still there")
}

// The same for a line read once the definition is there: a problem to report, and a line to keep.
@(test)
a_refused_line_of_the_profile_stays :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/wb_config_refused_line_test.txt", fsx.temp_dir(context.temp_allocator))
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("wbprefs 1\nnet.max_conns\t999\n")) == nil)
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	n, problems := load_file(&p, path, .User)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, len(problems), 1)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 6)
	testing.expect(t, save(&p, path))
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, strings.contains(string(data), "net.max_conns\t999\n"), "the line is still there")
}

// `user_version` counts what the file does not have yet: a change under a higher layer, a value not registered, never what
// was just read.
@(test)
user_version_counts_what_the_profile_does_not_have :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/wb_config_dirty_test.txt", fsx.temp_dir(context.temp_allocator))
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("wbprefs 1\nnet.max_conns\t9\nui.scale\t2\n")) == nil)
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:1])
	load_file(&p, path, .User)
	testing.expect_value(t, p.user_version, 0)   // a registered value, just read
	register(&p, DEFS[:])
	testing.expect_value(t, p.user_version, 0)   // a waiting value, just read
	testing.expect_value(t, float_of(&p, "ui.scale"), 2.0)

	set_from_string(&p, "net.agent", "cli", .Command_Line)
	testing.expect_value(t, p.user_version, 0)   // not the user's
	testing.expect_value(t, set_from_string(&p, "net.agent", "mine", .User), Set_Error.Locked)
	testing.expect(t, p.user_version != 0, "under the command line: the file does not have it")

	written := p.user_version
	set_from_string(&p, "not.yet", "1", .User)
	testing.expect(t, p.user_version != written, "not registered: the file does not have it")
}

// A program serializes on its loop and writes on a worker: the text is a copy, so a change made while it is written is
// not in this file, and it moves user_version past the version the file has, so the next save writes it.
@(test)
a_change_during_a_write_is_saved_next :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/wb_config_split_save_test.txt", fsx.temp_dir(context.temp_allocator))
	defer os.remove(path)
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	set_from_string(&p, "net.max_conns", "9", .User)
	text := serialize_user(&p)
	defer delete(text)
	written := p.user_version
	set_from_string(&p, "net.max_conns", "10", .User)   // (on the loop, while the worker writes)
	testing.expect(t, write_user_file(path, text))
	testing.expect(t, p.user_version != written, "10 is still to be saved")
	q := prefs_make()
	defer prefs_destroy(&q)
	register(&q, DEFS[:])
	load_file(&q, path, .User)
	testing.expect_value(t, int_of(&q, "net.max_conns"), 9)
}

// The same layer gives the same bytes: values no definition registers come sorted, not in the map's order.
@(test)
the_same_layer_gives_the_same_text :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	names := [?]string{"zz.one", "aa.two", "mm.three", "bb.four"}
	for name in names { set_from_string(&p, name, "1", .User) }
	set_from_string(&p, "net.max_conns", "9", .User)
	testing.expect_value(t, serialize_user(&p, context.temp_allocator),
		"wbprefs 1\nnet.max_conns\t9\naa.two\t1\nbb.four\t1\nmm.three\t1\nzz.one\t1\n")
}

// A save that cannot replace the file leaves all there was: never a profile removed in the hope of a second try.
@(test)
a_save_that_fails_leaves_what_was_there :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/wb_config_failed_save_test", fsx.temp_dir(context.temp_allocator))
	fsx.remove_tree(dir)
	defer fsx.remove_tree(dir)
	path := fmt.tprintf("%s/profile", dir)
	testing.expect(t, os.make_directory_all(path) == nil)   // (what cannot be replaced by a file)
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	set_from_string(&p, "net.max_conns", "9", .User)
	testing.expect(t, !save(&p, path), "it failed")
	testing.expect_value(t, fsx.path_kind(path), fsx.Path_Kind.Directory)
	testing.expect_value(t, len(fsx.list_files(dir)), 0)   // (no temporary file left)
}

// A file says what it is: a policy read as a profile would be written back as the user's, a profile read as a policy would lock.
@(test)
a_file_of_the_other_layer_is_refused :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/wb_config_magic_test.txt", fsx.temp_dir(context.temp_allocator))
	defer os.remove(path)
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("wbpolicy 1\nnet.max_conns\t3\n")) == nil)
	n, problems := load_file(&p, path, .User)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, len(problems), 1)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("wbprefs 1\nnet.max_conns\t3\n")) == nil)
	n, problems = load_file(&p, path, .Policy)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, len(problems), 1)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 6)
}
// The first save of a program makes the folder of its file.
@(test)
the_first_save_makes_its_folder :: proc(t: ^testing.T) {
	dir := fmt.tprintf("build/config_test_dirs_%d", os.get_pid())
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/a/b/prefs", dir)
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	set_from_string(&p, "net.max_conns", "9", .User)
	testing.expect(t, save(&p, path))
	q := prefs_make()
	defer prefs_destroy(&q)
	register(&q, DEFS[:])
	load_file(&q, path, .User)
	testing.expect_value(t, int_of(&q, "net.max_conns"), 9)
}

// The writer writes the user's file off the loop: nothing while nothing changed, the last of many changes once stopped.
@(test)
the_writer_writes_what_changed :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/wb_config_writer_test.txt", fsx.temp_dir(context.temp_allocator))
	os.remove(path)
	defer os.remove(path)
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	wr: User_Writer
	user_writer_start(&wr, &p, path)
	user_writer_save(&wr, &p)
	for v in ([]string{"7", "8", "9"}) {
		set_from_string(&p, "net.max_conns", v, .User)
		user_writer_save(&wr, &p)
	}
	testing.expect(t, user_writer_stop(&wr, &p), "written")
	q := prefs_make()
	defer prefs_destroy(&q)
	register(&q, DEFS[:])
	load_file(&q, path, .User)
	s, ok := user_text(&q, "net.max_conns")
	testing.expect(t, ok && s == "9", "the last value is in the file")

	// started on what the file has: stopped with no change, it writes nothing
	os.remove(path)
	user_writer_start(&wr, &q, path)
	testing.expect(t, user_writer_stop(&wr, &q))
	testing.expect_value(t, fsx.path_kind(path), fsx.Path_Kind.Absent)
}

// A write that fails is told once, and stop says so too.
@(test)
the_writer_tells_a_failed_write :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/wb_config_writer_failed_test", fsx.temp_dir(context.temp_allocator))
	fsx.remove_tree(dir)
	defer fsx.remove_tree(dir)
	path := fmt.tprintf("%s/profile", dir)
	testing.expect(t, os.make_directory_all(path) == nil)   // (what cannot be replaced by a file)
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	wr: User_Writer
	user_writer_start(&wr, &p, path)
	set_from_string(&p, "net.max_conns", "9", .User)
	testing.expect(t, !user_writer_stop(&wr, &p), "stop tells the failure")
}
