package tk_process

import "core:os"
import win "core:sys/windows"

// Each end inheritable for the spawn; what each was before, for ends_restore.
@(private)
ends_inherit :: proc(ends: [3]^os.File) -> (before: [3]bool) {
	for f, i in ends {
		if f == nil { continue }
		h := win.HANDLE(os.fd(f))
		flags: win.DWORD
		before[i] = bool(win.GetHandleInformation(h, &flags)) && flags & win.HANDLE_FLAG_INHERIT != 0
		_ = win.SetHandleInformation(h, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT)
	}
	return
}

// Each end as it was before the spawn: the child has its own copy, no later child takes this one.
@(private)
ends_restore :: proc(ends: [3]^os.File, before: [3]bool) {
	for f, i in ends {
		if f == nil || before[i] { continue }
		_ = win.SetHandleInformation(win.HANDLE(os.fd(f)), win.HANDLE_FLAG_INHERIT, 0)
	}
}

@(private)
not_inherited :: proc(f: ^os.File) {
	_ = win.SetHandleInformation(win.HANDLE(os.fd(f)), win.HANDLE_FLAG_INHERIT, 0)
}

// Windows has no SIGPIPE: a write to a closed pipe is an error of that write.
@(private)
broken_pipe_ignore :: proc() {}
