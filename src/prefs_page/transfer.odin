package tk_prefs_page

// Export and Import, at the foot of the sidebar. Export writes the user's settings (what differs from the defaults) in
// the format of the file's extension: JSON (as the settings.json of Zed or VS Code), TOML, INI, or this program's own
// (config.export with .Own), which Import reads back: settings carried from one machine to another. The other formats are
// written only (docs/config.md, "Export").
//
// The dialogs and the disk are tasks: the system's file dialog (ui.file_dialog), then the text made here (it reads the
// registry, which is this thread's) and written by a task; a file imported is read by a task, then its values set here
// (config.load_text), each change told to Options.changed as a change of the page.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "../ascii"
import config "../config"
import i18n "../i18n"
import "../fsx"
import "../platform"
import "../ui"

// The extension of each format (config.Export_Format: the order of the dialog's types).
@(private = "file", rodata) EXPORT_EXTS := [config.Export_Format]string{.Json = "json", .Toml = "toml", .Ini = "ini", .Own = "txt"}

// The format of a file by its extension ("settings.json": Json); a name with none of them: `chosen`, the type picked in
// the dialog.
export_format_of :: proc(path: string, chosen := config.Export_Format.Json) -> config.Export_Format {
	dot := strings.last_index_byte(path, '.')
	slash := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	if dot > slash {
		ext := path[dot + 1:]
		for e, f in EXPORT_EXTS { if ascii.equal_fold(ext, e) { return f } }
	}
	return chosen
}

// The Export button: the system's dialog to save, then export_to.
@(private)
export_ask :: proc(p: ^Page) {
	if p.state == nil { return }
	json := [?]string{"*.json"}
	toml := [?]string{"*.toml"}
	ini := [?]string{"*.ini"}
	own := [?]string{"*.txt"}
	filters := [?]platform.File_Filter{{name = "JSON", patterns = json[:]}, {name = "TOML", patterns = toml[:]}, {name = "INI", patterns = ini[:]}, {name = i18n.tr("This program's settings (to import)"), patterns = own[:]}}
	ui.file_dialog(p.state, .Save, {title = i18n.tr("Export the settings"), filters = filters[:], suggested_name = "settings.json", default_ext = "json", overwrite_prompt = true, remember_id = "prefs_page.export"},
		proc(r: platform.Dialog_Result, user: rawptr) {
			p := (^Page)(user)
			if r.status != .Chosen || len(r.paths) == 0 { return }
			chosen := config.Export_Format(clamp(r.filter, 0, int(max(config.Export_Format))))
			export_to(p, r.paths[0], export_format_of(r.paths[0], chosen))
		}, p)
}

@(private = "file")
Write_Job :: struct {
	page:  ^Page,
	path:  string,   // heap
	text:  string,   // heap
	ok:    bool,
}

// Writes the user's settings to `path` in `format`: the text is made now, a task writes it; what came of it shows at the
// foot of the sidebar (Page.note). The page's state must be built once (build) before.
export_to :: proc(p: ^Page, path: string, format: config.Export_Format) {
	if p.state == nil || p.prefs == nil { return }
	a := runtime.heap_allocator()
	j := new(Write_Job, a)
	j^ = {page = p, path = strings.clone(path, a), text = config.export(p.prefs, format, allocator = a)}
	work :: proc(d: rawptr) {
		j := (^Write_Job)(d)
		j.ok = fsx.write_atomic(j.path, transmute([]u8)j.text)
	}
	done :: proc(d: rawptr, _: u64) {
		j := (^Write_Job)(d)
		shown := home_short(j.path, context.temp_allocator)
		note_set(j.page, j.ok ? fmt.tprintf(i18n.tr("Exported to %s."), shown) : fmt.tprintf(i18n.tr("%s could not be written."), shown), !j.ok)
		write_job_free(d)
	}
	ui.task(p.state, work, done, j, write_job_free)
}

@(private = "file")
write_job_free :: proc(d: rawptr) {
	a := runtime.heap_allocator()
	j := (^Write_Job)(d)
	delete(j.path, a)
	delete(j.text, a)
	free(j, a)
}

// The Import button: the system's dialog to open, then import_from.
@(private)
import_ask :: proc(p: ^Page) {
	if p.state == nil { return }
	own := [?]string{"*.txt"}
	filters := [?]platform.File_Filter{{name = i18n.tr("This program's settings"), patterns = own[:]}}
	ui.file_dialog(p.state, .Open, {title = i18n.tr("Import settings"), filters = filters[:], all_files = true, remember_id = "prefs_page.export"},
		proc(r: platform.Dialog_Result, user: rawptr) {
			p := (^Page)(user)
			if r.status != .Chosen || len(r.paths) == 0 { return }
			import_from(p, r.paths[0])
		}, p)
}

@(private = "file")
Import_Job :: struct {
	page: ^Page,
	path: string,   // heap
	text: []byte,   // heap
	ok:   bool,
}

// Reads settings exported in this program's own format (config.Export_Format.Own) from `path`: a task reads the file, then its
// values are the user's, as if set on the page (Options.changed for each that changed; the loop's writer saves them).
// What came of it shows at the foot of the sidebar.
import_from :: proc(p: ^Page, path: string) {
	if p.state == nil || p.prefs == nil { return }
	a := runtime.heap_allocator()
	j := new(Import_Job, a)
	j^ = {page = p, path = strings.clone(path, a)}
	work :: proc(d: rawptr) {
		j := (^Import_Job)(d)
		j.text, j.ok = fsx.read_all(j.path, runtime.heap_allocator())
	}
	done :: proc(d: rawptr, _: u64) {
		j := (^Import_Job)(d)
		p := j.page
		shown := home_short(j.path, context.temp_allocator)
		if !j.ok {
			note_set(p, fmt.tprintf(i18n.tr("%s could not be read."), shown), true)
		} else {
			// (what each value was, to tell the program of those that changed)
			before := make([]string, len(p.prefs.entries), context.temp_allocator)
			for _, i in p.prefs.entries { before[i] = config.value_string(p.prefs, config.Ref(i)) }
			applied, problems := config.load_text(p.prefs, string(j.text), .User, shown, change = true)
			for i in 0 ..< min(len(before), len(p.prefs.entries)) {
				if p.changed == nil { break }
				if config.value_string(p.prefs, config.Ref(i)) != before[i] { p.changed(p.user, p.prefs.entries[i].def.name) }
			}
			// (each count takes its own form: two forms of one sentence cannot follow two counts)
			imported := fmt.tprintf(i18n.tr(applied, "Imported %d settings from %s", "Imported %d settings from %s"), applied, shown)
			switch {
			case applied == 0 && len(problems) > 0: note_set(p, problems[0], true)
			case len(problems) > 0:
				refused := fmt.tprintf(i18n.tr(len(problems), "%d refused (%s)", "%d refused (%s)"), len(problems), problems[0])
				note_set(p, fmt.tprintf(i18n.tr("%s; %s."), imported, refused), true)
			case: note_set(p, fmt.tprintf("%s.", imported), false)
			}
		}
		import_job_free(d)
	}
	ui.task(p.state, work, done, j, import_job_free)
}

@(private = "file")
import_job_free :: proc(d: rawptr) {
	a := runtime.heap_allocator()
	j := (^Import_Job)(d)
	delete(j.path, a)
	delete(j.text, a)
	free(j, a)
}

@(private = "file")
note_set :: proc(p: ^Page, text: string, bad: bool) {
	delete(p.note)
	p.note = strings.clone(text)
	p.note_bad = bad
}
