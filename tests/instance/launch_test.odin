package instance_test

// A second start's launch (instance.Launch): the token and the words come back as they went, whatever bytes they hold;
// the toolkit's messages and broken bytes are no launch.

import "core:testing"
import inst "gt:instance"

@(test)
a_launch_comes_back_whole :: proc(t: ^testing.T) {
	words := []string{
		"/home/me/a\x00b.txt",            // the NUL byte, which a separator format would split on
		"/home/me/two\nlines.md",         // a newline
		"/home/me/Économie/日本語 ✓.pdf",  // Unicode, a space
		"",                                // an empty word stays a word
		"copy", "12",                      // a command's words
	}
	m := inst.launch_encode({token = "launcher:token-1", args = words})
	l, ok := inst.launch_decode(m)
	testing.expect(t, ok, "a launch")
	testing.expect_value(t, l.token, "launcher:token-1")
	if !testing.expect_value(t, len(l.args), len(words)) { return }
	for w, i in words { testing.expect_value(t, l.args[i], w) }

	none, ok_none := inst.launch_decode(inst.launch_encode({}))
	testing.expect(t, ok_none, "an empty launch is a launch")
	testing.expect_value(t, none.token, "")
	testing.expect_value(t, len(none.args), 0)
}

@(test)
what_is_no_launch_is_refused :: proc(t: ^testing.T) {
	_, ping := inst.launch_decode(transmute([]byte)string(inst.MESSAGE_PING))
	testing.expect(t, !ping, "a PING is no launch")
	_, quit := inst.launch_decode(transmute([]byte)string(inst.MESSAGE_QUIT))
	testing.expect(t, !quit, "a QUIT is no launch")
	_, empty := inst.launch_decode(nil)
	testing.expect(t, !empty, "no bytes")
	m := inst.launch_encode({token = "t", args = {"/a", "/b"}})
	for n in 1 ..< len(m) {
		_, cut := inst.launch_decode(m[:n])
		testing.expectf(t, !cut, "cut at %d of %d bytes", n, len(m))
	}
	more := make([]byte, len(m) + 1, context.temp_allocator)
	copy(more, m)
	more[len(m)] = 7
	_, extra := inst.launch_decode(more)
	testing.expect(t, !extra, "a byte after the last field")
}
