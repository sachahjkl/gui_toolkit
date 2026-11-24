// The file browser (ui.file_dialog, docs/file-browser.md) on a fake source that answers when the test says (in order,
// late, never, refused, at once), and on the computer's files in a folder made in the temporary directory. What breaks
// first: a slow folder answering after the next one was asked; 100 000 entries; names of every kind of character;
// Save over a file; the dialog closed with a reading under way; an older search's late answer; the program's keys while
// the browser is open; a row's menu on a source that cannot rename nor trash, a rename and a trash's undo.
//   odin test tests/file_browser -collection:gt=src -vet -define:ODIN_TEST_THREADS=1 (Linux: -define:FONT_BACKEND=native)
//   -define:FILE_BROWSER_TIMING=true: a build of 100 000 entries is timed too (FILE_BROWSER_BUILD_BUDGET_MS)
package file_browser_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import desktop "gt:desktop"
import "gt:fsx"
import "gt:platform"
import png "gt:png"
import "gt:testkit/session"
import "gt:ui"

FILE_BROWSER_TIMING :: #config(FILE_BROWSER_TIMING, false)

// The frames a dialog takes to show (it is measured unseen first).
@(private = "file") SHOW_FRAMES :: 10
// The entries of the large folder.
@(private = "file") LARGE :: 100_000
// Frames that change nothing, after the large folder came.
@(private = "file") QUIET_FRAMES :: 20
@(private = "file") BOUND :: 20 * time.Second

////////////////////////////////
// A source that answers when the test says

@(private = "file")
Asked :: struct {
	path:  string,
	reply: ui.File_Reply,
}

// A search in subfolders asked of the fake source: answered when the test says (fake_found).
@(private = "file")
Asked_Find :: struct {
	folder: string,
	query:  string,
	limit:  int,
	reply:  ui.File_Reply,
}

@(private = "file")
Fake :: struct {
	folders: map[string][]ui.File_Entry,
	asked:   [dynamic]Asked,
	at_once: bool,   // answers in the call
	made:    [dynamic]string,
	finds:   [dynamic]Asked_Find,
	thumbs:  [dynamic]Asked,   // the thumbnails asked (answered when the test says)
	// a source that writes (fake_writes): its folder "/f", what it was asked, what its trash holds
	live:     [dynamic]ui.File_Entry,
	bin:      [dynamic]ui.File_Entry,
	names:    [dynamic]string,      // the names and tokens it made (freed with it)
	renamed:  [dynamic][2]string,   // (path, name)
	trashed:  [dynamic]string,
	restored: [dynamic]string,      // the tokens put back
}

@(private = "file")
fake_source :: proc(f: ^Fake, caps := ui.File_Caps{.Size, .Modified}, finds := false) -> ui.File_Source {
	src := ui.File_Source{
		user = f, caps = caps, separator = '/',
		list = proc(src: ^ui.File_Source, path: string, reply: ui.File_Reply) {
			f := (^Fake)(src.user)
			append(&f.asked, Asked{path = strings.clone(path, runtime.heap_allocator()), reply = reply})
			if f.at_once { fake_answer(f, len(f.asked) - 1) }
		},
		make_folder = proc(src: ^ui.File_Source, path: string, reply: ui.File_Reply) {
			f := (^Fake)(src.user)
			append(&f.made, strings.clone(path, runtime.heap_allocator()))
			ui.file_reply_made(reply)
		},
		// (asked only by the cards of the grid: the other tests' details ask nothing)
		thumbnail = proc(src: ^ui.File_Source, path: string, px: int, reply: ui.File_Reply) {
			f := (^Fake)(src.user)
			append(&f.thumbs, Asked{path = strings.clone(path, runtime.heap_allocator()), reply = reply})
		},
	}
	if finds {
		src.find = proc(src: ^ui.File_Source, folder, query: string, limit: int, reply: ui.File_Reply) {
			f := (^Fake)(src.user)
			a := runtime.heap_allocator()
			append(&f.finds, Asked_Find{folder = strings.clone(folder, a), query = strings.clone(query, a), limit = limit, reply = reply})
		}
	}
	return src
}

@(private = "file")
fake_found :: proc(f: ^Fake, i: int, entries: []ui.File_Entry) { ui.file_reply_found(f.finds[i].reply, entries) }

@(private = "file")
fake_answer :: proc(f: ^Fake, i: int) {
	a := f.asked[i]
	ui.file_reply_listed(a.reply, f.folders[a.path] or_else nil)
}

@(private = "file")
fake_destroy :: proc(f: ^Fake) {
	for a in f.asked { delete(a.path, runtime.heap_allocator()) }
	for m in f.made { delete(m, runtime.heap_allocator()) }
	for x in f.finds { delete(x.folder, runtime.heap_allocator()); delete(x.query, runtime.heap_allocator()) }
	for x in f.thumbs { delete(x.path, runtime.heap_allocator()) }
	delete(f.thumbs)
	a := runtime.heap_allocator()
	for x in f.names { delete(x, a) }
	for x in f.renamed { delete(x[0], a); delete(x[1], a) }
	for x in f.trashed { delete(x, a) }
	for x in f.restored { delete(x, a) }
	delete(f.live); delete(f.bin); delete(f.names); delete(f.renamed); delete(f.trashed); delete(f.restored)
	delete(f.asked)
	delete(f.made)
	delete(f.finds)
	delete(f.folders)
}

////////////////////////////////
// An application that asks for a dialog and keeps its answer

@(private = "file")
App :: struct {
	fake:     Fake,
	source:   ui.File_Source,
	local:    bool,                 // the computer's files (no source given)
	kind:     platform.File_Dialog_Kind,
	d:        platform.File_Dialog,
	ask:      bool,                 // the next build asks for the dialog
	answers:  int,
	status:   platform.Dialog_Status,
	paths:    [dynamic]string,
	// the program's own keys, read before the browser is built (as a program reads its shortcuts)
	watch:    bool,
	escapes:  int,   // key_press(.Escape) the program saw
	typed_q:  int,   // 'q' typed that the program took
}

@(private = "file")
build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	if app.watch {
		// (keys reach code outside a dialog: only the overlay's hold keeps them from the program)
		ui.set_keys_behind_dialogs(s.state, true)
		if ui.key_press(.Escape) { app.escapes += 1 }
		if ui.typed_take('q') { app.typed_q += 1 }
	}
	if app.ask {
		app.ask = false
		ui.file_dialog(s.state, app.kind, app.d, done, app, source = app.local ? nil : &app.source)
	}
}

@(private = "file")
done :: proc(r: platform.Dialog_Result, user: rawptr) {
	app := (^App)(user)
	app.answers += 1
	app.status = r.status
	for p in app.paths { delete(p, runtime.heap_allocator()) }
	clear(&app.paths)
	for p in r.paths { append(&app.paths, strings.clone(p, runtime.heap_allocator())) }
}

@(private = "file")
app_destroy :: proc(app: ^App) {
	fake_destroy(&app.fake)
	for p in app.paths { delete(p, runtime.heap_allocator()) }
	delete(app.paths)
}

// The dialog asked and shown.
@(private = "file")
open :: proc(s: ^session.Session, app: ^App, kind: platform.File_Dialog_Kind, d: platform.File_Dialog) {
	app.kind, app.d, app.ask = kind, d, true
	session.frames(s, SHOW_FRAMES)
}

@(private = "file")
counts :: proc(s: ^session.Session) -> ui.File_Picker_Counts { return ui.file_picker_counts(ui.file_dialog_picker(s.state)) }

@(private = "file")
start :: proc(t: ^testing.T, app: ^App) -> ^session.Session {
	app.source = fake_source(&app.fake)
	return session.start(t, {build = build, user = app, no_renderer = true, size = {1200, 800}})
}

@(private = "file")
F :: proc(name: string, kind := ui.File_Kind.File, size: i64 = 10) -> ui.File_Entry {
	return {name = name, kind = kind, size = kind == .Folder ? -1 : size, modified = 1_700_000_000_000}
}

////////////////////////////////
// The tests

// A folder that answers after the next one was asked says nothing: the folder shown is the last one asked, with its
// own entries. Enter enters a folder; Backspace goes up.
@(test)
a_late_answer_of_a_folder_left_is_dropped :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	a := []ui.File_Entry{F("docs", .Folder), F("top.txt")}
	docs := []ui.File_Entry{F("late.txt")}
	app.fake.folders["/a"] = a
	app.fake.folders["/a/docs"] = docs
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/a"})
	testing.expect_value(t, len(app.fake.asked), 1)
	fake_answer(&app.fake, 0)
	session.frames(s, 3)
	testing.expect_value(t, counts(s).rows_shown, 2)
	// (the list has the keyboard; its first row is the folder: folders first)
	session.key(s, .Down)
	session.key(s, .Return)
	testing.expect_value(t, counts(s).folder, "/a/docs")
	testing.expect_value(t, len(app.fake.asked), 2)
	session.key(s, .Backspace)
	testing.expect_value(t, counts(s).folder, "/a")
	testing.expect_value(t, len(app.fake.asked), 3)
	// the answer of /a/docs comes now: too late
	fake_answer(&app.fake, 1)
	session.frames(s, 3)
	testing.expect(t, session.find_text(s, "late.txt") == nil, "an answer of a folder left shows nothing")
	testing.expect_value(t, counts(s).entries, 0)
	fake_answer(&app.fake, 2)
	session.frames(s, 3)
	testing.expect_value(t, counts(s).folder, "/a")
	testing.expect_value(t, counts(s).rows_shown, 2)
	testing.expect(t, session.find_text(s, "top.txt") != nil)
}

// A folder that never answers: nothing at first (a fast folder does not flash), then a line that says it is read. The
// dialog closed meanwhile answers Cancelled; the answer that comes after it changes nothing.
@(test)
a_folder_that_never_answers :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/slow"] = []ui.File_Entry{F("x.txt")}
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/slow"})
	testing.expect(t, session.find_text(s, "Reading this folder") == nil, "not before FILE_BROWSER_SLOW_MS")
	session.advance(s, ui.FILE_PICKER_SLOW_MS + 50)
	testing.expect(t, session.find_text(s, "Reading this folder") != nil)
	session.click(s, "fb_cancel")
	testing.expect_value(t, app.answers, 1)
	testing.expect_value(t, app.status, platform.Dialog_Status.Cancelled)
	testing.expect(t, !counts(s).open)
	fake_answer(&app.fake, 0)   // (after the dialog closed: dropped)
	session.frames(s, 3)
	testing.expect_value(t, app.answers, 1)
	testing.expect_value(t, counts(s).entries, 0)
}

// A folder refused: the source's words and Try again, which asks again.
@(test)
a_refused_folder_says_so_and_tries_again :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/root"] = []ui.File_Entry{F("secret.txt")}
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/root"})
	ui.file_reply_failed(app.fake.asked[0].reply, "Not yours.", refused = true)
	session.frames(s, 3)
	testing.expect(t, session.find_text(s, "Not yours.") != nil)
	session.click(s, "empty_action0")
	testing.expect_value(t, len(app.fake.asked), 2)
	fake_answer(&app.fake, 1)
	session.frames(s, 3)
	testing.expect(t, session.find_text(s, "secret.txt") != nil)
}

// A folder that is not there any more: the dialog goes to its parent.
@(test)
a_missing_folder_goes_up :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/a"] = []ui.File_Entry{F("b", .Folder)}
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/a/gone"})
	ui.file_reply_failed(app.fake.asked[0].reply, "gone", missing = true)
	session.frames(s, 2)
	testing.expect_value(t, counts(s).folder, "/a")
	testing.expect_value(t, app.fake.asked[1].path, "/a")
}

// 100 000 entries: the rows are made once; a build that changes nothing filters, sorts and lays out nothing again.
@(test)
a_hundred_thousand_entries :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	entries := make([]ui.File_Entry, LARGE)
	defer {
		for e in entries { delete(e.name) }
		delete(entries)
	}
	for &e, i in entries { e = F(fmt.aprintf("file %06d.txt", i), size = i64(i)) }
	app.fake.folders["/big"] = entries
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/big"})
	fake_answer(&app.fake, 0)
	// (the rows in view measured, the list placed: then nothing more moves)
	session.frames(s, 8)
	testing.expect_value(t, counts(s).rows_shown, LARGE)
	before := counts(s)
	when FILE_BROWSER_TIMING { slowest: f64 }
	for _ in 0 ..< QUIET_FRAMES {
		session.frame(s)
		when FILE_BROWSER_TIMING { slowest = max(slowest, ui.build_metrics(s.state).build_ms) }
	}
	after := counts(s)
	testing.expect_value(t, after.rows_made, before.rows_made)
	testing.expect_value(t, after.rows_applied, before.rows_applied)
	testing.expect_value(t, after.list_layouts, before.list_layouts)
	when FILE_BROWSER_TIMING { testing.expectf(t, slowest < ui.FILE_PICKER_BUILD_BUDGET_MS, "a build took %.1f ms", slowest) }
	// the filter makes them again, once
	session.type_text(s, "042")
	testing.expect_value(t, counts(s).rows_applied, after.rows_applied + 1)
	testing.expect(t, counts(s).rows_shown > 0 && counts(s).rows_shown < LARGE)
}

// Names with spaces, Unicode, "%", quotes and "##": each is found by the filter and chosen as it is.
@(test)
names_of_every_kind_of_character :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	names := []string{"with space.txt", "ünïcødé ✓.md", "100%.txt", "quote\"s 'too'.txt", "a##b.txt"}
	list := make([]ui.File_Entry, len(names))
	defer delete(list)
	for n, i in names { list[i] = F(n) }
	app.fake.folders["/f"] = list
	app.fake.at_once = true
	s := start(t, &app)
	for n, i in names {
		open(s, &app, .Open, {start_dir = "/f"})
		session.type_text(s, n)
		session.key(s, .Return)
		testing.expectf(t, app.answers == i + 1, "%q chosen", n)
		testing.expect_value(t, app.status, platform.Dialog_Status.Chosen)
		if len(app.paths) == 1 { testing.expect_value(t, app.paths[0], fmt.tprintf("/f/%s", n)) }
	}
}

// Save over a file of the folder asks first; Cancel keeps the dialog, Replace answers. A name with no extension gets the
// type's.
@(test)
save_over_an_existing_file_asks :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("report.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Save, {start_dir = "/f", suggested_name = "report.txt", overwrite_prompt = true})
	session.click(s, "fb_act")
	session.frames(s, SHOW_FRAMES)
	testing.expect(t, session.find(s, "confirm_act") != nil, "the question")
	testing.expect_value(t, app.answers, 0)
	session.click(s, "confirm_cancel")
	session.frames(s, 2)
	testing.expect_value(t, app.answers, 0)
	testing.expect(t, counts(s).open)
	session.click(s, "fb_act")
	session.frames(s, SHOW_FRAMES)
	session.click(s, "confirm_act")
	testing.expect_value(t, app.answers, 1)
	if len(app.paths) == 1 { testing.expect_value(t, app.paths[0], "/f/report.txt") }
	// a new name: no question; the type's extension
	open(s, &app, .Save, {start_dir = "/f", suggested_name = "notes", overwrite_prompt = true, filters = {{name = "Text", patterns = {"*.txt"}}}})
	session.click(s, "fb_act")
	testing.expect_value(t, app.answers, 2)
	if len(app.paths) == 1 { testing.expect_value(t, app.paths[0], "/f/notes.txt") }
}

// Closed with a reading under way: the late answer is dropped, nothing crashes, nothing leaks.
@(test)
closed_with_a_reading_under_way :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("a.txt")}
	s := start(t, &app)
	open(s, &app, .Folder, {start_dir = "/f"})
	session.key(s, .Escape)
	testing.expect_value(t, app.answers, 1)
	testing.expect_value(t, app.status, platform.Dialog_Status.Cancelled)
	fake_answer(&app.fake, 0)
	ui.file_reply_failed(app.fake.asked[0].reply, "late")
	session.frames(s, 3)
	testing.expect(t, !counts(s).open)
	testing.expect_value(t, app.answers, 1)
}

// The keyboard: typing filters; Escape clears the filter first, then cancels.
@(test)
escape_clears_the_filter_then_cancels :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("alpha.txt"), F("beta.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/f"})
	session.type_text(s, "bet")
	testing.expect_value(t, counts(s).rows_shown, 1)
	session.key(s, .Escape)
	testing.expect_value(t, counts(s).rows_shown, 2)
	testing.expect(t, counts(s).open, "the first Escape clears the filter")
	session.key(s, .Escape)
	testing.expect(t, !counts(s).open)
	testing.expect_value(t, app.status, platform.Dialog_Status.Cancelled)
}

// Open with `multiple`: Ctrl+A selects every file, Open answers them all.
@(test)
several_files_are_opened :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("a.txt"), F("b.txt"), F("c.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/f", multiple = true})
	session.click(s, "lrow_0")
	session.key(s, .A, {.Ctrl})
	session.click(s, "fb_act")
	testing.expect_value(t, app.answers, 1)
	testing.expect_value(t, len(app.paths), 3)
	// Shift+Down selects from the anchor, the row clicked
	open(s, &app, .Open, {start_dir = "/f", multiple = true})
	session.click(s, "lrow_0")
	session.key(s, .Down, {.Shift})
	session.click(s, "fb_act")
	testing.expect_value(t, len(app.paths), 2)
}

// Folder: the folder selected, else the one shown.
@(test)
a_folder_is_chosen :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("sub", .Folder), F("x.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Folder, {start_dir = "/f"})
	session.click(s, "fb_act")
	if testing.expect_value(t, len(app.paths), 1) { testing.expect_value(t, app.paths[0], "/f") }
	open(s, &app, .Folder, {start_dir = "/f"})
	session.click(s, "lrow_0")
	session.click(s, "fb_act")
	if testing.expect_value(t, len(app.paths), 1) { testing.expect_value(t, app.paths[0], "/f/sub") }
}

// The program's places are listed, and a click on one goes there.
@(test)
the_programs_places :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.at_once = true
	s := start(t, &app)
	places := []platform.File_Place{{name = "Session one", path = "/p/one"}}
	open(s, &app, .Folder, {start_dir = "/f", places = places})
	testing.expect(t, session.find_text(s, "Session one") != nil)
	session.click_text(s, "Session one")
	testing.expect_value(t, counts(s).folder, "/p/one")
}

// New folder: its name typed in its row, made, then the folder read again.
@(test)
a_new_folder_is_made :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("x.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	app.source = fake_source(&app.fake, {.Size, .Modified, .Make_Folder})
	open(s, &app, .Folder, {start_dir = "/f"})
	session.click(s, "fb_new_folder")
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "made")
	session.key(s, .Return)
	if testing.expect_value(t, len(app.fake.made), 1) { testing.expect_value(t, app.fake.made[0], "/f/made") }
	testing.expect(t, len(app.fake.asked) >= 2, "the folder read again")
}

// The computer's files: a real folder in the temporary directory, its folder and its file with its size.
@(test)
the_local_source_lists_a_real_folder :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/gui_toolkit_file_browser_%d", fsx.temp_dir(context.temp_allocator), os.get_pid())
	fsx.remove_tree(root)
	fsx.make_dirs(fmt.tprintf("%s/sub folder", root))
	defer fsx.remove_tree(root)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/five.txt", root), transmute([]byte)string("12345")) == nil)
	app: App
	defer app_destroy(&app)
	app.local = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = root})
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.file_picker_counts(ui.file_dialog_picker(s.state)).rows_shown == 2 }, "the folder's two entries", BOUND)
	testing.expect(t, session.find_text(s, "sub folder") != nil)
	testing.expect(t, session.find_text(s, "five.txt") != nil)
	testing.expect(t, session.find_text(s, "5 B") != nil, "the file's size")
	session.click_text(s, "five.txt")
	session.click(s, "fb_act")
	if testing.expect_value(t, len(app.paths), 1) { testing.expect_value(t, app.paths[0], fmt.tprintf("%s%sfive.txt", root, ODIN_OS == .Windows ? "\\" : "/")) }
}

// A folder with a link to another folder (an NTFS junction on Windows, a symlink on Unix): before fsx.stat_follow,
// Odin's os.stat aliased the path string on Windows reparse points and os.file_info_delete + defer delete double-freed
// it (0xC0000374 in RtlFreeHeap).
@(test)
the_local_source_lists_a_folder_with_a_link :: proc(t: ^testing.T) {
	sep := ODIN_OS == .Windows ? "\\" : "/"
	root := fmt.tprintf("%s%sgui_toolkit_file_browser_link_%d", fsx.temp_dir(context.temp_allocator), sep, os.get_pid())
	fsx.remove_tree(root)
	real_dir := fmt.tprintf("%s%sreal_dir", root, sep)
	linked_dir := fmt.tprintf("%s%slinked_dir", root, sep)
	fsx.make_dirs(real_dir)
	defer fsx.remove_tree(root)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s%sinside.txt", real_dir, sep), transmute([]byte)string("ok")) == nil)
	if !testing.expect(t, make_folder_link(linked_dir, real_dir), "folder link made") { return }
	app: App
	defer app_destroy(&app)
	app.local = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = root})
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.file_picker_counts(ui.file_dialog_picker(s.state)).rows_shown == 2 }, "both folders shown", BOUND)
	testing.expect(t, session.find_text(s, "real_dir") != nil)
	testing.expect(t, session.find_text(s, "linked_dir") != nil)
}

// The computer's folder shown is followed: a file made in it shows with no F5, and the entry selected stays selected.
// (A file made before the system watched the folder is not told: the test makes one more until a change is told.)
@(test)
the_local_source_shows_a_new_file_without_a_reload :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/gui_toolkit_file_watch_%d", fsx.temp_dir(context.temp_allocator), os.get_pid())
	fsx.remove_tree(root)
	fsx.make_dirs(root)
	defer fsx.remove_tree(root)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/first.txt", root), transmute([]byte)string("x")) == nil)
	app: App
	defer app_destroy(&app)
	app.local = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = root})
	session.wait_until(s, proc(s: ^session.Session) -> bool { return counts(s).rows_shown == 1 }, "the folder's one file", BOUND)
	session.click_text(s, "first.txt")
	Made :: struct { root: string, n: int, last: time.Tick }
	made := Made{root = root, last = time.tick_now()}
	_ = os.write_entire_file(fmt.tprintf("%s/new_0.txt", root), transmute([]byte)string("x"))
	session.wait_until(s, &made, proc(s: ^session.Session, m: ^Made) -> bool {
		if counts(s).rows_shown > 1 { return true }
		if time.tick_since(m.last) > 250 * time.Millisecond {
			m.n += 1
			m.last = time.tick_now()
			_ = os.write_entire_file(fmt.tprintf("%s/new_%d.txt", m.root, m.n), transmute([]byte)string("x"))
		}
		return false
	}, "the new file shown with no reload", BOUND)
	testing.expect(t, session.find_text(s, "new_0.txt") != nil, "the new file")
	selected := ui.file_picker_selected(ui.file_dialog_picker(s.state))
	if testing.expect_value(t, len(selected), 1) {
		testing.expect_value(t, selected[0], fmt.tprintf("%s%sfirst.txt", root, ODIN_OS == .Windows ? "\\" : "/"))
	}
}

// The row of a menu whose id is `id` (a row is named mi_<its rank>_<its id>), nil when none is built.
@(private = "file")
menu_row :: proc(s: ^session.Session, id: string) -> ^ui.Box {
	for rank in 0 ..< 32 {
		if b := session.find(s, fmt.tprintf("mi_%d_%s", rank, id)); b != nil { return b }
	}
	return nil
}

// "Open with" of a computer's file: the submenu lists the handlers the system gives (here a fake list, with an icon for
// one), the default first with its word, and the one chosen opens the file (here: it writes a file beside it).
@(test)
open_with_lists_the_handlers_and_runs_the_one_chosen :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/gui_toolkit_file_open_with_%d", fsx.temp_dir(context.temp_allocator), os.get_pid())
	fsx.remove_tree(root)
	fsx.make_dirs(root)
	defer fsx.remove_tree(root)
	file := fmt.tprintf("%s%shere.txt", root, ODIN_OS == .Windows ? "\\" : "/")
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string("x")) == nil)
	app: App
	defer app_destroy(&app)
	app.local = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = root})
	session.wait_text(s, "here.txt", BOUND)
	ow := &ui.file_dialog_picker(s.state).open_with
	ow.handlers_of = proc(path: string, allocator: runtime.Allocator) -> []desktop.Handler {
		out := make([]desktop.Handler, 2, allocator)
		out[0] = {id = strings.clone("editor.desktop", allocator), name = strings.clone("Editor", allocator), icon = strings.clone("editor", allocator), default = true}
		out[1] = {id = strings.clone("viewer.desktop", allocator), name = strings.clone("Viewer", allocator)}
		return out
	}
	ow.icon_of = proc(h: desktop.Handler, size: int, allocator: runtime.Allocator) -> (desktop.File_Icon, bool) {
		if h.icon == "" { return {}, false }
		return {rgba = make([]u8, 4 * 4 * 4, allocator), size = {4, 4}}, true
	}
	ow.open = proc(path, id: string) -> bool {
		return os.write_entire_file(fmt.tprintf("%s.%s.opened", path, id), transmute([]byte)string("x")) == nil
	}
	session.click_text(s, "here.txt", .Right)
	// (by its id: a text would also match "Open with its program", which starts the system's program)
	if !testing.expect(t, menu_row(s, "fb_row_open_with") != nil, "the submenu's row") { return }
	session.click_at(s, session.center(menu_row(s, "fb_row_open_with")))
	session.wait_text(s, "Editor (default)", BOUND)
	testing.expect(t, session.find_text(s, "Viewer") != nil, "the other handler")
	if !testing.expect(t, menu_row(s, "fb_ow_1") != nil, "the second handler's row") { return }
	session.click_at(s, session.center(menu_row(s, "fb_ow_1")))
	Opened :: struct { path: string }
	session.wait_until(s, Opened{fmt.tprintf("%s.viewer.desktop.opened", file)}, proc(s: ^session.Session, o: Opened) -> bool {
		return os.exists(o.path)
	}, "the file opened with the one chosen", BOUND)
	testing.expect(t, !os.exists(fmt.tprintf("%s.editor.desktop.opened", file)), "not with the other")
}

////////////////////////////////
// Search in subfolders

// The frames past FILE_FIND_QUIET_MS: the query stayed the same long enough to be asked.
@(private = "file")
quiet :: proc(s: ^session.Session) { session.advance(s, ui.FILE_FIND_QUIET_MS + 50) }

// The computer's files: a file three folders deep is found by a fuzzy query, its path relative to the folder shown;
// what is in a hidden folder is found only with Hidden files on.
@(test)
the_local_source_finds_in_subfolders :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/gui_toolkit_file_find_%d", fsx.temp_dir(context.temp_allocator), os.get_pid())
	fsx.remove_tree(root)
	fsx.make_dirs(fmt.tprintf("%s/alpha/beta/gamma", root))
	fsx.make_dirs(fmt.tprintf("%s/.secret", root))
	defer fsx.remove_tree(root)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/alpha/beta/gamma/needle_report.txt", root), transmute([]byte)string("x")) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/.secret/hidden_report.txt", root), transmute([]byte)string("x")) == nil)
	sep := ODIN_OS == .Windows ? "\\" : "/"
	app: App
	defer app_destroy(&app)
	app.local = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = root, find_deep = true})
	testing.expect(t, counts(s).deep, "find_deep: on at open")
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.file_picker_counts(ui.file_dialog_picker(s.state)).entries == 2 }, "the folder's entries", BOUND)
	// (the letters in order, across the path's parts)
	session.type_text(s, "ndlrep")
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.file_picker_counts(ui.file_dialog_picker(s.state)).found > 0 }, "the find's answer", BOUND)
	testing.expect(t, counts(s).found_shown, "the rows are the find's")
	deep := fmt.tprintf("alpha%sbeta%sgamma%sneedle_report.txt", sep, sep, sep)
	testing.expect(t, session.find_text(s, deep) != nil, "the file three folders deep, by its relative path")
	session.key(s, .Return)
	if testing.expect_value(t, len(app.paths), 1) { testing.expect_value(t, app.paths[0], fmt.tprintf("%s%s%s", root, sep, deep)) }
	// a hidden folder: not entered while Hidden files is off
	open(s, &app, .Open, {start_dir = root, find_deep = true})
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.file_picker_counts(ui.file_dialog_picker(s.state)).entries == 2 }, "the folder's entries", BOUND)
	session.type_text(s, "hddnrep")
	session.wait_text(s, "Nothing found.", BOUND)
	session.key(s, .H, {.Ctrl})
	hidden := fmt.tprintf(".secret%shidden_report.txt", sep)
	session.wait_text(s, hidden, BOUND)
}

// A fake source that finds: the answer of an older query that comes late is dropped; the newer one's stays.
@(test)
a_late_answer_of_an_older_query_is_dropped :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("top.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	app.source = fake_source(&app.fake, finds = true)
	open(s, &app, .Open, {start_dir = "/f", find_deep = true})
	session.type_text(s, "ab")
	quiet(s)
	if !testing.expect_value(t, len(app.fake.finds), 1) { return }
	testing.expect_value(t, app.fake.finds[0].folder, "/f")
	testing.expect_value(t, app.fake.finds[0].query, "ab")
	testing.expect_value(t, app.fake.finds[0].limit, ui.FILE_FIND_LIMIT)
	session.type_text(s, "c")
	quiet(s)
	if !testing.expect_value(t, len(app.fake.finds), 2) { return }
	testing.expect_value(t, app.fake.finds[1].query, "abc")
	fake_found(&app.fake, 1, []ui.File_Entry{F("x/abc_new.txt")})
	fake_found(&app.fake, 0, []ui.File_Entry{F("y/ab_stale.txt")})   // (the older query's, after: too late)
	session.frames(s, 3)
	testing.expect(t, session.find_text(s, "x/abc_new.txt") != nil, "the newer query's answer")
	testing.expect(t, session.find_text(s, "ab_stale") == nil, "an older query's late answer shows nothing")
	testing.expect_value(t, counts(s).found, 1)
}

// A folder found is entered, the query cleared: the folder's own rows again.
@(test)
a_folder_found_is_entered :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("top.txt")}
	app.fake.folders["/f/sub/inner"] = []ui.File_Entry{F("in.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	app.source = fake_source(&app.fake, finds = true)
	open(s, &app, .Open, {start_dir = "/f", find_deep = true})
	session.type_text(s, "inner")
	quiet(s)
	if !testing.expect_value(t, len(app.fake.finds), 1) { return }
	fake_found(&app.fake, 0, []ui.File_Entry{F("sub/inner", .Folder)})
	session.frames(s, 3)
	session.key(s, .Return)   // (in the filter: the first row found, selected)
	testing.expect_value(t, counts(s).folder, "/f/sub/inner")
	session.frames(s, 3)
	testing.expect(t, !counts(s).found_shown, "the query cleared: the folder's rows")
	testing.expect(t, session.find_text(s, "in.txt") != nil)
}

// A file found is chosen as the folder's path joined to its relative one.
@(test)
a_file_found_is_chosen_by_its_whole_path :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("top.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	app.source = fake_source(&app.fake, finds = true)
	open(s, &app, .Open, {start_dir = "/f", find_deep = true})
	session.type_text(s, "deep")
	quiet(s)
	if !testing.expect_value(t, len(app.fake.finds), 1) { return }
	fake_found(&app.fake, 0, []ui.File_Entry{F("a/b/deep.txt"), F("deep_other.txt")})
	session.frames(s, 3)
	testing.expect_value(t, counts(s).rows_shown, 2)
	session.key(s, .Return)
	testing.expect_value(t, app.status, platform.Dialog_Status.Chosen)
	if testing.expect_value(t, len(app.paths), 1) { testing.expect_value(t, app.paths[0], "/f/a/b/deep.txt") }
}

// A query that does not change asks the source once, whatever the number of frames; the toggle off asks nothing.
@(test)
a_quiet_query_asks_once :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("top.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	app.source = fake_source(&app.fake, finds = true)
	open(s, &app, .Open, {start_dir = "/f", find_deep = true})
	session.type_text(s, "to")
	quiet(s)
	session.frames(s, 60)
	testing.expect_value(t, len(app.fake.finds), 1)
	fake_found(&app.fake, 0, []ui.File_Entry{F("x/top_deep.txt")})
	session.frames(s, 60)
	testing.expect_value(t, len(app.fake.finds), 1)
	// the toggle off: the folder's filter, no find
	session.click(s, "fb_deep")
	session.type_text(s, "p")
	quiet(s)
	session.frames(s, 30)
	testing.expect_value(t, len(app.fake.finds), 1)
	testing.expect(t, !counts(s).found_shown, "the folder's rows")
	testing.expect_value(t, counts(s).rows_shown, 1)
}

// find_deep turns the toggle on at open; without it, or with a source that cannot find, it is off (and not shown).
@(test)
find_deep_turns_the_toggle_on :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("top.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	app.source = fake_source(&app.fake, finds = true)
	open(s, &app, .Open, {start_dir = "/f", find_deep = true})
	testing.expect(t, counts(s).deep)
	testing.expect(t, session.find(s, "fb_deep") != nil, "the toggle")
	open(s, &app, .Open, {start_dir = "/f"})
	testing.expect(t, !counts(s).deep)
	app.source = fake_source(&app.fake)
	open(s, &app, .Open, {start_dir = "/f", find_deep = true})
	testing.expect(t, !counts(s).deep, "a source that cannot find")
	testing.expect(t, session.find(s, "fb_deep") == nil, "no toggle")
}

// The act's word: the program's own, else the mode's.
@(test)
the_act_says_the_programs_word :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Folder, {start_dir = "/f", act = "Start here"})
	testing.expect(t, session.find_text(s, "Start here") != nil)
	open(s, &app, .Folder, {start_dir = "/f"})
	testing.expect(t, session.find_text(s, "Start here") == nil)
	testing.expect(t, session.find_text(s, "Choose") != nil)
}

////////////////////////////////
// The program's acts on a row, and the folder the system names

// What the program's acts were called with.
@(private = "file")
Acts :: struct {
	downloaded: [dynamic]string,
	revealed:   [dynamic]string,
	actions:    [2]platform.File_Row_Action,   // (the options' slice: alive until the dialog copied them)
}

@(private = "file")
acts_destroy :: proc(a: ^Acts) {
	for p in a.downloaded { delete(p) }
	for p in a.revealed { delete(p) }
	delete(a.downloaded)
	delete(a.revealed)
}

@(private = "file")
acts_options :: proc(a: ^Acts, multiple := false) -> platform.File_Dialog {
	a.actions[0] = {label = "Download", act = proc(user: rawptr, path: string) {
		append(&(^Acts)(user).downloaded, strings.clone(path))
	}, user = a}
	a.actions[1] = {label = "Reveal", folders = true, act = proc(user: rawptr, path: string) {
		append(&(^Acts)(user).revealed, strings.clone(path))
	}, user = a}
	return {start_dir = "/f", row_actions = a.actions[:], multiple = multiple}
}

// A right click on a file opens its menu with the program's acts; an act gets the file's path and the dialog stays open.
// A folder's menu has only the acts that take folders.
@(test)
a_programs_act_on_a_row :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	acts: Acts
	defer acts_destroy(&acts)
	app.fake.folders["/f"] = []ui.File_Entry{F("docs", .Folder), F("a.txt"), F("b.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, acts_options(&acts))
	session.click_text(s, "a.txt", .Right)
	if !testing.expect(t, session.find_text(s, "Download") != nil, "the row's menu") { return }
	testing.expect(t, session.find_text(s, "Reveal") != nil)
	session.click_text(s, "Download")
	if testing.expect_value(t, len(acts.downloaded), 1) { testing.expect_value(t, acts.downloaded[0], "/f/a.txt") }
	testing.expect(t, counts(s).open, "an act is no answer: the dialog stays")
	testing.expect_value(t, app.answers, 0)
	testing.expect(t, session.find_text(s, "Download") == nil, "the menu closed")

	session.click_text(s, "docs", .Right)
	testing.expect(t, session.find_text(s, "Download") == nil, "an act on files only is not offered on a folder")
	session.click_text(s, "Reveal")
	if testing.expect_value(t, len(acts.revealed), 1) { testing.expect_value(t, acts.revealed[0], "/f/docs") }
	testing.expect_value(t, len(acts.downloaded), 1)

	// without the program's acts, the menu has the toolkit's alone
	open(s, &app, .Open, {start_dir = "/f"})
	session.click_text(s, "a.txt", .Right)
	testing.expect(t, session.find_text(s, "Download") == nil && session.find_text(s, "Reveal") == nil)
	testing.expect(t, session.find_text(s, "Copy path") != nil, "the toolkit's acts")
}

// Several files selected: the Menu key opens their menu, and an act runs once per file, in the folder's order.
@(test)
a_programs_act_on_several_rows :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	acts: Acts
	defer acts_destroy(&acts)
	app.fake.folders["/f"] = []ui.File_Entry{F("a.txt"), F("b.txt"), F("c.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, acts_options(&acts, multiple = true))
	session.click(s, "lrow_0")
	session.key(s, .A, {.Ctrl})
	session.key(s, .Menu)
	if !testing.expect(t, session.find_text(s, "Download") != nil, "the Menu key opens the rows' menu") { return }
	session.click_text(s, "Download")
	testing.expect_value(t, len(acts.downloaded), 3)
	if len(acts.downloaded) == 3 {
		testing.expect_value(t, acts.downloaded[0], "/f/a.txt")
		testing.expect_value(t, acts.downloaded[2], "/f/c.txt")
	}
	testing.expect(t, counts(s).open)
}

////////////////////////////////
// The toolkit's acts on a row (src/md/features/file-browser.md)

// The fake source's folder "/f" as a source that renames, trashes and puts back, answering at once (Fake.live).
@(private = "file")
fake_writes :: proc(app: ^App, entries: []ui.File_Entry) {
	f := &app.fake
	for e in entries { append(&f.live, e) }
	f.folders["/f"] = f.live[:]
	app.source.rename = proc(src: ^ui.File_Source, path, name: string, reply: ui.File_Reply) {
		f := (^Fake)(src.user)
		a := runtime.heap_allocator()
		append(&f.renamed, [2]string{strings.clone(path, a), strings.clone(name, a)})
		for &e in f.live {
			if strings.concatenate({"/f/", e.name}, context.temp_allocator) != path { continue }
			e.name = strings.clone(name, a)
			append(&f.names, e.name)
		}
		f.folders["/f"] = f.live[:]
		ui.file_reply_renamed(reply)
	}
	app.source.trash = proc(src: ^ui.File_Source, paths: []string, reply: ui.File_Reply) {
		f := (^Fake)(src.user)
		a := runtime.heap_allocator()
		items := make([dynamic]ui.File_Trashed, context.temp_allocator)
		for p in paths {
			append(&f.trashed, strings.clone(p, a))
			for e, i in f.live {
				if strings.concatenate({"/f/", e.name}, context.temp_allocator) != p { continue }
				append(&f.bin, e)
				ordered_remove(&f.live, i)
				token := strings.concatenate({"bin:", p}, a)
				append(&f.names, token)
				append(&items, ui.File_Trashed{path = p, token = token})
				break
			}
		}
		f.folders["/f"] = f.live[:]
		ui.file_reply_trashed(reply, items[:])
	}
	app.source.restore = proc(src: ^ui.File_Source, items: []ui.File_Trashed, reply: ui.File_Reply) {
		f := (^Fake)(src.user)
		for it in items { append(&f.restored, strings.clone(it.token, runtime.heap_allocator())) }
		for e in f.bin { append(&f.live, e) }
		clear(&f.bin)
		f.folders["/f"] = f.live[:]
		ui.file_reply_restored(reply)
	}
}

// With no act of the program, a right click opens the toolkit's menu; Copy path of one entry, then of two selected,
// gives one line per entry; Copy name and Copy relative path (the dialog started in "/f") too.
@(test)
the_toolkits_menu_copies :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("a.txt"), F("b.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/f", multiple = true})
	session.click_text(s, "a.txt", .Right)
	if !testing.expect(t, session.find_text(s, "Copy path") != nil, "the menu opens with no program act") { return }
	session.click_text(s, "Copy path")
	testing.expect_value(t, session.clipboard(s), "/f/a.txt")
	session.click(s, "lrow_0")
	session.key(s, .A, {.Ctrl})
	session.key(s, .Menu)
	session.click_text(s, "Copy path")
	testing.expect_value(t, session.clipboard(s), "/f/a.txt\n/f/b.txt")
	session.key(s, .Menu)
	session.click_text(s, "Copy name")
	testing.expect_value(t, session.clipboard(s), "a.txt\nb.txt")
	session.key(s, .Menu)
	session.click_text(s, "Copy relative path")
	testing.expect_value(t, session.clipboard(s), "a.txt\nb.txt")
	testing.expect(t, counts(s).open, "a copy is no answer")
}

// The row's menu filters what is typed, as every menu: its field shows the letters, the acts that do not match go, the
// first match is selected and Enter does it.
@(test)
the_row_menu_filters_what_is_typed :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("a.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/f"})
	session.click_text(s, "a.txt", .Right)
	if !testing.expect(t, session.find_text(s, "Copy path") != nil, "the menu opens") { return }
	testing.expect(t, session.find(s, "menu_search") != nil, "its field")
	session.type_text(s, "cpn")
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "cpn") != nil, "the field shows what is typed")
	testing.expect(t, session.find_text(s, "Copy name") != nil, "the match stays")
	testing.expect(t, session.find_text(s, "Copy path") == nil && session.find_text(s, "Copy relative path") == nil, "the others went")
	session.key(s, .Return)
	testing.expect_value(t, session.clipboard(s), "a.txt")
	testing.expect(t, counts(s).open, "the dialog stays")
}

// A source without rename nor trash (a server's) shows neither; nor Open or Show in folder (not the computer's files).
@(test)
a_remote_source_offers_what_it_can :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("a.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/f"})
	session.click_text(s, "a.txt", .Right)
	if !testing.expect(t, session.find_text(s, "Copy name") != nil, "the copies on every source") { return }
	testing.expect(t, session.find_text(s, "Rename") == nil, "no rename on a source without it")
	testing.expect(t, session.find_text(s, "Move to the trash") == nil, "no trash on a source without it")
	testing.expect(t, session.find_text(s, "Open with its program") == nil, "the system's programs: the computer's files only")
	testing.expect(t, session.find_text(s, "Show in folder") == nil)
	session.key(s, .Escape)
	session.key(s, .F2)
	session.key(s, .Delete)
	testing.expect(t, session.find(s, "fb_rename") == nil, "F2 does nothing either")
	testing.expect_value(t, counts(s).entries, 1)
}

// A program's off set removes those acts; all of them off and no act of its own: no menu.
@(test)
a_programs_off_set_removes_acts :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.at_once = true
	s := start(t, &app)
	fake_writes(&app, {F("a.txt")})
	open(s, &app, .Open, {start_dir = "/f", row_actions_off = {.Copy_Name, .Trash}})
	session.click_text(s, "a.txt", .Right)
	if !testing.expect(t, session.find_text(s, "Copy path") != nil) { return }
	testing.expect(t, session.find_text(s, "Rename") != nil, "the source renames")
	testing.expect(t, session.find_text(s, "Copy name") == nil, "turned off")
	testing.expect(t, session.find_text(s, "Move to the trash") == nil, "turned off")
	session.key(s, .Escape)
	session.key(s, .Delete)
	testing.expect_value(t, len(app.fake.trashed), 0)   // (its key is off too)
	open(s, &app, .Open, {start_dir = "/f", row_actions_off = {.Copy_Path, .Copy_Name, .Copy_Relative_Path, .Open, .Reveal, .Rename, .Trash}})
	session.click_text(s, "a.txt", .Right)
	testing.expect(t, session.find_text(s, "Copy path") == nil && session.find_text(s, "Rename") == nil, "no menu")
}

// Rename: a field in the row, the name selected without its extension; Enter asks the source with the new name, the
// folder is read again with it. F2 then Escape asks nothing.
@(test)
rename_edits_the_name_in_place :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.at_once = true
	s := start(t, &app)
	fake_writes(&app, {F("alpha.txt"), F("other.txt")})
	open(s, &app, .Open, {start_dir = "/f"})
	session.click_text(s, "alpha.txt", .Right)
	session.click_text(s, "Rename")
	if !testing.expect_value(t, session.focused_name(s), "fb_rename") { return }
	session.type_text(s, "beta")
	session.key(s, .Return)
	if testing.expect_value(t, len(app.fake.renamed), 1) {
		testing.expect_value(t, app.fake.renamed[0][0], "/f/alpha.txt")
		testing.expect_value(t, app.fake.renamed[0][1], "beta.txt")
	}
	testing.expect(t, session.find(s, "fb_rename") == nil, "the field went")
	testing.expect(t, session.find_text(s, "beta.txt") != nil, "the folder read again")
	testing.expect(t, session.find_text(s, "alpha.txt") == nil)
	// F2 on the row selected (the new name), then Escape: nothing asked
	session.key(s, .F2)
	testing.expect_value(t, session.focused_name(s), "fb_rename")
	session.type_text(s, "gamma")
	session.key(s, .Escape)
	testing.expect(t, session.find(s, "fb_rename") == nil)
	testing.expect_value(t, len(app.fake.renamed), 1)
	testing.expect(t, counts(s).open, "Escape gave the rename up, not the dialog")
}

// Move to the trash asks the source with the entries chosen; its toast's click asks restore with the source's tokens.
@(test)
trash_and_its_undo :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.at_once = true
	s := start(t, &app)
	fake_writes(&app, {F("gone.txt"), F("keep.txt")})
	open(s, &app, .Open, {start_dir = "/f"})
	session.click_text(s, "gone.txt", .Right)
	session.click_text(s, "Move to the trash")
	if testing.expect_value(t, len(app.fake.trashed), 1) { testing.expect_value(t, app.fake.trashed[0], "/f/gone.txt") }
	testing.expect_value(t, counts(s).entries, 1)
	testing.expect(t, session.find_text(s, "gone.txt moved to the trash") != nil, "the toast says it")
	session.click_text(s, "Click to undo.")
	if testing.expect_value(t, len(app.fake.restored), 1) { testing.expect_value(t, app.fake.restored[0], "bin:/f/gone.txt") }
	testing.expect_value(t, counts(s).entries, 2)
	// (once: the toast went with the click)
	testing.expect(t, session.find_text(s, "Click to undo.") == nil)
}

// The computer's files: Open with its program and Show in folder are offered (not clicked: they launch the system's
// programs), and the computer's source renames and trashes.
@(test)
open_and_show_in_folder_on_the_computers_files :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/gui_toolkit_file_rowmenu_%d", fsx.temp_dir(context.temp_allocator), os.get_pid())
	fsx.remove_tree(root)
	defer fsx.remove_tree(root)
	fsx.make_dirs(root)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/here.txt", root), transmute([]byte)string("x")) == nil)
	app: App
	defer app_destroy(&app)
	app.local = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = root})
	session.wait_text(s, "here.txt", BOUND)
	session.click_text(s, "here.txt", .Right)
	testing.expect(t, session.find_text(s, "Open with its program") != nil)
	testing.expect(t, session.find_text(s, "Show in folder") != nil)
	testing.expect(t, session.find_text(s, "Rename") != nil)
	testing.expect(t, session.find_text(s, "Move to the trash") != nil)
	session.key(s, .Escape)
}

// start_known: a source that knows the folder starts there (after start_dir and the dialog's memory); a source that
// knows none starts where it would without it.
@(test)
start_known_is_asked_of_the_source :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/home/me/Downloads"] = []ui.File_Entry{F("got.zip")}
	app.fake.folders["/elsewhere"] = []ui.File_Entry{F("x.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	app.source.known = proc(src: ^ui.File_Source, folder: platform.Known_Folder, allocator: runtime.Allocator) -> string {
		return folder == .Downloads ? strings.clone("/home/me/Downloads", allocator) : ""
	}
	open(s, &app, .Save, {start_known = .Downloads, suggested_name = "got.zip"})
	testing.expect_value(t, counts(s).folder, "/home/me/Downloads")
	testing.expect(t, session.find_text(s, "got.zip") != nil)
	session.key(s, .Escape)
	// start_dir first
	open(s, &app, .Save, {start_dir = "/elsewhere", start_known = .Downloads})
	testing.expect_value(t, counts(s).folder, "/elsewhere")
	session.key(s, .Escape)
	// a folder the source does not know: not that one
	open(s, &app, .Save, {start_dir = "", start_known = .Music})
	testing.expect(t, counts(s).folder != "/home/me/Downloads")
}

// The computer's files: start_known = .Downloads opens the person's Downloads folder (Linux: the one user-dirs.dirs
// names, here a folder of the test's; Windows: the system's).
@(test)
the_local_source_starts_in_downloads :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/gui_toolkit_file_known_%d", fsx.temp_dir(context.temp_allocator), os.get_pid())
	fsx.remove_tree(root)
	defer fsx.remove_tree(root)
	expected: string
	before, had := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	defer {
		when ODIN_OS == .Linux {
			if had { os.set_env("XDG_CONFIG_HOME", before) } else { os.unset_env("XDG_CONFIG_HOME") }
		} else {
			_, _ = before, had
		}
	}
	when ODIN_OS == .Linux {
		// (a user-dirs.dirs of the test's own: known_folder_path reads it again when its path changes)
		config := fmt.tprintf("%s/config", root)
		expected = fmt.tprintf("%s/Téléchargements", root)
		fsx.make_dirs(config)
		fsx.make_dirs(expected)
		dirs := fmt.tprintf("XDG_DOWNLOAD_DIR=\"%s\"\n", expected)
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/user-dirs.dirs", config), transmute([]byte)dirs) == nil)
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/arrived.bin", expected), transmute([]byte)string("x")) == nil)
		os.set_env("XDG_CONFIG_HOME", config)
	} else {
		expected = platform.known_folder_path(.Downloads, context.temp_allocator)
		if expected == "" || fsx.path_kind(expected) != .Directory { return }   // (a system with no Downloads folder)
	}
	app: App
	defer app_destroy(&app)
	app.local = true
	s := start(t, &app)
	open(s, &app, .Save, {start_known = .Downloads, suggested_name = "file.bin"})
	session.wait_until(s, expected, proc(s: ^session.Session, want: string) -> bool { return ui.file_picker_counts(ui.file_dialog_picker(s.state)).folder == want }, "the Downloads folder", BOUND)
	when ODIN_OS == .Linux {
		session.wait_text(s, "arrived.bin", BOUND)
	}
}

////////////////////////////////
// The path bar

// Ctrl+L: the path as a field, answered from the folder's entries (no reading); a path typed and Enter go there (its
// folder read, its last part entered).
@(test)
ctrl_l_and_a_path_typed :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/a"] = []ui.File_Entry{F("docs", .Folder), F("top.txt")}
	app.fake.folders["/a/docs"] = []ui.File_Entry{F("in.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/a"})
	session.key(s, .L, {.Ctrl})
	testing.expect_value(t, session.focused_name(s), "pb_field")
	testing.expect_value(t, len(app.fake.asked), 1)   // (the folder shown: its entries, no reading)
	session.type_text(s, "/a/docs")
	session.key(s, .Return)
	testing.expect_value(t, counts(s).folder, "/a/docs")
	testing.expect(t, counts(s).open)
	testing.expect(t, session.find_text(s, "in.txt") != nil)
}

// Tab takes the folder's child and its separator: the bar reads that folder on its own (the list stays the folder
// shown's); Enter on a path that ends with a separator enters it.
@(test)
tab_reads_the_next_level_beside_the_list :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/a"] = []ui.File_Entry{F("docs", .Folder), F("top.txt")}
	app.fake.folders["/a/docs"] = []ui.File_Entry{F("in.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/a"})
	session.key(s, .L, {.Ctrl})
	session.type_text(s, "/a/d")
	session.key(s, .Tab)
	if testing.expect_value(t, len(app.fake.asked), 2) {
		testing.expect_value(t, app.fake.asked[1].path, "/a/docs")
		testing.expect(t, app.fake.asked[1].reply.bar, "the bar's reading")
	}
	testing.expect_value(t, counts(s).folder, "/a")
	testing.expect_value(t, counts(s).rows_shown, 2)
	testing.expect(t, session.find_text(s, "in.txt") != nil, "the next level's child, in the dropdown")
	session.key(s, .Return)
	testing.expect_value(t, counts(s).folder, "/a/docs")
}

// A part of the breadcrumb goes to its folder.
@(test)
a_part_of_the_path_is_entered :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/a/docs"] = []ui.File_Entry{F("in.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/a/docs"})
	session.click(s, "pb_part_1")
	testing.expect_value(t, counts(s).folder, "/a")
}

// Escape in the path field is the bar's: it closes the dropdown, then gives the breadcrumb back; only then does Escape
// cancel the dialog.
@(test)
escape_in_the_path_field :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/a"] = []ui.File_Entry{F("top.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/a"})
	session.key(s, .L, {.Ctrl})
	session.key(s, .Escape)
	session.key(s, .Escape)
	testing.expect(t, counts(s).open, "the bar took both")
	testing.expect(t, session.find(s, "pb_field") == nil, "the breadcrumb again")
	session.key(s, .Escape)
	testing.expect(t, !counts(s).open)
	testing.expect_value(t, app.status, platform.Dialog_Status.Cancelled)
}

// The mouse's side buttons go back and forward in the history, with the pointer on the dialog, on the path bar's
// dropdown, and while a field has the keyboard; off the dialog they do nothing.
@(test)
the_side_buttons_go_back_and_forward :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/a"] = []ui.File_Entry{F("docs", .Folder), F("top.txt")}
	app.fake.folders["/a/docs"] = []ui.File_Entry{F("in.txt")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/a"})
	session.key(s, .Down)
	session.key(s, .Return)
	testing.expect_value(t, counts(s).folder, "/a/docs")
	on_list := session.center(session.get(s, "fb_table"))
	session.click_at(s, on_list, .Back)
	testing.expect_value(t, counts(s).folder, "/a")
	session.click_at(s, on_list, .Forward)
	testing.expect_value(t, counts(s).folder, "/a/docs")
	// (off the dialog: the window's corner, under no view)
	session.click_at(s, {2, 2}, .Back)
	testing.expect_value(t, counts(s).folder, "/a/docs")
	testing.expect(t, counts(s).open)
	// (the filter has the keyboard)
	session.click(s, "fb_filter")
	session.type_text(s, "in")
	session.click_at(s, on_list, .Back)
	testing.expect_value(t, counts(s).folder, "/a")
	// (on the path bar's dropdown, its field typed in)
	session.key(s, .L, {.Ctrl})
	session.type_text(s, "/a/")
	drop := session.get(s, "pb_list")
	session.click_at(s, session.center(drop), .Forward)
	testing.expect_value(t, counts(s).folder, "/a/docs")
}

////////////////////////////////
// The preview's text is content

// A text file's preview is selectable (src/md/features/text-selection.md): a drag across its lines selects them, and
// Ctrl+C copies what is selected.
@(test)
the_preview_text_selects_and_copies :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/p"] = []ui.File_Entry{F("notes.txt")}
	app.fake.at_once = true
	app.source = fake_source(&app.fake, {.Size, .Modified, .Read})
	app.source.read = proc(src: ^ui.File_Source, path: string, max: int, reply: ui.File_Reply) {
		text := "first line\nsecond line\nthird line\n"
		ui.file_reply_read(reply, transmute([]u8)text, i64(len(text)))
	}
	s := session.start(t, {build = build, user = &app, no_renderer = true, size = {1200, 800}})
	open(s, &app, .Open, {start_dir = "/p"})
	session.key(s, .Down)   // (the file selected: its preview is read)
	lines := session.wait_box(s, "fb_preview_lines", BOUND)
	r := lines.rect
	from := [2]f32{r.min.x + lines.text_pad + 1, r.min.y + lines.text_pad + 4}
	session.drag(s, from, {r.max.x - 4, r.max.y - lines.text_pad - 4})
	got := ui.selected_text(s.state, context.temp_allocator)
	testing.expectf(t, strings.has_prefix(got, "first line\nsecond line"), "the lines dragged over: %q", got)
	session.key(s, .C, {.Ctrl})
	testing.expect_value(t, session.clipboard(s), got)
}

// The preview closes and opens again (its button, Alt+P), and the picker remembers it per remember_id.
@(test)
the_preview_closes_and_is_remembered :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/p"] = []ui.File_Entry{F("notes.txt")}
	app.fake.at_once = true
	app.source = fake_source(&app.fake, {.Size, .Modified, .Read})
	app.source.read = proc(src: ^ui.File_Source, path: string, max: int, reply: ui.File_Reply) {
		text := "a line\n"
		ui.file_reply_read(reply, transmute([]u8)text, i64(len(text)))
	}
	s := session.start(t, {build = build, user = &app, no_renderer = true, size = {1200, 800}})
	d := platform.File_Dialog{start_dir = "/p", remember_id = "preview"}
	open(s, &app, .Open, d)
	testing.expect(t, session.find(s, "fb_preview") != nil, "the preview shows at first")
	session.click(s, "fb_preview_toggle")
	testing.expect(t, session.find(s, "fb_preview") == nil, "its button closes it")
	session.key(s, .P, {.Alt})
	testing.expect(t, session.find(s, "fb_preview") != nil, "Alt+P opens it again")
	session.key(s, .P, {.Alt})
	session.click(s, "fb_cancel")
	open(s, &app, .Open, d)
	testing.expect(t, session.find(s, "fb_preview") == nil, "closed, it stays closed with its remember_id")
	session.click(s, "fb_cancel")
}

////////////////////////////////
// The keyboard is the browser's

// While the browser is open, the program's key_press and typed text get nothing, even with keys behind dialogs: the
// browser gets them (the letter filters, Escape clears the filter then cancels). Once it closed, the program's again.
@(test)
the_browser_keeps_the_keyboard :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("quartz.txt"), F("other.txt")}
	app.fake.at_once = true
	app.watch = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/f"})
	testing.expect(t, ui.file_dialog_shown(s.state))
	session.type_text(s, "q")
	testing.expect_value(t, app.typed_q, 0)
	testing.expect_value(t, counts(s).rows_shown, 1)   // (the browser's filter took it)
	session.key(s, .Escape)
	testing.expect_value(t, app.escapes, 0)
	testing.expect(t, counts(s).open, "the first Escape clears the filter")
	testing.expect_value(t, counts(s).rows_shown, 2)
	session.key(s, .Escape)
	testing.expect_value(t, app.escapes, 0)
	testing.expect(t, !ui.file_dialog_shown(s.state), "the second cancels")
	testing.expect_value(t, app.status, platform.Dialog_Status.Cancelled)
	// (closed: the program's keys again)
	session.key(s, .Escape)
	testing.expect_value(t, app.escapes, 1)
	session.type_text(s, "q")
	testing.expect_value(t, app.typed_q, 1)
}

////////////////////////////////
// The views and the thumbnails (src/md/features/view-modes.md, thumbnails.md)

// The view's menu in the bar.
@(private = "file")
pick_view :: proc(s: ^session.Session, step: int) {
	session.click(s, "fb_view")
	// (a menu item's box is named mi_<its rank>_<its id>)
	session.click(s, fmt.tprintf("mi_%d_fb_view_%d", step, step))
}

// The view chosen in the bar's menu, and Ctrl+wheel over the list, are remembered by the dialog's remember_id: the
// next dialog of that id opens on them; another id in Details.
@(test)
the_dialog_remembers_its_view :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/p"] = []ui.File_Entry{F("a.png"), F("b.png")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/p", remember_id = "pictures"})
	testing.expect_value(t, counts(s).zoom, 0)
	pick_view(s, ui.TABLE_ZOOM_CARDS)
	testing.expect_value(t, counts(s).zoom, ui.TABLE_ZOOM_CARDS)
	testing.expect(t, session.find(s, "item0") != nil, "the cards")
	// a notch of Ctrl+wheel up over the list: the next step
	session.wheel(s, session.center(session.get(s, "fb_table")), {0, -1}, {.Ctrl})
	testing.expect_value(t, counts(s).zoom, ui.TABLE_ZOOM_CARDS + 1)
	session.click(s, "fb_cancel")
	open(s, &app, .Open, {start_dir = "/p", remember_id = "pictures"})
	testing.expect_value(t, counts(s).zoom, ui.TABLE_ZOOM_CARDS + 1)
	session.click(s, "fb_cancel")
	open(s, &app, .Open, {start_dir = "/p", remember_id = "other"})
	testing.expect_value(t, counts(s).zoom, 0)
}

// The cards ask their thumbnails of the source (the details none, a folder none); an answer shows the picture in its
// card (file_reply_thumbnail into the browser's cache), a failure keeps the icon.
@(test)
the_cards_ask_thumbnails_of_the_source :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/p"] = []ui.File_Entry{F("sub", .Folder), F("a.png"), F("b.png")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/p"})
	session.frames(s, 3)
	testing.expect_value(t, len(app.fake.thumbs), 0)   // (the details: no card)
	pick_view(s, ui.TABLE_ZOOM_CARDS)
	session.frames(s, 3)
	testing.expect_value(t, len(app.fake.thumbs), 2)
	testing.expect_value(t, counts(s).thumbs_asked, 2)
	for a in app.fake.thumbs { testing.expect(t, a.path == "/p/a.png" || a.path == "/p/b.png", "a file's path, not the folder's") }
	if len(app.fake.thumbs) < 2 { return }
	px := [16]u8{0xff, 0, 0, 0xff, 0xff, 0, 0, 0xff, 0xff, 0, 0, 0xff, 0xff, 0, 0, 0xff}
	ui.file_reply_thumbnail(app.fake.thumbs[0].reply, px[:], 2, 2)
	ui.file_reply_failed(app.fake.thumbs[1].reply, "")
	session.frames(s, 3)
	testing.expect_value(t, counts(s).thumbs_ready, 1)
	testing.expect(t, session.find(s, "thumb") != nil, "the picture in its card")
	testing.expect_value(t, len(app.fake.thumbs), 2)   // (each asked once: the failure is not asked again)
}

// The computer's files: a real PNG's thumbnail is decoded on the chores and comes to its card.
@(test)
the_local_source_makes_a_pictures_thumbnail :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/gui_toolkit_file_thumbs_%d", fsx.temp_dir(context.temp_allocator), os.get_pid())
	fsx.remove_tree(root)
	fsx.make_dirs(root)
	defer fsx.remove_tree(root)
	W, H :: 600, 300
	rgba := make([]u8, W * H * 4, context.temp_allocator)
	for i in 0 ..< W * H { rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3] = u8(i % 251), 0x80, u8(i % 7 * 30), 0xff }
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/wide.png", root), png.encode(rgba, W, H, allocator = context.temp_allocator)) == nil)
	app: App
	defer app_destroy(&app)
	app.local = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = root})
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.file_picker_counts(ui.file_dialog_picker(s.state)).rows_shown == 1 }, "the picture's row", BOUND)
	pick_view(s, ui.TABLE_ZOOM_CARDS)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.file_picker_counts(ui.file_dialog_picker(s.state)).thumbs_ready == 1 }, "its thumbnail", BOUND)
	testing.expect(t, session.find(s, "thumb") != nil, "the picture in its card")
}

// The picture's place of card `item` and the icon in it (the box that draws text), nil when there is none.
@(private = "file")
card_icon :: proc(s: ^session.Session, item: string) -> (pic, glyph: ^ui.Box) {
	card := session.find(s, item)
	if card == nil { return }
	pic = session.find(s, "pic", within = card)
	if pic == nil { return }
	for c := pic.first; c != nil; c = c.next { if .Draw_Text in c.flags { glyph = c } }
	return
}

// A card with no thumbnail (a folder; a file whose thumbnail is not answered) has its kind's icon at half its picture's
// height, at a small and at the largest step: not at the rows' font size, a dot in a large card.
@(test)
a_cards_icon_follows_the_cards_size :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/p"] = []ui.File_Entry{F("sub", .Folder), F("README.md")}
	app.fake.at_once = true
	s := start(t, &app)
	open(s, &app, .Open, {start_dir = "/p"})
	sizes: [2]f32
	steps := [2]int{ui.TABLE_ZOOM_CARDS - 1, ui.TABLE_ZOOMS - 1}
	items := [2]string{"item0", "item1"}
	for step, k in steps {
		pick_view(s, step)
		// (the cards grow to their step's size: anim)
		session.wait_idle(s, BOUND)
		for item in items {
			pic, glyph := card_icon(s, item)
			testing.expectf(t, glyph != nil, "%s at step %d: its icon", item, step)
			if glyph == nil { return }
			want := ui.table_card_icon_size(pic.rect.max.y - pic.rect.min.y)
			testing.expectf(t, glyph.font_size == want, "%s at step %d: icon %v, want %v", item, step, glyph.font_size, want)
			// (the card's name is at the rows' font size)
			if name := session.find(s, "n", within = session.find(s, item)); name != nil {
				testing.expectf(t, glyph.font_size >= 2 * name.font_size, "%s at step %d: icon %v, name %v", item, step, glyph.font_size, name.font_size)
			}
			sizes[k] = glyph.font_size
		}
	}
	testing.expectf(t, sizes[1] > sizes[0], "the icon grows with the card: %v", sizes)
}

// One thumbnail answered, then the dialog opened again: the same generation shows it without an ask; another
// generation (a server reached again, its picture changed: its listing has no date to tell) asks the source again.
@(test)
a_new_generation_asks_the_thumbnails_again :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/p"] = []ui.File_Entry{F("a.png")}
	app.fake.at_once = true
	s := start(t, &app)
	d := platform.File_Dialog{start_dir = "/p", remember_id = "pictures"}
	open(s, &app, .Open, d)
	pick_view(s, ui.TABLE_ZOOM_CARDS)
	session.frames(s, 3)
	testing.expect_value(t, len(app.fake.thumbs), 1)
	if len(app.fake.thumbs) < 1 { return }
	px := [16]u8{0xff, 0, 0, 0xff, 0xff, 0, 0, 0xff, 0xff, 0, 0, 0xff, 0xff, 0, 0, 0xff}
	ui.file_reply_thumbnail(app.fake.thumbs[0].reply, px[:], 2, 2)
	session.frames(s, 3)
	testing.expect_value(t, counts(s).thumbs_ready, 1)
	session.click(s, "fb_cancel")
	open(s, &app, .Open, d)
	session.frames(s, 3)
	testing.expect_value(t, len(app.fake.thumbs), 1)
	testing.expect(t, session.find(s, "thumb") != nil, "the same generation: the thumbnail kept")
	session.click(s, "fb_cancel")
	app.source.generation += 1
	open(s, &app, .Open, d)
	session.frames(s, 3)
	testing.expect_value(t, len(app.fake.thumbs), 2)
	if len(app.fake.thumbs) == 2 { testing.expect_value(t, app.fake.thumbs[1].path, "/p/a.png") }
	testing.expect(t, session.find(s, "thumb") == nil, "another generation: the old thumbnail is not shown")
}

// Two sources with the same paths (two servers): the second one's card does not show the first one's thumbnail, it
// asks its own source.
@(test)
two_sources_with_the_same_paths_do_not_share_thumbnails :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	other: Fake
	defer fake_destroy(&other)
	app.fake.folders["/p"] = []ui.File_Entry{F("a.png")}
	other.folders["/p"] = []ui.File_Entry{F("a.png")}
	app.fake.at_once, other.at_once = true, true
	s := start(t, &app)
	d := platform.File_Dialog{start_dir = "/p", remember_id = "pictures"}
	open(s, &app, .Open, d)
	pick_view(s, ui.TABLE_ZOOM_CARDS)
	session.frames(s, 3)
	testing.expect_value(t, len(app.fake.thumbs), 1)
	if len(app.fake.thumbs) < 1 { return }
	px := [16]u8{0xff, 0, 0, 0xff, 0xff, 0, 0, 0xff, 0xff, 0, 0, 0xff, 0xff, 0, 0, 0xff}
	ui.file_reply_thumbnail(app.fake.thumbs[0].reply, px[:], 2, 2)
	session.frames(s, 3)
	testing.expect_value(t, counts(s).thumbs_ready, 1)
	session.click(s, "fb_cancel")
	app.source = fake_source(&other)
	open(s, &app, .Open, d)
	session.frames(s, 3)
	testing.expect_value(t, len(other.thumbs), 1)
	testing.expect_value(t, len(app.fake.thumbs), 1)
	testing.expect(t, session.find(s, "thumb") == nil, "the other source's card: not the first one's thumbnail")
	// (closed while `other` lives: the dialog holds a copy of its source)
	session.click(s, "fb_cancel")
}
////////////////////////////////
// Save's type, Alt+Home

// Save: another type chosen changes the extension of the name typed; Alt+Home goes to the source's start.
@(test)
save_follows_the_type_and_alt_home_goes_home :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.fake.folders["/f"] = []ui.File_Entry{F("sub", .Folder)}
	app.fake.folders["/f/sub"] = []ui.File_Entry{}
	app.fake.at_once = true
	app.source = fake_source(&app.fake)
	app.source.start = proc(src: ^ui.File_Source, allocator: runtime.Allocator) -> string { return strings.clone("/f", allocator) }
	s := session.start(t, {build = build, user = &app, no_renderer = true, size = {1200, 800}})
	app.kind, app.d, app.ask = .Save, {start_dir = "/f/sub", suggested_name = "report.txt", filters = {{name = "Text", patterns = {"*.txt"}}, {name = "Markdown", patterns = {"*.md"}}}}, true
	session.frames(s, SHOW_FRAMES)
	testing.expect_value(t, counts(s).folder, "/f/sub")
	session.click(s, "fb_type")
	session.click_text(s, "Markdown")
	testing.expect_value(t, ui.line_edit_string(&ui.file_dialog_picker(s.state).name), "report.md")
	session.key(s, .Home, {.Alt})
	testing.expect_value(t, counts(s).folder, "/f")
	session.click(s, "fb_act")
	testing.expect_value(t, app.answers, 1)
	if len(app.paths) == 1 { testing.expect_value(t, app.paths[0], "/f/report.md") }
}

////////////////////////////////
// Pickers in a program's layout

// Two pickers of the program side by side, each on its own folder: the one with the focus reads the keys, the other
// none; each says its folder changed and its answer in its own events. A picker destroyed with a reading on its way
// drops the late answer.
@(private = "file")
Two :: struct {
	fake:     Fake,
	source:   ui.File_Source,
	a, b:     ui.File_Picker,
	ready:    bool,
	moved:    [2]int,      // folder_changed, per picker
	answered: [2]int,
	chosen:   string,      // (heap) a's last path chosen
	gone:     bool,        // b destroyed: not built
}

@(private = "file")
two_build :: proc(s: ^session.Session) {
	app := (^Two)(s.user)
	if !app.ready {
		app.ready = true
		ui.file_picker_init(&app.a, s.state, .Open, {start_dir = "/a"}, &app.source)
		ui.file_picker_init(&app.b, s.state, .Open, {start_dir = "/b"}, &app.source)
	}
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row() {
		ui.next({width = ui.px(580), height = ui.fill()})
		ea := ui.file_picker("###pick_a", &app.a)
		if ea.folder_changed { app.moved[0] += 1 }
		if ea.answered {
			app.answered[0] += 1
			if len(ea.result.paths) == 1 {
				delete(app.chosen, runtime.heap_allocator())
				app.chosen = strings.clone(ea.result.paths[0], runtime.heap_allocator())
			}
		}
		if !app.gone {
			ui.next({width = ui.px(580), height = ui.fill()})
			eb := ui.file_picker("###pick_b", &app.b)
			if eb.folder_changed { app.moved[1] += 1 }
			if eb.answered { app.answered[1] += 1 }
		}
	}
}

@(test)
two_pickers_in_a_programs_layout :: proc(t: ^testing.T) {
	app: Two
	defer {
		ui.file_picker_destroy(&app.a)
		ui.file_picker_destroy(&app.b)
		fake_destroy(&app.fake)
		delete(app.chosen, runtime.heap_allocator())
	}
	app.fake.folders["/a"] = []ui.File_Entry{F("docs", .Folder), F("a.txt")}
	app.fake.folders["/a/docs"] = []ui.File_Entry{F("in.txt")}
	app.fake.folders["/b"] = []ui.File_Entry{F("b.txt")}
	app.fake.at_once = true
	app.source = fake_source(&app.fake)
	s := session.start(t, {build = two_build, user = &app, no_renderer = true, size = {1200, 700}})
	session.frames(s, SHOW_FRAMES)
	testing.expect_value(t, ui.file_picker_folder(&app.a), "/a")
	testing.expect_value(t, ui.file_picker_folder(&app.b), "/b")
	// (the first built took the keyboard: a; b reads none)
	session.key(s, .Down)
	session.key(s, .Return)
	testing.expect_value(t, ui.file_picker_folder(&app.a), "/a/docs")
	testing.expect_value(t, ui.file_picker_folder(&app.b), "/b")
	testing.expect(t, app.moved[0] >= 2 && app.moved[1] == 1, "each says its own folder changed")
	// (a's answer, in a's events; the picker stays open)
	session.key(s, .Down)
	session.key(s, .Return)
	testing.expect_value(t, app.answered, [2]int{1, 0})
	testing.expect_value(t, app.chosen, "/a/docs/in.txt")
	testing.expect(t, ui.file_picker_counts(&app.a).open)
	// (a click in b: the keys are b's)
	session.click_text(s, "b.txt")
	session.key(s, .Escape)
	testing.expect_value(t, app.answered, [2]int{1, 1})
	session.key(s, .Backspace)
	testing.expect_value(t, ui.file_picker_folder(&app.a), "/a/docs")
	// b destroyed with a reading on its way: its late answer finds no picker
	app.fake.at_once = false
	asked := len(app.fake.asked)
	session.key(s, .F5)
	testing.expect_value(t, len(app.fake.asked), asked + 1)
	app.gone = true
	ui.file_picker_destroy(&app.b)
	fake_answer(&app.fake, asked)
	session.frames(s, 3)
	testing.expect_value(t, ui.file_picker_folder(&app.a), "/a/docs")
}
