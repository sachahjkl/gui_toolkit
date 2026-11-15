#+build linux
package platform

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import fsx "../fsx"

// The tests of this file change the process's environment: the runner's threads take turns on it.
@(private = "file") env_lock: sync.Mutex

// A program's folders on Linux: each kind's XDG variable when it is an absolute path, its default under the home when it is not
// there or is relative (the specification ignores a relative one), the program's folder in it.
@(test)
a_program_s_folders_are_the_xdg_ones :: proc(t: ^testing.T) {
	sync.mutex_guard(&env_lock)
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


// A variable of the test, put back as it was at the end.
@(private = "file")
Saved_Env :: struct { name, value: string, had: bool }

@(private = "file")
env_save :: proc(name: string) -> Saved_Env {
	v, had := os.lookup_env(name, context.allocator)
	return {name, v, had}
}

@(private = "file")
env_restore :: proc(s: Saved_Env) {
	if s.had { os.set_env(s.name, s.value) } else { os.unset_env(s.name) }
	delete(s.value)
}

// A fresh folder of the test in the temporary one (temp memory).
@(private = "file")
test_root :: proc(name: string) -> string {
	root := fmt.tprintf("%s/gt_platform_%s_%d", fsx.temp_dir(context.temp_allocator), name, os.get_pid())
	fsx.remove_tree(root)
	fsx.make_dirs(root)
	return root
}

// The mode and owner of a path, links not followed.
@(private = "file")
lstat_of :: proc(path: string) -> (st: posix.stat_t, ok: bool) {
	ok = posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK
	return
}

@(private = "file") OTHERS :: posix.mode_t{.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}

// The runtime folder: $XDG_RUNTIME_DIR as given; without it, the session's (/run/user/<uid>) or a folder of this user's
// alone, never a folder another user can enter.
@(test)
the_runtime_folder_is_the_sessions :: proc(t: ^testing.T) {
	sync.mutex_guard(&env_lock)
	saved := env_save("XDG_RUNTIME_DIR")
	defer env_restore(saved)
	os.set_env("XDG_RUNTIME_DIR", "/run/user/1000")
	testing.expect_value(t, user_dir(.Runtime, "sample", context.temp_allocator), "/run/user/1000/sample")
	session, ok := session_runtime_dir(context.temp_allocator)
	testing.expect(t, ok && session == "/run/user/1000", "the variable is the session's folder")
	os.set_env("XDG_RUNTIME_DIR", "relative")
	session, ok = session_runtime_dir(context.temp_allocator)
	testing.expect(t, !ok || session != "relative", "a relative variable is not taken")
	os.unset_env("XDG_RUNTIME_DIR")
	dir := user_dir(.Runtime, "", context.temp_allocator)
	if !testing.expect(t, dir != "", "a folder without the variable") { return }
	if session, ok = session_runtime_dir(context.temp_allocator); ok { testing.expect_value(t, dir, session) }
	if st, there := lstat_of(dir); testing.expect(t, there, "there") {
		testing.expect(t, posix.S_ISDIR(st.st_mode), "a folder, not a link")
		testing.expect_value(t, st.st_uid, posix.getuid())
		testing.expect_value(t, st.st_mode & OTHERS, posix.mode_t{})
	}
}

// The fallback without a session's folder: runtime-<uid> in $TMPDIR, made 0700; a link at that name (someone made it
// first) gives no folder at all.
@(test)
the_runtime_fallback_is_private :: proc(t: ^testing.T) {
	sync.mutex_guard(&env_lock)
	root := test_root("runtime")
	defer fsx.remove_tree(root)
	saved := env_save("TMPDIR")
	defer env_restore(saved)
	os.set_env("TMPDIR", root)
	want := fmt.tprintf("%s/runtime-%d", root, posix.getuid())
	testing.expect_value(t, private_runtime_dir(), want)
	if st, ok := lstat_of(want); testing.expect(t, ok, "made") {
		testing.expect(t, posix.S_ISDIR(st.st_mode))
		testing.expect_value(t, st.st_mode & OTHERS, posix.mode_t{})
	}
	fsx.remove_tree(want)
	testing.expect(t, fsx.make_dirs(fmt.tprintf("%s/elsewhere", root)))
	testing.expect_value(t, posix.symlink("elsewhere", strings.clone_to_cstring(want, context.temp_allocator)), posix.result.OK)
	testing.expect_value(t, private_runtime_dir(), "")
}

// user-dirs.dirs as GLib reads it: "$HOME" or an absolute path, "\" escapes, spaces around "=", a last "/" gone, the last
// line of a name wins; a comment, an unknown name, another form are left out.
@(test)
the_user_dirs_file_is_read_as_glib_reads_it :: proc(t: ^testing.T) {
	text := `# This file is written by xdg-user-dirs-update
XDG_DESKTOP_DIR="$HOME/Bureau"
XDG_DOWNLOAD_DIR="$HOME/Téléchargements"
XDG_TEMPLATES_DIR="$HOME/Modèles"
  XDG_DOCUMENTS_DIR = "$HOME/Mes \"documents\"/"
XDG_MUSIC_DIR="$HOME"
XDG_PICTURES_DIR="/data/Images"
XDG_PICTURES_DIR="/data/Photos"
XDG_VIDEOS_DIR="Vidéos"
#XDG_DESKTOP_DIR="$HOME/Ignored"
`
	dirs := user_dirs_parse(text, "/home/ada")
	testing.expect_value(t, dirs[.Desktop], "/home/ada/Bureau")
	testing.expect_value(t, dirs[.Downloads], "/home/ada/Téléchargements")
	testing.expect_value(t, dirs[.Documents], `/home/ada/Mes "documents"`)
	testing.expect_value(t, dirs[.Music], "/home/ada")
	testing.expect_value(t, dirs[.Pictures], "/data/Photos")
	testing.expect_value(t, dirs[.Videos], "")
	testing.expect_value(t, user_dirs_parse(`XDG_DESKTOP_DIR="$HOMEDIR/x"`, "/home/ada")[.Desktop], "")
	testing.expect_value(t, user_dirs_parse(`XDG_DESKTOP_DIR=$HOME/x`, "/home/ada")[.Desktop], "")
}

// known_folder_path reads $XDG_CONFIG_HOME/user-dirs.dirs: a named folder, the home for "disabled" (none), $HOME/<English
// name> for one it does not name; once per file and home, again when either changes.
@(test)
the_person_s_folders_are_their_desktop_s :: proc(t: ^testing.T) {
	sync.mutex_guard(&env_lock)
	// (the real home: HOME is read by other packages' code the runner may run meanwhile)
	home, _ := os.lookup_env("HOME", context.temp_allocator)
	if home == "" { return }
	root := test_root("user_dirs")
	defer fsx.remove_tree(root)
	saved_config := env_save("XDG_CONFIG_HOME")
	defer env_restore(saved_config)
	config := fmt.tprintf("%s/config", root)
	testing.expect(t, fsx.make_dirs(config))
	file := fmt.tprintf("%s/user-dirs.dirs", config)
	text := "XDG_DESKTOP_DIR=\"$HOME/Bureau\"\nXDG_DOWNLOAD_DIR=\"$HOME/Téléchargements\"\nXDG_MUSIC_DIR=\"$HOME/\"\nXDG_PICTURES_DIR=\"/data/Images\"\n"
	testing.expect(t, os.write_entire_file(file, transmute([]byte)text) == nil)
	os.set_env("XDG_CONFIG_HOME", config)
	path :: proc(k: Known_Folder) -> string { return known_folder_path(k, context.temp_allocator) }
	testing.expect_value(t, path(.Desktop), fmt.tprintf("%s/Bureau", home))
	testing.expect_value(t, path(.Downloads), fmt.tprintf("%s/Téléchargements", home))
	testing.expect_value(t, path(.Music), "")
	testing.expect_value(t, path(.Pictures), "/data/Images")
	testing.expect_value(t, path(.Documents), fmt.tprintf("%s/Documents", home))
	testing.expect_value(t, path(.Home), home)

	// (kept: the same file changed is not read again while its path and the home are the same)
	changed := "XDG_DESKTOP_DIR=\"$HOME/Escritorio\"\n"
	testing.expect(t, os.write_entire_file(file, transmute([]byte)changed) == nil)
	testing.expect_value(t, path(.Desktop), fmt.tprintf("%s/Bureau", home))
	other := fmt.tprintf("%s/config2", root)
	testing.expect(t, fsx.make_dirs(other))
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/user-dirs.dirs", other), transmute([]byte)changed) == nil)
	os.set_env("XDG_CONFIG_HOME", other)
	testing.expect_value(t, path(.Desktop), fmt.tprintf("%s/Escritorio", home))
	testing.expect_value(t, path(.Music), fmt.tprintf("%s/Music", home))

	os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/none", root))
	testing.expect_value(t, path(.Desktop), fmt.tprintf("%s/Desktop", home))
}

// The system's language from the POSIX locale: its tag; C is none.
@(test)
the_language_of_the_locale :: proc(t: ^testing.T) {
	testing.expect_value(t, locale_tag("fr_FR.UTF-8@euro", context.temp_allocator), "fr-FR")
	testing.expect_value(t, locale_tag("de", context.temp_allocator), "de")
}
