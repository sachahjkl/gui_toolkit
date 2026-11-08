package devtools

import "base:runtime"
import "core:strings"
import "core:testing"
import "../render"

// A frame still with its encoder when its cast ended: what it finds is no news of the cast that took its place.
@(test)
a_frame_of_a_cast_that_ended_says_nothing :: proc(t: ^testing.T) {
	OLD :: 1
	CURRENT :: 2
	srv := new(Server)
	defer free(srv)
	srv.casts, srv.cast_session = CURRENT, CURRENT
	srv.screencast.phase = .Sent
	srv.cast_hash = 1234
	h := runtime.heap_allocator()
	raw := render.Capture_Raw{size = {1, 1}, pixels = make([]u8, 4, h)}
	srv.encoding = 1
	encode_run(new_clone(Encode_Job{srv = srv, raw = raw, frame = true, session = OLD, meta = strings.clone("", h)}, h))
	testing.expect_value(t, srv.cast_same, u64(0))
	testing.expect_value(t, srv.cast_hash, u64(1234))
	testing.expect_value(t, srv.screencast.phase, Cast_Phase.Sent)
	testing.expect_value(t, srv.encoding, 0)
}

// A ';' ends a declaration, unless it is in parentheses, a string or a comment.
@(test)
a_declaration_ends_at_its_own_semicolon :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, text: string, values: ..string) {
		props := css_parse(text)
		if !testing.expectf(t, len(props) == len(values), "%s: %d properties", text, len(props)) { return }
		for v, i in values { testing.expect_value(t, props[i].value, v) }
	}
	check(t, `a: b; c: d`, "b", "d")
	check(t, `a: url(x;y); c: d`, "url(x;y)", "d")
	check(t, `content: "x;y"; c: d`, `"x;y"`, "d")
	check(t, `content: 'it\'s;'; c: d`, `'it\'s;'`, "d")
	check(t, `a: b /* x;y */ e; c: d`, "b /* x;y */ e", "d")
	check(t, `a: b; /* c: d; */ e: f`, "b", "d", "f")
	check(t, `content: "cut \`, `"cut \`)
	check(t, `a: b /* cut`, "b /* cut")
}
