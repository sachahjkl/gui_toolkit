// Package crashsite names where a test crashed (src/md/infrastructure/test-crash-site.md): on Linux, a handler chained
// after the test runner's writes the signal, the instruction's module and offset and its nearest symbol to stderr.
// Elsewhere arm does nothing (Windows: gt:testkit/unwatched names the module and offset).
package crashsite

// One line of the report, from its parts. Pure: the handler and the test share it. `buf` is filled from its start; the
// line's length is returned (cut at the buffer's end).
Site :: struct {
	signal:   string,    // "SIGSEGV"
	pc:       uintptr,   // the faulting instruction
	memory:   bool,      // a memory fault (SIGSEGV, SIGBUS): `fault` is the address it touched, 0 a nil pointer
	fault:    uintptr,
	module:   string,    // the instruction's file ("": unknown)
	base:     uintptr,   // where it is loaded
	symbol:   string,    // the nearest symbol ("": none)
	sym_addr: uintptr,
	trap:     bool,      // a ud2: an assertion, a bounds check or fail_now
	again:    bool,      // the same thread faulted again at the same instruction: ended by the signal now
}

format :: proc "contextless" (buf: []u8, s: Site) -> int {
	n := 0
	put :: proc "contextless" (buf: []u8, n: ^int, s: string) {
		for i in 0 ..< len(s) {
			if n^ >= len(buf) { return }
			buf[n^] = s[i]
			n^ += 1
		}
	}
	hex :: proc "contextless" (buf: []u8, n: ^int, v: uintptr) {
		digits := "0123456789abcdef"
		tmp: [16]u8
		k := 0
		x := v
		for {
			tmp[k] = digits[x & 0xf]
			k += 1
			x >>= 4
			if x == 0 { break }
		}
		put(buf, n, "0x")
		for k > 0 {
			k -= 1
			if n^ >= len(buf) { return }
			buf[n^] = tmp[k]
			n^ += 1
		}
	}
	put(buf, &n, "crash site: ")
	put(buf, &n, s.signal)
	if s.memory { put(buf, &n, " touching "); hex(buf, &n, s.fault) }
	put(buf, &n, " at ")
	if s.module != "" {
		put(buf, &n, s.module)
		put(buf, &n, "+")
		hex(buf, &n, s.pc - s.base)
	} else {
		hex(buf, &n, s.pc)
	}
	if s.symbol != "" {
		put(buf, &n, " (")
		put(buf, &n, s.symbol)
		put(buf, &n, "+")
		hex(buf, &n, s.pc - s.sym_addr)
		put(buf, &n, ")")
	}
	if s.trap { put(buf, &n, ": a trap (an assertion, a bounds check or fail_now: its message is above)") }
	if s.again { put(buf, &n, ": again on a thread the runner does not stop, the process ends") }
	put(buf, &n, "\n")
	return n
}
