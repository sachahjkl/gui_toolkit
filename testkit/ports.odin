// Package testkit: reusable building blocks for an application's own tests — the parts that are pure Odin and not tied to
// any one application. Today: a block of test-server ports (so several worktrees test side by side without clashing) and a
// reader of the process's memory and handle counts (for endurance and leak tests). Pure of any product name; an
// application passes in its own environment variable and defaults.
//
// The package name is `tk_testkit` (the directory is `testkit`, imported as `toolkit:testkit`): import it as `testkit`
// unless the application keeps a package of its own by that name.
package tk_testkit

import "base:runtime"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"

// A block of consecutive ports for the end-to-end tools. Every origin the tests use is a fixed offset from one base port
// (the default below), so the tools write the default ports and pass every address through `url`, which moves them to the
// run's block (and changes nothing on the default one). A run gets its own block through `base_env` so several worktrees
// test at once.
//
//	PORTS := testkit.Ports{base_env = "MYAPP_TEST_BASE_PORT", default_base = 8765, span = 5}
//	addr  := testkit.url(&PORTS, "http://127.0.0.1:8765/x")   // moved to the run's block, or unchanged on the default one
//
// The block's ports share their first three digits and differ only in the last (8765 ..< 8770): a readable default that
// keeps `url` a simple scan. The default range is `default_base ..< default_base + span`.
Ports :: struct {
	base_env:     string,   // the environment variable that carries the run's base port ("" never overrides the default)
	default_base: int,      // the base port the tools write and the default block starts at
	span:         int,      // how many consecutive ports a block holds
	// filled in lazily, guarded by `lock`:
	cached:       int,
	lock:         sync.Mutex,
	// url() results kept for the life of the process (the heap, never freed): an address may be handed to anything that
	// keeps it. Tests allocate a bounded set of these.
	interned:     map[string]string,
}

// The base port of this run: `base_env` from the environment if it is a usable port, else `default_base`.
base_port :: proc(p: ^Ports) -> int {
	if p.cached != 0 { return p.cached }
	b := p.default_base
	if p.base_env != "" {
		if v := os.get_env(p.base_env, context.temp_allocator); v != "" {
			if n, ok := strconv.parse_int(v, 10); ok && n > 0 && n + p.span <= 65536 { b = n }
		}
	}
	p.cached = b
	return b
}

// The port `offset` places after the base (0 the first origin, 1 the next, ...).
port :: proc(p: ^Ports, offset := 0) -> int { return base_port(p) + offset }

// `s` with every default port written after a host (":<default_base>" up to ":<default_base + span - 1>", not a longer
// number, not inside another number) moved to the run's block. On the default block, `s` itself. The result is interned,
// so the same address is rewritten once and may be handed to anything that keeps it.
url :: proc(p: ^Ports, s: string) -> string {
	b := base_port(p)
	prefix := port_prefix(p.default_base)   // e.g. ":876" for 8765
	if b == p.default_base || prefix == "" || !strings.contains(s, prefix) { return s }
	sync.guard(&p.lock)
	if r, ok := p.interned[s]; ok { return r }
	context.allocator = runtime.heap_allocator()
	if p.interned == nil { p.interned = make(map[string]string) }
	r := rewrite(p, s, b)
	p.interned[strings.clone(s)] = r
	return r
}

// The shared "<colon><first three digits>" of a base port (8765 -> ":876"). Empty when the base is out of the range this
// simple scheme covers (1000 ..= 9990): an application should keep ports whose block shares the first three digits.
@(private)
port_prefix :: proc(default_base: int) -> string {
	if default_base < 1000 || default_base > 9990 { return "" }
	n := default_base / 10
	buf: [4]u8
	buf[0] = ':'
	buf[1] = u8('0' + (n / 100) % 10)
	buf[2] = u8('0' + (n / 10) % 10)
	buf[3] = u8('0' + n % 10)
	return strings.clone(string(buf[:]), context.temp_allocator)
}

@(private)
rewrite :: proc(p: ^Ports, s: string, b: int) -> string {
	last := p.default_base % 10
	out := strings.builder_make(0, len(s) + 16)
	for i := 0; i < len(s); {
		if d, ok := default_port_at(p, s, i); ok {
			strings.write_byte(&out, ':')
			strings.write_int(&out, b + (d - last))
			i += 5
			continue
		}
		strings.write_byte(&out, s[i])
		i += 1
	}
	return strings.to_string(out)
}

// ":<first three digits><d>" at i, the last digit d within the block's span, after a host character and not followed by
// another digit. Returns the last digit's value.
@(private)
default_port_at :: proc(p: ^Ports, s: string, i: int) -> (digit: int, ok: bool) {
	prefix := port_prefix(p.default_base)   // ":876"
	plen := len(prefix)
	if plen == 0 || i == 0 || i + plen + 1 > len(s) { return 0, false }
	if s[i:i + plen] != prefix { return 0, false }
	c_digit := s[i + plen]
	if c_digit < '0' || c_digit > '9' { return 0, false }
	d := int(c_digit - '0')
	last := p.default_base % 10
	if d < last || d >= last + p.span { return 0, false }
	next := i + plen + 1
	if next < len(s) && s[next] >= '0' && s[next] <= '9' { return 0, false }
	c := s[i - 1]
	if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == ']') { return 0, false }
	return d, true
}
