package tk_prefs_page

// A user's own themes, in a file of theirs beside the program's preferences (themes.txt): the page's Theme section says
// it can be made and links to it; a click makes it from THEMES_TEMPLATE when it is not there (a commented guide: nothing
// changes until a line is written) and opens it in the system's editor. The program's themes come first in `all`; the
// user's follow, read again when the file changes.
//
//	themes_file_init(&app.themes_file, path, app_themes[:])          // path: beside the preferences
//	// each build (cheap: at most one task every THEMES_FILE_POLL_MS looks at the file)
//	if prefs_page.themes_file_poll(&app.themes_file, &app.state) { /* show the theme again */ }
//	opts.themes, opts.themes_file = app.themes_file.all[:], &app.themes_file
//
// Every disk access is a task (ui.task): the stamp, the read, the template written and the editor started. Nothing of it
// runs on the interface's thread. Keep the Themes_File as long as the ui.State its tasks answer to (their answers come
// in that state's builds; ui.destroy drops those still on their way).

import "base:runtime"
import "core:os"
import "core:strings"
import "core:time"
import "../ascii"
import "../fsx"
import "../platform"
import "../ui"

// How often, at most, a task looks whether the file changed (only while builds happen: a window at rest is not woken
// for it, the next build looks).
THEMES_FILE_POLL_MS :: 2000

// What a new themes file says: how it is read, and a theme to start from, all commented. `from` names a theme of the
// program's, the keys are ui.THEME_KEYS.
THEMES_TEMPLATE :: `# Themes of your own. Each [section] is one theme, by its name: it shows with the program's themes in
# Settings > Appearance, and this file is read again each time it is saved.
#
# A colour is #rrggbb. A line that starts with # or ; is a comment. What a theme does not give is the
# dark version of the program's first theme, or of the theme it starts from:
#   from = Name                      start from one of the program's themes (its two versions)
#
# The keys of the dark version:
#   well bg0 bg1 bg2 bg3 line        the surfaces, from the deepest (wells, fields) to the lines
#   faint weak text bright           the texts, from the faintest
#   accent blue purple green yellow red cyan rose
#                                    the accent (selection, focus, the main button) and the hues
# The same keys with "light." before them make its light version ("light.accent = #b58900"). A theme
# with no light key stays dark in light mode.
#
# An example (remove the # at the start of its lines):
#
# [My theme]
# from = Midnight
# accent = #e5c07b
# bg0 = #050505
# text = #d0d0d0
# light.accent = #b58900
# light.bg0 = #fdf6e3
`

Themes_File :: struct {
	path:    string,                // owned
	catalog: []ui.Theme_Def,        // the program's themes (not owned): first in `all`, and what `from =` names
	all:     [dynamic]ui.Theme_Def, // the program's, then the user's (their names owned); a user's theme of a program's
	                                // theme's name takes its place
	own:     int,                   // where the user's begin in `all`
	stamp:   i64,                   // the file's time of change when last read (ns; 0: none)
	serial:  int,                   // counts the reloads: a program that keeps the theme shown shows it again
	seen:    int,                   // the serial the last poll told of
	busy:    bool,                  // a task on the file is on its way
	due_ms:  f64,                   // when the next look is due (the state's clock)
	error:   string,                // the last open that failed, in words (owned; "": none)
}

// `path`: the file (beside the preferences); `catalog`: the program's themes, which outlive it. `all` holds them at once,
// the user's come at the first poll.
themes_file_init :: proc(tf: ^Themes_File, path: string, catalog: []ui.Theme_Def) {
	tf^ = {path = strings.clone(path), catalog = catalog}
	append(&tf.all, ..catalog)
	tf.own = len(tf.all)
}

themes_file_destroy :: proc(tf: ^Themes_File) {
	for t in tf.all[tf.own:] { delete(t.name) }
	delete(tf.all)
	delete(tf.path)
	delete(tf.error)
	tf^ = {}
}

// Writes the template when there is no file at `path` (a file that is there is never touched). False: it could not be
// written. It touches the disk: a task's, never the interface's thread.
themes_file_make :: proc(path: string) -> bool {
	if os.exists(path) { return true }
	if dir := parent_dir(path); dir != "" { _ = os.make_directory_all(dir) }
	return fsx.write_atomic(path, transmute([]u8)string(THEMES_TEMPLATE))
}

@(private = "file")
parent_dir :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' { return path[:i] }
	}
	return ""
}

@(private = "file")
Open_Job :: struct {
	tf:   ^Themes_File,
	path: string,   // heap
	ok:   bool,
}

// Opens the file in the system's editor, made from the template first when it is not there. On a task; a file that could
// not be written says so in `tf.error`.
themes_file_open :: proc(tf: ^Themes_File, s: ^ui.State) {
	if tf.path == "" { return }
	a := runtime.heap_allocator()
	j := new(Open_Job, a)
	j^ = {tf = tf, path = strings.clone(tf.path, a)}
	work :: proc(d: rawptr) {
		j := (^Open_Job)(d)
		j.ok = themes_file_make(j.path)
		if j.ok { _ = platform.open_path(j.path) }
	}
	done :: proc(d: rawptr, _: u64) {
		j := (^Open_Job)(d)
		delete(j.tf.error)
		j.tf.error = j.ok ? "" : strings.clone("The file could not be written.")
		if j.ok { j.tf.due_ms = 0 }   // (looked at again at once: it may be new)
		open_job_free(d)
	}
	ui.task(s, work, done, j, open_job_free)
}

@(private = "file")
open_job_free :: proc(d: rawptr) {
	a := runtime.heap_allocator()
	j := (^Open_Job)(d)
	delete(j.path, a)
	free(j, a)
}

@(private = "file")
Theme_Read_Job :: struct {
	tf:      ^Themes_File,
	path:    string,           // heap
	catalog: []ui.Theme_Def,
	base:    ui.Theme_Def,
	known:   i64,              // the stamp the file had when last read
	stamp:   i64,
	read:    bool,             // the file changed and was read: `themes` is the new list (0 themes: the file is gone)
	themes:  [dynamic]ui.Theme_Def,   // heap, names heap
}

// Looks whether the file changed, at most every THEMES_FILE_POLL_MS (a task: its stamp, and its text when it changed,
// read and parsed off this thread). True on the build its new themes came in: `all` changed.
@(private = "file") THEMES_FILE_LOST_MS :: 30_000

themes_file_poll :: proc(tf: ^Themes_File, s: ^ui.State) -> (changed: bool) {
	changed = tf.serial != tf.seen
	tf.seen = tf.serial
	if tf.path == "" { return }
	now := ui.now_ms()
	// (a poll whose task was dropped with its state, a window closed, never answers: past THEMES_FILE_LOST_MS it is
	// taken as lost and the file is asked again)
	if tf.busy && now < tf.due_ms + THEMES_FILE_LOST_MS { return }
	if now < tf.due_ms { return }
	tf.busy = true
	tf.due_ms = now + THEMES_FILE_POLL_MS
	a := runtime.heap_allocator()
	j := new(Theme_Read_Job, a)
	j^ = {tf = tf, path = strings.clone(tf.path, a), catalog = tf.catalog, known = tf.stamp}
	if len(tf.catalog) > 0 { j.base = tf.catalog[0] }
	work :: proc(d: rawptr) {
		j := (^Theme_Read_Job)(d)
		a := runtime.heap_allocator()
		fi, err := os.stat(j.path, a)
		if err == nil {
			j.stamp = time.to_unix_nanoseconds(fi.modification_time)
			os.file_info_delete(fi, a)
		}
		if j.stamp == j.known { return }
		j.read = true
		if j.stamp == 0 { return }
		data, ok := fsx.read_all(j.path, a)
		if !ok { return }
		defer delete(data, a)
		j.themes = ui.themes_read(string(data), j.catalog, j.base, a)
	}
	done :: proc(d: rawptr, _: u64) {
		j := (^Theme_Read_Job)(d)
		tf := j.tf
		tf.busy = false
		if j.read {
			tf.stamp = j.stamp
			themes_take(tf, j.themes[:])
			tf.serial += 1
		}
		theme_read_job_free(d)
	}
	ui.task(s, work, done, j, theme_read_job_free)
	return
}

// (the answer of a poll comes in a later build: themes_file_poll says it changed there)
@(private = "file")
themes_take :: proc(tf: ^Themes_File, themes: []ui.Theme_Def) {
	for t in tf.all[tf.own:] { delete(t.name) }
	clear(&tf.all)
	append(&tf.all, ..tf.catalog)
	tf.own = len(tf.all)
	for t in themes {
		u := t
		u.name = strings.clone(t.name)
		// (a user's theme of a program's theme's name takes its place; of two of the user's, the last stands)
		for x, i in tf.all {
			if !ascii.equal_fold(x.name, u.name) { continue }
			if i >= tf.own { delete(x.name) } else { tf.own -= 1 }
			ordered_remove(&tf.all, i)
			break
		}
		append(&tf.all, u)
	}
}

@(private = "file")
theme_read_job_free :: proc(d: rawptr) {
	a := runtime.heap_allocator()
	j := (^Theme_Read_Job)(d)
	for t in j.themes { delete(t.name, a) }
	delete(j.themes)
	delete(j.path, a)
	free(j, a)
}
