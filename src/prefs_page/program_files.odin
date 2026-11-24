package tk_prefs_page

// A program's standard files and the start of its preferences (src/md/features/program-files.md).
//
//	files := prefs_page.program_files(APP_FOLDER, memory = headless)
//	defer prefs_page.program_files_destroy(&files)
//	rest, problems := prefs_page.prefs_open(&prefs, files, prefs_page.STANDARD_ALL, standard_defaults(), {PREF_DEFS[:]}, args)
//	ui.views_init(&views, {path = files.views})

import "base:runtime"
import "core:path/filepath"
import config "../config"
import "../platform"

// The files every program keeps, by their place: the person's choices in the config folder, the memory in the state
// folder. A path "" is memory only: nothing is read or written there.
Program_Files :: struct {
	config_dir:      string,   // the program's config folder
	state_dir:       string,   // the program's state folder
	prefs:           string,   // the preferences (config: "prefs")
	themes:          string,   // the person's own themes (config: "themes.txt"; Themes_File)
	views:           string,   // how each view is shown (state: "views.txt"; ui.views_init)
	palette_choices: string,   // the palette's memory of what was chosen (state: "palette_choices.txt")
	file_dialogs:    string,   // the file dialogs' folders, sizes and recent folders (state: "file_dialogs.txt")
	allocator:       runtime.Allocator,
}

PREFS_FILE           :: "prefs"
THEMES_FILE          :: "themes.txt"
VIEWS_FILE           :: "views.txt"
PALETTE_CHOICES_FILE :: "palette_choices.txt"
FILE_DIALOGS_FILE    :: "file_dialogs.txt"

// The paths of the program whose folder is `folder` (platform.user_dir's name). `memory`: every path "" (a test, a
// headless run). A test that keeps one file sets that field afterwards, in `allocator` (program_files_destroy frees it).
program_files :: proc(folder: string, memory := false, allocator := context.allocator) -> (f: Program_Files) {
	f.allocator = allocator
	if memory { return }
	f.config_dir = platform.user_dir(.Config, folder, allocator)
	f.state_dir = platform.user_dir(.State, folder, allocator)
	in_dir :: proc(dir, name: string, allocator: runtime.Allocator) -> string {
		if dir == "" { return "" }
		p, _ := filepath.join({dir, name}, allocator)
		return p
	}
	f.prefs = in_dir(f.config_dir, PREFS_FILE, allocator)
	f.themes = in_dir(f.config_dir, THEMES_FILE, allocator)
	f.views = in_dir(f.state_dir, VIEWS_FILE, allocator)
	f.palette_choices = in_dir(f.state_dir, PALETTE_CHOICES_FILE, allocator)
	f.file_dialogs = in_dir(f.state_dir, FILE_DIALOGS_FILE, allocator)
	return
}

program_files_destroy :: proc(f: ^Program_Files) {
	a := f.allocator
	for s in ([]string{f.config_dir, f.state_dir, f.prefs, f.themes, f.views, f.palette_choices, f.file_dialogs}) {
		delete(s, a)
	}
	f^ = {}
}

// A new registry in `p`: the toolkit's standard preferences (`sets`, with the program's `defaults`), the program's own
// (`defs`, in order), the version last started (What's new), then the file `files.prefs` ("": none read), then the
// command line's --pref in `args`. `rest`: the arguments that are not preferences; `problems`: the file's, then the
// command line's (both in the temporary allocator). `descriptions`: where the standard preferences make their
// descriptions, which the registry keeps and never frees. It reads a file: call it at the start, before the loop.
prefs_open :: proc(p: ^config.Prefs, files: Program_Files, sets: Standard, defaults: Standard_Defaults, defs: [][]config.Def, args: []string, descriptions := context.allocator) -> (rest: [dynamic]string, problems: [dynamic]string) {
	p^ = config.prefs_make()
	standard_register(p, sets, defaults, descriptions)
	for d in defs { config.register(p, d) }
	changelog_register(p)
	problems = make([dynamic]string, context.temp_allocator)
	if files.prefs != "" {
		_, file_problems := config.load_file(p, files.prefs, .User)
		append(&problems, ..file_problems[:])
	}
	arg_problems: [dynamic]string
	rest, arg_problems = config.apply_args(p, args, context.temp_allocator)
	append(&problems, ..arg_problems[:])
	return
}
