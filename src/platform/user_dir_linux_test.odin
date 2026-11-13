#+build linux
package platform

import "core:os"
import "core:strings"
import "core:testing"

// A program's folders on Linux: each kind's XDG variable when it is an absolute path, its default under the home when it is not
// there or is relative (the specification ignores a relative one), the program's folder in it.
@(test)
a_program_s_folders_are_the_xdg_ones :: proc(t: ^testing.T) {
	NAMES :: #partial [User_Dir]string{.Config = "XDG_CONFIG_HOME", .Data = "XDG_DATA_HOME", .State = "XDG_STATE_HOME", .Cache = "XDG_CACHE_HOME"}
	DEFAULTS :: #partial [User_Dir]string{.Config = "/.config", .Data = "/.local/share", .State = "/.local/state", .Cache = "/.cache"}
	names, defaults := NAMES, DEFAULTS
	home, _ := os.lookup_env("HOME", context.temp_allocator)
	for kind in User_Dir {
		if kind == .Runtime { continue }   // (its own test: no home default)
		old, had := os.lookup_env(names[kind], context.temp_allocator)
		defer { if had { os.set_env(names[kind], old) } else { os.unset_env(names[kind]) } }
		os.set_env(names[kind], "/somewhere/else")
		testing.expect_value(t, user_dir(kind, "prog", context.temp_allocator), "/somewhere/else/prog")
		os.set_env(names[kind], "relative/path")
		testing.expect_value(t, user_dir(kind, "prog", context.temp_allocator), strings.concatenate({home, defaults[kind], "/prog"}, context.temp_allocator))
		os.unset_env(names[kind])
		testing.expect_value(t, user_dir(kind, "", context.temp_allocator), strings.concatenate({home, defaults[kind]}, context.temp_allocator))
	}
}


// The runtime folder: $XDG_RUNTIME_DIR, else the system's temporary folder.
@(test)
the_runtime_folder_is_the_sessions :: proc(t: ^testing.T) {
	old, had := os.lookup_env("XDG_RUNTIME_DIR", context.temp_allocator)
	defer if had { os.set_env("XDG_RUNTIME_DIR", old) } else { os.unset_env("XDG_RUNTIME_DIR") }
	os.set_env("XDG_RUNTIME_DIR", "/run/user/1000")
	testing.expect_value(t, user_dir(.Runtime, "sample", context.temp_allocator), "/run/user/1000/sample")
	os.unset_env("XDG_RUNTIME_DIR")
	testing.expect(t, user_dir(.Runtime, "", context.temp_allocator) != "", "a temporary folder without it")
}

// The system's language from the POSIX locale: its tag; C is none.
@(test)
the_language_of_the_locale :: proc(t: ^testing.T) {
	testing.expect_value(t, locale_tag("fr_FR.UTF-8@euro", context.temp_allocator), "fr-FR")
	testing.expect_value(t, locale_tag("de", context.temp_allocator), "de")
}
