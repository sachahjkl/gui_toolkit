#+build linux
package platform

import "core:os"
import "core:path/filepath"
import "core:strings"

@(private) USER_DIR_SEPARATOR :: "/"

// $XDG_<kind>_HOME when it is absolute, else its default under the home (temp memory; "": no home).
@(private)
user_dir_base :: proc(kind: User_Dir) -> string {
	name, fallback: string
	switch kind {
	case .Config: name, fallback = "XDG_CONFIG_HOME", "/.config"
	case .Data:   name, fallback = "XDG_DATA_HOME", "/.local/share"
	case .State:  name, fallback = "XDG_STATE_HOME", "/.local/state"
	case .Cache:  name, fallback = "XDG_CACHE_HOME", "/.cache"
	}
	if v, ok := os.lookup_env(name, context.temp_allocator); ok && filepath.is_abs(v) { return v }
	home, ok := os.lookup_env("HOME", context.temp_allocator)
	if !ok || home == "" { return "" }
	return strings.concatenate({home, fallback}, context.temp_allocator)
}

// (Linux keeps each kind in a folder of its own: nothing under the program's.)
@(private)
user_dir_leaf :: proc(kind: User_Dir) -> string { return "" }
