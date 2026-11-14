// The file browser (ui.file_dialog, docs/file-browser.md) on a fake source that answers when the test says (in order,
// late, never, refused, at once), and on the computer's files in a folder made in the temporary directory. What breaks
// first: a slow folder answering after the next one was asked; 100 000 entries; names of every kind of character;
// Save over a file; the dialog closed with a reading under way.
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

@(private = "file")
Fake :: struct {
	folders: map[string][]ui.File_Entry,
	asked:   [dynamic]Asked,
	at_once: bool,   // answers in the call
	made:    [dynamic]string,
}

@(private = "file")
fake_source :: proc(f: ^Fake, caps := ui.File_Caps{.Size, .Modified}) -> ui.File_Source {
	return {
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
}

@(private = "file")
fake_answer :: proc(f: ^Fake, i: int) {
	a := f.asked[i]
	ui.file_reply_listed(a.reply, f.folders[a.path] or_else nil)
}

@(private = "file")
fake_destroy :: proc(f: ^Fake) {
	for a in f.asked { delete(a.path, runtime.heap_allocator()) }
	for m in f.made { delete(m, runtime.heap_allocator()) }
	delete(f.asked)
	delete(f.made)
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
}

@(private = "file")
build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
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
