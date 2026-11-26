package tk_desktop

// The Task_Manager part on Windows (src/md/features/default-task-manager.md):
//
//   HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\taskmgr.exe
//       Debugger                  "<machine copy>": Windows starts it in place of taskmgr.exe (Ctrl+Shift+Esc, the
//                                 taskbar, Ctrl+Alt+Del), taskmgr's path and options after it
//       <registry_mark>           the AppUserModelID: the program wrote this key
//       <registry_mark>Previous   the Debugger there before, of its kind, which Off gives back
//   %ProgramFiles%\<vendor>\<name>\<exe>   the machine copy: only an administrator can write there, and it hands over
//                                         to the person's own install when it starts unelevated (setup.task_manager_start)
//
// The state is read without elevation. A change is made in a process that an administrator allowed: Install and
// Uninstall start `"<exe>" --task-manager on|off` with the verb runas, and only when a person asked
// (Integration_Options.ask_administrator). A test's roots (image_options_root under HKCU, machine_dir) are written here,
// in this process.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "../process"

@(private = "file")
IMAGE_OPTIONS_KEY :: `SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options`

// How long Install waits for the elevated process, in milliseconds: the person answers the consent prompt first.
@(private = "file")
TASK_MANAGER_WAIT_MS :: 10 * 60 * 1000

// (winerror.h: the person declined the consent prompt)
@(private = "file")
ERROR_CANCELLED :: 1223

// The value under Software\<vendor_key>\<key> (HKCU) that says this account put the part: only then does its Uninstall
// ask an administrator to give Task Manager back. Another account's part stays at its Uninstall.
@(private = "file")
TASK_MANAGER_SET_HERE :: "TaskManagerSetHere"

foreign import kernel32_task_manager "system:Kernel32.lib"

@(private = "file", default_calling_convention = "system")
foreign kernel32_task_manager {
	K32GetMappedFileNameW :: proc(process: win.HANDLE, address: rawptr, name: [^]u16, size: win.DWORD) -> win.DWORD ---
}

@(private = "file")
Task_Manager_Place :: struct {
	hive:     win.HKEY,
	key:      string,   // ...\Image File Execution Options\taskmgr.exe
	copy:     string,   // the machine copy
	previous: string,   // the name of the value that keeps the Debugger there before
}

@(private = "file")
task_manager_place :: proc(o: ^Integration_Options) -> (p: Task_Manager_Place, ok: bool) {
	if o.image_options_root != "" {
		p.hive, p.key = win.HKEY_CURRENT_USER, reg_join(o.image_options_root, "taskmgr.exe")
	} else {
		p.hive, p.key = win.HKEY_LOCAL_MACHINE, reg_join(IMAGE_OPTIONS_KEY, "taskmgr.exe")
	}
	p.copy = task_manager_copy(o)
	p.previous = strings.concatenate({o.identity.registry_mark, "Previous"}, context.temp_allocator)
	return p, p.copy != ""
}

// Where the machine copy of the program is: %ProgramFiles%\<vendor>\<name>, or <machine_dir> with a test's key
// (machine_copy_path), then the executable's name (temp memory; "" when Windows does not say where Program Files is).
task_manager_copy :: proc(o: ^Integration_Options) -> string {
	return machine_copy_path(o, o.image_options_root == "" ? known_folder(win.FOLDERID_ProgramFiles) : "")
}

@(private = "file")
image_options_read :: proc(o: ^Integration_Options, p: Task_Manager_Place) -> (k: Image_Options) {
	if v, expand, ok := reg_get_any(p.key, "Debugger", p.hive); ok { k.debugger = {v, expand, true} }
	if v, expand, ok := reg_get_any(p.key, p.previous, p.hive); ok { k.previous = {v, expand, true} }
	mark, _ := reg_get(p.key, o.identity.registry_mark, p.hive)
	k.marked = mark == identity_aumid(o.identity)
	return
}

// The Debugger runs the machine copy (a REG_EXPAND_SZ one is never the program's: it writes REG_SZ).
@(private = "file")
debugger_runs_copy :: proc(k: Image_Options, p: Task_Manager_Place) -> bool {
	return k.debugger.present && !k.debugger.expand && same_path(command_program(k.debugger.value), p.copy)
}

// The part: present when the key is the program's (its mark) or its Debugger runs the machine copy; stale when the
// Debugger runs something else (another program took it since); partial when the machine copy is not there.
@(private)
task_manager_status :: proc(o: ^Integration_Options, allocator: runtime.Allocator) -> (ps: Part_Status) {
	p, ok := task_manager_place(o)
	if !ok { return }
	k := image_options_read(o, p)
	runs := debugger_runs_copy(k, p)
	if !(k.marked || runs) { return }
	ps.present = true
	ps.target = clone_or_empty(command_program(k.debugger.value), allocator)
	ps.stale = !runs
	ps.partial = runs && !os.is_file(p.copy)
	return
}

// Install (`on`) or Uninstall (`removing`): the part as the options want it. Install with the part off takes it away
// only when the Debugger runs the program; Uninstall also takes the marks and the machine copy. A change of the
// machine is asked of an administrator only when a person asked for this install (ask_administrator); else the part
// stays as it is.
@(private)
task_manager_apply :: proc(o: ^Integration_Options, on, removing: bool) -> Result {
	p, ok := task_manager_place(o)
	if !ok { return {.Machine, "the Program Files folder is unknown"} }
	k := image_options_read(o, p)
	runs := debugger_runs_copy(k, p)
	need: bool
	switch {
	case on:       need = !runs || !k.marked || !os.is_file(p.copy)
	// (an Uninstall gives Task Manager back only when this account put the part: another account's stays, and no
	// administrator is asked for it)
	case removing: need = (k.marked || runs || os.is_file(p.copy)) && set_here(o)
	case:          need = runs   // (the box unticked: a person's explicit request, whoever put the part)
	}
	if !need {
		if removing { set_here_forget(o) }
		return {}
	}
	r: Result
	if o.image_options_root != "" {
		r = task_manager_write(o, on)   // (a test's key under HKCU: no administrator)
	} else if !o.ask_administrator {
		return {}
	} else {
		r = task_manager_elevated(o, on, p)
	}
	if r.error == .None {
		if on { set_here_remember(o) } else { set_here_forget(o) }
	}
	return r
}

// The record of this account in HKCU (TASK_MANAGER_SET_HERE), under the program's own key.
@(private = "file")
set_here_key :: proc(o: ^Integration_Options) -> string { return reg_join(registry_root_of(o), o.identity.vendor_key, o.identity.key) }

@(private = "file")
set_here :: proc(o: ^Integration_Options) -> bool {
	v, ok := reg_get(set_here_key(o), TASK_MANAGER_SET_HERE)
	return ok && v == "1"
}

@(private = "file")
set_here_remember :: proc(o: ^Integration_Options) { _ = reg_set(set_here_key(o), TASK_MANAGER_SET_HERE, "1") }

@(private = "file")
set_here_forget :: proc(o: ^Integration_Options) { _ = reg_delete_value(set_here_key(o), TASK_MANAGER_SET_HERE) }

// Starts `"<exe>" --task-manager on|off` as an administrator (Windows asks the person) and waits for it.
@(private = "file")
task_manager_elevated :: proc(o: ^Integration_Options, on: bool, p: Task_Manager_Place) -> Result {
	// Off: the machine copy, which only an administrator wrote, so the consent prompt names a file of Program Files and
	// no code that the user can write runs elevated. On: the installed copy (a broken install without it: this program;
	// any copy of it does the same), which the administrator then trusts to become the machine copy.
	exe := os.is_file(o.exe) ? o.exe : process.executable_path()
	if !on && os.is_file(p.copy) { exe = p.copy }
	params := strings.concatenate({TASK_MANAGER_FLAG, on ? " on" : " off"}, context.temp_allocator)
	info := win.SHELLEXECUTEINFOW{
		cbSize = size_of(win.SHELLEXECUTEINFOW),
		fMask = win.SEE_MASK_NOCLOSEPROCESS | win.SEE_MASK_NOASYNC | win.SEE_MASK_FLAG_NO_UI,
		hwnd = win.GetForegroundWindow(),   // (the consent prompt comes over the window the person clicked in)
		lpVerb = win.L("runas"),
		lpFile = wide(exe),
		lpParameters = wide(params),
		lpDirectory = wide(process.parent_dir(exe)),
		nShow = win.SW_HIDE,
	}
	if !win.ShellExecuteExW(&info) {
		if win.GetLastError() == ERROR_CANCELLED { return {.Not_Allowed, error_text(.Not_Allowed)} }
		return {.Machine, fmt.tprintf("the change of Task Manager could not start (error %d)", win.GetLastError())}
	}
	if info.hProcess == nil { return {.Machine, "the change of Task Manager gave no process"} }
	defer win.CloseHandle(info.hProcess)
	if win.WaitForSingleObject(info.hProcess, TASK_MANAGER_WAIT_MS) != win.WAIT_OBJECT_0 { return {.Machine, "the change of Task Manager did not end"} }
	code: win.DWORD
	if !win.GetExitCodeProcess(info.hProcess, &code) || code != 0 { return {.Machine, fmt.tprintf("the change of Task Manager failed (exit code %d)", code)} }
	// (what the system has now, not what the process said)
	k := image_options_read(o, p)
	runs := debugger_runs_copy(k, p)
	if on && !(runs && os.is_file(p.copy)) { return {.Machine, "Task Manager does not run the program after the change"} }
	if !on && runs { return {.Machine, "Task Manager still runs the program after the change"} }
	return {}
}

// The change itself, in the process that an administrator allowed (`--task-manager on|off`, setup.command_run), or in
// a test's roots. On: the machine copy written from o.exe, the Debugger set to it, the one there before kept. Off: that
// one given back, the marks and the machine copy taken away.
task_manager_write :: proc(o: ^Integration_Options, on: bool) -> Result {
	if e := validate(o, need_exe = on); e.error != .None { return e }
	p, ok := task_manager_place(o)
	if !ok { return {.System, "the Program Files folder is unknown"} }
	k := image_options_read(o, p)
	runs := debugger_runs_copy(k, p)
	if on {
		// The machine copy is the image of this very process, which the administrator allowed: a copy by path would
		// read whatever a user put at that path once the consent was given (the running file can be renamed, and
		// another dropped in its place). A test's roots copy o.exe, a file that stands for the program.
		r := o.image_options_root != "" ? machine_copy_write(o.exe, p.copy) : image_copy_self(p.copy)
		if r.error != .None { return r }
		return image_options_write(o, p, image_options_on(k, task_manager_debugger(p.copy), runs))
	}
	res := image_options_write(o, p, image_options_off(k, runs))
	if r := machine_copy_remove(o, p.copy); r.error != .None && res.error == .None { res = r }
	return res
}

// Writes what the key holds after a change. The order keeps the Debugger there before in one value or the other at
// each step: the kept one is written before the Debugger changes, and deleted after it is given back.
@(private = "file")
image_options_write :: proc(o: ^Integration_Options, p: Task_Manager_Place, after: Image_Options) -> Result {
	failed :: proc(p: Task_Manager_Place) -> Result { return {.System, strings.concatenate({"cannot write ", p.key}, context.temp_allocator)} }
	put :: proc(p: Task_Manager_Place, name: string, v: Registry_String) -> bool {
		if v.present { return reg_set_kind(p.key, name, v.value, v.expand, p.hive) }
		return reg_delete_value(p.key, name, p.hive)
	}
	if after.previous.present && !put(p, p.previous, after.previous) { return failed(p) }
	if !put(p, "Debugger", after.debugger) { return failed(p) }
	mark := o.identity.registry_mark
	if after.marked {
		if !reg_set(p.key, mark, identity_aumid(o.identity), p.hive) { return failed(p) }
	} else if !reg_delete_value(p.key, mark, p.hive) { return failed(p) }
	if !after.previous.present && !put(p, p.previous, after.previous) { return failed(p) }
	if !after.debugger.present && !after.marked { _ = reg_delete_if_empty(p.key, p.hive) }
	return {}
}

// The machine copy made from `src`. A copy that runs (another account's Task Manager) cannot be written over: it is
// put aside, deleted at the next restart, and the copy made again. CopyFileW gives the new file the folder's rights
// (Program Files': only an administrator writes), not the source's.
@(private = "file")
machine_copy_write :: proc(src, dst: string) -> Result {
	if same_path(src, dst) { return {} }
	if !ensure_dir(process.parent_dir(dst)) { return {.Io, strings.concatenate({"cannot create ", process.parent_dir(dst)}, context.temp_allocator)} }
	if files_alike(src, dst) { return {} }
	if win.CopyFileW(wide(src), wide(dst), false) { return {} }
	if !put_aside(dst) { return {.Io, strings.concatenate({"cannot replace ", dst}, context.temp_allocator)} }
	if !win.CopyFileW(wide(src), wide(dst), false) { return {.Io, strings.concatenate({"cannot write ", dst}, context.temp_allocator)} }
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

// The same size and the same time of the last write: CopyFileW keeps the time, so a copy of this file.
@(private = "file")
files_alike :: proc(a, b: string) -> bool {
	fa, ea := os.stat(a, context.temp_allocator)
	fb, eb := os.stat(b, context.temp_allocator)
	return ea == nil && eb == nil && fa.size == fb.size && fa.modification_time == fb.modification_time
}

// Deletes the machine copy (at the next restart when it runs), then its folder and the vendor's when they are empty
// (Program Files' own; a test's machine_dir is the test's).
@(private = "file")
machine_copy_remove :: proc(o: ^Integration_Options, copy: string) -> Result {
	if os.is_file(copy) && os.remove(copy) != nil {
		if !put_aside(copy) { return {.Io, strings.concatenate({"cannot delete ", copy}, context.temp_allocator)} }
		return {}
	}
	if o.machine_dir == "" {
		dir := process.parent_dir(copy)
		if os.remove(dir) == nil && o.identity.vendor != "" { _ = os.remove(process.parent_dir(dir)) }
	}
	return {}
}
