#+build linux
package tk_desktop

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// A data directory and a configuration one of the test's own: a type, its parent, three applications, mimeapps.list.
@(private = "file")
roots_make :: proc(t: ^testing.T) -> (roots: Xdg_Roots, base: string) {
	tmp, _ := os.temp_directory(context.temp_allocator)
	base = fmt.tprintf("%s/tk_open_with_%d", tmp, os.get_pid())
	_ = os.remove_all(base)
	data, config := fmt.tprintf("%s/data", base), fmt.tprintf("%s/config", base)
	files := [?][2]string{
		{"data/mime/globs2", "# comment\n50:text/x-csrc:*.c\n50:text/plain:*.txt\n50:image/png:*.png\n"},
		{"data/mime/subclasses", "text/x-csrc text/plain\n"},
		{"data/applications/editor.desktop", "[Desktop Entry]\nType=Application\nName=Editor\nExec=editor --new %F\nMimeType=text/plain;\n"},
		{"data/applications/ide/code.desktop", "[Desktop Entry]\nType=Application\nName=An IDE\nExec=\"/opt/my ide/ide\" %u\nMimeType=text/x-csrc;\n"},
		{"data/applications/viewer.desktop", "[Desktop Entry]\nType=Application\nName=Viewer\nExec=viewer\nMimeType=image/png;\n"},
		{"data/applications/vim.desktop", "[Desktop Entry]\nType=Application\nName=Vim\nExec=vim %F\nTerminal=true\nMimeType=text/plain;\n"},
		{"config/mimeapps.list", "[Default Applications]\ntext/plain=editor.desktop;\n[Added Associations]\nimage/png=editor.desktop;\n[Removed Associations]\n"},
	}
	for f in files {
		path := fmt.tprintf("%s/%s", base, f[0])
		dir := path[:strings.last_index_byte(path, '/')]
		_ = os.make_directory_all(dir)   // (the write below says whether it is there)
		testing.expect(t, os.write_entire_file(path, f[1]) == nil, path)
	}
	d := make([]string, 1, context.temp_allocator)
	c := make([]string, 1, context.temp_allocator)
	d[0], c[0] = data, config
	return {d, c}, base
}

// A C file: the IDE (for text/x-csrc) and the editor (for its parent text/plain, the default there), not the terminal
// program; a picture: the viewer, and the editor its association adds.
@(test)
the_handlers_of_a_file :: proc(t: ^testing.T) {
	roots, base := roots_make(t)
	defer os.remove_all(base)
	testing.expect_value(t, mime_of_file(roots, "/x/main.C"), "text/x-csrc")
	testing.expect_value(t, mime_of_file(roots, "/x/notes"), "application/octet-stream")
	hs := handlers_in(roots, "/x/main.c", context.allocator)
	defer handlers_destroy(hs)
	testing.expect_value(t, len(hs), 2)
	if len(hs) == 2 {
		testing.expect(t, hs[0].id == "editor.desktop" && hs[0].default, "the default first")
		testing.expect(t, hs[1].id == "ide-code.desktop" && hs[1].name == "An IDE" && !hs[1].default, "an id of a subfolder")
	}
	png := handlers_in(roots, "/x/a.png", context.allocator)
	defer handlers_destroy(png)
	testing.expect_value(t, len(png), 2)
	if len(png) == 2 { testing.expect(t, png[0].name == "Editor" && png[1].name == "Viewer", "by name, none the default") }
}

// An Exec value read as the specification says, and its field codes replaced.
@(test)
an_exec_line_expanded :: proc(t: ^testing.T) {
	args := exec_arguments(`"/opt/my ide/ide" --flag "a \"q\"" %u`)
	testing.expect_value(t, len(args), 4)
	if len(args) == 4 {
		testing.expect_value(t, args[0], "/opt/my ide/ide")
		testing.expect_value(t, args[2], `a "q"`)
	}
	testing.expect_value(t, exec_program(`"/opt/my ide/ide" %u`), "/opt/my ide/ide")
	e := exec_expand("editor --name=%c %i --file=%f 100%%", "/a b.txt", "Ed", "ed", "/apps/ed.desktop")
	testing.expect_value(t, strings.join(e, "|", context.temp_allocator), "editor|--name=Ed|--icon|ed|--file=/a b.txt|100%")
	tail := exec_expand("viewer", "/p.png", "", "", "")
	testing.expect_value(t, strings.join(tail, "|", context.temp_allocator), "viewer|/p.png")
}
