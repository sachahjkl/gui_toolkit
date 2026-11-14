// The file browser (ui.file_dialog, docs/file-browser.md) on a fake source that answers when the test says (in order,
// late, never, refused, at once), and on the computer's files in a folder made in the temporary directory. What breaks
// first: a slow folder answering after the next one was asked; 100 000 entries; names of every kind of character;
// Save over a file; the dialog closed with a reading under way; an older search's late answer; the program's keys while
// the browser is open.
//   odin test tests/file_browser -vet -define:ODIN_TEST_THREADS=1 (Linux: -define:FONT_BACKEND=native)
//   -define:FILE_BROWSER_TIMING=true: a build of 100 000 entries is timed too (FILE_BROWSER_BUILD_BUDGET_MS)
package file_browser_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "../../src/fsx"
import "../../src/platform"
import "../../src/testkit/session"
import "../../src/ui"

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
	kind:     ui.File_Dialog_Kind,
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
open :: proc(s: ^session.Session, app: ^App, kind: ui.File_Dialog_Kind, d: platform.File_Dialog) {
	app.kind, app.d, app.ask = kind, d, true
	session.frames(s, SHOW_FRAMES)
}

@(private = "file")
counts :: proc(s: ^session.Session) -> ui.File_Browser_Counts { return ui.file_browser_counts(s.state) }

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
	session.advance(s, ui.FILE_BROWSER_SLOW_MS + 50)
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
	when FILE_BROWSER_TIMING { testing.expectf(t, slowest < ui.FILE_BROWSER_BUILD_BUDGET_MS, "a build took %.1f ms", slowest) }
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

// Open with `multiple`: Ctrl+A marks every file, Open answers them all.
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
	// Shift+Down marks from the row the keyboard is on
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
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.file_browser_counts(s.state).rows_shown == 2 }, "the folder's two entries", BOUND)
	testing.expect(t, session.find_text(s, "sub folder") != nil)
	testing.expect(t, session.find_text(s, "five.txt") != nil)
	testing.expect(t, session.find_text(s, "5 B") != nil, "the file's size")
	session.click_text(s, "five.txt")
	session.click(s, "fb_act")
	if testing.expect_value(t, len(app.paths), 1) { testing.expect_value(t, app.paths[0], fmt.tprintf("%s%sfive.txt", root, ODIN_OS == .Windows ? "\\" : "/")) }
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
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.file_browser_counts(s.state).entries == 2 }, "the folder's entries", BOUND)
	// (the letters in order, across the path's parts)
	session.type_text(s, "ndlrep")
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.file_browser_counts(s.state).found > 0 }, "the find's answer", BOUND)
	testing.expect(t, counts(s).found_shown, "the rows are the find's")
	deep := fmt.tprintf("alpha%sbeta%sgamma%sneedle_report.txt", sep, sep, sep)
	testing.expect(t, session.find_text(s, deep) != nil, "the file three folders deep, by its relative path")
	session.key(s, .Return)
	if testing.expect_value(t, len(app.paths), 1) { testing.expect_value(t, app.paths[0], fmt.tprintf("%s%s%s", root, sep, deep)) }
	// a hidden folder: not entered while Hidden files is off
	open(s, &app, .Open, {start_dir = root, find_deep = true})
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.file_browser_counts(s.state).entries == 2 }, "the folder's entries", BOUND)
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
