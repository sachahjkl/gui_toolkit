package tk_cdp

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:time"

// A screencast (Page.startScreencast): each frame the window sends is a PNG in `dir`, named frame-NNNNNN.png from 0, with its
// time (the frame's metadata, in seconds). A frame is acknowledged as it comes, or no other follows.
Screencast :: struct {
	dir:   string,
	names: [dynamic]string,
	times: [dynamic]f64,
}

// The frames go to `sc.dir` from now on, at most one each `every_ms` (0: each one drawn).
screencast_start :: proc(c: ^Client, sc: ^Screencast, every_ms := 0) -> bool {
	c.screencast = sc
	_, ok := call(c, "Page.startScreencast", fmt.tprintf(`{{"format":"png","minIntervalMs":%d}}`, every_ms))
	if !ok { c.screencast = nil }
	return ok
}

screencast_stop :: proc(c: ^Client) -> bool {
	_, ok := call(c, "Page.stopScreencast")
	c.screencast = nil
	return ok
}

screencast_destroy :: proc(sc: ^Screencast) {
	for n in sc.names { delete(n) }
	delete(sc.names)
	delete(sc.times)
}

// Handles what comes within `limit`, for a caller with nothing to ask: the frames of a screencast keep coming. !alive: the connection
// ended.
pump :: proc(c: ^Client, limit: time.Duration) -> (alive: bool) {
	wait := limit
	for {
		message, ok, timed_out := next_message(c, wait)
		if timed_out { return true }
		if !ok { return false }
		event(c, message)
		// (what already came is handled now; the next wait is short: the limit was for the first message)
		wait = PUMP_DRAIN
	}
}

// A pump's wait for the messages after its first.
@(private) PUMP_DRAIN :: time.Millisecond

@(private)
screencast_frame :: proc(c: ^Client, message: string) {
	v, err := json.parse_string(message, allocator = context.temp_allocator)
	if err != nil { return }
	o, _ := v.(json.Object)
	if str(o["method"]) != "Page.screencastFrame" { return }
	p, _ := o["params"].(json.Object)
	m, _ := p["metadata"].(json.Object)
	id, _ := integer(p["sessionId"])
	png, decode_err := base64.decode(str(p["data"]), allocator = context.temp_allocator)
	if decode_err != nil { return }
	name := fmt.aprintf("frame-%06d.png", len(c.screencast.names))
	if os.write_entire_file(fmt.tprintf("%s/%s", c.screencast.dir, name), png) != nil { delete(name); return }
	append(&c.screencast.names, name)
	append(&c.screencast.times, number(m["timestamp"]))
	send(c, "Page.screencastFrameAck", fmt.tprintf(`{{"sessionId":%d}}`, id))
}
