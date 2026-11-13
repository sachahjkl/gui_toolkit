package tk_desktop

// The console launcher, `<stem>.com` beside `<stem>.exe` (Windows): a small console program that `install` writes when
// the PATH part is on and takes away when it is off (and when the installation goes). It exists because a program with a
// window gives the prompt back at once from cmd or PowerShell and has no console of its own, so a script gets neither its
// output nor its exit code. cmd.exe and PowerShell prefer `<stem>.com` to `<stem>.exe` when `<stem>` is typed: the
// launcher, which the program provides, starts the program and gives its output and code through.
//
// The program passes the launcher's bytes in `Integration_Options.launcher` (it can embed them: the release stays one file). It is
// written only next to the executable of an integration whose PATH part is on: never in another folder, never without the
// PATH entry that makes it reachable. Removal deletes only a file that carries `Identity.launcher_mark`.

import "core:os"
import "core:strings"

@(private = "file") LAUNCHER_MAX_BYTES :: 16 << 20   // (a file larger than any launcher is not read to be searched)

// `<dir>\<stem>.com` for the executable `<dir>\<stem>.exe`; "" where there is no such thing (not Windows) or `exe` has no
// extension.
launcher_file :: proc(exe: string, allocator := context.temp_allocator) -> string {
	when ODIN_OS != .Windows { return "" }
	slash := max(strings.last_index_byte(exe, '\\'), strings.last_index_byte(exe, '/'))
	dot := strings.last_index_byte(exe, '.')
	if dot <= slash + 1 { return "" }
	return strings.concatenate({exe[:dot], ".com"}, allocator)
}

// Is the file at `path` a launcher of ours (it carries the identity's mark)? Never without a mark.
launcher_is_ours :: proc(o: ^Integration_Options, path: string) -> bool {
	mark := o.identity.launcher_mark
	if mark == "" || path == "" || !os.is_file(path) { return false }
	if info, err := os.stat(path, context.temp_allocator); err != nil || info.size <= 0 || info.size > LAUNCHER_MAX_BYTES { return false }
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil && strings.contains(string(data), mark)
}

// Is there a launcher of ours beside the executable of these options?
launcher_current :: proc(o: ^Integration_Options) -> bool {
	return launcher_is_ours(o, launcher_file(o.exe))
}

// Writes the launcher beside `o.exe`, unless the options carry none. A file that is not the launcher's (no mark) is never
// replaced. One that is the same bytes is left alone (it may be running); another version is renamed aside and replaced,
// as a running program's file can be renamed, not overwritten.
launcher_write :: proc(o: ^Integration_Options) -> Result {
	if len(o.launcher) == 0 { return {} }
	path := launcher_file(o.exe)
	if path == "" { return {} }
	had := os.exists(path)
	if had {
		if !launcher_is_ours(o, path) {
			return {.Io, strings.concatenate({path, " exists and is not ", o.identity.name, "'s console launcher: it is left as it is, so the program does not run from a terminal through it"}, context.temp_allocator)}
		}
		if same, err := os.read_entire_file(path, context.temp_allocator); err == nil && string(same) == string(o.launcher) { return {} }
	}
	fresh := strings.concatenate({path, ".new"}, context.temp_allocator)
	old := strings.concatenate({path, OLD_SUFFIX}, context.temp_allocator)
	if err := os.write_entire_file(fresh, o.launcher); err != nil {
		_ = os.remove(fresh)
		return {.Io, strings.concatenate({"cannot write ", fresh}, context.temp_allocator)}
	}
	if had {
		_ = os.remove(old)
		if err := os.rename(path, old); err != nil {
			_ = os.remove(fresh)
			return {.Io, strings.concatenate({"cannot move ", path, " aside (is it running?)"}, context.temp_allocator)}
		}
	}
	if err := os.rename(fresh, path); err != nil {
		_ = os.remove(fresh)
		if had { _ = os.rename(old, path) }
		return {.Io, strings.concatenate({"cannot write ", path}, context.temp_allocator)}
	}
	if had { _ = os.remove(old) }   // (a running launcher holds it: the next write or removal gets it)
	return {}
}

// Deletes the launcher beside `exe` when it is ours (and the `.old` a replacement left). One that runs now cannot be
// deleted: it is renamed aside so that the name is free, and the next removal gets it.
launcher_remove :: proc(o: ^Integration_Options, exe: string) -> Result {
	path := launcher_file(exe)
	if path == "" { return {} }
	old := strings.concatenate({path, OLD_SUFFIX}, context.temp_allocator)
	if launcher_is_ours(o, old) { _ = os.remove(old) }
	if !launcher_is_ours(o, path) { return {} }
	if err := os.remove(path); err != nil {
		_ = os.remove(old)
		if os.rename(path, old) != nil { return {.Io, strings.concatenate({"cannot delete ", path}, context.temp_allocator)} }
	}
	return {}
}
