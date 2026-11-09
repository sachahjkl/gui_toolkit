#+build linux
package tk_desktop

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

// The test's own XDG folders under a temporary one named `name` (each test its own: they run on several threads): the
// user's configuration and data ("config", "data") before the system's ("sysconfig", "sysdata"). `files` are written
// there, by path under it and text.
@(private = "file")
roots_make :: proc(t: ^testing.T, name: string, files: [][2]string, desktops: []string = nil) -> (roots: Xdg_Roots, base: string) {
	tmp, _ := os.temp_directory(context.temp_allocator)
	base = fmt.tprintf("%s/tk_open_with_%d_%s", tmp, os.get_pid(), name)
	_ = os.remove_all(base)
	for f in files {
		path := fmt.tprintf("%s/%s", base, f[0])
		dir := path[:strings.last_index_byte(path, '/')]
		_ = os.make_directory_all(dir)   // (the write below says whether it is there)
		testing.expect(t, os.write_entire_file(path, f[1]) == nil, path)
	}
	d := make([]string, 2, context.temp_allocator)
	c := make([]string, 2, context.temp_allocator)
	d[0], d[1] = fmt.tprintf("%s/data", base), fmt.tprintf("%s/sysdata", base)
	c[0], c[1] = fmt.tprintf("%s/config", base), fmt.tprintf("%s/sysconfig", base)
	return {d, c, desktops}, base
}

@(private = "file")
MIME_FILES :: [?][2]string{
	{"sysdata/mime/globs2", "# comment\n50:text/x-csrc:*.c\n50:text/plain:*.txt\n50:image/png:*.png\n"},
	{"sysdata/mime/subclasses", "text/x-csrc text/plain\n"},
}

@(private = "file")
entry :: proc(name, exec, mimes: string, extra := "") -> string {
	return fmt.tprintf("[Desktop Entry]\nType=Application\nName=%s\nExec=%s\nMimeType=%s\n%s", name, exec, mimes, extra)
}

@(private = "file")
ids_of :: proc(hs: []Handler) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for h, i in hs {
		if i > 0 { strings.write_byte(&sb, '|') }
		strings.write_string(&sb, h.id)
		if h.default { strings.write_byte(&sb, '*') }
	}
	return strings.to_string(sb)
}

@(private = "file")
handler_ids :: proc(roots: Xdg_Roots, path: string) -> string {
	db := mime_database(roots, context.temp_allocator)
	hs := handlers_of(&db, path, context.allocator)
	defer handlers_destroy(hs)
	return ids_of(hs)
}

// A C file: the IDE (for text/x-csrc: a more specific type wins over the default of text/plain) and the editor (for its
// parent text/plain), not the terminal program nor the one whose Exec line is refused; a picture: the viewer, and the
// editor its association adds, by name.
@(test)
the_handlers_of_a_file :: proc(t: ^testing.T) {
	files := [?][2]string{
		MIME_FILES[0], MIME_FILES[1],
		{"sysdata/applications/editor.desktop", entry("Editor", "editor --new %F", "text/plain;")},
		{"sysdata/applications/ide/code.desktop", entry("An IDE", `"/opt/my ide/ide" %u`, "text/x-csrc;")},
		{"sysdata/applications/viewer.desktop", entry("Viewer", "viewer", "image/png;")},
		{"sysdata/applications/vim.desktop", entry("Vim", "vim %F", "text/plain;", "Terminal=true\n")},
		{"sysdata/applications/shell.desktop", entry("Shell", `sh -c "cat %f"`, "text/plain;")},
		{"config/mimeapps.list", "[Default Applications]\ntext/plain=editor.desktop;\n[Added Associations]\nimage/png=editor.desktop;\n[Removed Associations]\n"},
	}
	roots, base := roots_make(t, "handlers", files[:])
	defer os.remove_all(base)
	db := mime_database(roots, context.temp_allocator)
	testing.expect_value(t, mime_of_file(&db, "/x/main.C"), "text/x-csrc")
	testing.expect_value(t, mime_of_file(&db, "/x/notes"), "application/octet-stream")
	testing.expect_value(t, handler_ids(roots, "/x/main.c"), "ide-code.desktop*|editor.desktop")
	testing.expect_value(t, handler_ids(roots, "/x/a.txt"), "editor.desktop*")
	hs := handlers_of(&db, "/x/a.png", context.allocator)
	defer handlers_destroy(hs)
	testing.expect_value(t, ids_of(hs), "editor.desktop*|viewer.desktop")
	if len(hs) == 2 { testing.expect(t, hs[0].name == "Editor" && hs[1].name == "Viewer", "the names") }
}

// mimeapps.list as the MIME Applications specification orders it: a level removes only for the levels after it, a
// desktop's own list gives defaults only, an association of the system's data does not reach an entry the user's data
// has, and with no [Default Applications] the most preferred application is the default.
@(test)
mimeapps_precedence :: proc(t: ^testing.T) {
	files := [?][2]string{
		MIME_FILES[0], MIME_FILES[1],
		{"sysdata/applications/editor.desktop", entry("Editor", "editor %f", "text/plain;")},
		{"sysdata/applications/viewer.desktop", entry("Viewer", "viewer %f", "image/png;")},
		{"sysdata/applications/paint.desktop", entry("Paint", "paint %f", "image/png;")},
		{"sysdata/applications/pad.desktop", entry("Pad", "pad %f", "text/plain;")},
		{"data/applications/notes.desktop", entry("Notes", "notes %f", "text/x-csrc;")},
		// the user adds the editor for pictures, the system removes it: the user wins
		{"config/mimeapps.list", "[Added Associations]\nimage/png=editor.desktop;\n[Removed Associations]\nimage/png=paint.desktop;\n"},
		{"sysconfig/mimeapps.list", "[Removed Associations]\nimage/png=editor.desktop;\n[Default Applications]\nimage/png=paint.desktop;viewer.desktop;\n"},
		// the desktop's own list: its default counts, its added association does not
		{"config/gnome-mimeapps.list", "[Default Applications]\ntext/plain=missing.desktop;pad.desktop;\n[Added Associations]\ntext/plain=viewer.desktop;\n"},
		// the system's data removes notes for C files: the user's data has notes, which this level cannot reach
		{"sysdata/applications/mimeapps.list", "[Removed Associations]\ntext/x-csrc=notes.desktop;\n"},
	}
	desktops := [?]string{"gnome"}
	roots, base := roots_make(t, "precedence", files[:], desktops[:])
	defer os.remove_all(base)
	// paint is removed by the user: the system's default goes to the next one, the viewer
	testing.expect_value(t, handler_ids(roots, "/x/a.png"), "viewer.desktop*|editor.desktop")
	testing.expect_value(t, handler_ids(roots, "/x/a.txt"), "pad.desktop*|editor.desktop")
	testing.expect_value(t, handler_ids(roots, "/x/a.c"), "notes.desktop*|editor.desktop|pad.desktop")
	// without the desktop's list: no default for text/plain is written, the most preferred one is the default
	plain := roots
	plain.desktops = nil
	testing.expect_value(t, handler_ids(plain, "/x/a.txt"), "editor.desktop*|pad.desktop")
	// the user's data has its own viewer that does not open pictures: the system's one is hidden
	_ = os.write_entire_file(fmt.tprintf("%s/data/applications/viewer.desktop", base), entry("Viewer", "viewer %f", "text/x-other;"))
	testing.expect_value(t, handler_ids(roots, "/x/a.png"), "editor.desktop*")
}

// A link that loops under applications/ is read once: the entries are found and the walk ends.
@(test)
a_looping_link_under_applications :: proc(t: ^testing.T) {
	files := [?][2]string{
		MIME_FILES[0], MIME_FILES[1],
		{"sysdata/applications/editor.desktop", entry("Editor", "editor %f", "text/plain;")},
		{"sysdata/applications/sub/viewer.desktop", entry("Viewer", "viewer %f", "text/plain;")},
	}
	roots, base := roots_make(t, "loop", files[:])
	defer os.remove_all(base)
	apps := fmt.tprintf("%s/sysdata/applications", base)
	testing.expect(t, os.symlink("..", fmt.tprintf("%s/up", apps)) == nil, "link up")
	testing.expect(t, os.symlink(".", fmt.tprintf("%s/sub/self", apps)) == nil, "link to itself")
	testing.expect(t, os.symlink(apps, fmt.tprintf("%s/sub/back", apps)) == nil, "link back")
	testing.expect_value(t, handler_ids(roots, "/x/a.txt"), "editor.desktop*|sub-viewer.desktop")
}

// The cache reads the system once, and again when a file or folder it read changes, appears or goes, or when the roots
// change.
@(test)
the_database_is_cached_until_a_file_changes :: proc(t: ^testing.T) {
	files := [?][2]string{
		MIME_FILES[0], MIME_FILES[1],
		{"sysdata/applications/editor.desktop", entry("Editor", "editor %f", "text/plain;")},
	}
	roots, base := roots_make(t, "cache", files[:])
	defer os.remove_all(base)
	c: Mime_Cache
	defer virtual.arena_destroy(&c.arena)
	ids :: proc(c: ^Mime_Cache, roots: Xdg_Roots) -> string {
		hs := handlers_of(mime_cache_get(c, roots), "/x/a.txt", context.allocator)
		defer handlers_destroy(hs)
		return ids_of(hs)
	}
	testing.expect_value(t, ids(&c, roots), "editor.desktop*")
	testing.expect_value(t, ids(&c, roots), "editor.desktop*")
	testing.expect_value(t, c.reads, 1)
	// a new entry: its folder changed
	write :: proc(t: ^testing.T, base, path, text: string) {
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", base, path), text) == nil, path)
	}
	write(t, base, "sysdata/applications/pad.desktop", entry("Pad", "pad %f", "text/plain;"))
	testing.expect_value(t, ids(&c, roots), "editor.desktop*|pad.desktop")
	testing.expect_value(t, c.reads, 2)
	// an entry changed where it is
	write(t, base, "sysdata/applications/pad.desktop", entry("Pad", "pad %f", "text/x-other;"))
	testing.expect_value(t, ids(&c, roots), "editor.desktop*")
	// a mimeapps.list that was not there
	_ = os.make_directory_all(fmt.tprintf("%s/config", base))
	write(t, base, "config/mimeapps.list", "[Added Associations]\ntext/plain=pad.desktop;\n")
	testing.expect_value(t, ids(&c, roots), "pad.desktop*|editor.desktop")
	testing.expect_value(t, c.reads, 4)
	// other roots
	other := roots
	other.config = nil
	testing.expect_value(t, ids(&c, other), "editor.desktop*")
	testing.expect_value(t, c.reads, 5)
}

// An Exec value read as the specification says, and its field codes replaced.
@(test)
an_exec_line_expanded :: proc(t: ^testing.T) {
	args := exec_arguments(`"/opt/my ide/ide" --flag "a \"q\"" %u`)
	testing.expect_value(t, len(args), 4)
	if len(args) == 4 {
		testing.expect_value(t, args[0], Exec_Argument{"/opt/my ide/ide", true})
		testing.expect_value(t, args[2], Exec_Argument{`a "q"`, true})
		testing.expect_value(t, args[3], Exec_Argument{"%u", false})
	}
	testing.expect_value(t, exec_program(`"/opt/my ide/ide" %u`), "/opt/my ide/ide")

	expand :: proc(exec: string) -> (string, bool) {
		e, ok := exec_expand(exec, "/a b.txt", "Ed", "ed", "/apps/ed.desktop")
		return strings.join(e, "|", context.temp_allocator), ok
	}
	cases := [?]struct { exec, want: string, ok: bool }{
		{"editor --name=%c %i --file=%f 100%%", "editor|--name=Ed|--icon|ed|--file=/a b.txt|100%", true},
		{"editor %F", "editor|/a b.txt", true},
		{"editor %U --new", "editor|/a b.txt|--new", true},
		{"editor %k %d %D %n %N %v %m", "editor|/apps/ed.desktop|/a b.txt", true},   // deprecated: dropped
		{"viewer", "viewer|/a b.txt", true},                                         // no file code: the path at the end
		{`"/x/my viewer" "100%%"`, "/x/my viewer|100%|/a b.txt", true},               // %% in quotes is a %
		// the specification's refusals
		{`sh -c "viewer %f"`, "", false},     // a field code in a quoted argument: the shell would read the name
		{`sh -c "viewer %c"`, "", false},
		{`"%f"`, "", false},
		{"editor %z", "", false},             // a code the specification does not list
		{"editor 100%", "", false},           // a % alone at the end
		{"editor --files=%F", "", false},     // %F %U %i only as an argument of their own
		{"editor x%i", "", false},
		{"editor %f %u", "", false},          // two file codes
		{"", "", false},
	}
	for c in cases {
		got, ok := expand(c.exec)
		testing.expectf(t, ok == c.ok && got == c.want, "%q: %q %v, want %q %v", c.exec, got, ok, c.want, c.ok)
	}
	// the name of a file a shell would read is one argument, as it is
	e, ok := exec_expand("viewer %f", "a;rm -rf ~.txt", "", "", "")
	testing.expect(t, ok && len(e) == 2 && e[1] == "a;rm -rf ~.txt", "one argument")
}
