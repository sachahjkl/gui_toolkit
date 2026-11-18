package tk_plugins

// A plugin's lazy list on the interface's thread (plugins.md, "As built: lazy lists"): a `list` node of a view's
// display list says how many rows there are, not what they are. The replay builds it as the toolkit's virtual list
// (ui.vlist), which says which rows are in view; the host asks the plugin's process for the rows in view and a margin
// around them, by range, and builds a placeholder for a row not answered yet. One ask waits at a time per list: a
// plugin that is slow gets no more work than it can do, and the window builds on whatever it does. An answer for an
// older version of the list, for an ask that went past the bound, or for rows no longer wanted, is dropped.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import plugin_api "../plugin_api"
import "../ui"

// The most rows a list has: past it, the rest is not shown (its ids cost 8 bytes a row).
LAZY_MAX_ROWS :: 1_000_000
// A row's height in lines before its rows are measured, and the rows the list is high, when the node does not say.
LAZY_ROW_LINES :: 2
LAZY_VISIBLE_ROWS :: 10
LAZY_MOST_VISIBLE_ROWS :: 100

// An ask of a list's rows, as the host sends it and the process sends it back with its answer.
@(private)
Rows_Ask :: struct {
	seq:       u64,   // the list's asks so far (0: none waits)
	version:   i64,   // the list's version when it was asked
	from, to:  int,   // the rows to render
	// the rows the host keeps: the process lets go of the handlers of the others
	keep_from, keep_to: int,
}

// Rows the plugin answered: one column node per row (plugin_api.list_write_rows). `list` nil: the rows are empty (the
// plugin's row function threw).
@(private)
Rows_Answer :: struct {
	list:     ^plugin_api.List,   // (owned)
	from, to: int,
	starts:   []int,              // (heap) the node of each row's column in `list`
}

// An answer let go of: freed two builds later, when no widget holds its strings any more.
@(private)
Rows_Retired :: struct {
	answer: Rows_Answer,
	build:  u64,
}

@(private)
Lazy :: struct {
	key:         string,   // (owned: the record's map's key too)
	vl:          ui.Virtual_List,
	count:       int,
	version:     i64,
	ids:         [dynamic]u64,   // row i's identity is i + 1: a new version forgets the heights (vlist_invalidate)
	ids_version: u64,
	answers:     [dynamic]Rows_Answer,
	retired:     [dynamic]Rows_Retired,
	asked:       Rows_Ask,       // the ask that waits (seq 0: none)
	asked_ms:    i64,
	seq:         u64,
	want_from, want_to: int,     // the rows kept: those in view and a margin
	guessed:   bool,             // the last build's rows were ui.vlist's guess (Vlist_Rows.guessed): nothing is asked
	shown_from, shown_to: int,   // the rows the last build built
	builds:      u64,
	// what a test reads (list_info)
	asks:        int,
	asked_most:  int,
	dropped:     int,
}

// What the host knows of a lazy list, for a test or a program's own page.
List_Info :: struct {
	count:      int,
	version:    i64,
	shown_from: int,   // the rows the last build built (the view and the virtual list's margin)
	shown_to:   int,
	asks:       int,   // the asks sent
	asked_most: int,   // the end of the highest range ever asked
	answered:   int,   // the rows answered and kept
	waiting:    bool,  // an ask waits for its answer
	dropped:    int,   // the answers dropped: an older version's, an ask past the bound, rows no longer wanted
}

// Plugin `plugin_id`'s view `view_id`'s lazy list `key`, as the host knows it. False: no such list was built.
list_info :: proc(h: ^Host, plugin_id, view_id, key: string) -> (info: List_Info, ok: bool) {
	r := view_record(h, plugin_id, view_id)
	if r == nil { return }
	lz := r.lazies[key] or_else nil
	if lz == nil { return }
	answered := 0
	for a in lz.answers { answered += a.to - a.from }
	return List_Info{
		count = lz.count, version = lz.version, shown_from = lz.shown_from, shown_to = lz.shown_to, asks = lz.asks,
		asked_most = lz.asked_most, answered = answered, waiting = lz.asked.seq != 0, dropped = lz.dropped,
	}, true
}

// Scrolls a lazy list so that row `row` is at its top, at the next build. False: no such list was built.
list_scroll_to :: proc(h: ^Host, plugin_id, view_id, key: string, row: int) -> bool {
	r := view_record(h, plugin_id, view_id)
	if r == nil { return false }
	lz := r.lazies[key] or_else nil
	if lz == nil { return false }
	top, _ := ui.vlist_row_extent(&lz.vl, clamp(row, 0, max(lz.count - 1, 0)))
	ui.vlist_scroll_to(&lz.vl, top)
	return true
}

@(private)
lazy_of :: proc(r: ^View_Record, key: string) -> ^Lazy {
	if lz, ok := r.lazies[key]; ok { return lz }
	lz := new(Lazy)
	lz.key = strings.clone(key)
	r.lazies[lz.key] = lz
	return lz
}

@(private)
lazy_free :: proc(lz: ^Lazy) {
	ui.vlist_destroy(&lz.vl)
	for a in lz.answers { answer_free(a) }
	delete(lz.answers)
	for t in lz.retired { answer_free(t.answer) }
	delete(lz.retired)
	delete(lz.ids)
	delete(lz.key)
	free(lz)
}

@(private)
answer_free :: proc(a: Rows_Answer) {
	plugin_api.list_free(a.list)
	delete(a.starts, runtime.heap_allocator())
}

// The lists of a record that its list no longer has (view_draw, once that list was replayed: no widget holds their
// strings any more).
@(private)
lazies_prune :: proc(r: ^View_Record) {
	present := make(map[string]bool, context.temp_allocator)
	if r.list != nil { for n in r.list.nodes { if n.kind == .List { present[n.key] = true } } }
	gone := make([dynamic]string, context.temp_allocator)
	for k in r.lazies { if !present[k] { append(&gone, k) } }
	for k in gone {
		lz := r.lazies[k]
		delete_key(&r.lazies, k)
		lazy_controls_drop(r, lz, 0, LAZY_MAX_ROWS, true)
		lazy_free(lz)
	}
}

// A `list` node, as the toolkit's virtual list: the rows answered replayed, a placeholder for the others; then the
// rows wanted and not answered asked for.
@(private)
lazy_replay :: proc(r: ^View_Record, n: plugin_api.List_Node) {
	props := plugin_api.node_props(n, plugin_api.Lazy_List_Node)
	if props == nil { return }
	lz := lazy_of(r, n.key)
	lz.builds += 1
	lazy_free_retired(r, lz)
	if i64(props.version) != lz.version {
		// (the rows' content changed: what was answered goes, heights too; the ask that waits is answered for the old
		// version and dropped when it comes)
		lz.version = i64(props.version)
		for len(lz.answers) > 0 { lazy_retire(lz, len(lz.answers) - 1) }
		ui.vlist_invalidate(&lz.vl)
		lz.asked = {}
	}
	count := clamp(props.count, 0, LAZY_MAX_ROWS)
	if count != lz.count {
		// (the ids change with the count only: work in proportion to the rows when they change, never in a build that
		// changes nothing)
		old := len(lz.ids)
		resize(&lz.ids, count)
		for i in old ..< count { lz.ids[i] = u64(i) + 1 }
		lz.count = count
		lz.ids_version += 1
	}
	em := ui.font_size()
	lines := props.rowHeight > 0 ? f32(props.rowHeight) : LAZY_ROW_LINES
	est := max(math.round(em * lines), 1)
	if len(lz.vl.measured) == 0 { lz.vl.est = est }
	visible := props.visibleRows > 0 ? min(props.visibleRows, LAZY_MOST_VISIBLE_ROWS) : LAZY_VISIBLE_ROWS
	ui.next({width = ui.fill(), height = ui.px(est * f32(visible))})
	if rows, ok := ui.vlist(fmt.tprintf("###pv:%s", n.key), &lz.vl, lz.ids[:], ids_version = lz.ids_version); ok {
		lz.shown_from, lz.shown_to = rows.first, rows.last
		lz.guessed = rows.guessed
		for i in rows.first ..< rows.last {
			// (the row box is the virtual list's name for row i: the list measures its height)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = ui.vlist_row_name(i)) {
				a, at := lazy_row(lz, i)
				switch {
				case a == nil:
					// (not answered yet: its place, as high as a row is thought to be)
					if ui.tags("weak") {
						ui.next({width = ui.fill(), height = ui.px(lz.vl.est)})
						ui.label("…###pv_wait")
					}
				case a.list != nil:
					nodes := a.list.nodes[:]
					k := at + 1
					replay_children(r, nodes, &k, nodes[at].children, false)
				}
			}
		}
	}
	lazy_ask(r, lz)
}

// The answer that has row `i`, and the node of its row's column. nil: row `i` is not answered.
@(private)
lazy_row :: proc(lz: ^Lazy, i: int) -> (^Rows_Answer, int) {
	for &a in lz.answers {
		if i < a.from || i >= a.to { continue }
		return &a, a.list != nil ? a.starts[i - a.from] : -1
	}
	return nil, 0
}

// The rows wanted: those built (the view and the virtual list's margin) and as many again on each side. The answers
// with none of them let go of; the first rows wanted and not answered asked for, when no ask waits.
@(private)
lazy_ask :: proc(r: ^View_Record, lz: ^Lazy) {
	context.allocator = runtime.heap_allocator()
	h := r.host
	first, last := min(lz.shown_from, lz.count), min(lz.shown_to, lz.count)
	span := max(last - first, 1)
	want_from, want_to := max(first - span, 0), min(last + span, lz.count)
	if want_from != lz.want_from || want_to != lz.want_to {
		lz.want_from, lz.want_to = want_from, want_to
		for i := len(lz.answers) - 1; i >= 0; i -= 1 {
			a := lz.answers[i]
			if a.to <= want_from || a.from >= want_to { lazy_retire(lz, i) }
		}
	}
	// (the list's first build guesses its rows from the window's height: asked, they would be more than it shows)
	if want_to <= want_from || lz.guessed { return }
	p := find(h, r.plugin_id)
	if p == nil || !p.alive || !r.told_open { return }
	now := now_ms()
	if lz.asked.seq != 0 {
		if now - lz.asked_ms < i64(h.o.bound_ms) { return }
		// (no answer within the bound: the plugin is said not to respond; one more ask may go, its rows as they are
		// wanted now, and the late answer is dropped)
		lz.asked = {}
	}
	// (the rows in view first, then the margin's)
	from := -1
	for i in first ..< last { if a, _ := lazy_row(lz, i); a == nil { from = i; break } }
	if from < 0 { for i in want_from ..< want_to { if a, _ := lazy_row(lz, i); a == nil { from = i; break } } }
	if from < 0 { return }
	to := from + 1
	for to < want_to && to - from < plugin_api.ROWS_MAX_PER_ASK {
		if a, _ := lazy_row(lz, to); a != nil { break }
		to += 1
	}
	lz.seq += 1
	lz.asked = {seq = lz.seq, version = lz.version, from = from, to = to, keep_from = want_from, keep_to = want_to}
	lz.asked_ms = now
	lz.asks += 1
	lz.asked_most = max(lz.asked_most, to)
	queue_push(p, Message{kind = .Rows, view = strings.clone(r.view_id), key = strings.clone(lz.key), rows = lz.asked})
	wake_after(h, h.o.bound_ms + WAKE_MARGIN_MS)
}

// Rows came (event_run). True: the list is taken.
@(private)
lazy_take :: proc(r: ^View_Record, key: string, a: Rows_Ask, list: ^plugin_api.List) -> bool {
	context.allocator = runtime.heap_allocator()
	lz := r.lazies[key] or_else nil
	if lz == nil { return false }
	if a.seq == 0 || a.seq != lz.asked.seq || a.version != lz.version {
		lz.dropped += 1
		return false
	}
	ask := lz.asked
	lz.asked = {}
	// (a range that is not the ask's: the process says what it likes; rows no longer wanted: the person scrolled on)
	if a.from != ask.from || a.to != ask.to || a.to <= lz.want_from || a.from >= lz.want_to {
		lz.dropped += 1
		return false
	}
	answer := Rows_Answer{list = list, from = a.from, to = a.to}
	if list != nil {
		// (one column per row, in order, and nothing else: anything else is no answer of list_write_rows')
		answer.starts = make([]int, a.to - a.from, runtime.heap_allocator())
		nodes := list.nodes[:]
		i, k := 0, 0
		for i < len(nodes) && k < len(answer.starts) && nodes[i].kind == .Column {
			answer.starts[k] = i
			k += 1
			skip(nodes, &i)
		}
		if k != len(answer.starts) || i != len(nodes) {
			delete(answer.starts, runtime.heap_allocator())
			lz.dropped += 1
			return false
		}
	}
	append(&lz.answers, answer)
	return true
}

@(private)
lazy_retire :: proc(lz: ^Lazy, i: int) {
	append(&lz.retired, Rows_Retired{answer = lz.answers[i], build = lz.builds})
	unordered_remove(&lz.answers, i)
}

// The answers let go of two builds ago or more: freed, and the state of their fields and boxes that are not wanted
// again since.
@(private)
lazy_free_retired :: proc(r: ^View_Record, lz: ^Lazy) {
	for i := len(lz.retired) - 1; i >= 0; i -= 1 {
		t := lz.retired[i]
		if t.build + 2 > lz.builds { continue }
		lazy_controls_drop(r, lz, t.answer.from, t.answer.to, false)
		answer_free(t.answer)
		unordered_remove(&lz.retired, i)
	}
}

// The host's state of the fields and boxes of rows `from ..< to` (keys `<list>~<row>...`), those not wanted now, or
// all of them with `all`.
@(private)
lazy_controls_drop :: proc(r: ^View_Record, lz: ^Lazy, from, to: int, all: bool) {
	prefix := strings.concatenate({lz.key, "~"}, context.temp_allocator)
	gone := make([dynamic]string, context.temp_allocator)
	for k in r.controls {
		i, ok := row_of_key(k, prefix)
		if !ok || i < from || i >= to { continue }
		if all || i < lz.want_from || i >= lz.want_to { append(&gone, k) }
	}
	for k in gone {
		c := r.controls[k]
		delete_key(&r.controls, k)
		ui.line_edit_destroy(&c.edit)
		free(c)
		delete(k)
	}
}

// The row of a key under a lazy list (`<list>~<row>`, then '/', '~', or the end; a handler's key ends with "\x1f...").
// False: the key is not under it.
@(private)
row_of_key :: proc(key, prefix: string) -> (row: int, ok: bool) {
	if !strings.has_prefix(key, prefix) { return }
	rest := key[len(prefix):]
	end := strings.index_any(rest, "/~\x1f")
	if end < 0 { end = len(rest) }
	if end == 0 { return }
	n, good := strconv.parse_int(rest[:end], 10)
	return n, good && n >= 0
}
