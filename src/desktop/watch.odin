package tk_desktop

// Watching the places an integration lives: the system tells the program when one of them changes, so that what shows
// the state reads it at that moment instead of on a timer. `wake` runs on the watcher's own thread (named
// `Identity.watch_thread_name`, with the default context) and must only flag and wake the program's loop (never touch
// the integration itself).
//
// The platform files implement it: on Windows, the registry subtree the keys live in (RegNotifyChangeKeyValue) and the
// Start menu's Programs folder (FindFirstChangeNotificationW), on one named thread; on Linux, inotify. A platform with no watcher returns
// nil from watch_start: the caller keeps a periodic check.

Watch_Proc :: proc(user: rawptr)

Watcher :: struct {
	user: rawptr,
	wake: Watch_Proc,
	impl: rawptr,   // the platform's own state (watch_windows.odin)
}

// Starts watching what `o` names. Nil when nothing could be watched (the platform has no watcher, a place could not be
// opened): the caller's periodic check stays.
watch_start :: proc(o: ^Options, wake: Watch_Proc, user: rawptr) -> ^Watcher {
	when ODIN_OS == .Windows { return watch_start_windows(o, wake, user) }
	else when ODIN_OS == .Linux { return watch_start_linux(o, wake, user) }
	else { return nil }
}

watch_stop :: proc(w: ^Watcher) {
	if w == nil { return }
	when ODIN_OS == .Windows { watch_stop_windows(w) }
	else when ODIN_OS == .Linux { watch_stop_linux(w) }
	free(w)
}

// The watcher thread's name, nil when the identity gives none.
@(private)
thread_name :: proc(o: ^Options) -> Maybe(string) {
	if o.identity.watch_thread_name == "" { return nil }
	return o.identity.watch_thread_name
}
