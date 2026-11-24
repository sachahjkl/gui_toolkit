package tk_host

// A program's single instance served for its window (src/md/features/second-start.md): a PING answered, a QUIT and each
// second start's launch handed to the window's thread, the window raised with the launch's token.
//
//	outcome, owner := instance.acquire(options, instance.launch_encode({token = token, args = paths}))
//	if outcome == .Forwarded { return }
//	...the window is open...
//	if outcome == .First { host.instance_serve(&app.service, &app.main, owner, app_launch) }
//	...the loop...
//	host.instance_serve_stop(&app.service)   // before host_close
//
// The service is the caller's memory: a call posted to the window points to it, so it must live as long as the State.

import "base:runtime"
import "core:slice"
import "core:sync"
import instance "../instance"
import "../platform"
import "../ui"

// A launch, on the window's thread; its strings are valid only during the call. true: the window comes to the front
// with the launch's token.
On_Launch :: #type proc(h: ^Host, l: instance.Launch) -> (raise: bool)
// A QUIT (an installer's --quit), on the window's thread.
On_Quit :: #type proc(h: ^Host)

Instance_Service :: struct {
	host:      ^Host,
	on_launch: On_Launch,
	on_quit:   On_Quit,
	server:    ^instance.Server,
	lock:      sync.Mutex,
	launches:  [dynamic][]byte,   // (under lock) the messages not yet handed over, in the heap
	quit:      bool,              // (under lock) a QUIT came
	serving:   bool,              // (the window's thread) between instance_serve and instance_serve_stop
}

// Serves `owner` (acquire's, First) on a thread of its own for the window `h`. on_launch nil: each launch only raises
// the window. on_quit nil: the window closes as its title bar's close does (platform.request_close). false: it could not
// be served (the Owner is stopped).
instance_serve :: proc(s: ^Instance_Service, h: ^Host, owner: instance.Owner, on_launch: On_Launch, on_quit: On_Quit = nil) -> bool {
	s^ = {host = h, on_launch = on_launch, on_quit = on_quit, serving = true}
	s.launches = make([dynamic][]byte, runtime.heap_allocator())
	s.server = instance.serve_start(owner, service_message, s, runtime.heap_allocator())
	if s.server == nil {
		delete(s.launches)
		s.launches = nil
		s.serving = false
		return false
	}
	return true
}

// Ends the Owner (the name is free when this returns) and drops what was not handed over. On the window's thread,
// before host_close.
instance_serve_stop :: proc(s: ^Instance_Service) {
	if !s.serving { return }
	instance.serve_stop(s.server, runtime.heap_allocator())
	s.server = nil
	s.serving = false
	sync.mutex_guard(&s.lock)
	for m in s.launches { delete(m, runtime.heap_allocator()) }
	delete(s.launches)
	s.launches = nil
	s.quit = false
}

// (the instance's thread) The message is valid only during the call: a launch is copied into the queue.
@(private = "file")
service_message :: proc(user: rawptr, message: []byte) {
	s := (^Instance_Service)(user)
	switch string(message) {
	case instance.MESSAGE_PING:
		return
	case instance.MESSAGE_QUIT:
		sync.mutex_guard(&s.lock)
		s.quit = true
	case:
		if _, ok := instance.launch_decode(message); !ok { return }
		sync.mutex_guard(&s.lock)
		append(&s.launches, slice.clone(message, runtime.heap_allocator()))
	}
	// (a post that fails, the window closing, loses nothing: the queue keeps it until instance_serve_stop)
	_ = ui.post(&s.host.state, service_run, s)
}

// (the window's thread) What came, in its order, then the quit.
@(private = "file")
service_run :: proc(data: rawptr, _: u64) {
	s := (^Instance_Service)(data)
	if !s.serving { return }   // (posted before the stop, run after it)
	sync.mutex_lock(&s.lock)
	pending := s.launches
	s.launches = make([dynamic][]byte, runtime.heap_allocator())
	quit := s.quit
	s.quit = false
	sync.mutex_unlock(&s.lock)
	h := s.host
	for m in pending {
		if l, ok := instance.launch_decode(m, context.temp_allocator); ok && (s.on_launch == nil || s.on_launch(h, l)) {
			platform.raise_window_token(h.win, l.token)
			host_settle(h)
		}
		delete(m, runtime.heap_allocator())
	}
	delete(pending)
	if quit {
		if s.on_quit != nil { s.on_quit(h) } else { platform.request_close(h.win) }
	}
}
