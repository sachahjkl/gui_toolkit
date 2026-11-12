// tk_diff: a unified diff read into lines (headers, hunks, their numbers, what changed in a line), two texts compared, the rows of a
// split view, the rows a view builds; then the widget over frames: a patch read once, only the rows in view built.
//   odin test tests/diff -vet -define:ODIN_TEST_THREADS=1 (Linux: -define:FONT_BACKEND=native)
package diff_test

import "core:fmt"
import "core:strings"
import "core:testing"
import diff "../../src/diff"
import "../../src/testkit/session"
import "../../src/ui"

// The lines of `patch` as "<sign><text>|" each.
@(private = "file")
signs :: proc(patch: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for l in diff.parse_lines(patch, context.temp_allocator) { fmt.sbprintf(&b, "%c%s|", diff.sign(l.kind), l.text) }
	return strings.to_string(b)
}

@(private = "file")
L :: proc(k: diff.Kind) -> diff.Line { return diff.Line{kind = k} }

////////////////////////////////
// Reading a patch

@(test)
a_line_that_looks_like_a_header_is_a_line :: proc(t: ^testing.T) {
	testing.expect_value(t, signs("--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n--- x\n+++ y\n z\n"), "--- x|+++ y| z|")
}

@(test)
what_between_writes_has_no_header_to_skip :: proc(t: ^testing.T) {
	testing.expect_value(t, signs(diff.between("-- x\nsame", "++ y\nsame", context.temp_allocator)), "--- x|+++ y| same|")
}

@(test)
a_changed_line_is_removed_then_added :: proc(t: ^testing.T) {
	testing.expect_value(t, diff.between("a\nb\nc", "a\nx\nc", context.temp_allocator), " a\n-b\n+x\n c\n")
}

@(test)
a_second_file_starts_with_its_headers :: proc(t: ^testing.T) {
	patch := "diff --git a/a b/a\nindex 1..2 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-one\n+two\ndiff --git a/b b/b\nindex 3..4 100644\n--- a/b\n+++ b/b\n@@ -5 +5 @@\n-three\n+four\n"
	testing.expect_value(t, signs(patch), "-one|+two|@|-three|+four|")
}

@(test)
a_git_patch_shows_only_its_lines :: proc(t: ^testing.T) {
	lines := diff.parse_lines("diff --git a/p.txt b/p.txt\nindex 26af6a8..43dd47e 100644\n--- a/p.txt\n+++ b/p.txt\n@@ -1 +1 @@\n-zero\n+index one\n\\ No newline at end of file\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0].kind, diff.Kind.Removed)
	testing.expect_value(t, lines[1].text, "index one")
}

@(test)
the_numbers_of_a_hunk_follow_its_lines :: proc(t: ^testing.T) {
	lines := diff.parse_lines("@@ -3,2 +7,2 @@\n a\n--- b\n+c\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[1].old_no, 4)
	testing.expect_value(t, lines[1].text, "-- b")
	testing.expect_value(t, lines[2].new_no, 8)
}

// Each hunk starts its numbers from its header; a line on one side has no number on the other; the gap between has none.
@(test)
a_hunk_s_lines_are_numbered_from_its_header :: proc(t: ^testing.T) {
	p := diff.parse("@@ -10,3 +20,3 @@\n a\n-b\n+B\n c\n@@ -40,2 +41,3 @@\n d\n+e\n f\n", context.temp_allocator)
	testing.expect(t, p.numbered)
	testing.expect_value(t, p.added, 2)
	testing.expect_value(t, p.removed, 1)
	Want :: struct { kind: diff.Kind, old_no, new_no: int }
	want := []Want{{.Same, 10, 20}, {.Removed, 11, 0}, {.Added, 0, 21}, {.Same, 12, 22}, {.Gap, 0, 0}, {.Same, 40, 41}, {.Added, 0, 42}, {.Same, 41, 43}}
	testing.expect_value(t, len(p.lines), len(want))
	for w, i in want {
		if i >= len(p.lines) { break }
		l := p.lines[i]
		testing.expectf(t, l.kind == w.kind && l.old_no == w.old_no && l.new_no == w.new_no, "line %d: %v %d %d, not %v", i, l.kind, l.old_no, l.new_no, w)
	}
}

@(test)
lines_without_hunks_have_no_numbers :: proc(t: ^testing.T) {
	p := diff.parse("-a\n+b\n", context.temp_allocator)
	testing.expect(t, !p.numbered)
	testing.expect_value(t, len(p.lines), 2)
}

@(test)
a_hunk_with_no_count_is_one_line :: proc(t: ^testing.T) {
	testing.expect_value(t, signs("--- a/a\n+++ b/a\n@@ -1 +1 @@\n-a\n+b\n--- a/b\n+++ b/b\n@@ -2 +2 @@\n-c\n+d\n"), "-a|+b|@|-c|+d|")
}

// (no count in its header: one line each, and those lines are lines, whatever they look like)
@(test)
a_hunk_of_one_line_holds_it :: proc(t: ^testing.T) {
	testing.expect_value(t, signs("--- a/a\n+++ b/a\n@@ -1 +1 @@\n--- x\n+++ y\n"), "--- x|+++ y|")
}

@(test)
a_hunk_that_only_removes_ends_on_its_count :: proc(t: ^testing.T) {
	testing.expect_value(t, signs("--- a/a\n+++ b/a\n@@ -1,1 +0,0 @@\n-a\n--- a/b\n+++ b/b\n@@ -0,0 +1,1 @@\n+b\n"), "-a|@|+b|")
}

// What two facing lines share at each end is plain; between is marked, never inside a character; nothing shared, nothing marked.
@(test)
what_changed_in_a_line_is_marked :: proc(t: ^testing.T) {
	p := diff.parse("-let x = 1;\n+let x = 22;\n-é1\n-same\n+é2\n+other\n", context.temp_allocator)
	testing.expect_value(t, p.lines[0].text[p.lines[0].lo:p.lines[0].hi], "1")
	testing.expect_value(t, p.lines[1].text[p.lines[1].lo:p.lines[1].hi], "22")
	testing.expect_value(t, p.lines[2].text[p.lines[2].lo:p.lines[2].hi], "1")
	testing.expect_value(t, p.lines[4].text[p.lines[4].lo:p.lines[4].hi], "2")
	testing.expect_value(t, p.lines[3].hi, p.lines[3].lo)
	q := diff.parse("-é\n+è\n", context.temp_allocator)   // (é and è share their first byte)
	testing.expect_value(t, q.lines[0].lo, 0)
}

////////////////////////////////
// The rows of a view

@(test)
a_changed_line_faces_itself :: proc(t: ^testing.T) {
	rows := diff.split_rows({L(.Same), L(.Removed), L(.Removed), L(.Added), L(.Same)}, context.temp_allocator)
	testing.expect_value(t, len(rows), 4)
	testing.expect_value(t, rows[0], diff.Row{0, 0})
	testing.expect_value(t, rows[1], diff.Row{1, 3})
	testing.expect_value(t, rows[2], diff.Row{2, -1})
	testing.expect_value(t, rows[3], diff.Row{4, 4})
}

@(test)
what_is_only_added_has_nothing_on_the_left :: proc(t: ^testing.T) {
	rows := diff.split_rows({L(.Added), L(.Added), L(.Gap), L(.Removed)}, context.temp_allocator)
	testing.expect_value(t, len(rows), 4)
	testing.expect_value(t, rows[0], diff.Row{-1, 0})
	testing.expect_value(t, rows[1], diff.Row{-1, 1})
	testing.expect_value(t, rows[2], diff.Row{2, 2})
	testing.expect_value(t, rows[3], diff.Row{3, -1})
}

@(test)
every_line_is_in_the_rows_once_on_its_side :: proc(t: ^testing.T) {
	lines := diff.parse_lines("@@ -1,4 +1,4 @@\n a\n-b\n-c\n+d\n e\n@@ -20,2 +20,3 @@\n f\n+g\n h\n", context.temp_allocator)
	rows := diff.split_rows(lines, context.temp_allocator)
	seen := make([]int, len(lines), context.temp_allocator)
	for r in rows {
		if r.left >= 0 { seen[r.left] += 1 }
		if r.right >= 0 && r.right != r.left { seen[r.right] += 1 }
	}
	for n in seen { testing.expect_value(t, n, 1) }
}

@(test)
what_is_built_is_what_shows_and_a_margin :: proc(t: ^testing.T) {
	M :: diff.VIEW_MARGIN_ROWS
	first, last := diff.visible_rows(0, 0, 200, 20, 20000)
	testing.expect_value(t, first, 0)
	testing.expect_value(t, last, 11 + M)
	first, last = diff.visible_rows(10000, 10000, 200, 20, 20000)
	testing.expect_value(t, first, 500 - M)
	testing.expect_value(t, last, 511 + M)
	first, last = diff.visible_rows(399900, 399900, 200, 20, 20000)
	testing.expect_value(t, last, 20000)
	first, last = diff.visible_rows(0, 0, 200, 20, 3)
	testing.expect_value(t, last, 3)
	first, last = diff.visible_rows(0, 0, 200, 0, 3)
	testing.expect_value(t, last, 0)
}

@(test)
where_the_view_goes_is_built_too :: proc(t: ^testing.T) {
	first, last := diff.visible_rows(0, 4000, 200, 20, 20000)
	testing.expect_value(t, first, 0)
	testing.expect_value(t, last, 211 + diff.VIEW_MARGIN_ROWS)
}

////////////////////////////////
// A doc, and the widget over frames

@(test)
a_doc_reads_its_patch_only_when_it_changes :: proc(t: ^testing.T) {
	d: diff.Doc
	defer diff.doc_destroy(&d)
	testing.expect(t, diff.doc_set(&d, "@@ -1 +1 @@\n-a\n+b\n"))
	first := raw_data(d.lines)
	testing.expect(t, !diff.doc_set(&d, strings.clone("@@ -1 +1 @@\n-a\n+b\n", context.temp_allocator)), "the same text: not read again")
	testing.expect(t, raw_data(d.lines) == first)
	testing.expect_value(t, d.version, 1)
	testing.expect(t, diff.doc_set(&d, "@@ -1 +1,2 @@\n-a\n+c\n+d\n"))
	testing.expect_value(t, d.version, 2)
	testing.expect_value(t, d.added, 2)
	testing.expect_value(t, len(d.rows), 2)
}

// A patch of LONG_LINES lines in a view of VIEW_H px: the frames build what shows, the patch is read once.
@(private = "file") LONG_LINES :: 5000
@(private = "file") VIEW_H :: 300

@(private = "file")
App :: struct {
	doc:    diff.Doc,
	patch:  string,
	layout: diff.Layout,
	reads:  int,
}

@(private = "file")
build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	// (a program hands its patch at each build: only a new text is read)
	if diff.doc_set(&app.doc, app.patch) { app.reads += 1 }
	ui.next({width = ui.px(600), height = ui.px(VIEW_H), axis = .Y})
	if ui.column(id = "###frame") { diff.view("###view", &app.doc, app.layout, {row_height = 20, selectable = true}) }
}

@(private = "file")
long_patch :: proc() -> string {
	b := strings.builder_make()   // (not the frames' temp memory: it outlives them)
	fmt.sbprintf(&b, "--- a/f\n+++ b/f\n@@ -1,%d +1,%d @@\n", LONG_LINES, LONG_LINES)
	for i in 0 ..< LONG_LINES {
		if i % 10 == 3 { fmt.sbprintf(&b, "-old %d\n+new %d\n", i, i) } else { fmt.sbprintf(&b, " line %d\n", i) }
	}
	return strings.to_string(b)
}

@(test)
a_patch_is_read_once_across_frames :: proc(t: ^testing.T) {
	app := App{patch = long_patch()}
	defer delete(app.patch)
	defer diff.doc_destroy(&app.doc)
	s := session.start(t, {build = build, user = &app, no_renderer = true})
	session.frames(s, 5)
	testing.expect_value(t, app.reads, 1)
	testing.expect_value(t, app.doc.version, 1)
	testing.expect(t, session.find(s, "l0") != nil, "the first row is built")
	testing.expect(t, session.find(s, fmt.tprintf("l%d", VIEW_H / 20 + diff.VIEW_MARGIN_ROWS + 5)) == nil, "a row far below the view is not")
	app.layout = .Split
	session.frames(s, 2)
	testing.expect_value(t, app.reads, 1)
	testing.expect(t, session.find(s, "r0") != nil, "a split row")
	testing.expect(t, session.find(s, "bar") != nil, "the line between the sides")
}
