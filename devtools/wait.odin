package devtools

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "../platform"
import "../ui"

// Answers that wait for the interface: Toolkit.waitFor (a box there, or gone) and Toolkit.waitIdle (nothing moving). A
// script says what it waits for instead of sleeping a guess. Checked at each frame; while one waits, the ticker keeps
// the window waking, so a timeout comes on time in a program that is not drawing.

@(private)
Wait_Kind :: enum { Box, Idle }

@(private)
Wait :: struct {
	to:       Reply_To,    // (its session and the strings below are held: the server's heap)
	kind:     Wait_Kind,
	name:     string,
	text:     string,
	gone:     bool,
	first:    u64,         // the build from which an answer counts: input sent before the wait has been through it
	seen:     u64,         // the last build looked at (Idle)
	quiet:    int,         // builds in a row with nothing moving (Idle)
	deadline: time.Tick,
	timeout:  f64,
}

// What input sent just before needs: the press in the next build, a release the one after.
@(private)
WAIT_BUILDS :: 2
// Builds in a row without animation that make "idle": an app may react to a frame with one more frame.
@(private)
IDLE_BUILDS :: 3
@(private)
WAIT_DEFAULT_MS :: 5000.0

@(private)
wait_add :: proc(srv: ^Server, s: ^ui.State, to: Reply_To, kind: Wait_Kind, p: json.Object) {
	h := runtime.heap_allocator()
	ms := num(p["timeout"], WAIT_DEFAULT_MS)
	append(&srv.waits, Wait{
		to = hold(to), kind = kind,
		name = strings.clone(str(p["name"]), h), text = strings.clone(str(p["text"]), h), gone = bool_of(p["gone"]),
		first = s.build_index + WAIT_BUILDS, seen = s.build_index, timeout = ms,
		deadline = time.tick_add(time.tick_now(), time.Duration(ms * f64(time.Millisecond))),
	})
}

@(private)
wait_free :: proc(w: Wait) {
	h := runtime.heap_allocator()
	release(w.to)
	delete(w.name, h)
	delete(w.text, h)
}

// Each frame: answers the waits that are over. (The tree read is the last build's.)
@(private)
waits_poll :: proc(srv: ^Server, s: ^ui.State) {
	if len(srv.waits) == 0 { return }
	now := time.tick_now()
	#reverse for &w, i in srv.waits {
		over := false
		switch {
		case conn_gone(w.to.conn):
			over = true
		case w.kind == .Box:
			over = wait_box(srv, s, &w)
		case w.kind == .Idle:
			over = wait_idle(srv, s, &w)
		}
		if !over && time.tick_diff(now, w.deadline) <= 0 {
			over = true
			if w.kind == .Idle {
				reply(w.to, fmt.tprintf(`{{"idle":false,"build":%d}}`, s.build_index))   // (something moves for good: not an error)
			} else {
				error_reply(w.to, -32000, fmt.tprintf("waitFor: %s after %.0f ms", w.gone ? "still there" : "not there", w.timeout))
			}
		}
		if over {
			wait_free(w)
			ordered_remove(&srv.waits, i)
		}
	}
}

@(private)
wait_box :: proc(srv: ^Server, s: ^ui.State, w: ^Wait) -> bool {
	if s.build_index < w.first { return false }
	ms := matches_of(s, w.name, w.text)
	if w.gone {
		if len(ms) > 0 { return false }
		reply(w.to, `{"nodes":[]}`)
		return true
	}
	if len(ms) == 0 { return false }
	sb := strings.builder_make(context.temp_allocator)
	write_matches(&sb, srv, ms)
	reply(w.to, strings.to_string(sb))
	return true
}

@(private)
wait_idle :: proc(srv: ^Server, s: ^ui.State, w: ^Wait) -> bool {
	if s.build_index == w.seen { return false }
	w.seen = s.build_index
	if s.build_index < w.first { return false }
	w.quiet = ui.needs_frame(s) || len(srv.later) > 0 ? 0 : w.quiet + 1
	if w.quiet < IDLE_BUILDS { return false }
	reply(w.to, fmt.tprintf(`{{"idle":true,"build":%d}}`, s.build_index))
	return true
}

// Wakes the window while something waits (a program at rest draws nothing and would never look).
@(private)
ticker :: proc(srv: ^Server) {
	for !sync.atomic_load(&srv.stopping) {
		time.sleep(8 * time.Millisecond)
		if sync.atomic_load(&srv.waiting) > 0 { platform.wake(srv.win) }
	}
}
