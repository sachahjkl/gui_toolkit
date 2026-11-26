package tk_desktop

// The system scope on Linux (src/md/features/install-scope.md): the program in /opt/<vendor_key>/<name>, its entry,
// icons and thumbnailer under /usr/local/share, its link in /usr/local/bin; root writes them through pkexec.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import i18n "../i18n"
import "../process"

// Where polkit's pkexec is, in the system's folders only (never looked for on the PATH: the user writes it).
@(private = "file")
PKEXEC_PLACES :: [?]string{"/usr/bin/pkexec", "/bin/pkexec", "/run/wrappers/bin/pkexec"}

// (pkexec's exit codes: the person dismissed the prompt or is not allowed; no agent could ask, or another failure)
@(private = "file") PKEXEC_REFUSED :: 126
@(private = "file") PKEXEC_FAILED  :: 127

@(private = "file")
pkexec_path :: proc() -> string {
	for p in PKEXEC_PLACES { if os.is_file(p) { return p } }
	return ""
}

@(private)
system_refusal_here :: proc() -> System_Refusal { return pkexec_path() == "" ? .No_Elevation : .None }

@(private)
no_elevation_words :: proc() -> string {
	return i18n.tr("No administrator can be asked here: polkit's pkexec is not installed.")
}

// <root>/opt/<vendor_key>/<name>, beside the others of its vendor as ~/.local/opt has the person's.
@(private)
system_install_dir_here :: proc(o: ^Integration_Options, root: string, allocator: runtime.Allocator) -> string {
	if !folder_name_ok(o.identity.name) { return "" }
	if o.identity.vendor_key == "" { return strings.concatenate({root, "/opt/", o.identity.name}, allocator) }
	return strings.concatenate({root, "/opt/", o.identity.vendor_key, "/", o.identity.name}, allocator)
}

// The machine's shared data folder: <root>/usr/local/share (in XDG_DATA_DIRS by default).
@(private)
machine_share :: proc(o: ^Integration_Options) -> string {
	return strings.concatenate({machine_root_of(o), "/usr/local/share"}, context.temp_allocator)
}

// The machine's folder of programs on every account's PATH.
@(private)
machine_bin :: proc(o: ^Integration_Options) -> string {
	return strings.concatenate({machine_root_of(o), "/usr/local/bin"}, context.temp_allocator)
}

// Before root writes or deletes: files it makes are readable by every account (umask 022), and no folder that it writes
// in (machine_folders) is one that a user owns or a group or others can write. Else a user who made /opt/<vendor_key>
// first would own the program that every account runs, and one who could write /usr/local/share/applications would
// put a link where root then writes. Removal checks the same folders: root deletes what a manifest names, and a link
// that a user put in the program's folder would lead root's deletions elsewhere.
@(private)
machine_prepare :: proc(o: ^Integration_Options, dir: string) -> Result {
	if machine_is_scratch(o) { return {} }
	_ = linux.umask({.IWGRP, .IWOTH})
	for folder in machine_folders(o, dir) {
		if why := folder_chain_words(folder); why != "" { return {.Machine, why} }
	}
	return {}
}

// The folders that the machine half writes in: the program's, the menu's, the thumbnailers', the PATH's, the icons'.
@(private)
machine_folders :: proc(o: ^Integration_Options, dir: string) -> []string {
	share := machine_share(o)
	out := make([dynamic]string, context.temp_allocator)
	append(&out, dir, strings.concatenate({share, "/applications"}, context.temp_allocator),
		strings.concatenate({share, "/thumbnailers"}, context.temp_allocator), machine_bin(o))
	append(&out, strings.concatenate({share, "/icons/hicolor"}, context.temp_allocator))
	for ic in o.icons { append(&out, fmt.tprintf("%s/icons/hicolor/%dx%d/apps", share, ic.size, ic.size)) }
	return out[:]
}

// "" when root may write in `path`: each folder of it, up to /, is missing (root makes it) or is root's alone.
@(private)
folder_chain_words :: proc(path: string) -> string {
	p := path
	for p != "" && p != "/" {
		if why := folder_owned_by_root_words(p); why != "" { return why }
		i := strings.last_index_byte(p, '/')
		p = i > 0 ? p[:i] : ""
	}
	return ""
}

// "" when `path` is missing (root makes it), is a folder of root's that only root writes, or is a link of root's to
// such a folder whose own folders are all root's (Fedora Atomic's /opt is a link to /var/opt); else why not.
@(private)
folder_owned_by_root_words :: proc(path: string) -> string {
	st: linux.Stat
	if err := linux.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st); err != .NONE {
		return err == .ENOENT ? "" : fmt.tprintf("cannot read %s", path)
	}
	if linux.S_ISLNK(st.mode) {
		// (only root changes a link of root's in a folder of root's; what it leads to is checked as any folder, and
		// realpath leaves no link in it: no loop)
		if st.uid != 0 { return fmt.tprintf("%s is a link that is not root's", path) }
		buf: [4096]byte   // (Linux's PATH_MAX, what realpath may write)
		real := posix.realpath(strings.clone_to_cstring(path, context.temp_allocator), raw_data(buf[:]))
		if real == nil { return fmt.tprintf("cannot follow the link %s", path) }
		resolved := string(real)
		if resolved == "/" { return "" }
		if !os.is_dir(resolved) { return fmt.tprintf("%s is not a folder", path) }
		return folder_chain_words(strings.clone(resolved, context.temp_allocator))
	}
	if !linux.S_ISDIR(st.mode) { return fmt.tprintf("%s is not a folder", path) }
	if st.uid != 0 { return fmt.tprintf("%s is not root's", path) }
	if st.mode & {.IWGRP, .IWOTH} != {} { return fmt.tprintf("%s can be written by others than root", path) }
	return ""
}

// The program from this process's own image: /proc/self/exe is the file that runs, even renamed or replaced since.
@(private)
self_image_place :: proc(exe: string) -> Result {
	if !ensure_dir(process.parent_dir(exe)) { return {.Io, strings.concatenate({"cannot create ", process.parent_dir(exe)}, context.temp_allocator)} }
	fresh := strings.concatenate({exe, ".new"}, context.temp_allocator)
	_ = os.remove(fresh)
	if err := os.copy_file(fresh, "/proc/self/exe"); err != nil { _ = os.remove(fresh); return {.Io, strings.concatenate({"cannot write ", fresh}, context.temp_allocator)} }
	_ = os.chmod(fresh, os.Permissions_Default_File | {.Execute_User, .Execute_Group, .Execute_Other})
	if err := os.rename(fresh, exe); err != nil { _ = os.remove(fresh); return {.Io, strings.concatenate({"cannot write ", exe}, context.temp_allocator)} }
	return {}
}

// Linux deletes a file that runs: nothing waits for a restart.
@(private)
remove_at_restart :: proc(path: string) { _ = os.remove(path) }

// Runs the elevated verb as root through pkexec (polkit asks for an administrator's password) and waits for it. pkexec
// gives the program a clean environment: no root of the person's reaches it.
machine_elevate :: proc(o: ^Integration_Options, exe: string, arguments: []string) -> Result {
	pk := pkexec_path()
	if pk == "" { return {.Not_Allowed, no_elevation_words()} }
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, pk, exe)
	append(&cmd, ..arguments)
	r := process.run(cmd[:], {}, context.temp_allocator)
	switch {
	case r.ok:                     return {}
	case r.code == PKEXEC_REFUSED: return {.Not_Allowed, error_text(.Not_Allowed)}
	case r.code == PKEXEC_FAILED:  return {.Not_Allowed, i18n.tr("No administrator could be asked: no polkit agent runs in this session.")}
	}
	return {.Machine, fmt.tprintf("the change for every account failed (exit code %d): %s", r.code, strings.trim_space(r.stderr))}
}
