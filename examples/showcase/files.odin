package showcase

// The file browser's scene: ui.file_dialog over the page, reading a demo source of its own (a person's home of fixed
// folders and files, kept in this table): the picture shows nothing of the machine it is made on, and is the same each
// run. The path bar's picture is the same scene: tk screenshots presses Ctrl+L and types (Shot.keys).

import "core:mem"
import "core:strings"
import lucide "../../src/lucide"
import "../../src/platform"
import "../../src/ui"

DEMO_HOME :: "/home/robin"
DEMO_START :: "/home/robin/Projects/harbour"

// A demo entry: a folder's path ends with "/". Its date is days before DEMO_DAY_MS, at its hour and minute.
@(private = "file")
Demo_File :: struct {
	path:         string,
	size:         i64,
	days:         int,
	hour, minute: int,
}

// 2026-11-10 at 00:00 UTC: a fixed day, so the dates the list tells are the same each run.
@(private = "file") DEMO_DAY_MS :: i64(1_794_268_800_000)
@(private = "file") DAY_MS :: i64(86_400_000)
@(private = "file") MINUTE_MS :: i64(60_000)

@(private = "file")
DEMO_FILES := [?]Demo_File{
	{"/home/", -1, 400, 9, 0},
	{"/home/robin/", -1, 2, 18, 4},
	{"/home/robin/.config/", -1, 0, 9, 12},
	{"/home/robin/.local/", -1, 12, 11, 30},
	{"/home/robin/.bashrc", 3_771, 210, 16, 2},
	{"/home/robin/Desktop/", -1, 30, 10, 0},
	{"/home/robin/Documents/", -1, 3, 15, 41},
	{"/home/robin/Downloads/", -1, 0, 8, 57},
	{"/home/robin/Music/", -1, 160, 20, 10},
	{"/home/robin/Pictures/", -1, 1, 18, 44},
	{"/home/robin/Projects/", -1, 0, 9, 20},
	{"/home/robin/Videos/", -1, 95, 21, 3},
	{"/home/robin/Desktop/sketch.png", 412_330, 30, 10, 0},
	{"/home/robin/Documents/Invoices/", -1, 14, 9, 5},
	{"/home/robin/Documents/Letters/", -1, 60, 17, 22},
	{"/home/robin/Documents/budget-2026.ods", 48_211, 3, 15, 41},
	{"/home/robin/Documents/lease.pdf", 1_204_993, 120, 12, 0},
	{"/home/robin/Documents/notes.md", 4_102, 6, 22, 18},
	{"/home/robin/Documents/Invoices/2026-10.pdf", 88_410, 14, 9, 5},
	{"/home/robin/Documents/Invoices/2026-09.pdf", 86_002, 44, 9, 1},
	{"/home/robin/Downloads/odin-linux-amd64-dev-2026-11.zip", 38_912_220, 0, 8, 57},
	{"/home/robin/Downloads/cwebp-1.4.0.tar.gz", 4_611_982, 21, 13, 40},
	{"/home/robin/Downloads/fonts.zip", 9_204_117, 70, 19, 15},
	{"/home/robin/Music/Field recordings/", -1, 160, 20, 10},
	{"/home/robin/Pictures/Shots/", -1, 1, 18, 44},
	{"/home/robin/Pictures/harbour-at-dusk.webp", 59_310, 1, 18, 42},
	{"/home/robin/Pictures/lighthouse.jpg", 348_120, 2, 11, 9},
	{"/home/robin/Pictures/pier-in-fog.png", 1_288_004, 2, 11, 2},
	{"/home/robin/Projects/harbour/", -1, 0, 14, 2},
	{"/home/robin/Projects/lantern/", -1, 9, 16, 48},
	{"/home/robin/Projects/tidepool/", -1, 41, 10, 31},
	{"/home/robin/Projects/harbour/.git/", -1, 0, 14, 2},
	{"/home/robin/Projects/harbour/assets/", -1, 18, 12, 14},
	{"/home/robin/Projects/harbour/docs/", -1, 1, 17, 55},
	{"/home/robin/Projects/harbour/examples/", -1, 5, 10, 20},
	{"/home/robin/Projects/harbour/src/", -1, 0, 14, 1},
	{"/home/robin/Projects/harbour/tests/", -1, 0, 13, 37},
	{"/home/robin/Projects/harbour/.gitignore", 212, 90, 9, 0},
	{"/home/robin/Projects/harbour/CHANGELOG.md", 18_604, 1, 17, 55},
	{"/home/robin/Projects/harbour/LICENSE", 1_068, 300, 9, 0},
	{"/home/robin/Projects/harbour/README.md", 4_310, 1, 17, 52},
	{"/home/robin/Projects/harbour/ROADMAP.md", 2_007, 4, 11, 26},
	{"/home/robin/Projects/harbour/screenshot.webp", 61_822, 1, 18, 44},
	{"/home/robin/Projects/harbour/shell.nix", 640, 33, 15, 12},
	{"/home/robin/Projects/harbour/assets/icon.png", 18_420, 18, 12, 14},
	{"/home/robin/Projects/harbour/assets/icon.svg", 2_941, 18, 12, 10},
	{"/home/robin/Projects/harbour/assets/Inter.ttf", 804_612, 200, 9, 0},
	{"/home/robin/Projects/harbour/docs/getting-started.md", 9_812, 1, 17, 55},
	{"/home/robin/Projects/harbour/docs/themes.md", 6_403, 8, 10, 2},
	{"/home/robin/Projects/harbour/docs/screenshots/", -1, 1, 18, 44},
	{"/home/robin/Projects/harbour/examples/hello/", -1, 5, 10, 20},
	{"/home/robin/Projects/harbour/examples/gallery/", -1, 5, 10, 19},
	{"/home/robin/Projects/harbour/src/render/", -1, 3, 9, 48},
	{"/home/robin/Projects/harbour/src/ui/", -1, 0, 14, 1},
	{"/home/robin/Projects/harbour/src/harbour.odin", 7_204, 0, 13, 58},
	{"/home/robin/Projects/harbour/src/tide.odin", 3_116, 2, 16, 40},
	{"/home/robin/Projects/harbour/src/ui/dock.odin", 21_380, 0, 14, 1},
	{"/home/robin/Projects/harbour/src/ui/moorings.odin", 11_902, 1, 11, 33},
	{"/home/robin/Projects/harbour/tests/tide_test.odin", 5_640, 0, 13, 37},
}

// What the preview reads of the text files: the start of each.
@(private = "file")
DEMO_TEXTS := [?][2]string{
	{"/home/robin/Projects/harbour/README.md", `# harbour

A tide table for the small ports of the coast: the hours of high and low water, the
coefficients, and a warning when the wind turns against the tide.

## Build

    odin build src -out:build/harbour

## Use

Open a port with Ctrl+O, or drop its file on the window. The table follows the
clock; Space jumps to now.
`},
	{"/home/robin/Projects/harbour/CHANGELOG.md", `# Changelog

## [0.7.0] - 2026-11-09

### Added

- **The wind against the tide** is told in the hour's line.
- **Ports of the Channel Islands.**

### Fixed

- **Spring tides** no longer round the coefficient down.
`},
	{"/home/robin/Projects/harbour/ROADMAP.md", `# Roadmap

## Now

- **A week at a glance**: seven days of tides side by side.

## Next

- **Print a month** on one page.
`},
	{"/home/robin/Projects/harbour/src/harbour.odin", `package harbour

import "core:fmt"
import "core:time"

// A port's tides for one day: the hours of high and low water.
Day :: struct {
	high, low: [2]time.Time,
	coefficient: int,
}

main :: proc() {
	port := port_open("saint-malo")
	defer port_close(&port)
	fmt.println(day_of(port, time.now()))
}
`},
	{"/home/robin/Documents/notes.md", `# Notes

- call the harbour master about the new pontoon
- tide tables for December
- order the chart of the bay
`},
}

// The demo source: every call answers at once, from the tables above.
demo_files :: proc() -> ui.File_Source {
	return ui.File_Source{
		caps = {.Size, .Modified, .Read}, separator = '/',
		list = demo_list, read = demo_read, find = demo_find, places = demo_places, start = demo_start,
	}
}

@(private = "file")
demo_entry :: proc(f: Demo_File, name: string) -> ui.File_Entry {
	folder := strings.has_suffix(f.path, "/")
	return {
		name = name, kind = folder ? ui.File_Kind.Folder : ui.File_Kind.File, size = folder ? -1 : f.size,
		modified = DEMO_DAY_MS - i64(f.days) * DAY_MS + i64(f.hour * 60 + f.minute) * MINUTE_MS,
	}
}

@(private = "file")
demo_is_folder :: proc(path: string) -> bool {
	p := ui.file_path_trim(path, '/')
	if p == "/" { return true }
	for f in DEMO_FILES {
		if strings.has_suffix(f.path, "/") && f.path[:len(f.path) - 1] == p { return true }
	}
	return false
}

@(private = "file")
demo_list :: proc(src: ^ui.File_Source, path: string, reply: ui.File_Reply) {
	folder := ui.file_path_trim(path, '/')
	if !demo_is_folder(folder) {
		ui.file_reply_failed(reply, "This folder does not exist.", missing = true)
		return
	}
	entries := make([dynamic]ui.File_Entry, context.temp_allocator)
	for f in DEMO_FILES {
		p := ui.file_path_trim(f.path, '/')
		if ui.file_path_parent(p, '/') != folder || p == folder { continue }
		append(&entries, demo_entry(f, ui.file_path_name(p, '/')))
	}
	ui.file_reply_listed(reply, entries[:])
}

@(private = "file")
demo_read :: proc(src: ^ui.File_Source, path: string, max: int, reply: ui.File_Reply) {
	size := i64(-1)
	for f in DEMO_FILES { if f.path == path { size = f.size } }
	if size < 0 {
		ui.file_reply_failed(reply, "This file does not exist.", missing = true)
		return
	}
	for t in DEMO_TEXTS {
		if t[0] != path { continue }
		text := transmute([]u8)(t[1])
		ui.file_reply_read(reply, text[:min(max, len(text))], i64(len(text)))
		return
	}
	// (no bytes: the preview shows the file's icon, its name, its size and its date)
	ui.file_reply_read(reply, nil, size)
}

// Every entry under `folder` whose path from it matches `query`, best first.
@(private = "file")
demo_find :: proc(src: ^ui.File_Source, folder, query: string, limit: int, reply: ui.File_Reply) {
	Found :: struct { entry: ui.File_Entry, score: int }
	base := ui.file_path_trim(folder, '/')
	found := make([dynamic]Found, context.temp_allocator)
	for f in DEMO_FILES {
		p := ui.file_path_trim(f.path, '/')
		if p == base || !ui.file_path_within(p, base, '/') { continue }
		relative := strings.trim_prefix(p[len(base):], "/")
		if !reply.hidden && (strings.has_prefix(relative, ".") || strings.contains(relative, "/.")) { continue }
		score, _, ok := ui.fuzzy_score(query, relative)
		if !ok { continue }
		append(&found, Found{demo_entry(f, relative), score})
	}
	// (a few dozen entries: an insertion by score keeps the best first)
	for i in 1 ..< len(found) {
		for k := i; k > 0 && found[k].score > found[k - 1].score; k -= 1 { found[k], found[k - 1] = found[k - 1], found[k] }
	}
	entries := make([]ui.File_Entry, min(len(found), limit), context.temp_allocator)
	for &e, i in entries { e = found[i].entry }
	ui.file_reply_found(reply, entries)
}

@(private = "file")
demo_places :: proc(src: ^ui.File_Source, allocator: mem.Allocator) -> []platform.File_Place {
	places := []platform.File_Place{
		{name = "Home", path = DEMO_HOME, icon = lucide.HOME},
		{name = "Desktop", path = DEMO_HOME + "/Desktop", icon = lucide.MONITOR},
		{name = "Documents", path = DEMO_HOME + "/Documents", icon = lucide.FILE_TEXT},
		{name = "Downloads", path = DEMO_HOME + "/Downloads", icon = lucide.DOWNLOAD},
		{name = "Pictures", path = DEMO_HOME + "/Pictures", icon = lucide.IMAGE},
		{name = "Music", path = DEMO_HOME + "/Music", icon = lucide.MUSIC},
		{name = "Projects", path = DEMO_HOME + "/Projects", icon = lucide.FOLDER_TREE},
		{name = "/", path = "/"},
	}
	out := make([]platform.File_Place, len(places), allocator)
	copy(out, places)
	return out
}

@(private = "file")
demo_start :: proc(src: ^ui.File_Source, allocator: mem.Allocator) -> string { return strings.clone(DEMO_START, allocator) }

// Opens the browser over the page, on the demo source: an Open dialog of the project's files.
files_open :: proc(app: ^App) {
	places := []platform.File_Place{{name = "Last session", path = DEMO_START + "/src/ui", icon = lucide.STAR}}
	ui.file_dialog(&app.main.state, .Open, {
		owner = app.main.win, title = "Open a file", start_dir = DEMO_START, remember_id = "showcase_files",
		places = places, multiple = true,
	}, files_done, app, source = &app.files)
}

@(private = "file")
files_done :: proc(r: platform.Dialog_Result, user: rawptr) {
	app := (^App)(user)
	switch r.status {
	case .Chosen:
		if len(r.paths) > 0 { ui.announce(&app.announcer, .Good, "Opened", r.paths[0]) }
	case .Cancelled, .Unsupported, .Failed:
	}
}
