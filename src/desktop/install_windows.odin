package tk_desktop

import "core:fmt"
import "core:os"
import "core:strings"
import i18n "../i18n"

// What an executable's file name ends with.
@(private) EXE_SUFFIX :: ".exe"
// What separates a path's folders.
@(private) SEPARATOR :: "\\"

// Why `d` is not a full path to an install folder, "" when it is: a drive path, C:\dir; a colon only after the drive
// letter; no network share (a program is not installed there); not the root of a drive.
@(private)
full_path_refusal :: proc(d, name: string) -> string {
	if len(d) < 3 || !is_ascii_letter(d[0]) || d[1] != ':' || (d[2] != '\\' && d[2] != '/') {
		return fmt.tprintf(i18n.tr("Use a full path on a local drive, such as C:\\Users\\you\\AppData\\Local\\Programs\\%s."), name)
	}
	if strings.contains(d[2:], ":") { return i18n.tr("The folder name has a colon after the drive letter.") }
	if strings.trim_right(d[2:], "\\/") == "" { return i18n.tr("Pick a folder, not the root of a drive.") }
	return ""
}

// Two parts of paths name the same thing: case does not count.
@(private)
same_path_part :: proc(a, b: string) -> bool { return strings.equal_fold(a, b) }

// The system's own folders, where nothing is installed.
@(private)
system_folders :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for name in ([]string{"SystemRoot", "windir", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "ProgramData", "CommonProgramFiles"}) {
		if v, ok := os.lookup_env(name, context.temp_allocator); ok && v != "" { append(&out, v) }
	}
	return out[:]
}
