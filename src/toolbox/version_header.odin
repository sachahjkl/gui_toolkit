package tk_toolbox

// The version of a Windows executable (its VERSIONINFO resource): a C header the .rc file includes, written by the build.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The header of a version of three numbers ("0.9.0"): VER_MAJOR, VER_MINOR, VER_PATCH and VER_STRING. "": not three numbers.
version_header :: proc(version: string, allocator := context.temp_allocator) -> string {
	parts := strings.split(version, ".", context.temp_allocator)
	if len(parts) != 3 { return "" }
	for p in parts {
		if p == "" { return "" }
		for c in p { if c < '0' || c > '9' { return "" } }
	}
	return fmt.aprintf("#define VER_MAJOR %s\r\n#define VER_MINOR %s\r\n#define VER_PATCH %s\r\n#define VER_STRING \"%s\"\r\n",
		parts[0], parts[1], parts[2], version, allocator = allocator)
}

// Writes the header of `version` at `path` (its folder made), only when it changes: the resource is not compiled again.
// why: "" when it is there.
write_version_header :: proc(path, version: string) -> (why: string) {
	header := version_header(version)
	if header == "" { return fmt.tprintf("%q is not a version of three numbers", version) }
	if old, err := os.read_entire_file(path, context.temp_allocator); err == nil && string(old) == header { return "" }
	_ = os.make_directory_all(filepath.dir(path))
	if os.write_entire_file(path, transmute([]u8)header) != nil { return fmt.tprintf("%s cannot be written", path) }
	return ""
}
