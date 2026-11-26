package tk_desktop

// The few registry operations the Windows backend needs, with paths given as plain strings. Each works under
// HKEY_CURRENT_USER unless given another hive: only the Task_Manager part (task_manager_windows.odin) reads
// HKEY_LOCAL_MACHINE, and writes it only in the process that an administrator allowed.

import "core:strings"
import win "core:sys/windows"
import "../ascii"

// The key that stands for HKCU\Software: "Software" itself, or a scratch key under it for the tests.
@(private)
registry_root_of :: proc(o: ^Integration_Options) -> string { return o.registry_root != "" ? o.registry_root : "Software" }

@(private)
reg_join :: proc(parts: ..string) -> string { return strings.join(parts, "\\", context.temp_allocator) }

// Sets a string value (the default value when `name` is empty), creating the key and its parents.
@(private)
reg_set :: proc(path, name, value: string, hive := win.HKEY_CURRENT_USER) -> bool {
	key: win.HKEY
	if win.RegCreateKeyExW(hive, wide(path), 0, nil, win.REG_OPTION_NON_VOLATILE, win.KEY_SET_VALUE | win.KEY_CREATE_SUB_KEY, nil, &key, nil) != 0 { return false }
	defer win.RegCloseKey(key)
	w := win.utf8_to_wstring(value, context.temp_allocator)
	units := 0
	for (cast([^]u16)w)[units] != 0 { units += 1 }
	return win.RegSetValueExW(key, name == "" ? nil : wide(name), 0, win.REG_SZ, cast(^win.BYTE)rawptr(w), win.DWORD((units + 1) * 2)) == 0
}

// A string value ("" and false when the key or the value is missing, or the value is not a string).
@(private)
reg_get :: proc(path, name: string, hive := win.HKEY_CURRENT_USER) -> (value: string, ok: bool) {
	size: win.DWORD
	if win.RegGetValueW(hive, wide(path), name == "" ? nil : wide(name), win.RRF_RT_REG_SZ, nil, nil, &size) != 0 || size < 2 { return "", false }
	buf := make([]u16, int(size) / 2 + 1, context.temp_allocator)
	if win.RegGetValueW(hive, wide(path), name == "" ? nil : wide(name), win.RRF_RT_REG_SZ, nil, raw_data(buf), &size) != 0 { return "", false }
	return narrow(buf), true
}

// A REG_SZ or REG_EXPAND_SZ value as stored (%VARIABLES% not expanded), with whether it is the expanding kind.
@(private)
reg_get_any :: proc(path, name: string, hive := win.HKEY_CURRENT_USER) -> (value: string, expand, ok: bool) {
	flags := win.DWORD(win.RRF_RT_REG_SZ | win.RRF_RT_REG_EXPAND_SZ | win.RRF_NOEXPAND)
	size, kind: win.DWORD
	if win.RegGetValueW(hive, wide(path), name == "" ? nil : wide(name), flags, &kind, nil, &size) != 0 { return "", false, false }
	buf := make([]u16, int(size) / 2 + 1, context.temp_allocator)
	if win.RegGetValueW(hive, wide(path), name == "" ? nil : wide(name), flags, &kind, raw_data(buf), &size) != 0 { return "", false, false }
	return narrow(buf), kind == win.REG_EXPAND_SZ, true
}

// Sets a string value of the given kind (REG_EXPAND_SZ when `expand`), creating the key.
@(private)
reg_set_kind :: proc(path, name, value: string, expand: bool, hive := win.HKEY_CURRENT_USER) -> bool {
	key: win.HKEY
	if win.RegCreateKeyExW(hive, wide(path), 0, nil, win.REG_OPTION_NON_VOLATILE, win.KEY_SET_VALUE | win.KEY_CREATE_SUB_KEY, nil, &key, nil) != 0 { return false }
	defer win.RegCloseKey(key)
	w := win.utf8_to_wstring(value, context.temp_allocator)
	units := 0
	for (cast([^]u16)w)[units] != 0 { units += 1 }
	kind := expand ? win.DWORD(win.REG_EXPAND_SZ) : win.DWORD(win.REG_SZ)
	return win.RegSetValueExW(key, name == "" ? nil : wide(name), 0, kind, cast(^win.BYTE)rawptr(w), win.DWORD((units + 1) * 2)) == 0
}

// A DWORD value (0 and false when missing).
@(private)
reg_set_dword :: proc(path, name: string, value: u32) -> bool {
	key: win.HKEY
	if win.RegCreateKeyExW(win.HKEY_CURRENT_USER, wide(path), 0, nil, win.REG_OPTION_NON_VOLATILE, win.KEY_SET_VALUE | win.KEY_CREATE_SUB_KEY, nil, &key, nil) != 0 { return false }
	defer win.RegCloseKey(key)
	v := value
	return win.RegSetValueExW(key, wide(name), 0, win.REG_DWORD, cast(^win.BYTE)&v, 4) == 0
}

@(private)
reg_key_exists :: proc(path: string, hive := win.HKEY_CURRENT_USER) -> bool {
	key: win.HKEY
	if win.RegOpenKeyExW(hive, wide(path), 0, win.KEY_READ, &key) != 0 { return false }
	win.RegCloseKey(key)
	return true
}

// Deletes the key and everything under it (true when it is gone, also when it never was there).
@(private)
reg_delete_tree :: proc(path: string) -> bool {
	r := RegDeleteTreeW(win.HKEY_CURRENT_USER, wide(path))
	return r == 0 || r == win.LSTATUS(win.ERROR_FILE_NOT_FOUND)
}

// Deletes the key when it holds no subkey and no value: a parent the program created goes with its last child, and
// one that holds something of another program stays. True when it is gone or never was there.
@(private)
reg_delete_if_empty :: proc(path: string, hive := win.HKEY_CURRENT_USER) -> bool {
	key: win.HKEY
	r := win.RegOpenKeyExW(hive, wide(path), 0, win.KEY_READ, &key)
	if r == win.LSTATUS(win.ERROR_FILE_NOT_FOUND) { return true }
	if r != 0 { return false }
	subkeys, values: win.DWORD
	r = win.RegQueryInfoKeyW(key, nil, nil, nil, &subkeys, nil, nil, &values, nil, nil, nil, nil)
	win.RegCloseKey(key)
	if r != 0 { return false }
	if subkeys > 0 || values > 0 { return false }
	return RegDeleteKeyW(hive, wide(path)) == 0
}

// The names of the values of a key, the default value left out (nil when the key is missing; temp memory).
@(private)
reg_value_names :: proc(path: string) -> []string {
	key: win.HKEY
	if win.RegOpenKeyExW(win.HKEY_CURRENT_USER, wide(path), 0, win.KEY_READ, &key) != 0 { return nil }
	defer win.RegCloseKey(key)
	out := make([dynamic]string, context.temp_allocator)
	buf := make([]u16, 16384, context.temp_allocator)   // (a value's name is at most 16383 characters)
	for i: win.DWORD = 0; ; i += 1 {
		n := win.DWORD(len(buf))
		if win.RegEnumValueW(key, i, raw_data(buf), &n, nil, nil, nil, nil) != 0 { break }
		if n == 0 { continue }
		if s, err := win.utf16_to_utf8(buf[:n], context.temp_allocator); err == nil { append(&out, s) }
	}
	return out[:]
}

@(private)
reg_delete_value :: proc(path, name: string, hive := win.HKEY_CURRENT_USER) -> bool {
	key: win.HKEY
	r := win.RegOpenKeyExW(hive, wide(path), 0, win.KEY_SET_VALUE, &key)
	if r == win.LSTATUS(win.ERROR_FILE_NOT_FOUND) { return true }
	if r != 0 { return false }
	defer win.RegCloseKey(key)
	r = RegDeleteValueW(key, wide(name))
	return r == 0 || r == win.LSTATUS(win.ERROR_FILE_NOT_FOUND)
}

// The program a shell command line runs: `"C:\dir\app.exe" "%1"` -> C:\dir\app.exe.
@(private)
command_program :: proc(command: string) -> string {
	c := strings.trim_left_space(command)
	if c == "" { return "" }
	if c[0] == '"' {
		end := strings.index_byte(c[1:], '"')
		return end < 0 ? c[1:] : c[1:1 + end]
	}
	end := strings.index_any(c, " \t")
	return end < 0 ? c : c[:end]
}

// Deletes a scratch registry root (a test's, or a script's dry run): only a key that begins with one of the identity's
// `scratch_roots` (and is longer than it) can be deleted, so a wrong argument cannot reach the real ones.
delete_scratch_root :: proc(id: Identity, root: string) -> bool {
	if strings.contains(root, "..") { return false }
	for prefix in id.scratch_roots {
		if len(prefix) >= len("Software\\x") && len(root) > len(prefix) && ascii.has_prefix_fold(root, prefix) { return reg_delete_tree(root) }
	}
	return false
}
