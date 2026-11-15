#+build !windows
#+build !linux
package tk_desktop

// No watcher here yet: the caller's periodic check stays.
watch_system_start :: proc(o: ^Integration_Options, wake: Watch_Proc, user: rawptr) -> ^Watcher { return nil }
watch_system_stop :: proc(w: ^Watcher) {}
