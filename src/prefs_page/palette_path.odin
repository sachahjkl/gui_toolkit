package tk_prefs_page

// A path completes in the palette's run mode (src/md/features/everything-palette.md, "A path completes"): under the
// field, the entries of the folder typed whose names start with the last part of it; Up and Down choose one, Tab puts it
// in the field (a folder with its separator, so the next Tab goes on inside it), Enter keeps the field's text as the
// value. The folder is read on a chore, as the file browser reads: never on the interface's thread, never at each build
// (only when the folder typed changes).

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "../ascii"
import "../fsx"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"
import "../ui"

// The entries of the folder last read for a path's run, and the read on its way.
@(private)
Path_Completion :: struct {
	dir:     string,               // (owned) the folder as typed ("~/Doc" gives "~/"): what the entries are of
	names:   [dynamic]string,      // (owned) its entries, folders first, each group by name
	folders: [dynamic]bool,        // ... whether each is a folder
	reading: ^Path_Read,           // the chore's job while it runs (nil: none)
	failed:  bool,                 // the folder cannot be read
	rows:    [dynamic]int,         // the entries the last part keeps
	rows_for: string,              // (owned) the field's text they were kept for
	sub:     ui.Palette_Sublist,
}

// One read of a folder on a chore. Its run may end before it does: `orphan` says so, and the job frees itself.
@(private = "file")
Path_Read :: struct {
	owner:   ^Path_Completion,
	dir:     string,               // (owned) as typed
	read_at: string,               // (owned) as read ("~" expanded)
	names:   [dynamic]string,
	folders: [dynamic]bool,
	failed:  bool,
	orphan:  bool,
}

// The run ends: its entries go; a read still on the chores is left to free itself.
@(private)
path_completion_end :: proc(c: ^Path_Completion) {
	if c.reading != nil { c.reading.orphan = true }
	path_entries_clear(c)
	delete(c.dir)
	delete(c.rows)
	delete(c.rows_for)
	c^ = {}
}

@(private = "file")
path_entries_clear :: proc(c: ^Path_Completion) {
	for n in c.names { delete(n) }
	clear(&c.names)
	clear(&c.folders)
}

// Where the folder part of `text` ends: after its last separator ("/" everywhere, "\" too on Windows).
@(private = "file")
path_split :: proc(text: string) -> (dir, last: string) {
	i := strings.last_index_byte(text, '/')
	when ODIN_OS == .Windows { i = max(i, strings.last_index_byte(text, '\\')) }
	return text[:i + 1], text[i + 1:]
}

// The control of a path in the run mode: the entries that complete the field's last part, Tab takes the one selected.
@(private)
path_build :: proc(p: ^ui.Command_Palette, c: ^Path_Completion, query: string, keys: ui.Palette_Run_Keys, height: f32) {
	em := ui.font_size()
	dir, last := path_split(query)
	if dir != "" && dir != c.dir && (c.reading == nil || c.reading.dir != dir) { path_read(c, dir) }
	if dir == "" {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), text_pad = em * 0.9})
			ui.label(fmt.tprintf("%s###path_hint", i18n.tr("Type a folder, then Tab completes its entries")))
		}
		return
	}
	if c.dir != dir {   // (the folder typed is on its way)
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), text_pad = em * 0.9})
			ui.label(fmt.tprintf("%s###path_reading", i18n.tr("Reading the folder…")))
		}
		return
	}
	// (the entries the last part keeps: made when the field's text changes, never at each build)
	if c.rows_for != query {
		delete(c.rows_for)
		c.rows_for = strings.clone(query)
		clear(&c.rows)
		hidden := strings.has_prefix(last, ".")
		for n, i in c.names {
			if !hidden && strings.has_prefix(n, ".") { continue }
			if len(n) < len(last) || !ascii.equal_fold(n[:len(last)], last) { continue }
			append(&c.rows, i)
		}
		c.sub.sel, c.sub.reveal = 0, true
	}
	if c.failed || len(c.rows) == 0 {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), text_align = .Center})
			ui.label(fmt.tprintf("%s###path_none", c.failed ? i18n.tr("This folder cannot be read") : i18n.tr("Nothing matches")))
		}
		return
	}
	_, clicked := ui.palette_sublist("###path_rows", &c.sub, len(c.rows), keys.step, height, path_row, c)
	if (keys.tab || clicked >= 0) && c.sub.sel >= 0 && c.sub.sel < len(c.rows) {
		i := c.rows[c.sub.sel]
		sep := ODIN_OS == .Windows ? "\\" : "/"
		ui.palette_run_set_text(p, fmt.tprintf("%s%s%s", dir, c.names[i], c.folders[i] ? sep : ""))
	}
}

// One entry: a folder's or a file's icon, its name with the part typed marked.
@(private = "file")
path_row :: proc(user: rawptr, k: int, selected: bool) {
	c := (^Path_Completion)(user)
	em := ui.font_size()
	i := c.rows[k]
	ui.spacer(ui.px(math.round(em * 0.9)))
	ui.next({width = ui.px(em * 1.4), height = ui.pct(1), font = ui.lucide_icons(), font_size = em * 0.9, text_align = .Center, text_pad = 0})
	ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###i", c.folders[i] ? lucide.FOLDER : lucide.FILE))
	ui.space(ui.ICON_GAP)
	ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
	_, last := path_split(c.rows_for)
	ranges := len(last) > 0 ? []ui.Fuzzy_Range{{0, len(last)}} : nil
	ui.matched_label("###t", c.names[i], ranges)
	ui.spacer(ui.px(math.round(em * 0.9)))
}

// Reads the folder `dir` (as typed) on a chore; its answer replaces the entries at the interface's next turn.
@(private = "file")
path_read :: proc(c: ^Path_Completion, dir: string) {
	if c.reading != nil { c.reading.orphan = true }
	j := new(Path_Read)
	j.owner, j.dir = c, strings.clone(dir)
	at := dir
	if strings.has_prefix(at, "~") {
		home := platform.known_folder_path(.Home, context.temp_allocator)
		at = strings.concatenate({home, at[1:]}, context.temp_allocator)
	}
	j.read_at = strings.clone(at)
	c.reading = j
	ui.task(ui.current_state(), proc(data: rawptr) {
		j := (^Path_Read)(data)
		entries, err := fsx.read_folder(j.read_at, context.temp_allocator)
		if err != nil { j.failed = true; return }
		// (folders first: the next Tab goes on inside one; each group by name, case folded)
		slice.sort_by(entries, proc(a, b: fsx.Folder_Entry) -> bool {
			fa, fb := a.kind == .Directory, b.kind == .Directory
			if fa != fb { return fa }
			return ascii.compare_fold(a.name, b.name) < 0
		})
		for e in entries {
			append(&j.names, strings.clone(e.name))
			append(&j.folders, e.kind == .Directory)
		}
	}, proc(data: rawptr, _: u64) {
		j := (^Path_Read)(data)
		if !j.orphan {
			c := j.owner
			path_entries_clear(c)
			delete(c.names)
			delete(c.folders)
			delete(c.dir)
			c.names, c.folders, c.dir, c.failed = j.names, j.folders, j.dir, j.failed
			j.names, j.folders, j.dir = {}, {}, ""
			delete(c.rows_for)
			c.rows_for = ""
			c.reading = nil
		}
		path_read_free(j)
	}, j, proc(data: rawptr) { path_read_free((^Path_Read)(data)) })
}

@(private = "file")
path_read_free :: proc(j: ^Path_Read) {
	for n in j.names { delete(n) }
	delete(j.names)
	delete(j.folders)
	delete(j.dir)
	delete(j.read_at)
	free(j)
}
