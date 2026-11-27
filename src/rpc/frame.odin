#+private
package tk_rpc

// The framing of the messages on a byte stream, as a pure state machine fed with what a read gives (rpc.md, "The
// framing"). Lines: a message per line, '\n' its end, a '\r' before it dropped, an empty line skipped.
// Content_Length: a header block ended by an empty line, then the body of the length it says. A message beyond the
// maximum is never held: its bytes are counted and thrown away up to its end.

import "core:bytes"
import "core:strconv"
import "core:strings"
import "../ascii"

// The bytes of a header block (Content_Length) at most: past them the stream is not LSP's.
HEADER_MAX :: 8 * 1024
// A buffer kept between messages at most: a larger one, grown for a large message, is given back after it.
@(private = "file") KEEP_BUFFER_BYTES :: 64 * 1024

// What went wrong with a frame.
Frame_Fault :: enum u8 {
	None,
	Too_Long,    // beyond the maximum: `size` says its length, the message is empty
	No_Length,   // a header block without a valid Content-Length (or beyond HEADER_MAX): the block is dropped
}

// Called for each message found, in the order of the stream. `message` is valid during the call only.
Frame_Proc :: #type proc(user: rawptr, message: []u8, fault: Frame_Fault, size: int)

Framer :: struct {
	framing:   Framing,
	max:       int,          // a message's bytes at most
	buf:       [dynamic]u8,  // the line, the headers or the body in progress
	skipping:  bool,         // a message beyond max is being thrown away
	skipped:   int,          // its bytes so far
	in_body:   bool,         // Content_Length: past the headers
	body_left: int,          // Content_Length: the body's bytes still to come
	body_len:  int,
}

framer_make :: proc(framing: Framing, max: int, allocator := context.allocator) -> Framer {
	return Framer{framing = framing, max = max, buf = make([dynamic]u8, allocator)}
}

framer_destroy :: proc(f: ^Framer) {
	delete(f.buf)
	f^ = {}
}

// Feeds what a read gave; `emit` gets each message completed in it.
framer_feed :: proc(f: ^Framer, data: []u8, emit: Frame_Proc, user: rawptr) {
	switch f.framing {
	case .Lines:          feed_lines(f, data, emit, user)
	case .Content_Length: feed_headed(f, data, emit, user)
	}
}

// The end of the stream: a last line without its '\n' is a message; a header block or a body cut short is dropped.
framer_finish :: proc(f: ^Framer, emit: Frame_Proc, user: rawptr) {
	if f.framing == .Lines {
		if f.skipping {
			emit(user, nil, .Too_Long, f.skipped)
		} else {
			line := trim_line(f.buf[:])
			if len(line) > 0 { emit(user, line, .None, len(line)) }
		}
	}
	clear(&f.buf)
	f.skipping, f.skipped, f.in_body, f.body_left = false, 0, false, 0
}

@(private = "file")
trim_line :: proc(line: []u8) -> []u8 {
	l := line
	if len(l) > 0 && l[len(l) - 1] == '\r' { l = l[:len(l) - 1] }
	// (a line of whitespace alone holds no message)
	for b in l { if b != ' ' && b != '\t' && b != '\r' { return l } }
	return nil
}

@(private = "file")
feed_lines :: proc(f: ^Framer, data: []u8, emit: Frame_Proc, user: rawptr) {
	rest := data
	for len(rest) > 0 {
		end := bytes.index_byte(rest, '\n')
		if f.skipping {
			if end < 0 { f.skipped += len(rest); return }
			emit(user, nil, .Too_Long, f.skipped + end)
			f.skipping, f.skipped = false, 0
			rest = rest[end + 1:]
			continue
		}
		if end < 0 {
			if len(f.buf) + len(rest) > f.max {
				f.skipping, f.skipped = true, len(f.buf) + len(rest)
				buffer_release(f)
				return
			}
			append(&f.buf, ..rest)
			return
		}
		size := len(f.buf) + end
		if size > f.max {
			emit(user, nil, .Too_Long, size)
		} else if len(f.buf) == 0 {
			// (the whole line is in this read: no copy)
			if line := trim_line(rest[:end]); len(line) > 0 { emit(user, line, .None, len(line)) }
		} else {
			append(&f.buf, ..rest[:end])
			if line := trim_line(f.buf[:]); len(line) > 0 { emit(user, line, .None, len(line)) }
		}
		buffer_release(f)
		rest = rest[end + 1:]
	}
}

// Empties the buffer; one grown for a large message gives its memory back.
@(private = "file")
buffer_release :: proc(f: ^Framer) {
	if cap(f.buf) > KEEP_BUFFER_BYTES {
		allocator := f.buf.allocator
		delete(f.buf)
		f.buf = make([dynamic]u8, allocator)
	} else {
		clear(&f.buf)
	}
}

@(private = "file")
feed_headed :: proc(f: ^Framer, data: []u8, emit: Frame_Proc, user: rawptr) {
	rest := data
	for len(rest) > 0 {
		if f.in_body {
			take := min(f.body_left, len(rest))
			if !f.skipping { append(&f.buf, ..rest[:take]) }
			f.body_left -= take
			rest = rest[take:]
			if f.body_left > 0 { return }
			if f.skipping {
				emit(user, nil, .Too_Long, f.body_len)
			} else {
				emit(user, f.buf[:], .None, len(f.buf))
			}
			f.in_body, f.skipping = false, false
			buffer_release(f)
			continue
		}
		// the headers, up to the empty line (CRLF CRLF; LF LF from a lenient writer)
		before := len(f.buf)
		append(&f.buf, ..rest)
		end, mark := headers_end(f.buf[:], max(0, before - 3))
		if end < 0 {
			if len(f.buf) > HEADER_MAX {
				emit(user, nil, .No_Length, len(f.buf))
				buffer_release(f)
			}
			return
		}
		used := end + mark - before   // (the bytes of this read that the headers took)
		length, ok := content_length(string(f.buf[:end]))
		rest = rest[used:]
		clear(&f.buf)
		if !ok {
			emit(user, nil, .No_Length, end)
			continue
		}
		f.in_body, f.body_len, f.body_left = true, length, length
		f.skipping = length > f.max
		if length == 0 {
			// (an empty body holds no message, and no read will come for it)
			f.in_body, f.skipping = false, false
		}
	}
}

// Where the header block ends (the index of its blank line) and the length of that blank line's mark; -1 if not yet.
@(private = "file")
headers_end :: proc(b: []u8, from: int) -> (end: int, mark: int) {
	for i in from ..< len(b) {
		if b[i] != '\n' { continue }
		if i >= 3 && b[i - 1] == '\r' && b[i - 2] == '\n' && b[i - 3] == '\r' { return i - 3, 4 }
		if i >= 1 && b[i - 1] == '\n' { return i - 1, 2 }
	}
	return -1, 0
}

// The Content-Length of a header block (its name in any case).
@(private = "file")
content_length :: proc(block: string) -> (n: int, ok: bool) {
	rest := block
	for line in strings.split_lines_iterator(&rest) {
		colon := strings.index_byte(line, ':')
		if colon < 0 { continue }
		if !ascii.equal_fold(strings.trim_space(line[:colon]), "Content-Length") { continue }
		v, parsed := strconv.parse_int(strings.trim_space(line[colon + 1:]), 10)
		if !parsed || v < 0 { return }
		return v, true
	}
	return
}
