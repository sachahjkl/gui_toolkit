package tk_desktop

// The Task_Manager part on Windows (src/md/features/default-task-manager.md), a part of an install for everyone only
// (src/md/features/install-scope.md):
//
//   HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\taskmgr.exe
//       Debugger                  "<installed program>": Windows starts it in place of taskmgr.exe (Ctrl+Shift+Esc, the
//                                 taskbar, Ctrl+Alt+Del), taskmgr's path and options after it
//       <registry_mark>           the AppUserModelID: the program wrote this key
//       <registry_mark>Previous   the Debugger there before, of its kind, which Off gives back
//
// The installed program is in Program Files, where only an administrator writes. The state is read without elevation;
// the machine half of the install (the elevated verb, or a test's machine_registry_root) writes it. The image's copy
// (image_copy_self) is the elevated verb's way to put the program in Program Files.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "../process"

@(private = "file")
IMAGE_OPTIONS_KEY :: `SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options`

foreign import kernel32_task_manager "system:Kernel32.lib"

@(private = "file", default_calling_convention = "system")
foreign kernel32_task_manager {
	K32GetMappedFileNameW :: proc(process: win.HANDLE, address: rawptr, name: [^]u16, size: win.DWORD) -> win.DWORD ---
}

@(private = "file")
Task_Manager_Place :: struct {
	key:      string,   // ...\Image File Execution Options\taskmgr.exe, under the machine's hive (machine_hive)
	program:  string,   // the installed program the Debugger runs
	previous: string,   // the name of the value that keeps the Debugger there before
}

@(private = "file")
task_manager_place :: proc(o: ^Integration_Options) -> Task_Manager_Place {
	return {
		key = reg_join(machine_hive(o), IMAGE_OPTIONS_KEY, "taskmgr.exe"),
		program = o.exe,
		previous = strings.concatenate({o.identity.registry_mark, "Previous"}, context.temp_allocator),
	}
}

@(private = "file")
image_options_read :: proc(o: ^Integration_Options, p: Task_Manager_Place) -> (k: Image_Options) {
	if v, expand, ok := reg_get_any(p.key, "Debugger"); ok { k.debugger = {v, expand, true} }
	if v, expand, ok := reg_get_any(p.key, p.previous); ok { k.previous = {v, expand, true} }
	mark, _ := reg_get(p.key, o.identity.registry_mark)
	k.marked = mark == identity_aumid(o.identity)
	return
}

// The Debugger runs the installed program (a REG_EXPAND_SZ one is never the program's: it writes REG_SZ).
@(private = "file")
debugger_runs_program :: proc(k: Image_Options, p: Task_Manager_Place) -> bool {
	return k.debugger.present && !k.debugger.expand && same_path(command_program(k.debugger.value), p.program)
}

// The part: present when the key is the program's (its mark) or its Debugger runs the installed program; stale when
// the Debugger runs something else (another program took it since); partial when the program is not there.
@(private)
task_manager_status :: proc(o: ^Integration_Options, allocator: runtime.Allocator) -> (ps: Part_Status) {
	p := task_manager_place(o)
	k := image_options_read(o, p)
	runs := debugger_runs_program(k, p)
	if !(k.marked || runs) { return }
	ps.present = true
	ps.target = clone_or_empty(command_program(k.debugger.value), allocator)
	ps.stale = !runs
	ps.partial = runs && !os.is_file(p.program)
	return
}

// The machine half of a system install: the part as the options want it (`on`), or taken away (`removing`, or off
// while the key is the program's). The Debugger there before is kept and given back exactly; one that another program
// set after ours stays.
@(private)
task_manager_apply :: proc(o: ^Integration_Options, on, removing: bool) -> Result {
	p := task_manager_place(o)
	k := image_options_read(o, p)
	runs := debugger_runs_program(k, p)
	if on && !removing {
		if runs && k.marked { return {} }
		return image_options_write(o, p, image_options_on(k, task_manager_debugger(p.program), runs))
	}
	if !runs && !k.marked { return {} }
	return image_options_write(o, p, image_options_off(k, runs))
}

// Writes what the key holds after a change. The order keeps the Debugger there before in one value or the other at
// each step: the kept one is written before the Debugger changes, and deleted after it is given back.
@(private = "file")
image_options_write :: proc(o: ^Integration_Options, p: Task_Manager_Place, after: Image_Options) -> Result {
	failed :: proc(p: Task_Manager_Place) -> Result { return {.Machine, strings.concatenate({"cannot write ", p.key}, context.temp_allocator)} }
	put :: proc(p: Task_Manager_Place, name: string, v: Registry_String) -> bool {
		if v.present { return reg_set_kind(p.key, name, v.value, v.expand) }
		return reg_delete_value(p.key, name)
	}
	if after.previous.present && !put(p, p.previous, after.previous) { return failed(p) }
	if !put(p, "Debugger", after.debugger) { return failed(p) }
	mark := o.identity.registry_mark
	if after.marked {
		if !reg_set(p.key, mark, identity_aumid(o.identity)) { return failed(p) }
	} else if !reg_delete_value(p.key, mark) { return failed(p) }
	if !after.previous.present && !put(p, p.previous, after.previous) { return failed(p) }
	if !after.debugger.present && !after.marked { _ = reg_delete_if_empty(p.key) }
	return {}
}

// Moves a file that runs (it cannot be deleted) to a name of its own beside it, deleted at the next restart. The
// restart deletes the name it was given: never `path` itself, where a later On puts a new machine copy before it.
@(private = "file")
put_aside :: proc(path: string) -> bool {
	// (a name that is free: an earlier one may still run, or wait for its restart)
	for i in 0 ..< 64 {
		aside := fmt.tprintf("%s.%d.%d.old", path, win.GetCurrentProcessId(), i)
		if !win.MoveFileExW(wide(path), wide(aside), 0) {
			if win.GetLastError() == win.ERROR_ALREADY_EXISTS { continue }
			return false
		}
		_ = win.MoveFileExW(wide(aside), nil, win.MOVEFILE_DELAY_UNTIL_REBOOT)
		return true
	}
	return false
}

// Writes `dst` from the file of this process's own image. The image's current name (GetMappedFileNameW: the file
// system's name of the mapped file, which follows a rename) is opened with no write and no delete sharing, so it can no
// longer be renamed nor changed; the name read again then still being the one opened proves the handle is the image's
// file (one name is one file). The bytes go to <dst>.new, which takes dst's name (the running copy put aside first).
// The new file gets the folder's rights (Program Files': only an administrator writes).
@(private)
image_copy_self :: proc(dst: string) -> Result {
	if !ensure_dir(process.parent_dir(dst)) { return {.Io, strings.concatenate({"cannot create ", process.parent_dir(dst)}, context.temp_allocator)} }
	data, ok := image_read_self()
	if !ok { return {.Io, "the program's own file could not be read safely"} }
	next := strings.concatenate({dst, ".new"}, context.temp_allocator)
	_ = win.DeleteFileW(wide(next))
	if !file_write_flushed(next, data) { _ = win.DeleteFileW(wide(next)); return {.Io, strings.concatenate({"cannot write ", next}, context.temp_allocator)} }
	if win.MoveFileExW(wide(next), wide(dst), win.MOVEFILE_REPLACE_EXISTING) { return {} }
	if !put_aside(dst) || !win.MoveFileExW(wide(next), wide(dst), 0) {
		_ = win.DeleteFileW(wide(next))
		return {.Io, strings.concatenate({"cannot replace ", dst}, context.temp_allocator)}
	}
	return {}
}

// Writes `data` to a new file and flushes it to the disk (FlushFileBuffers) before it is closed: the move that follows
// gives it the machine copy's name, and a crash or a power cut after it must not leave the Debugger on a torn file.
@(private = "file")
file_write_flushed :: proc(path: string, data: []byte) -> bool {
	f, err := os.open(path, {.Write, .Create, .Trunc})
	if err != nil { return false }
	defer os.close(f)
	n, werr := os.write(f, data)
	if werr != nil || n != len(data) { return false }
	return os.flush(f) == nil   // (FlushFileBuffers on Windows)
}

// The bytes of this process's own image file, read through a handle that holds it (image_copy_self says why).
@(private = "file")
image_read_self :: proc() -> (data: []byte, ok: bool) {
	module := rawptr(win.GetModuleHandleW(nil))
	for _ in 0 ..< 3 {
		before := mapped_name(module)
		if before == "" { return nil, false }
		h := win.CreateFileW(wide(global_root_path(before)), win.GENERIC_READ, win.FILE_SHARE_READ, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
		if h == win.INVALID_HANDLE_VALUE { return nil, false }
		if mapped_name(module) != before {   // (renamed meanwhile: the handle may be another file's)
			win.CloseHandle(h)
			continue
		}
		defer win.CloseHandle(h)
		size: win.LARGE_INTEGER
		if !win.GetFileSizeEx(h, &size) || size <= 0 || size > 1 << 31 { return nil, false }
		out := make([]byte, int(size), context.temp_allocator)
		at := 0
		for at < len(out) {
			n: win.DWORD
			if !win.ReadFile(h, raw_data(out[at:]), win.DWORD(min(len(out) - at, 1 << 24)), &n, nil) || n == 0 { return nil, false }
			at += int(n)
		}
		return out, true
	}
	return nil, false
}

// The NT name of the file mapped at `address` in this process ("\Device\HarddiskVolume3\...": "" when it cannot say).
@(private = "file")
mapped_name :: proc(address: rawptr) -> string {
	buf: [1024]u16
	n := K32GetMappedFileNameW(win.GetCurrentProcess(), address, &buf[0], len(buf))
	if n == 0 || int(n) >= len(buf) { return "" }
	s, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	return err == nil ? s : ""
}
