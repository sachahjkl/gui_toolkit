package tk_rpc

import "core:encoding/json"
import "core:math/rand"
import "core:strings"
import "core:testing"

@(private = "file")
Seen :: struct {
	texts:  [dynamic]string,
	faults: [dynamic]Frame_Fault,
	sizes:  [dynamic]int,
}

@(private = "file")
collect :: proc(user: rawptr, message: []u8, fault: Frame_Fault, size: int) {
	s := (^Seen)(user)
	append(&s.texts, strings.clone(string(message), context.temp_allocator))
	append(&s.faults, fault)
	append(&s.sizes, size)
}

@(private = "file")
seen_make :: proc() -> Seen {
	return {make([dynamic]string, context.temp_allocator), make([dynamic]Frame_Fault, context.temp_allocator), make([dynamic]int, context.temp_allocator)}
}

// Fed in every split of the stream, the lines come out the same: a line split across reads, a \r\n, an empty line.
@(test)
lines_are_framed_whatever_the_reads :: proc(t: ^testing.T) {
	stream := "{\"a\":1}\n\r\n{\"b\":2}\r\n  \n{\"c\":3}"
	for cut in 0 ..= len(stream) {
		s := seen_make()
		f := framer_make(.Lines, 64, context.temp_allocator)
		framer_feed(&f, transmute([]u8)stream[:cut], collect, &s)
		framer_feed(&f, transmute([]u8)stream[cut:], collect, &s)
		framer_finish(&f, collect, &s)
		testing.expect_value(t, len(s.texts), 3)
		if len(s.texts) == 3 {
			testing.expect_value(t, s.texts[0], `{"a":1}`)
			testing.expect_value(t, s.texts[1], `{"b":2}`)
			testing.expect_value(t, s.texts[2], `{"c":3}`)
		}
	}
}

// A line beyond the maximum is counted and dropped, never held, and the next line still comes.
@(test)
a_line_too_long_is_dropped_and_the_next_comes :: proc(t: ^testing.T) {
	big := strings.repeat("x", 1000, context.temp_allocator)
	stream := strings.concatenate({"{}\n", big, "\n", "{\"next\":1}\n"}, context.temp_allocator)
	for step in ([]int{1, 7, 64, 2000}) {
		s := seen_make()
		f := framer_make(.Lines, 100, context.temp_allocator)
		for i := 0; i < len(stream); i += step {
			framer_feed(&f, transmute([]u8)stream[i:min(i + step, len(stream))], collect, &s)
			testing.expect(t, len(f.buf) <= 100, "never more than the maximum held")
		}
		framer_finish(&f, collect, &s)
		testing.expect_value(t, len(s.texts), 3)
		if len(s.texts) != 3 { continue }
		testing.expect_value(t, s.faults[1], Frame_Fault.Too_Long)
		testing.expect_value(t, s.sizes[1], 1000)
		testing.expect_value(t, s.texts[2], `{"next":1}`)
	}
}

// LSP's framing: headers in any case, other headers ignored, a body split anywhere, a body too long skipped by its
// length, a block without a length dropped.
@(test)
content_length_frames_whatever_the_reads :: proc(t: ^testing.T) {
	body1 := `{"jsonrpc":"2.0","method":"a"}`
	body2 := `{"x":"\r\n\r\n"}`
	stream := strings.concatenate({
		"Content-Length: 30\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n", body1,
		"content-length:20\r\n\r\n", strings.repeat("y", 20, context.temp_allocator),
		"X-Other: 1\r\n\r\n",
		"Content-Length: 16\r\n\r\n", body2,
	}, context.temp_allocator)
	for cut in 0 ..= len(stream) {
		s := seen_make()
		f := framer_make(.Content_Length, 19, context.temp_allocator)
		framer_feed(&f, transmute([]u8)stream[:cut], collect, &s)
		framer_feed(&f, transmute([]u8)stream[cut:], collect, &s)
		if !testing.expect_value(t, len(s.texts), 4) { return }
		testing.expect_value(t, s.faults[0], Frame_Fault.Too_Long)   // (30 bytes over 19)
		testing.expect_value(t, s.sizes[0], 30)
		testing.expect_value(t, s.faults[1], Frame_Fault.Too_Long)
		testing.expect_value(t, s.faults[2], Frame_Fault.No_Length)
		testing.expect_value(t, s.texts[3], body2)
	}
	// (the same with room for the first body: it comes whole)
	s := seen_make()
	f := framer_make(.Content_Length, 1024, context.temp_allocator)
	framer_feed(&f, transmute([]u8)stream, collect, &s)
	testing.expect_value(t, s.texts[0], body1)
}

// Random bytes in any framing: no panic, nothing held beyond the maximum, and every message parsed or refused as a value.
@(test)
random_bytes_never_panic :: proc(t: ^testing.T) {
	// (the runner seeds the generator of each test: its seed is in the log)
	ALPHABET :: "{}[]\":,0123456789.eE+-truefalsnul \\\n\r\tContent-Length: \x00\xff\xc3\xa9"
	for _ in 0 ..< 2000 {
		n := rand.int_max(300)
		data := make([]u8, n, context.temp_allocator)
		alphabet := ALPHABET
		for &b in data { b = alphabet[rand.int_max(len(alphabet))] }
		for framing in Framing {
			Check :: struct { t: ^testing.T }
			c := Check{t}
			f := framer_make(framing, 128, context.temp_allocator)
			framer_feed(&f, data, proc(user: rawptr, message: []u8, fault: Frame_Fault, size: int) {
				if fault != .None { return }
				if !depth_ok(message) { return }
				v, err := json.parse_string(string(message), .JSON, true, context.temp_allocator)
				if err == .None { _ = read_message(v) }
			}, &c)
			testing.expect(t, len(f.buf) <= HEADER_MAX + 128)
		}
		free_all(context.temp_allocator)
	}
}
