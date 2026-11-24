#+build !windows
#+build !linux
package fsx

// Another system (macOS first): no watcher yet (FSEvents or kqueue). watch_open fails, as it does when the system
// refuses one: the program then starts no waiting thread, and a folder is read again when the person asks.

@(private)
Watch_Native :: struct {}

@(private)
watch_open_native :: proc(w: ^Watch) -> bool { return false }

@(private)
watch_close_native :: proc(w: ^Watch) {}

@(private)
watch_wake_native :: proc(w: ^Watch) {}

// Never opened: no thread waits here. Says closed, so that a caller that waits anyway ends.
watch_wait :: proc(w: ^Watch, allocator := context.temp_allocator) -> (changed: []string, closed: bool) { return nil, true }
