package ui

import "base:runtime"
import "core:strings"

// Rows built only in view (gt:diff's view, a lazy column), declared to the text selection so that a selection outlives
// the rows it spans (src/md/features/text-selection.md, "Rows built only in view"):
//
//   ui.selection_rows_begin({count = len(lines), text = line_text, user = doc})
//   held := ui.selection_held_rows()                 // build these rows too, wherever they are
//   for i in rows_to_build {
//       ui.selection_row(i)                          // the boxes built next are row i's
//       ... row i ...
//   }
//   ui.selection_rows_end()
//
// The rows of the selection's two ends are built whatever; a copy reads the rows between that are not built from `text`.

// A container's rows for the text selection. `text` and `user` are read when the selection's text is asked, after the
// build: `user` is the program's lasting data, not temp memory.
Text_Rows :: struct {
	count: int,
	// row `row`'s selectable text, as its boxes would give it (two boxes of one row: joined by "\n"); ok false: the row
	// has none (a gap's mark)
	text:  proc(user: rawptr, row: int, allocator: runtime.Allocator) -> (text: string, ok: bool),
	user:  rawptr,
	gap:   string,   // before each row read ("": "\n"; "\n\n": rows that are blocks of a document)
	// row `row`'s identity, which stays when rows are inserted before it (a page of older messages loaded above a
	// selection). nil: the index is the identity (rows only appended, a diff)
	id:    proc(user: rawptr, row: int) -> u64,
}

// A selectable box's row: its container (the box the rows were declared in), its index there and its identity.
@(private)
Sel_Row :: struct {
	region: Key,
	row:    int,
	id:     u64,
	checked: u64,   // (an end's: the build its row was found again in)
}

// A run of rows a copy reads from their container, put at `at` in the text of the boxes.
@(private)
Sel_Gap :: struct {
	at:     int,
	rows:   Text_Rows,
	lo, hi: int,   // [lo, hi)
}

// Declares the rows built until selection_rows_end: the box being built into is their container.
selection_rows_begin :: proc(rows: Text_Rows) {
	s := gs()
	k := parent_box().key
	append(&s.sel.region_stack, Sel_Row{region = k, row = -1})
	s.sel.regions[k] = rows
}

// The boxes built next are row `i`'s (until the next call or selection_rows_end).
selection_row :: proc(i: int) {
	s := gs()
	n := len(s.sel.region_stack)
	if n == 0 { return }
	top := &s.sel.region_stack[n - 1]
	top.row, top.id = i, 0
	if rows := s.sel.regions[top.region]; rows.id != nil { top.id = rows.id(rows.user, i) }
}

selection_rows_end :: proc() {
	s := gs()
	if len(s.sel.region_stack) > 0 { pop(&s.sel.region_stack) }
}

// The rows of this container that hold an end of the selection (-1: none): build them whatever, wherever they are.
selection_held_rows :: proc() -> (rows: [2]int) {
	s := gs()
	rows = {-1, -1}
	n := len(s.sel.region_stack)
	if n == 0 || s.sel.phase == .None { return }
	k := s.sel.region_stack[n - 1].region
	if k == 0 { return }
	sel_ends_find(s, k)
	for e, i in s.sel.ends { if e.region == k { rows[i] = e.row } }
	return
}

// The ends' rows found again by their identity, once a build: rows inserted before an end (a page loaded above) moved
// it. A look at its index first; a search of the rows only when it moved, once for the move.
@(private = "file")
sel_ends_find :: proc(s: ^State, region: Key) {
	rows := s.sel.regions[region]
	if rows.id == nil { return }
	for &e in s.sel.ends {
		if e.region != region || e.checked == s.build_index { continue }
		e.checked = s.build_index
		if e.row >= 0 && e.row < rows.count && rows.id(rows.user, e.row) == e.id { continue }
		e.row = -1
		for r in 0 ..< rows.count { if rows.id(rows.user, r) == e.id { e.row = r; break } }
	}
}

// Whether row `i` of this container holds an end of the selection (a lazy column asks it of each item).
selection_holds_row :: proc(i: int) -> bool {
	h := selection_held_rows()
	return i >= 0 && (h[0] == i || h[1] == i)
}

// The rows between two boxes that follow each other in the selection: none built, read from their containers.
@(private)
sel_gaps_between :: proc(s: ^State, p, q: Key, at: int, gaps: ^[dynamic]Sel_Gap) {
	rp, inp := s.sel.row_of[p]
	rq, inq := s.sel.row_of[q]
	if inp && inq && rp.region == rq.region {
		sel_gap_add(s, rp.region, rp.row + 1, rq.row, at, gaps)
		return
	}
	if inp { sel_gap_add(s, rp.region, rp.row + 1, max(int), at, gaps) }
	if inq { sel_gap_add(s, rq.region, 0, rq.row, at, gaps) }
}

@(private = "file")
sel_gap_add :: proc(s: ^State, region: Key, lo, hi: int, at: int, gaps: ^[dynamic]Sel_Gap) {
	rows, ok := s.sel.regions[region]
	if !ok || rows.text == nil { return }
	end := min(hi, rows.count)
	if end <= lo { return }
	append(gaps, Sel_Gap{at, rows, lo, end})
}

// The text with its gaps' rows put in, each row read after its gap (a row built is not in a gap: its boxes gave it).
@(private)
sel_text_with_gaps :: proc(text: string, gaps: []Sel_Gap, allocator: runtime.Allocator) -> string {
	if len(gaps) == 0 { return strings.clone(text, allocator) }
	sb := strings.builder_make(allocator)
	from := 0
	for g in gaps {
		strings.write_string(&sb, text[from:g.at])
		from = g.at
		gap := g.rows.gap != "" ? g.rows.gap : "\n"
		for r in g.lo ..< g.hi {
			t, ok := g.rows.text(g.rows.user, r, context.temp_allocator)
			if !ok { continue }
			strings.write_string(&sb, gap)
			strings.write_string(&sb, t)
		}
	}
	strings.write_string(&sb, text[from:])
	return strings.to_string(sb)
}
