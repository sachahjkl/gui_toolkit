#+build !windows
#+build !linux
package tk_instance

import "core:sync"

// No messages come here (instance_other.odin): the thread waits for serve_stop alone.
@(private)
Wake :: struct { sema: sync.Sema }

@(private)
wake_make :: proc(w: ^Wake) -> bool { return true }

@(private)
wake_ring :: proc(w: ^Wake) { sync.sema_post(&w.sema) }

@(private)
wake_free :: proc(w: ^Wake) {}

@(private)
serve_wait :: proc(s: ^Server) { sync.sema_wait(&s.wake.sema) }
