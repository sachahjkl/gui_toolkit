#+build !windows
package tk_desktop

import "core:strings"
import i18n "../i18n"

// What an executable's file name ends with: nothing.
@(private) EXE_SUFFIX :: ""
// What separates a path's folders.
@(private) SEPARATOR :: "/"

// Why `d` is not a full path to an install folder, "" when it is: absolute, not the root.
@(private)
full_path_refusal :: proc(d, name: string) -> string {
	if !strings.has_prefix(d, "/") { return i18n.tr("Use a full path.") }
	if strings.trim_right(d, "/") == "" { return i18n.tr("Pick a folder, not the root.") }
	return ""
}

// Two parts of paths name the same thing: exactly.
@(private)
same_path_part :: proc(a, b: string) -> bool { return a == b }

// The system's own folders, where nothing is installed.
@(private)
system_folders :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for p in ([]string{"/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/boot", "/dev", "/proc", "/sys", "/var", "/opt", "/root"}) { append(&out, p) }
	return out[:]
}
