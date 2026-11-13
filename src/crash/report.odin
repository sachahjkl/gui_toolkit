package tk_crash

// The report: one text file per crash, read by a person and by a program (report_parse). The first line names the format and its
// version; a reader that meets a newer version reads the keys it knows and keeps the others in Report.extra.
//
//	gt-crash-report: 1
//	program: fidget
//	version: 0.51.0
//	commit: 1a2b3c4
//	build: 9f86d081884c7d65
//	system: linux amd64
//	date: 2026-11-13T17:03:00Z
//	pid: 4242
//	kind: signal
//	code: SIGSEGV
//	reason: segmentation fault (an invalid memory access)
//	address: 0x0
//	pc: 0x55D0C0DE1234
//	thread: 4242
//
//	[thread 4242]
//	  name: fidget
//	  crashed: yes
//	  #00	0x55D0C0DE1234	fidget	0x1234	?
//	[modules]
//	  0x55D0C0DE0000	0x5000	fidget	/home/me/fidget
//	[log]
//	  2026-11-13T17:02:59.120Z INFO  opened /home/me/a.txt
//	[settings]
//	  theme = dark
//	[symbols]
//	  0x7F0012345678	abort+0x8F
//	[end]
//
// A header line is "key: value"; a section starts with "[name]" at the start of a line, and every line inside it is indented by two
// spaces, so that no text of a log or a setting can start a section. A frame is "#<n>", its address, its module, its offset in the
// module and its symbol ("?": not known), separated by tabs. [symbols] names the addresses the system could name after the stack
// was written (the crash handler writes the addresses first: naming them may take locks the crash left held). [end] is the last
// line: a report without it was cut short.

import "core:strconv"
import "core:strings"

FORMAT_VERSION :: 1
FORMAT_MAGIC :: "gt-crash-report"
// What a crash and its kin are called in a report's "kind" line.
KIND_SIGNAL :: "signal"       // Linux: a signal (code: its name)
KIND_EXCEPTION :: "exception" // Windows: an exception (code: 0x...)
KIND_EXIT :: "exit"           // Windows: the program ended itself (ExitProcess) with its session open
KIND_UNCLEAN :: "unclean"     // the last session ended without a report (found at the next begin_session)
UNKNOWN_SYMBOL :: "?"
@(private) INDENT :: "  "

Frame :: struct {
	pc:     u64,
	module: string,   // the file name of the module ("": none found)
	offset: u64,      // pc - the module's base
	symbol: string,   // "name+0xoffset", or "" when not known
}

Thread :: struct {
	id:      u64,
	name:    string,
	crashed: bool,
	frames:  [dynamic]Frame,   // innermost first
}

Module :: struct {
	base, size: u64,
	name:       string,   // the file name
	path:       string,
}

Field :: struct {
	key, value: string,
}

// A report as report_parse reads it. Its strings point into the text parsed; its arrays are in the parser's allocator
// (report_destroy).
Report :: struct {
	format:   int,
	program:  string,
	version:  string,
	commit:   string,
	build:    string,   // Linux: the GNU build id of the executable; Windows: its PE time stamp and size, "%08X%X"
	system:   string,   // "<os> <arch>"
	date:     string,   // UTC, "YYYY-MM-DDTHH:MM:SSZ"
	pid:      u64,
	kind:     string,   // KIND_*
	code:     string,   // "SIGSEGV", "0xC0000005"
	reason:   string,   // what the code means, in words
	address:  u64,      // the address the fault was about (0: none)
	pc:       u64,      // the faulting instruction
	thread:   u64,      // the faulting thread
	extra:    [dynamic]Field,    // header keys this version does not know, in their order
	threads:  [dynamic]Thread,   // the faulting thread first
	modules:  [dynamic]Module,
	log:      [dynamic]string,   // the last lines of the log
	settings: [dynamic]string,   // the settings that differ from their default
	complete: bool,              // the [end] line was there
}

report_destroy :: proc(r: ^Report) {
	for &t in r.threads { delete(t.frames) }
	delete(r.threads)
	delete(r.extra)
	delete(r.modules)
	delete(r.log)
	delete(r.settings)
	r^ = {}
}

// The report's text: what the crash handler writes for the same values (the symbols in their frames, no [symbols] section).
report_text :: proc(r: Report, allocator := context.allocator) -> string {
	size := 64 * 1024
	for {
		buf := make([]u8, size, allocator)
		o := Out{buf = buf}
		write_report(&o, r)
		if !o.lost { return string(buf[:o.n]) }
		delete(buf, allocator)
		size *= 2
	}
}

@(private)
write_report :: proc(o: ^Out, r: Report) {
	write_head(o, Head{
		program = r.program, version = r.version, commit = r.commit, build = r.build, system = r.system, date = r.date,
		pid = r.pid, kind = r.kind, code = r.code, reason = r.reason, address = r.address, pc = r.pc, thread = r.thread,
	})
	for f in r.extra { out_field(o, f.key, f.value) }
	for t in r.threads {
		out_thread(o, t.id, t.name, t.crashed)
		for f, i in t.frames { out_frame(o, i, f.pc, f.module, f.offset, f.symbol) }
	}
	out_section(o, "modules")
	for m in r.modules { out_module(o, m.base, m.size, m.name, m.path) }
	out_section(o, "log")
	for l in r.log { out_indented(o, l) }
	out_section(o, "settings")
	for l in r.settings { out_indented(o, l) }
	if r.complete { out_section(o, "end") }
}

// What the head of a report says.
@(private)
Head :: struct {
	program, version, commit, build, system, date: string,
	pid:                                         u64,
	kind, code, reason:                          string,
	address, pc, thread:                         u64,
}

@(private)
write_head :: proc "contextless" (o: ^Out, h: Head) {
	out_string(o, FORMAT_MAGIC)
	out_string(o, ": ")
	out_dec(o, FORMAT_VERSION)
	out_byte(o, '\n')
	out_field(o, "program", h.program)
	out_field(o, "version", h.version)
	out_field(o, "commit", h.commit)
	out_field(o, "build", h.build)
	out_field(o, "system", h.system)
	out_field(o, "date", h.date)
	out_field_dec(o, "pid", h.pid)
	out_field(o, "kind", h.kind)
	out_field(o, "code", h.code)
	out_field(o, "reason", h.reason)
	out_field_hex(o, "address", h.address)
	out_field_hex(o, "pc", h.pc)
	out_field_dec(o, "thread", h.thread)
}

////////////////////////////////
// Writing, with no allocation (the crash handler's)

// Bytes gathered in `buf`, handed to `sink` when it is full (nil: the buffer only, and what does not fit is lost).
@(private)
Out :: struct {
	buf:    []u8,
	n:      int,
	sink:   proc "contextless" (o: ^Out, data: []u8),
	lost:   bool,
}

@(private)
out_flush :: proc "contextless" (o: ^Out) {
	if o.sink != nil && o.n > 0 { o.sink(o, o.buf[:o.n]) }
	if o.sink != nil { o.n = 0 }
}

@(private)
out_byte :: proc "contextless" (o: ^Out, b: u8) {
	if o.n == len(o.buf) { out_flush(o) }
	if o.n == len(o.buf) { o.lost = true; return }
	o.buf[o.n] = b
	o.n += 1
}

@(private)
out_string :: proc "contextless" (o: ^Out, s: string) {
	for i in 0 ..< len(s) { out_byte(o, s[i]) }
}

// One line of a value: a line end or a tab inside it becomes a space, so that the line stays one field.
@(private)
out_flat :: proc "contextless" (o: ^Out, s: string) {
	for i in 0 ..< len(s) {
		c := s[i]
		out_byte(o, c == '\n' || c == '\r' || c == '\t' ? ' ' : c)
	}
}

@(private)
out_dec :: proc "contextless" (o: ^Out, v: u64) {
	digits: [20]u8
	n := 0
	v := v
	for {
		digits[n] = '0' + u8(v % 10)
		n += 1
		v /= 10
		if v == 0 { break }
	}
	for i := n - 1; i >= 0; i -= 1 { out_byte(o, digits[i]) }
}

@(private)
out_hex :: proc "contextless" (o: ^Out, v: u64) {
	hex := "0123456789ABCDEF"
	out_string(o, "0x")
	digits: [16]u8
	n := 0
	v := v
	for {
		digits[n] = hex[v & 15]
		n += 1
		v >>= 4
		if v == 0 { break }
	}
	for i := n - 1; i >= 0; i -= 1 { out_byte(o, digits[i]) }
}

// A number on two digits at least (a date's).
@(private)
out_dec2 :: proc "contextless" (o: ^Out, v: int) {
	if v < 10 { out_byte(o, '0') }
	out_dec(o, u64(v))
}

@(private)
out_field :: proc "contextless" (o: ^Out, key, value: string) {
	out_string(o, key)
	out_string(o, ": ")
	out_flat(o, value)
	out_byte(o, '\n')
}

@(private)
out_field_dec :: proc "contextless" (o: ^Out, key: string, v: u64) {
	out_string(o, key)
	out_string(o, ": ")
	out_dec(o, v)
	out_byte(o, '\n')
}

@(private)
out_field_hex :: proc "contextless" (o: ^Out, key: string, v: u64) {
	out_string(o, key)
	out_string(o, ": ")
	out_hex(o, v)
	out_byte(o, '\n')
}

@(private)
out_section :: proc "contextless" (o: ^Out, name: string) {
	out_byte(o, '[')
	out_string(o, name)
	out_string(o, "]\n")
}

@(private)
out_thread :: proc "contextless" (o: ^Out, id: u64, name: string, crashed: bool) {
	out_string(o, "[thread ")
	out_dec(o, id)
	out_string(o, "]\n")
	if name != "" {
		out_string(o, INDENT)
		out_field(o, "name", name)
	}
	if crashed {
		out_string(o, INDENT)
		out_field(o, "crashed", "yes")
	}
}

@(private)
out_frame :: proc "contextless" (o: ^Out, i: int, pc: u64, module: string, offset: u64, symbol: string) {
	out_string(o, INDENT)
	out_byte(o, '#')
	out_dec2(o, i)
	out_byte(o, '\t')
	out_hex(o, pc)
	out_byte(o, '\t')
	out_flat(o, module)
	out_byte(o, '\t')
	out_hex(o, offset)
	out_byte(o, '\t')
	out_flat(o, symbol != "" ? symbol : UNKNOWN_SYMBOL)
	out_byte(o, '\n')
}

@(private)
out_module :: proc "contextless" (o: ^Out, base, size: u64, name, path: string) {
	out_string(o, INDENT)
	out_hex(o, base)
	out_byte(o, '\t')
	out_hex(o, size)
	out_byte(o, '\t')
	out_flat(o, name)
	out_byte(o, '\t')
	out_flat(o, path)
	out_byte(o, '\n')
}

@(private)
out_symbol :: proc "contextless" (o: ^Out, pc: u64, name: string) {
	out_string(o, INDENT)
	out_hex(o, pc)
	out_byte(o, '\t')
	out_flat(o, name)
	out_byte(o, '\n')
}

@(private)
out_indented :: proc "contextless" (o: ^Out, line: string) {
	out_string(o, INDENT)
	out_flat(o, line)
	out_byte(o, '\n')
}

// Text a Source gave, line by line under the section `name` (empty lines dropped).
@(private)
out_text_section :: proc "contextless" (o: ^Out, name: string, text: []u8) {
	out_section(o, name)
	rest := string(text)
	for len(rest) > 0 {
		end := len(rest)
		for i in 0 ..< len(rest) { if rest[i] == '\n' { end = i; break } }
		line := rest[:end]
		if len(line) > 0 && line[len(line) - 1] == '\r' { line = line[:len(line) - 1] }
		if len(line) > 0 { out_indented(o, line) }
		rest = end < len(rest) ? rest[end + 1:] : ""
	}
}

// "YYYY-MM-DDTHH:MM:SSZ" of seconds since 1970.
@(private)
out_date :: proc "contextless" (buf: []u8, unix: i64) -> string {
	y, mo, d, h, mi, s := civil_utc(unix)
	o := Out{buf = buf}
	out_dec(&o, u64(y))
	out_byte(&o, '-'); out_dec2(&o, mo)
	out_byte(&o, '-'); out_dec2(&o, d)
	out_byte(&o, 'T'); out_dec2(&o, h)
	out_byte(&o, ':'); out_dec2(&o, mi)
	out_byte(&o, ':'); out_dec2(&o, s)
	out_byte(&o, 'Z')
	return string(buf[:o.n])
}

// "<kind>-YYYYMMDD-HHMMSS-<pid>.txt": a report's file name, in the order of the dates when sorted.
@(private)
out_report_name :: proc "contextless" (buf: []u8, kind: string, unix: i64, pid: u64) -> string {
	y, mo, d, h, mi, s := civil_utc(unix)
	o := Out{buf = buf}
	out_string(&o, kind)
	out_byte(&o, '-')
	out_dec(&o, u64(y)); out_dec2(&o, mo); out_dec2(&o, d)
	out_byte(&o, '-')
	out_dec2(&o, h); out_dec2(&o, mi); out_dec2(&o, s)
	out_byte(&o, '-')
	out_dec(&o, pid)
	out_string(&o, REPORT_EXTENSION)
	return string(buf[:o.n])
}

// Seconds since 1970 as a UTC date and time (days to a civil date: H. Hinnant's algorithm).
@(private)
civil_utc :: proc "contextless" (t: i64) -> (y, mo, d, h, mi, s: int) {
	days := t / 86400
	rem := t - days * 86400
	if rem < 0 { rem += 86400; days -= 1 }
	h, mi, s = int(rem / 3600), int(rem % 3600 / 60), int(rem % 60)
	z := days + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d = int(doy - (153 * mp + 2) / 5 + 1)
	mo = int(mp < 10 ? mp + 3 : mp - 9)
	y = int(yoe + era * 400 + (mo <= 2 ? 1 : 0))
	return
}

////////////////////////////////
// Reading

// The report in `text`. ok is false when the text is no report (its first line is not FORMAT_MAGIC's). A report of a newer format
// is read as far as this version knows it (r.format says which it was).
report_parse :: proc(text: string, allocator := context.allocator) -> (r: Report, ok: bool) {
	r.extra = make([dynamic]Field, allocator)
	r.threads = make([dynamic]Thread, allocator)
	r.modules = make([dynamic]Module, allocator)
	r.log = make([dynamic]string, allocator)
	r.settings = make([dynamic]string, allocator)
	symbols := make([dynamic]Field, context.temp_allocator)   // [symbols]: the address's text, its name

	rest := strings.trim_prefix(text, "\ufeff")
	first := true
	section := ""
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(raw, "\r")
		if first {
			first = false
			key, value, is_field := split_field(line)
			if !is_field || key != FORMAT_MAGIC { return r, false }
			r.format, _ = strconv.parse_int(value, 10)
			ok = true
			continue
		}
		if strings.has_prefix(line, "[") && strings.has_suffix(line, "]") {
			name := line[1:len(line) - 1]
			section = name
			if strings.has_prefix(name, "thread ") {
				id, _ := strconv.parse_u64(strings.trim_space(name[len("thread "):]), 10)
				append(&r.threads, Thread{id = id, frames = make([dynamic]Frame, allocator)})
				section = "thread"
			} else if name == "end" {
				r.complete = true
			}
			continue
		}
		if section == "" {
			if key, value, is_field := split_field(line); is_field { head_field(&r, key, value) }
			continue
		}
		if !strings.has_prefix(line, INDENT) { continue }
		body := line[len(INDENT):]
		switch section {
		case "thread":
			t := &r.threads[len(r.threads) - 1]
			if strings.has_prefix(body, "#") {
				if f, good := parse_frame(body); good { append(&t.frames, f) }
			} else if key, value, is_field := split_field(body); is_field {
				switch key {
				case "name":    t.name = value
				case "crashed": t.crashed = value == "yes"
				}
			}
		case "modules":
			p := tab_fields(body)
			if p.n < 4 { continue }
			base, g1 := parse_hex(p.f[0])
			size, g2 := parse_hex(p.f[1])
			if g1 && g2 { append(&r.modules, Module{base = base, size = size, name = p.f[2], path = p.f[3]}) }
		case "log":      append(&r.log, body)
		case "settings": append(&r.settings, body)
		case "symbols":
			if tab := strings.index_byte(body, '\t'); tab > 0 { append(&symbols, Field{body[:tab], body[tab + 1:]}) }
		}
	}
	// a name found after the stack goes to every frame of that address that has none
	for s in symbols {
		pc, good := parse_hex(s.key)
		if !good { continue }
		for &t in r.threads { for &f in t.frames { if f.pc == pc && f.symbol == "" { f.symbol = s.value } } }
	}
	return r, ok
}

@(private)
head_field :: proc(r: ^Report, key, value: string) {
	switch key {
	case "program": r.program = value
	case "version": r.version = value
	case "commit":  r.commit = value
	case "build":   r.build = value
	case "system":  r.system = value
	case "date":    r.date = value
	case "pid":     r.pid, _ = strconv.parse_u64(value, 10)
	case "kind":    r.kind = value
	case "code":    r.code = value
	case "reason":  r.reason = value
	case "address": r.address, _ = parse_hex(value)
	case "pc":      r.pc, _ = parse_hex(value)
	case "thread":  r.thread, _ = strconv.parse_u64(value, 10)
	case:           append(&r.extra, Field{key, value})
	}
}

// "key: value" (the value may be empty).
@(private)
split_field :: proc(line: string) -> (key, value: string, ok: bool) {
	i := strings.index(line, ":")
	if i <= 0 { return }
	key = line[:i]
	if strings.index_any(key, " \t") >= 0 { return }
	return key, strings.trim_space(line[i + 1:]), true
}

@(private)
Tab_Fields :: struct { f: [5]string, n: int }

// Up to five tab-separated fields; the last takes the rest of the line (a symbol may hold a tab no more, but a path may hold anything).
@(private)
tab_fields :: proc(s: string) -> (p: Tab_Fields) {
	rest := s
	for p.n < len(p.f) - 1 {
		i := strings.index_byte(rest, '\t')
		if i < 0 { break }
		p.f[p.n] = rest[:i]
		p.n += 1
		rest = rest[i + 1:]
	}
	p.f[p.n] = rest
	p.n += 1
	return
}

// "#NN\t0xPC\tmodule\t0xOFFSET\tsymbol"
@(private)
parse_frame :: proc(body: string) -> (f: Frame, ok: bool) {
	p := tab_fields(body)
	if p.n < 5 { return }
	pc, g1 := parse_hex(p.f[1])
	off, g2 := parse_hex(p.f[3])
	if !g1 || !g2 { return }
	f = Frame{pc = pc, module = p.f[2], offset = off, symbol = p.f[4] == UNKNOWN_SYMBOL ? "" : p.f[4]}
	return f, true
}

@(private)
parse_hex :: proc(s: string) -> (v: u64, ok: bool) {
	t := strings.trim_space(s)
	if !strings.has_prefix(t, "0x") && !strings.has_prefix(t, "0X") { return }
	return strconv.parse_u64(t[2:], 16)
}
