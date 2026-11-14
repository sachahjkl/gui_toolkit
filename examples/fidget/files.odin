package fidget

// The Files card of the Inputs page: the toolkit's file browser in its three modes, and its path bar on its own.
// The browser reads the computer's files (ui.local_files): a person who runs fidget picks real files. It opens on a
// click only, so a test reads no disk unless it clicks, and then platform.dialog_test_hook answers in its place.
// The path bar walks a fixed tree of a project's folders: a program's own folders, which the bar knows nothing of.

import "core:fmt"
import "core:math"
import "core:strings"
import "../../src/platform"
import "../../src/ui"

// The project's folders the path bar walks. A folder is its index here: the card keeps no string of its own.
FILES_TREE := [?]string{
	"/",
	"/harbour", "/harbour/assets", "/harbour/docs", "/harbour/docs/screenshots", "/harbour/examples",
	"/harbour/src", "/harbour/src/render", "/harbour/src/ui", "/harbour/src/ui/widgets", "/harbour/tests",
	"/lantern", "/lantern/src", "/lantern/web", "/lantern/web/static",
	"/tidepool", "/tidepool/data", "/tidepool/notebooks",
}
FILES_START :: 6   // "/harbour/src"

// The bar's suggestions, under "Places": set once (files_init), not per frame.
files_init :: proc(app: ^App) {
	app.files_folder = FILES_START
	places := []ui.Path_Bar_Entry{
		{name = "harbour", path = "/harbour", detail = "Project", branch = true},
		{name = "lantern", path = "/lantern", detail = "Project", branch = true},
		{name = "tidepool", path = "/tidepool", detail = "Project", branch = true},
	}
	groups := []ui.Path_Bar_Group{{title = "Places", entries = places}}
	ui.path_bar_suggestions(&app.files_bar, groups)
}

files_destroy :: proc(app: ^App) {
	ui.path_bar_destroy(&app.files_bar)
	delete(app.files_said)
	app.files_said = ""
}

// The index of a folder of the tree (-1: none).
files_index :: proc(path: string) -> int {
	p := ui.file_path_trim(path, '/')
	for f, i in FILES_TREE { if f == p { return i } }
	return -1
}

files_card :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.8))})
	if ui.row(.Center, id = "###files_acts") {
		if ui.button("###fb_open", "Open…", ICON_FOLDER_OPEN).clicked { files_dialog(app, .Open) }
		ui.spacer(ui.px(em * 0.5))
		if ui.button("###fb_folder", "Folder…", ICON_FOLDER).clicked { files_dialog(app, .Folder) }
		ui.spacer(ui.px(em * 0.5))
		if ui.button("###fb_save", "Save as…", ICON_SAVE).clicked { files_dialog(app, .Save) }
	}
	if app.files_said != "" {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
		ui.label(fmt.tprintf("%s###files_said", app.files_said))
	} else if ui.tags("weak") {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
		ui.label("Nothing chosen yet.###files_said")
	}
	ui.spacer(ui.px(em * 0.6))
	if ui.tags("weak") {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.8)), font_size = math.round(em * 0.85)})
		ui.label("A project's folders in ui.path_bar: click a part, or its empty end to type (fuzzy).")
	}
	folder := FILES_TREE[app.files_folder]
	ui.next({width = ui.fill()})
	ev := ui.path_bar("###files_bar", &app.files_bar, folder, {separator = '/', name = "Project folder", placeholder = "A folder of the project"})
	if w, ok := ev.wants.?; ok { files_children(app, w) }
	if p, ok := ev.go.?; ok {
		if i := files_index(ui.file_path_clean(p, '/')); i >= 0 {
			app.files_folder = i
		} else {
			ui.announce(&app.announcer, .Warn, fmt.tprintf("%s is not a folder of the project", p))
		}
	}
}

// The folders right under `folder`, answered at once: the tree is in memory.
@(private = "file")
files_children :: proc(app: ^App, folder: string) {
	f := ui.file_path_trim(folder, '/')
	if files_index(f) < 0 {
		ui.path_bar_failed(&app.files_bar, folder, "No such folder in the project.")
		return
	}
	entries := make([dynamic]ui.Path_Bar_Entry, context.temp_allocator)
	for p in FILES_TREE {
		if p == "/" || ui.file_path_parent(p, '/') != f { continue }
		append(&entries, ui.Path_Bar_Entry{name = ui.file_path_name(p, '/'), branch = true})
	}
	ui.path_bar_children(&app.files_bar, folder, entries[:])
}

@(private = "file")
files_dialog :: proc(app: ^App, kind: ui.File_Dialog_Kind) {
	d := platform.File_Dialog{owner = app.win, remember_id = "fidget_files"}
	filters := []platform.File_Filter{{name = "Text", patterns = {"*.txt", "*.md"}}, {name = "Images", patterns = {"*.png", "*.jpg", "*.webp"}}}
	switch kind {
	case .Open:
		d.title, d.multiple, d.filters, d.all_files = "Open files", true, filters, true
	case .Folder:
		d.title = "Choose a folder"
	case .Save:
		d.title, d.suggested_name, d.default_ext, d.overwrite_prompt = "Save as", "notes.txt", "txt", true
		d.filters = filters[:1]
	}
	ui.file_dialog(&app.ui_state, kind, d, files_done, app)
}

// (the paths are freed after the call: the card keeps its own words)
@(private = "file")
files_done :: proc(r: platform.Dialog_Result, user: rawptr) {
	app := (^App)(user)
	delete(app.files_said)
	switch r.status {
	case .Chosen:
		switch len(r.paths) {
		case 0: app.files_said = strings.clone("Chosen: nothing.")
		case 1: app.files_said = fmt.aprintf("Chosen: %s", r.paths[0])
		case:   app.files_said = fmt.aprintf("Chosen: %d files, the first %s", len(r.paths), r.paths[0])
		}
	case .Cancelled:
		app.files_said = strings.clone("Cancelled.")
	case .Unsupported, .Failed:
		app.files_said = strings.clone("The dialog failed.")
	}
}
