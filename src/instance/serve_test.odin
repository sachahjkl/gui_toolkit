#+build linux, windows
package tk_instance

import "core:fmt"
import "core:sync"
import "core:testing"
import "core:time"

@(private = "file")
Got :: struct {
	mutex: sync.Mutex,
	text:  [64]u8,
	n:     int,
	count: int,
}

// A server on its own thread takes a second start's message with no loop of the caller's; once stopped, the name is free.
@(test)
a_server_takes_messages_on_its_thread :: proc(t: ^testing.T) {
	name := fmt.tprintf("tk.instance.serve.%d", time.to_unix_nanoseconds(time.now()))
	outcome, owner := acquire({name = name, wait_ms = 1000}, nil)
	testing.expect_value(t, outcome, Outcome.First)
	got: Got
	s := serve_start(owner, proc(user: rawptr, message: []byte) {
		g := (^Got)(user)
		sync.mutex_guard(&g.mutex)
		g.n = copy(g.text[:], message)
		g.count += 1
	}, &got)
	testing.expect(t, s != nil, "served")
	testing.expect_value(t, send({name = name, wait_ms = 2000}, transmute([]u8)string("open /tmp")), Outcome.Forwarded)
	{
		sync.mutex_guard(&got.mutex)
		testing.expect_value(t, got.count, 1)
		testing.expect_value(t, string(got.text[:got.n]), "open /tmp")
	}
	serve_stop(s)
	// the name is free again: a new start owns it
	again, o2 := acquire({name = name, wait_ms = 1000}, nil)
	testing.expect_value(t, again, Outcome.First)
	owner_stop(&o2)
}
