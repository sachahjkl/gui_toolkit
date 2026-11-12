// Package diff: a unified diff read into its lines, a diff of two texts written as one, and a widget that shows it (view.odin).
//
//	parsed := diff.parse(patch)                      // once, when the patch is new: a build only shows it
//	diff.lines_view("###diff", parsed.lines[:16], parsed.numbered, opts)
//
//	doc: diff.Doc                                    // a whole patch in a window: its text owned, read again only when it changes
//	diff.doc_set(&doc, patch)
//	diff.view("###full", &doc, .Split, opts)         // only the rows in view are built
//
// A patch is git's or diff -u's (headers, hunks, several files), or the bare lines that `between` writes (a sign then the
// text, no header, no hunk). Its lines' texts are slices of the patch: keep the patch while they are used.
package tk_diff

import "core:slice"
import "core:strconv"
import "core:strings"
import cdiff "core:diff"

Kind :: enum u8 {
	Same,      // in both
	Added,
	Removed,
	Gap,       // between two hunks: what is not in the patch
}

Line :: struct {
	kind:           Kind,
	text:           string,   // without its sign, a slice of the patch
	old_no, new_no: int,      // its numbers in the old and the new text (0: none, as on the side it is not on, or a patch without hunks)
	lo, hi:         int,      // what changed in it, in bytes of `text` (lo == hi: nothing to mark): see `mark`
}

// The sign of a line in a unified diff ('@' for a gap).
sign :: proc(k: Kind) -> byte {
	switch k {
	case .Same:    return ' '
	case .Added:   return '+'
	case .Removed: return '-'
	case .Gap:     return '@'
	}
	return ' '
}

// A patch read: its lines with their changes marked, whether they have numbers, what it adds and removes.
Parsed :: struct {
	lines:          []Line,   // (allocated; their texts are the patch's)
	numbered:       bool,     // some line has a number: it came with hunks
	added, removed: int,
}

// `patch` read into lines (in `allocator`), each changed line's change marked.
parse :: proc(patch: string, allocator := context.allocator) -> Parsed {
	lines := parse_lines(patch, context.temp_allocator)
	mark(lines)
	p := Parsed{lines = slice.clone(lines, allocator)}
	for l in lines {
		if l.old_no > 0 || l.new_no > 0 { p.numbered = true }
		if l.kind == .Added { p.added += 1 }
		if l.kind == .Removed { p.removed += 1 }
	}
	return p
}

parsed_destroy :: proc(p: ^Parsed, allocator := context.allocator) {
	delete(p.lines, allocator)
	p^ = {}
}

// A line of a hunk begins with a sign, and only the counts of its header say where the hunk ends: "--- x" in it is the line "-- x"
// removed. Out of a hunk, "--- x" is a file's header.
@(private)
Mode :: enum u8 { Header, Hunk }

// `patch`'s lines, unmarked, in `allocator`.
parse_lines :: proc(patch: string, allocator := context.allocator) -> []Line {
	out := make([dynamic]Line, allocator)
	old_no, new_no := 0, 0
	old_left, new_left := 0, 0
	mode := Mode.Header
	// (a patch of `between` has no header and no hunk: each of its lines is a line, whatever it looks like)
	headers := false
	scan := patch
	for l in strings.split_lines_iterator(&scan) {
		if strings.has_prefix(l, "@@") || file_header(l) { headers = true; break }
	}
	line :: proc(out: ^[dynamic]Line, l: string, old_no, new_no: ^int) {
		switch {
		case strings.has_prefix(l, "+"):
			append(out, Line{kind = .Added, text = l[1:], new_no = new_no^})
			if new_no^ > 0 { new_no^ += 1 }
		case strings.has_prefix(l, "-"):
			append(out, Line{kind = .Removed, text = l[1:], old_no = old_no^})
			if old_no^ > 0 { old_no^ += 1 }
		case:
			append(out, Line{kind = .Same, text = strings.trim_prefix(l, " "), old_no = old_no^, new_no = new_no^})
			if old_no^ > 0 { old_no^ += 1 }
			if new_no^ > 0 { new_no^ += 1 }
		}
	}
	rest := patch
	for l in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(l, "\\ ") { continue }   // "\ No newline at end of file"
		switch mode {
		case .Hunk:
			line(&out, l, &old_no, &new_no)
			if !strings.has_prefix(l, "+") { old_left -= 1 }
			if !strings.has_prefix(l, "-") { new_left -= 1 }
			if old_left <= 0 && new_left <= 0 { mode = .Header }
		case .Header:
			switch {
			case strings.has_prefix(l, "@@"):
				old_no, new_no = hunk_start(l, '-'), hunk_start(l, '+')
				old_left, new_left = hunk_count(l, '-'), hunk_count(l, '+')
				if len(out) > 0 { append(&out, Line{kind = .Gap}) }
				if old_left > 0 || new_left > 0 { mode = .Hunk }
			case !headers:
				line(&out, l, &old_no, &new_no)
			case file_header(l), strings.has_prefix(l, "--- "), strings.has_prefix(l, "+++ "):
			case:
				line(&out, l, &old_no, &new_no)
			}
		}
	}
	return out[:]
}

// The number after `side` in a hunk's header, "@@ -12,3 +14,4 @@".
@(private)
hunk_start :: proc(h: string, side: byte) -> int {
	i := strings.index_byte(h, side)
	if i < 0 { return 0 }
	end := i + 1
	for end < len(h) && h[end] >= '0' && h[end] <= '9' { end += 1 }
	n, _ := strconv.parse_int(h[i + 1:end])
	return n
}

// The count after `side`'s number in a hunk's header: "-12,3". (None said: one line.)
@(private)
hunk_count :: proc(h: string, side: byte) -> int {
	i := strings.index_byte(h, side)
	if i < 0 { return 0 }
	end := i + 1
	for end < len(h) && h[end] >= '0' && h[end] <= '9' { end += 1 }
	if end >= len(h) || h[end] != ',' { return 1 }
	stop := end + 1
	for stop < len(h) && h[stop] >= '0' && h[stop] <= '9' { stop += 1 }
	n, _ := strconv.parse_int(h[end + 1:stop])
	return n
}

// What comes before a file's first hunk. (The line "Binary files … differ" says something, and stays.)
@(private)
file_header :: proc(l: string) -> bool {
	for p in ([]string{"diff --git ", "index ", "new file mode ", "deleted file mode ", "old mode ", "new mode ", "similarity index ", "rename from ", "rename to ", "Index: ", "====="}) {
		if strings.has_prefix(l, p) { return true }
	}
	return false
}

// In a block of lines removed then added, the k-th of each are the same line changed: what they share at each end is left
// plain, what is between is what the eye looks for (lo, hi). A pair that shares nothing is not marked: all of it changed.
mark :: proc(lines: []Line) {
	i := 0
	for i < len(lines) {
		if lines[i].kind != .Removed { i += 1; continue }
		d0 := i
		for i < len(lines) && lines[i].kind == .Removed { i += 1 }
		a0 := i
		for i < len(lines) && lines[i].kind == .Added { i += 1 }
		for k in 0 ..< min(a0 - d0, i - a0) {
			x, y := &lines[d0 + k], &lines[a0 + k]
			p := 0
			for p < len(x.text) && p < len(y.text) && x.text[p] == y.text[p] { p += 1 }
			for p > 0 && p < len(x.text) && x.text[p] & 0xC0 == 0x80 { p -= 1 }   // (not inside a character)
			s := 0
			for s < len(x.text) - p && s < len(y.text) - p && x.text[len(x.text) - 1 - s] == y.text[len(y.text) - 1 - s] { s += 1 }
			for s > 0 && x.text[len(x.text) - s] & 0xC0 == 0x80 { s -= 1 }
			if p == 0 && s == 0 { continue }
			x.lo, x.hi = p, len(x.text) - s
			y.lo, y.hi = p, len(y.text) - s
		}
	}
}

@(private)
bit_at :: proc(bits: []u64, i: int) -> bool { return bits[i / 64] & (u64(1) << uint(i % 64)) != 0 }

// `old` to `new` as the lines of a unified diff, without headers or hunks: a whole text, so no numbers to give. ("": they could
// not be compared.)
between :: proc(old, new: string, allocator := context.allocator) -> string {
	a := strings.split_lines(old, context.temp_allocator)
	b := strings.split_lines(new, context.temp_allocator)
	c, err := cdiff.diff(a, b, context.temp_allocator, context.temp_allocator)
	if err != nil { return "" }
	out := strings.builder_make(allocator)
	line :: proc(out: ^strings.Builder, c: byte, s: string) {
		strings.write_byte(out, c)
		strings.write_string(out, s)
		strings.write_byte(out, '\n')
	}
	b_bits := c.bits[(c.n + 63) / 64:]
	i, j := 0, 0
	for i < c.n || j < c.m {
		if i < c.n && bit_at(c.bits, i) { line(&out, '-', a[i]); i += 1; continue }
		if j < c.m && bit_at(b_bits, j) { line(&out, '+', b[j]); j += 1; continue }
		if i < c.n { line(&out, ' ', a[i]) }
		i += 1
		j += 1
	}
	return strings.to_string(out)
}

// The two sides of a row of a split view, by index in the lines; -1: nothing on that side. A line that is the same, or a gap, is on
// both.
Row :: struct { left, right: int }

// In a block of lines removed then added, the k-th of each are the same line changed, as `mark` has them: they face each other.
split_rows :: proc(lines: []Line, allocator := context.allocator) -> []Row {
	out := make([dynamic]Row, 0, len(lines), allocator)
	i := 0
	for i < len(lines) {
		if lines[i].kind != .Removed && lines[i].kind != .Added {
			append(&out, Row{i, i})
			i += 1
			continue
		}
		d0 := i
		for i < len(lines) && lines[i].kind == .Removed { i += 1 }
		a0 := i
		for i < len(lines) && lines[i].kind == .Added { i += 1 }
		removed, added := a0 - d0, i - a0
		for k in 0 ..< max(removed, added) {
			append(&out, Row{k < removed ? d0 + k : -1, k < added ? a0 + k : -1})
		}
	}
	return out[:]
}

// Rows built beyond each edge of a view by default: a wheel's step lands on rows already there.
VIEW_MARGIN_ROWS :: 30

// The rows to build for a view of rows of one height: those where the view is (`offset`) and where it goes (`target`), and a
// margin beyond. A sum, whatever the length of the diff.
visible_rows :: proc(offset, target, view_h, row_h: f32, count: int, margin := VIEW_MARGIN_ROWS) -> (first, last: int) {
	if row_h <= 0 { return 0, 0 }
	top := min(offset, target)
	bottom := max(offset, target) + view_h
	first = clamp(int(top / row_h) - margin, 0, count)
	last = clamp(int(bottom / row_h) + 1 + margin, first, count)
	return
}

// A patch and what is read from it, owned: `doc_set` reads it when its text changes, a build only shows it. `version` counts the
// readings (a cache keyed by it knows when the lines changed).
Doc :: struct {
	patch:          string,
	using parsed:   Parsed,
	rows:           []Row,   // the split view's
	version:        u64,
}

// `patch` is the doc's: read when it differs from the one it has (false: the same, nothing read).
doc_set :: proc(d: ^Doc, patch: string) -> (read: bool) {
	if d.version != 0 && d.patch == patch { return false }
	version := d.version
	doc_destroy(d)
	d.patch = strings.clone(patch)
	d.parsed = parse(d.patch)
	d.rows = split_rows(d.lines)
	d.version = version + 1
	return true
}

doc_destroy :: proc(d: ^Doc) {
	delete(d.patch)
	delete(d.lines)
	delete(d.rows)
	d^ = {}
}
