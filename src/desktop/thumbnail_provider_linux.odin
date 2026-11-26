package tk_desktop

// The Thumbnails part on Linux: $XDG_DATA_HOME/thumbnailers/<slug>.thumbnailer (thumbnailer_text), which every file
// manager of the freedesktop.org family reads, the program itself its command. Ours: the identity's entry_marker key, or
// an Exec that runs the executable, as a desktop entry.

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../fsx"
import "../platform"

// <thumbnailers_dir>/<slug>.thumbnailer ("" when neither the option nor the data directory is known).
@(private)
thumbnailer_path :: proc(o: ^Integration_Options) -> string {
	dir := in_machine(o) ? strings.concatenate({machine_share(o), "/thumbnailers"}, context.temp_allocator) : o.thumbnailers_dir
	if dir == "" {
		data := platform.user_dir(.Data, "", context.temp_allocator)
		if data == "" { return "" }
		dir = strings.concatenate({data, "/thumbnailers"}, context.temp_allocator)
	}
	return strings.concatenate({dir, "/", o.identity.slug, ".thumbnailer"}, context.temp_allocator)
}

// The .thumbnailer at `path` when it is the program's, and the program it runs.
@(private = "file")
thumbnailer_ours :: proc(o: ^Integration_Options, path: string) -> (ours: bool, target, text: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	text = string(data)
	GROUP :: "[Thumbnailer Entry]"
	mark, _ := group_value(text, GROUP, o.identity.entry_marker)
	exec, _ := group_value(text, GROUP, "Exec")
	target = exec_program(exec)
	return mark == o.identity.slug || same_path(target, o.exe), target, text
}

// Present when the file is the program's; partial when it is not what these options write (other types, other
// arguments), stale when it runs another executable.
@(private)
thumbnailer_status :: proc(o: ^Integration_Options, allocator: runtime.Allocator) -> (ps: Part_Status) {
	path := thumbnailer_path(o)
	if path == "" { return }
	ours, target, text := thumbnailer_ours(o, path)
	if !ours { return }
	ps.present = true
	ps.target = clone_or_empty(target, allocator)
	ps.stale = !same_path(target, o.exe)
	ps.partial = thumbnails_wanted(o) && !ps.stale && text != thumbnailer_text(o)
	return
}

// Writes the file when the options ask for the part, else takes ours away. Another program's file of that name is never
// replaced.
@(private)
thumbnailer_apply :: proc(o: ^Integration_Options) -> Result {
	path := thumbnailer_path(o)
	if path == "" {
		if thumbnails_wanted(o) { return {.System, "neither $XDG_DATA_HOME nor the home directory is known"} }
		return {}
	}
	ours, _, _ := thumbnailer_ours(o, path)
	if !thumbnails_wanted(o) {
		if ours { return thumbnailer_remove(o) }
		return {}
	}
	if os.exists(path) && !ours { return {.Io, strings.concatenate({path, " is another program's"}, context.temp_allocator)} }
	if !ensure_dir(filepath.dir(path)) { return {.Io, strings.concatenate({"cannot create the directory of ", path}, context.temp_allocator)} }
	if !fsx.write_atomic(path, transmute([]byte)thumbnailer_text(o)) { return {.Io, strings.concatenate({"cannot write ", path}, context.temp_allocator)} }
	return {}
}

@(private)
thumbnailer_remove :: proc(o: ^Integration_Options) -> Result {
	path := thumbnailer_path(o)
	if path == "" { return {} }
	if ours, _, _ := thumbnailer_ours(o, path); ours {
		if err := os.remove(path); err != nil { return {.Io, strings.concatenate({"cannot delete ", path}, context.temp_allocator)} }
	}
	return {}
}
