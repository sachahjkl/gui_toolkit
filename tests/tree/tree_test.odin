// The tree view (ui.tree, ui.file_tree; src/md/features/tree-view.md) in a window of its own. What breaks first: a row
// indented by steps of the spacing scale instead of pixels (plume's side tree: names pushed off to the right); a tree
// of 100 000 rows that builds them all; the cursor lost when rows open above it; a reveal of a row not built; a
// screen reader that reads no level; a folder read on the interface's thread; a change on disk never seen.
//   odin run tools/run_tests -- tree
package tree_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import lucide "gt:lucide"
import "gt:testkit"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") PANEL_PX :: 300
@(private = "file") LARGE :: 100_000
// Rows a view of the window's height builds at most, with its margins.
@(private = "file") BUILT_MAX :: 200
@(private = "file") BOUND :: 20 * time.Second
// A pixel of rounding between a part's place and the sum of its sizes.
@(private = "file") SLACK_PX :: 1.01

////////////////////////////////
// A small tree of the program's

@(private = "file")
Node :: struct {
	id:     u64,
	parent: u64,   // 0: the top level
	label:  string,
	branch: bool,
}

@(private = "file")
NODES := [?]Node{
	{1, 0, "alpha", true},
	{2, 1, "a one", false},
	{3, 1, "a two", true},
	{4, 3, "a two x", false},
	{5, 0, "beta", false},
	{6, 0, "gamma", true},
	{7, 6, "g one", false},
}

@(private = "file")
App :: struct {
	t:       ui.Tree,
	nodes:   []Node,
	rows:    [dynamic]ui.Tree_Row,
	version: u64,
	seen:    u64,
	large:   bool,       // LARGE rows, all open, made once
	chosen:  [dynamic]u64,
	trailing: string,    // every row's text at its end
}

@(private = "file")
rows_make :: proc(app: ^App) {
	clear(&app.rows)
	if app.large {
		// (depths 0, 1, 2, 3, 0, 1...: every row but a leaf at depth 3 is a branch with one child)
		for i in 0 ..< LARGE {
			d := i % 4
			append(&app.rows, ui.Tree_Row{id = u64(i + 1), depth = d, label = "row", branch = d < 3})
		}
		return
	}
	add :: proc(app: ^App, parent: u64, depth: int) {
		for n in app.nodes {
			if n.parent != parent { continue }
			append(&app.rows, ui.Tree_Row{id = n.id, depth = depth, label = n.label, branch = n.branch, icon = n.branch ? lucide.FOLDER : ""})
			if n.branch && ui.tree_is_open(&app.t, n.id) { add(app, n.id, depth + 1) }
		}
	}
	add(app, 0, 0)
}

@(private = "file")
build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	if app.version == 0 || (!app.large && app.seen != app.t.open_version) {
		rows_make(app)
		app.version += 1
		app.seen = app.t.open_version
	}
	ui.next({width = ui.px(PANEL_PX), height = ui.fill()})
	if shown, ok := ui.tree("###tree", &app.t, app.rows[:], app.version); ok {
		for i in shown.first ..< shown.last { ui.tree_row(&app.t, i, {trailing = app.trailing}) }
	}
	if app.t.chosen >= 0 { append(&app.chosen, app.rows[app.t.chosen].id) }
}

@(private = "file")
app_destroy :: proc(app: ^App) {
	ui.tree_destroy(&app.t)
	delete(app.rows)
	delete(app.chosen)
}

@(private = "file")
start :: proc(t: ^testing.T, app: ^App) -> ^session.Session {
	app.nodes = NODES[:]
	s := session.start(t, {build = build, user = app, size = {700, 500}})
	session.frames(s, 3)
	return s
}

@(private = "file")
row_box :: proc(s: ^session.Session, i: int) -> ^ui.Box { return session.find(s, fmt.tprintf("lrow_%d", i)) }

@(private = "file")
row_index :: proc(app: ^App, id: u64) -> int {
	for r, i in app.rows { if r.id == id { return i } }
	return -1
}

// The rows a list built: its children named lrow_.
@(private = "file")
built_rows :: proc(list: ^ui.Box) -> (n: int) {
	for c := list.first; c != nil; c = c.next { if strings.has_prefix(c.name, "lrow_") { n += 1 } }
	return
}

////////////////////////////////

@(test)
rows_at_depth_zero_start_at_the_left_plus_the_chevron :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app)
	ui.tree_set_open(&app.t, 1, true)
	ui.tree_set_open(&app.t, 3, true)
	session.frames(s, 3)
	list := session.get(s, "tree")
	em := list.font_size
	top := session.get(s, "icon", within = row_box(s, 0))
	edge, chevron, indent := f32(int(em * ui.TREE_EDGE_EM + 0.5)), f32(int(em * ui.TREE_CHEVRON_EM + 0.5)), f32(int(em * ui.TREE_INDENT_EM + 0.5))
	testing.expectf(t, abs(top.rect.min.x - (list.rect.min.x + edge + chevron)) <= SLACK_PX, "depth 0's icon at %v, the list at %v", top.rect.min.x, list.rect.min.x)
	// (each level moves the row by one indent, in pixels: never by a step of the spacing scale)
	one := session.get(s, "icon", within = row_box(s, 2))   // "a two", depth 1
	testing.expect_value(t, app.rows[2].depth, 1)
	testing.expectf(t, abs(one.rect.min.x - top.rect.min.x - indent) <= SLACK_PX, "depth 1's icon %v after depth 0's", one.rect.min.x - top.rect.min.x)
	// a leaf with no icon: its label where a branch's icon starts, after the chevron's cell
	leaf := session.get(s, "label", within = row_box(s, 3))   // "a two x", depth 2
	testing.expect_value(t, app.rows[3].depth, 2)
	testing.expectf(t, abs(leaf.rect.min.x - (list.rect.min.x + edge + 2 * indent + chevron)) <= SLACK_PX, "depth 2's label at %v", leaf.rect.min.x - list.rect.min.x)
	// the label takes the rest of the row
	label := session.get(s, "label", within = row_box(s, 0))
	testing.expect(t, abs(label.rect.min.x - top.rect.max.x) <= SLACK_PX)
	testing.expect(t, abs(label.rect.max.x - row_box(s, 0).rect.max.x) <= SLACK_PX)
}

// A git letter at a row's end takes its text's width: the label takes the rest of the row, up to it (a name cut while
// there was room before the letter: the letter's box padded on both sides).
@(test)
a_label_takes_the_row_up_to_the_trailing_text :: proc(t: ^testing.T) {
	app: App
	app.trailing = "U"
	defer app_destroy(&app)
	s := start(t, &app)
	row := row_box(s, 0)
	label := session.get(s, "label", within = row)
	end := session.get(s, "trailing", within = row)
	testing.expectf(t, end.rect.max.x - end.rect.min.x <= end.text_dim.x + SLACK_PX, "the trailing text's box is %v wide for a text of %v", end.rect.max.x - end.rect.min.x, end.text_dim.x)
	testing.expectf(t, abs(label.rect.max.x - end.rect.min.x) <= SLACK_PX, "the label ends at %v, the trailing text starts at %v", label.rect.max.x, end.rect.min.x)
	testing.expect(t, end.rect.max.x < row.rect.max.x, "an inset after the trailing text")
	// a name a filter lit (rich text on one line), a little too wide: cut between letters as a label is, never back
	// at the break after its "-"
	name := []ui.Rich_Run{{text = "tree"}, {text = "-view.md"}}
	c := ui.Rich_Context{fonts = s.state.fonts, base_font = label.font, base_size = label.font_size}
	whole := ui.rich_layout(name, c, 0)
	defer ui.rich_layout_destroy(&whole)
	one := ui.rich_layout(name, c, whole.size.x - 2, max_lines = 1)
	defer ui.rich_layout_destroy(&one)
	testing.expect(t, len(one.lines) == 1 && one.truncated && one.lines[0].ellipsis_x > 0, "a name too wide by a little ends with an ellipsis")
	testing.expectf(t, one.lines[0].end > len("tree-v"), "the line keeps what fits: %d bytes of %d", one.lines[0].end, len("tree-view.md"))
	testing.expectf(t, one.lines[0].width <= whole.size.x - 2 + 0.01, "the line with its ellipsis fits (%v)", one.lines[0].width)
}

@(test)
a_tree_of_100k_rows_builds_only_those_in_view :: proc(t: ^testing.T) {
	app: App
	app.large = true
	defer app_destroy(&app)
	s := start(t, &app)
	list := session.get(s, "tree")
	n := built_rows(list)
	testing.expectf(t, n > 0 && n < BUILT_MAX, "%d rows built of %d", n, LARGE)
	session.click(s, "lrow_0")
	session.key(s, .End)
	session.frames(s, 4)
	testing.expect_value(t, app.t.sel, LARGE - 1)
	testing.expect(t, row_box(s, LARGE - 1) != nil)
	testing.expect(t, built_rows(session.get(s, "tree")) < BUILT_MAX)
	// Left from the last row (a leaf at depth 3) goes to its parent
	session.key(s, .Left)
	testing.expect_value(t, app.t.sel, LARGE - 2)
}

@(test)
the_keys_move_open_close_and_choose :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app)
	testing.expect_value(t, len(app.rows), 3)   // alpha, beta, gamma
	session.click(s, "lrow_0")                 // alpha: selected and opened
	testing.expect(t, ui.tree_is_open(&app.t, 1))
	testing.expect_value(t, len(app.rows), 5)
	session.key(s, .Right)                     // open: to its first child
	testing.expect_value(t, app.rows[app.t.sel].id, 2)
	session.key(s, .Down)                      // a two
	session.key(s, .Right)                     // opens it
	testing.expect(t, ui.tree_is_open(&app.t, 3))
	session.key(s, .Right)                     // to a two x
	testing.expect_value(t, app.rows[app.t.sel].id, 4)
	session.key(s, .Return)                    // a leaf: chosen
	testing.expect(t, len(app.chosen) == 1 && app.chosen[0] == 4)
	session.key(s, .Left)                      // a leaf: to its parent
	testing.expect_value(t, app.rows[app.t.sel].id, 3)
	session.key(s, .Left)                      // open: closes
	testing.expect(t, !ui.tree_is_open(&app.t, 3))
	session.key(s, .Left)                      // closed: to its parent
	testing.expect_value(t, app.rows[app.t.sel].id, 1)
	session.key(s, .Space)                     // a branch: closes
	testing.expect(t, !ui.tree_is_open(&app.t, 1))
	testing.expect_value(t, len(app.rows), 3)
	session.key(s, .End)
	testing.expect_value(t, app.rows[app.t.sel].id, 6)
	session.key(s, .Space)                     // gamma opens
	testing.expect(t, ui.tree_is_open(&app.t, 6))
	// type-ahead: "b" goes to beta
	session.type_text(s, "b")
	session.frames(s, 2)
	testing.expect_value(t, app.rows[app.t.sel].id, 5)
}

@(test)
the_cursor_follows_its_row_when_rows_open_above_it :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app)
	session.click(s, "lrow_2")                 // gamma, opened
	testing.expect_value(t, app.rows[app.t.sel].id, 6)
	ui.tree_set_open(&app.t, 1, true)          // alpha opens above it: two rows more
	session.frames(s, 3)
	testing.expect_value(t, app.rows[app.t.sel].id, 6)
	testing.expect_value(t, app.t.sel, 4)
}

@(test)
a_reveal_selects_a_row_out_of_view_and_brings_it_in :: proc(t: ^testing.T) {
	app: App
	app.large = true
	defer app_destroy(&app)
	s := start(t, &app)
	target := u64(LARGE / 2)
	ui.tree_reveal(&app.t, target)
	session.frames(s, 8)
	i := row_index(&app, target)
	testing.expect_value(t, app.t.sel, i)
	b := row_box(s, i)
	list := session.get(s, "tree")
	testing.expect(t, b != nil && b.rect.min.y >= list.rect.min.y - SLACK_PX && b.rect.max.y <= list.rect.max.y + SLACK_PX)
}

@(test)
a_screen_reader_reads_a_tree_with_levels :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app)
	ui.tree_set_open(&app.t, 1, true)
	session.frames(s, 3)
	list := session.get(s, "tree")
	testing.expect(t, list.a11y != nil && list.a11y.role == .Tree)
	// alpha: level 1, 1 of 3, expanded; "a two": level 2, 2 of 2, collapsed; beta: 2 of 3, no expanded state
	a := row_box(s, 0).a11y
	testing.expect(t, a != nil && a.role == .Tree_Item && a.level == 1 && a.position == 1 && a.set_size == 3 && a.expanded == true)
	two := row_box(s, 2).a11y
	testing.expect(t, two != nil && two.level == 2 && two.position == 2 && two.set_size == 2 && two.expanded == false)
	beta := row_box(s, 3).a11y
	testing.expect(t, beta != nil && beta.level == 1 && beta.position == 2 && beta.set_size == 3 && beta.expanded == nil)
}

////////////////////////////////
// The file tree

Files :: struct {
	t:         ui.File_Tree,
	chosen:    [dynamic]string,
	undo_next: bool,   // the next build puts the last trash back
}

files_build :: proc(s: ^session.Session) {
	f := (^Files)(s.user)
	if f.undo_next { ui.file_tree_undo(&f.t); f.undo_next = false }
	ui.next({width = ui.px(PANEL_PX), height = ui.fill()})
	if shown, ok := ui.file_tree("###files", &f.t); ok {
		for i in shown.first ..< shown.last { ui.file_tree_row(&f.t, i) }
	}
	if f.t.chosen >= 0 { append(&f.chosen, ui.file_tree_path(&f.t, f.t.chosen, runtime.heap_allocator())) }
}

files_destroy :: proc(f: ^Files) {
	ui.file_tree_destroy(&f.t)
	for p in f.chosen { delete(p, runtime.heap_allocator()) }
	delete(f.chosen)
}

write :: proc(root, rel: string, text := "") {
	path := strings.concatenate({root, "/", rel}, context.temp_allocator)
	if strings.has_suffix(rel, "/") {
		_ = os.make_directory_all(path)
		return
	}
	_ = os.write_entire_file(path, transmute([]u8)text)
}

// The labels of the rows, in order.
labels :: proc(f: ^Files) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r, i in f.t.file_rows {
		if i > 0 { strings.write_byte(&b, ',') }
		for _ in 0 ..< r.depth { strings.write_byte(&b, '>') }
		strings.write_string(&b, r.label)
	}
	return strings.to_string(b)
}

Wait_Labels :: struct { f: ^Files, want: string }

labels_are :: proc(s: ^session.Session, w: Wait_Labels) -> bool { return labels(w.f) == w.want }

@(test)
a_file_tree_lists_a_folder_off_the_interface_thread_and_follows_it :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "tree")
	write(dir, "b/")
	write(dir, "a/")
	write(dir, "a/inner.txt", "x")
	write(dir, "file10.txt", "x")
	write(dir, "file2.txt", "x")
	write(dir, ".hidden", "x")
	f: Files
	defer files_destroy(&f)
	ui.file_tree_set_root(&f.t, dir)
	s := session.start(t, {build = files_build, user = &f, size = {700, 500}})
	// folders first, then the natural order; the hidden file left out
	session.wait_until(s, Wait_Labels{&f, "a,b,file2.txt,file10.txt"}, labels_are, "the folder listed", BOUND)
	ui.file_tree_set_hidden(&f.t, true)
	session.wait_until(s, Wait_Labels{&f, "a,b,.hidden,file2.txt,file10.txt"}, labels_are, "the hidden file shown", BOUND)
	ui.file_tree_set_hidden(&f.t, false)
	// a folder opened is read
	session.click(s, "lrow_0")
	session.wait_until(s, Wait_Labels{&f, "a,>inner.txt,b,file2.txt,file10.txt"}, labels_are, "a folder opened", BOUND)
	// a file made on disk comes in its place
	write(dir, "a/c.txt", "x")
	session.wait_until(s, Wait_Labels{&f, "a,>c.txt,>inner.txt,b,file2.txt,file10.txt"}, labels_are, "a file made", BOUND)
	write(dir, "file3.txt", "x")
	session.wait_until(s, Wait_Labels{&f, "a,>c.txt,>inner.txt,b,file2.txt,file3.txt,file10.txt"}, labels_are, "a file made at the top", BOUND)
	// a file chosen gives its path
	session.click(s, "lrow_5")
	testing.expect(t, len(f.chosen) == 1 && f.chosen[0] == strings.concatenate({dir, "/file3.txt"}, context.temp_allocator))
}

// An open folder removed, then made again at its path (a build folder cleaned): its rows come back, and it is
// followed again.
@(test)
an_open_folder_removed_and_made_again_is_followed_again :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "tree")
	write(dir, "out/")
	write(dir, "out/old.txt", "x")
	write(dir, "z.txt", "x")
	f: Files
	defer files_destroy(&f)
	ui.file_tree_set_root(&f.t, dir)
	s := session.start(t, {build = files_build, user = &f, size = {700, 500}})
	session.wait_until(s, Wait_Labels{&f, "out,z.txt"}, labels_are, "the folder listed", BOUND)
	session.click(s, "lrow_0")
	session.wait_until(s, Wait_Labels{&f, "out,>old.txt,z.txt"}, labels_are, "out opened", BOUND)
	out := strings.concatenate({dir, "/out"}, context.temp_allocator)
	_ = os.remove_all(out)
	session.wait_until(s, Wait_Labels{&f, "z.txt"}, labels_are, "out removed", BOUND)
	write(dir, "out/")
	write(dir, "out/new.txt", "x")
	session.wait_until(s, Wait_Labels{&f, "out,>new.txt,z.txt"}, labels_are, "out made again, still open", BOUND)
	write(dir, "out/later.txt", "x")
	session.wait_until(s, Wait_Labels{&f, "out,>later.txt,>new.txt,z.txt"}, labels_are, "out followed again", BOUND)
}

@(test)
a_file_tree_reveals_a_path_in_folders_not_read_yet :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "tree")
	write(dir, "x/")
	write(dir, "x/y/")
	write(dir, "x/y/z/")
	write(dir, "x/y/z/deep.md", "x")
	write(dir, "top.md", "x")
	f: Files
	defer files_destroy(&f)
	ui.file_tree_set_root(&f.t, dir)
	s := session.start(t, {build = files_build, user = &f, size = {700, 500}})
	ui.file_tree_reveal(&f.t, strings.concatenate({dir, "/x/y/z/deep.md"}, context.temp_allocator))
	session.wait_until(s, Wait_Labels{&f, "x,>y,>>z,>>>deep.md,top.md"}, labels_are, "the folders opened", BOUND)
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		f := (^Files)(s.user)
		return f.t.sel == 3
	}, "the row selected", BOUND)
}

// The row named `label` (-1: none).
row_named :: proc(f: ^Files, label: string) -> string {
	for r, i in f.t.file_rows { if r.label == label { return fmt.tprintf("lrow_%d", i) } }
	return "lrow_none"
}

@(test)
the_filter_finds_names_in_folders_not_read_and_gives_back_the_open_folders :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "tree")
	for rel in ([]string{"a/", "a/inner.txt", "b/", "b/deep/", "b/deep/needle.md", "c.txt", ".git/", "ignored/", "ignored/needle.txt", "keep/", "keep/needle.txt"}) { write(dir, rel, "x") }
	write(dir, ".gitignore", "ignored/\n")
	f: Files
	defer files_destroy(&f)
	ui.file_tree_set_root(&f.t, dir)
	s := session.start(t, {build = files_build, user = &f, size = {700, 500}})
	session.wait_until(s, Wait_Labels{&f, "a,b,ignored,keep,c.txt"}, labels_are, "the folder listed", BOUND)
	session.click(s, "lrow_0")
	session.wait_until(s, Wait_Labels{&f, "a,>inner.txt,b,ignored,keep,c.txt"}, labels_are, "a opened", BOUND)
	session.key(s, .F, {.Ctrl})
	session.type_text(s, "needle")
	// (b/deep was never read; ignored/ is the repository's ignored folder)
	session.wait_until(s, Wait_Labels{&f, "b,>deep,>>needle.md,keep,>needle.txt"}, labels_are, "what the filter found", BOUND)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !(^Files)(s.user).t.searching }, "the search's end", BOUND)
	testing.expect_value(t, len(f.t.matches), 2)
	// the field takes the row; the count is inside its end
	field := session.get(s, "ft_filter")
	count := session.find_text(s, "2 found")
	tree := session.get(s, "files")
	testing.expect(t, count != nil && count.rect.min.x >= field.rect.min.x && count.rect.max.x <= field.rect.max.x, "the count inside the field")
	testing.expectf(t, field.rect.max.x - field.rect.min.x >= (tree.rect.max.x - tree.rect.min.x) * 0.9, "the field %v wide in a tree %v wide", field.rect.max.x - field.rect.min.x, tree.rect.max.x - tree.rect.min.x)
	session.key(s, .Escape)
	session.wait_until(s, Wait_Labels{&f, "a,>inner.txt,b,ignored,keep,c.txt"}, labels_are, "the open folders of before", BOUND)
	testing.expect(t, !f.t.filter_open)
	// with the repository's ignored files
	f.t.gitignored = true
	session.click(s, "lrow_0")
	session.key(s, .F, {.Ctrl})
	session.type_text(s, "needle")
	session.wait_until(s, Wait_Labels{&f, "b,>deep,>>needle.md,ignored,>needle.txt,keep,>needle.txt"}, labels_are, "the ignored folder found too", BOUND)
}

@(test)
the_acts_copy_duplicate_rename_and_paste_on_the_disk :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "tree")
	write(dir, "docs/")
	write(dir, "a.txt", "hello")
	f: Files
	defer files_destroy(&f)
	ui.file_tree_set_root(&f.t, dir)
	s := session.start(t, {build = files_build, user = &f, size = {700, 500}})
	session.wait_until(s, Wait_Labels{&f, "docs,a.txt"}, labels_are, "the folder listed", BOUND)
	a_txt := strings.concatenate({dir, "/a.txt"}, context.temp_allocator)
	// copy the path
	session.click(s, "lrow_1")
	session.key(s, .C, {.Alt, .Shift})
	testing.expect_value(t, session.clipboard(s), a_txt)
	// duplicate from the menu
	session.click(s, "lrow_1", .Right)
	session.click_text(s, "Duplicate")
	session.wait_until(s, Wait_Labels{&f, "docs,a copy.txt,a.txt"}, labels_are, "the copy", BOUND)
	testing.expect(t, os.exists(strings.concatenate({dir, "/a copy.txt"}, context.temp_allocator)))
	// rename in place: F2, the stem replaced, Enter
	session.click(s, row_named(&f, "a copy.txt"))
	session.key(s, .F2)
	session.type_text(s, "b")
	session.key(s, .Return)
	session.wait_until(s, Wait_Labels{&f, "docs,a.txt,b.txt"}, labels_are, "the rename", BOUND)
	// a rename onto a name taken: said in a toast, nothing changed
	session.click(s, row_named(&f, "b.txt"))
	session.key(s, .F2)
	session.type_text(s, "a")
	session.key(s, .Return)
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		for x in s.state.toasts { if x.alive && x.kind == .Bad { return true } }
		return false
	}, "the toast of the refused rename", BOUND)
	testing.expect(t, os.exists(strings.concatenate({dir, "/b.txt"}, context.temp_allocator)))
	// copy, then paste into docs
	session.click(s, row_named(&f, "a.txt"))
	session.key(s, .C, {.Ctrl})
	session.click(s, "lrow_0")   // docs, opened and selected
	session.key(s, .V, {.Ctrl})
	session.wait_until(s, Wait_Labels{&f, "docs,>a.txt,a.txt,b.txt"}, labels_are, "the paste", BOUND)
	// a new folder from the menu of the tree's empty part: its name edited at once
	session.click_at(s, {100, 400}, .Right)
	session.click_text(s, "New folder")
	session.wait_until(s, proc(s: ^session.Session) -> bool { return (^Files)(s.user).t.renaming }, "the new folder's name edited", BOUND)
	session.frames(s, 2)   // (the field built: it has the keyboard)
	session.type_text(s, "made")
	session.key(s, .Return)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return strings.contains(labels((^Files)(s.user)), "made") }, "the folder named", BOUND)
	testing.expect(t, os.is_dir(strings.concatenate({dir, "/made"}, context.temp_allocator)))
}

// A name the system refuses, or would change, is caught before the rename: each system's rules, Windows' from Linux too.
@(test)
a_name_is_checked_by_each_system_s_rules :: proc(t: ^testing.T) {
	cases := []struct { name: string, windows: bool, want: ui.File_Name_Problem }{
		{"notes.txt", false, .None},
		{"notes.txt", true, .None},
		{"  ", false, .Empty},
		{"..", false, .Dots},
		{"a/b", false, .Separator},
		{"a\\b", false, .None},          // (a backslash is a letter of a name on Linux)
		{"a\\b", true, .Separator},
		{"a\x00b", false, .Control},
		{"tab\there", true, .Control},
		{"what?", false, .None},
		{"what?", true, .Windows_Char},
		{"a:b", true, .Windows_Char},
		{"end.", true, .Windows_End},
		{"end ", true, .Windows_End},
		{"end.", false, .None},
		{"CON", true, .Windows_Device},
		{"nul.txt", true, .Windows_Device},
		{"Com7.log", true, .Windows_Device},
		{"lpt0", true, .Windows_Device},
		{"nul .txt", true, .Windows_Device},
		{"CONIN$", true, .Windows_Device},
		{"console", true, .None},
		{"com10", true, .None},
		{"CON", false, .None},
	}
	for c in cases {
		got := ui.file_name_problem(c.name, c.windows)
		testing.expectf(t, got == c.want, "%q (Windows %v): %v, want %v", c.name, c.windows, got, c.want)
	}
}

// A rename that changes only the case of a name never replaces another entry: on a disk that tells case apart, "A.txt"
// and "a.txt" are two files.
@(test)
a_case_rename_never_replaces_another_file :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "tree")
	write(dir, "A.txt", "upper")
	write(dir, "a.txt", "lower")
	lower := strings.concatenate({dir, "/a.txt"}, context.temp_allocator)
	upper := strings.concatenate({dir, "/A.txt"}, context.temp_allocator)
	data, _ := os.read_entire_file(lower, context.temp_allocator)
	if string(data) != "lower" { return }   // (a disk that ignores case: one file, nothing to test)
	f: Files
	defer files_destroy(&f)
	ui.file_tree_set_root(&f.t, dir)
	s := session.start(t, {build = files_build, user = &f, size = {700, 500}})
	session.wait_until(s, Wait_Labels{&f, "A.txt,a.txt"}, labels_are, "the folder listed", BOUND)
	session.click(s, row_named(&f, "A.txt"))
	session.key(s, .F2)
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "a.txt")
	session.key(s, .Return)
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		for x in s.state.toasts { if x.alive && x.kind == .Bad { return true } }
		return false
	}, "the toast of the refused rename", BOUND)
	kept, _ := os.read_entire_file(lower, context.temp_allocator)
	testing.expect_value(t, string(kept), "lower")
	testing.expect(t, os.exists(upper))
}

// A folder's duplicate has no extension cut from its name; a folder dropped on its own row does nothing and says
// nothing.
@(test)
a_folder_s_duplicate_and_a_drop_on_itself :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "tree")
	write(dir, "v1.2/")
	write(dir, "v1.2/in.txt", "x")
	f: Files
	defer files_destroy(&f)
	ui.file_tree_set_root(&f.t, dir)
	s := session.start(t, {build = files_build, user = &f, size = {700, 500}})
	session.wait_until(s, Wait_Labels{&f, "v1.2"}, labels_are, "the folder listed", BOUND)
	session.click(s, "lrow_0", .Right)
	session.click_text(s, "Duplicate")
	session.wait_until(s, Wait_Labels{&f, "v1.2,v1.2 copy"}, labels_are, "the folder's copy", BOUND)
	testing.expect(t, os.exists(strings.concatenate({dir, "/v1.2 copy/in.txt"}, context.temp_allocator)))
	// (a drag that ends on the row it started from)
	c := session.center(session.get(s, "lrow_0"))
	session.drag(s, c, c + {40, 0})
	session.frames(s, 10)
	for x in s.state.toasts { testing.expect(t, !(x.alive && x.kind == .Bad), "no toast for a drop on itself") }
	testing.expect(t, os.exists(strings.concatenate({dir, "/v1.2/in.txt"}, context.temp_allocator)))
}

// A move that the system refuses for another reason than another volume (a folder that cannot be written) copies
// nothing: no copy is left beside the original.
@(test)
a_refused_move_copies_nothing :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux { return }
	dir := testkit.temp_folder(t, "tree")
	write(dir, "into/")
	write(dir, "locked/")
	write(dir, "locked/file.txt", "x")
	locked := strings.concatenate({dir, "/locked"}, context.temp_allocator)
	// (read and searched, not written: its entries cannot be renamed out of it)
	_ = os.chmod(locked, {.Read_User, .Execute_User})
	defer _ = os.chmod(locked, {.Read_User, .Write_User, .Execute_User})
	probe := strings.concatenate({locked, "/probe"}, context.temp_allocator)
	if os.write_entire_file(probe, []u8{}) == nil { return }   // (root writes anyway: nothing to test)
	f: Files
	defer files_destroy(&f)
	ui.file_tree_set_root(&f.t, dir)
	s := session.start(t, {build = files_build, user = &f, size = {700, 500}})
	session.wait_until(s, Wait_Labels{&f, "into,locked"}, labels_are, "the folder listed", BOUND)
	session.click(s, "lrow_1")
	session.wait_until(s, Wait_Labels{&f, "into,locked,>file.txt"}, labels_are, "locked opened", BOUND)
	session.drag(s, session.center(session.get(s, "lrow_2")), session.center(session.get(s, "lrow_0")))
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		for x in s.state.toasts { if x.alive && x.kind == .Bad { return true } }
		return false
	}, "the toast of the refused move", BOUND)
	testing.expect(t, !os.exists(strings.concatenate({dir, "/into/file.txt"}, context.temp_allocator)), "no copy left")
	testing.expect(t, os.exists(strings.concatenate({locked, "/file.txt"}, context.temp_allocator)))
}

@(test)
a_row_dragged_onto_a_folder_moves_its_file :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "tree")
	write(dir, "into/")
	write(dir, "moved.txt", "x")
	f: Files
	defer files_destroy(&f)
	ui.file_tree_set_root(&f.t, dir)
	s := session.start(t, {build = files_build, user = &f, size = {700, 500}})
	session.wait_until(s, Wait_Labels{&f, "into,moved.txt"}, labels_are, "the folder listed", BOUND)
	from := session.center(session.get(s, "lrow_1"))
	to := session.center(session.get(s, "lrow_0"))
	session.drag(s, from, to)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !strings.contains(labels((^Files)(s.user)), ",moved.txt") || strings.contains(labels((^Files)(s.user)), ">moved") }, "the move", BOUND)
	session.frames(s, 5)
	testing.expect(t, os.exists(strings.concatenate({dir, "/into/moved.txt"}, context.temp_allocator)))
	testing.expect(t, !os.exists(strings.concatenate({dir, "/moved.txt"}, context.temp_allocator)))
}

////////////////////////////////
// Pictures of a file tree, for a person to judge: -define:TREE_PICTURES=true writes them to the test's folder.

TREE_PICTURES :: #config(TREE_PICTURES, false)
@(private = "file") PICTURE_DPI :: 1.5

@(private = "file")
picture_build :: proc(s: ^session.Session) {
	f := (^Files)(s.user)
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.parent(ui.build_box({}, "###window")) {
		ui.next({width = ui.px(PANEL_PX), height = ui.fill(), axis = .Y, bg = ui.color("well")})
		if ui.parent(ui.build_box({.Draw_Background}, "###panel")) {
			ui.next({width = ui.fill(), height = ui.px(em * 2.2), text_pad = em * 0.7})
			if ui.tags("weak") { ui.build_box({.Draw_Text}, "GT-PROJECT###head") }
			ui.next({width = ui.fill(), height = ui.fill()})
			if shown, ok := ui.file_tree("###files", &f.t); ok {
				for i in shown.first ..< shown.last {
					o: ui.Tree_Row_Options
					switch f.t.file_rows[i].label {
					case "tree.odin":      o.trailing, o.trailing_tag = "M", "warn"
					case "file_tree.odin": o.trailing, o.trailing_tag = "U", "good"
					case "tree-view.md":   o.trailing, o.trailing_tag = "U", "good"
					}
					ui.file_tree_row(&f.t, i, o)
				}
			}
		}
		ui.next({width = ui.px(1), height = ui.fill(), bg = ui.color("border")})
		ui.build_box({.Draw_Background}, "###rule")
		ui.next({width = ui.fill(), height = ui.fill(), bg = ui.color("background")})
		ui.build_box({.Draw_Background}, "###document")
	}
}

@(test)
pictures_of_a_file_tree :: proc(t: ^testing.T) {
	when !TREE_PICTURES { return }
	dir := testkit.temp_folder(t, "project")
	for rel in ([]string{
		".git/", ".github/", ".github/workflows/", ".github/workflows/ci.yml", ".gitignore",
		"docs/", "docs/getting-started.md", "docs/file-browser.md", "docs/screenshots/", "docs/screenshots/tree.png",
		"src/", "src/fsx/", "src/fsx/watch.odin", "src/md/", "src/md/features/", "src/md/features/tree-view.md",
		"src/md/features/file-browser.md", "src/md/README.md", "src/ui/", "src/ui/file_icon.odin", "src/ui/file_tree.odin",
		"src/ui/list.odin", "src/ui/tree.odin", "src/ui/vlist.odin", "src/ui/a_name_far_too_long_for_the_width_of_this_panel_of_files.odin",
		"tests/", "tests/tree/", "tests/tree/tree_test.odin", "tests/tree/tree_trash_linux_test.odin", "tools/", "tools/tree_sitter/", "tools/tree_sitter/grammar.js", "build.sh", "CHANGELOG.md", "config.toml", "data.json", "flake.lock", "flake.nix", "icon.png",
		"LICENSE", "notes 2.txt", "notes 10.txt", "README.md", "release.tar.gz",
	}) { write(dir, rel, "x") }
	for light in ([]bool{false, true}) {
		f: Files
		defer files_destroy(&f)
		ui.file_tree_set_root(&f.t, dir)
		ui.file_tree_reveal(&f.t, strings.concatenate({dir, "/src/md/features/tree-view.md"}, context.temp_allocator))
		s := session.start(t, {build = picture_build, user = &f, size = {int(900 * PICTURE_DPI), int(560 * PICTURE_DPI)}, dpi_scale = PICTURE_DPI, palette = ui.palette_of("Midnight", light)})
		session.wait_until(s, proc(s: ^session.Session) -> bool { return (^Files)(s.user).t.sel >= 0 }, "the first reveal", BOUND)
		open := strings.concatenate({dir, "/src/ui/tree.odin"}, context.temp_allocator)
		ui.file_tree_set_open_file(&f.t, open)
		ui.file_tree_reveal(&f.t, open)
		session.wait_until(s, proc(s: ^session.Session) -> bool {
			f := (^Files)(s.user)
			return f.t.sel >= 0 && f.t.file_rows[f.t.sel].label == "tree.odin"
		}, "the open file revealed", BOUND)
		session.click(s, strings.concatenate({"lrow_", fmt.tprint(row_of(&f, "docs"))}, context.temp_allocator))   // docs opened
		session.click(s, strings.concatenate({"lrow_", fmt.tprint(row_of(&f, "tree.odin"))}, context.temp_allocator))
		session.hover(s, strings.concatenate({"lrow_", fmt.tprint(row_of(&f, "list.odin"))}, context.temp_allocator))
		session.frames(s, 30)
		session.save_png(s, light ? "file_tree_light" : "file_tree_dark")
		if light { continue }
		// the menu of a row
		session.click(s, strings.concatenate({"lrow_", fmt.tprint(row_of(&f, "file_tree.odin"))}, context.temp_allocator), .Right)
		session.frames(s, 20)
		session.save_png(s, "file_tree_menu")
		session.key(s, .Escape)
		session.frames(s, 10)
		// the filter: names found in folders never opened
		session.click(s, strings.concatenate({"lrow_", fmt.tprint(row_of(&f, "tree.odin"))}, context.temp_allocator))
		session.key(s, .F, {.Ctrl})
		session.type_text(s, "tree")
		session.wait_until(s, proc(s: ^session.Session) -> bool { f := (^Files)(s.user); return !f.t.searching && len(f.t.matches) > 0 }, "the filter's search", BOUND)
		session.frames(s, 20)
		session.save_png(s, "file_tree_filter")
	}
}

@(private = "file")
row_of :: proc(f: ^Files, label: string) -> int {
	for r, i in f.t.file_rows { if r.label == label { return i } }
	return -1
}
