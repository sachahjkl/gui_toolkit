package tk_instance

// An Owner served on a thread of its own: for a program whose loop sleeps until its window has an event, and so never
// calls pump_messages in time. The thread starts the Owner (owner_start: its window or socket is that thread's), wakes
// when a message comes, runs the handler there, and ends the Owner when serve_stop asks. The handler runs on that thread,
// not the interface's: it copies the message and hands it over (ui.post).

import "core:sync"
import "core:thread"

Server :: struct {
	owner:   Owner,
	handler: Handler,
	user:    rawptr,
	thread:  ^thread.Thread,
	stop:    bool,         // atomic
	started: sync.Sema,    // posted once owner_start has run (`ok` says how it went)
	ok:      bool,
	wake:    Wake,         // what serve_stop rings
}

// Serves `owner` (as acquire gave it, First) on a new thread. nil, the Owner stopped, when it cannot be served.
serve_start :: proc(owner: Owner, handler: Handler, user: rawptr, allocator := context.allocator) -> ^Server {
	s := new(Server, allocator)
	s.owner, s.handler, s.user = owner, handler, user
	if !wake_make(&s.wake) {
		o := s.owner
		owner_stop(&o)
		free(s, allocator)
		return nil
	}
	s.thread = thread.create_and_start_with_data(s, serve_main)
	sync.sema_wait(&s.started)
	if !s.ok {
		thread.join(s.thread)
		thread.destroy(s.thread)
		wake_free(&s.wake)
		free(s, allocator)
		return nil
	}
	return s
}

// Ends the Owner (the name is free when this returns) and the thread.
serve_stop :: proc(s: ^Server, allocator := context.allocator) {
	if s == nil { return }
	sync.atomic_store(&s.stop, true)
	wake_ring(&s.wake)
	thread.join(s.thread)
	thread.destroy(s.thread)
	wake_free(&s.wake)
	free(s, allocator)
}

@(private = "file")
serve_main :: proc(data: rawptr) {
	s := (^Server)(data)
	s.ok = owner_start(&s.owner, s.handler, s.user)
	sync.sema_post(&s.started)
	if !s.ok {
		owner_stop(&s.owner)
		return
	}
	for !sync.atomic_load(&s.stop) {
		serve_wait(s)
		pump_messages()
		free_all(context.temp_allocator)
	}
	owner_stop(&s.owner)
}
