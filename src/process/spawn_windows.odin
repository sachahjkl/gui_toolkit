package tk_process

// Windows' spawn: our own CreateProcessW (process-trees.md, "Every start"). The name is resolved before (PATH and
// PATHEXT, never the current folder) and given as the application, so the system searches nothing; a .bat or .cmd
// script runs through cmd.exe with Rust's quoting (windows_command_line); the child gets no console window, and inherits
// only its three standard handles (PROC_THREAD_ATTRIBUTE_HANDLE_LIST).

import "core:os"
import "core:slice"
import "core:strings"
import win "core:sys/windows"
import "../ascii"

foreign import kernel32_spawn "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32_spawn {
	InitializeProcThreadAttributeList :: proc(list: rawptr, count: win.DWORD, flags: win.DWORD, size: ^win.SIZE_T) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc(list: rawptr, flags: win.DWORD, attribute: win.DWORD_PTR, value: rawptr, size: win.SIZE_T, previous: rawptr, return_size: ^win.SIZE_T) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc(list: rawptr) ---
}

@(private = "file") PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: 0x20002

@(private = "file")
STARTUPINFOEXW :: struct {
	StartupInfo:     win.STARTUPINFOW,
	lpAttributeList: rawptr,
}

// The file that runs `name`: PATH's absolute folders and PATHEXT's extensions, from the child's environment when
// `env` is given, else this process's. In temp memory.
@(private)
resolve :: proc(name: string, env: []string) -> (path: string, ok: bool) {
	path_env, pathext: string
	if env != nil {
		for e in env {
			if ascii.has_prefix_fold(e, "PATH=") { path_env = e[len("PATH="):] }
			if ascii.has_prefix_fold(e, "PATHEXT=") { pathext = e[len("PATHEXT="):] }
		}
	} else {
		path_env = os.get_env("PATH", context.temp_allocator)
		pathext = os.get_env("PATHEXT", context.temp_allocator)
	}
	return resolve_command(name, path_env, pathext, true, proc(p: string, _: rawptr) -> bool {
		attrs := win.GetFileAttributesW(win.utf8_to_wstring(p, context.temp_allocator))
		return attrs != win.INVALID_FILE_ATTRIBUTES && attrs & win.FILE_ATTRIBUTE_DIRECTORY == 0
	}, nil, context.temp_allocator)
}

@(private)
spawn :: proc(desc: os.Process_Desc, resolved: string) -> (p: os.Process, err: os.Error) {
	process, thread, pid := create_process(desc, resolved, false) or_return
	win.CloseHandle(thread)
	return {pid = int(pid), handle = uintptr(process)}, nil
}

// CreateProcessW for `desc`, run by the file `resolved`: no console window; suspended when asked (a tree assigns it
// to its job first). Called under start_lock, the ends made inheritable by the caller.
@(private)
create_process :: proc(desc: os.Process_Desc, resolved: string, suspended: bool) -> (process, thread: win.HANDLE, pid: win.DWORD, err: os.Error) {
	system: [win.MAX_PATH]u16
	n := win.GetSystemDirectoryW(raw_data(system[:]), win.MAX_PATH)
	system_dir, _ := win.utf16_to_utf8(system[:n], context.temp_allocator)
	cl, cerr := windows_command_line(resolved, desc.command, system_dir, context.temp_allocator)
	if cerr != .None { return nil, nil, 0, os.General_Error.Invalid_Command }

	env := desc.env
	if env == nil { env, _ = os.environ(context.temp_allocator) }
	block := environment_block(env)

	null: win.HANDLE
	if desc.stdin == nil || desc.stdout == nil || desc.stderr == nil {
		sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
		null = win.CreateFileW(win.L("NUL"), win.GENERIC_READ | win.GENERIC_WRITE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, &sa, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	}
	defer if null != nil && null != win.INVALID_HANDLE_VALUE { win.CloseHandle(null) }
	end :: proc(f: ^os.File, null: win.HANDLE) -> win.HANDLE { return f != nil ? win.HANDLE(os.fd(f)) : null }
	si := STARTUPINFOEXW{StartupInfo = {
		cb = size_of(STARTUPINFOEXW),
		dwFlags = win.STARTF_USESTDHANDLES,
		hStdInput = end(desc.stdin, null),
		hStdOutput = end(desc.stdout, null),
		hStdError = end(desc.stderr, null),
	}}
	flags := win.DWORD(win.CREATE_UNICODE_ENVIRONMENT | win.CREATE_NO_WINDOW | win.EXTENDED_STARTUPINFO_PRESENT)
	if suspended { flags |= win.CREATE_SUSPENDED }

	// (the child inherits these three handles and no other: without the list it takes every inheritable handle of
	// the program, a pipe end made by a library or a log file opened inheritable on purpose. Each once: a handle
	// listed twice is an invalid parameter)
	inherit: [3]win.HANDLE
	count := 0
	add: for h in ([3]win.HANDLE{si.StartupInfo.hStdInput, si.StartupInfo.hStdOutput, si.StartupInfo.hStdError}) {
		if h == nil || h == win.INVALID_HANDLE_VALUE { continue }
		for k in inherit[:count] { if k == h { continue add } }
		inherit[count] = h
		count += 1
	}
	if count > 0 {
		size: win.SIZE_T
		_ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
		list := make([]u8, size, context.temp_allocator)
		if !InitializeProcThreadAttributeList(raw_data(list), 1, 0, &size) {
			return nil, nil, 0, os.Platform_Error(win.GetLastError())
		}
		si.lpAttributeList = raw_data(list)
		if !UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &inherit[0], win.SIZE_T(count * size_of(win.HANDLE)), nil, nil) {
			e := win.GetLastError()
			DeleteProcThreadAttributeList(si.lpAttributeList)
			return nil, nil, 0, os.Platform_Error(e)
		}
	}
	defer if si.lpAttributeList != nil { DeleteProcThreadAttributeList(si.lpAttributeList) }
	dir: win.wstring
	if desc.working_dir != "" { dir = win.utf8_to_wstring(desc.working_dir, context.temp_allocator) }
	pi: win.PROCESS_INFORMATION
	app := win.utf8_to_wstring(cl.application, context.temp_allocator)
	line := win.utf8_to_wstring(cl.line, context.temp_allocator)
	// (count 0: nothing to inherit, and no list)
	if !win.CreateProcessW(app, line, nil, nil, count > 0, flags, raw_data(block), dir, &si.StartupInfo, &pi) {
		return nil, nil, 0, os.Platform_Error(win.GetLastError())
	}
	return pi.hProcess, pi.hThread, pi.dwProcessId, nil
}

// "NAME=value\0" for each variable, sorted by name without case as Windows wants it, then a last "\0". In temp memory.
@(private = "file")
environment_block :: proc(env: []string) -> []u16 {
	sorted := slice.clone(env, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: string) -> bool {
		an := a[:max(strings.index_byte(a, '='), 0)]
		bn := b[:max(strings.index_byte(b, '='), 0)]
		return ascii.compare_fold(an, bn) < 0
	})
	b := strings.builder_make(context.temp_allocator)
	for e in sorted {
		if e == "" || strings.index_byte(e, 0) >= 0 { continue }
		strings.write_string(&b, e)
		strings.write_byte(&b, 0)
	}
	strings.write_byte(&b, 0)
	if len(sorted) == 0 { strings.write_byte(&b, 0) }
	return win.utf8_to_utf16(strings.to_string(b), context.temp_allocator)
}
