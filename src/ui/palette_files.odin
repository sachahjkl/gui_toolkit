package ui

// Palette source backed by gt:filesearch (src/md/features/file-search.md): plugs a fast typo-tolerant file and folder
// index into ui.Command_Palette under the Paths ('/') prefix (and optionally plain search) without ever touching disk,
// search, or LMDB on the interface thread.
//
//   ui.palette_files_add(&app.palette, &app.files, {dirs = true})
//   ui.palette_files_set(&app.files, idx, project_root)
//   // when palette_chosen returns c.source == &app.files.source:
//   ui.palette_files_opened(&app.ui, app.files.index, c.id)

import "base:runtime"
import "core:strings"
import filesearch "../filesearch"
import "../fsx"
import i18n "../i18n"
import lucide "../lucide"

// Default maximum results returned per palette query.
PALETTE_FILES_LIMIT_DEFAULT :: 50

// Configuration for ui.palette_files_add.
Palette_Files_Options :: struct {
	title:      string,             // English heading/hint label ("": "Files")
	plain:      bool,               // also search without typing the '/' prefix
	dirs:       bool,               // include directories alongside files
	limit:      int,                // max hits per query (0: PALETTE_FILES_LIMIT_DEFAULT)
	root:       string,             // optional root directory joined onto hit paths to form Palette_Item.id ("": relative)
	enter:      string,             // English label for Enter in the hint row ("": "Open")
	alternates: Palette_Alternates, // optional Ctrl+Enter / Alt+Enter hints
}

// Reusable '/' palette source backed by a filesearch.Index. Keep at a stable address while registered with the palette.
Palette_Files :: struct {
	source: Palette_Source,
	index:  filesearch.Index,
	root:   string, // owned (runtime.heap_allocator)
	dirs:   bool,
	limit:  int,
}

@(private = "file")
Palette_Files_Job :: struct {
	q:        Palette_Question,
	index:    filesearch.Index,
	root:     string,
	query:    string,
	dirs:     bool,
	limit:    int,
	ans:      Palette_Answer,
	answered: bool,
}

@(private = "file")
Palette_Files_Open_Job :: struct {
	index: filesearch.Index,
	path:  string,
}

// Registers `pf` on `p` as a searching Paths ('/') source. Call palette_files_set once an index is open and
// palette_files_destroy before freeing `pf`.
palette_files_add :: proc(p: ^Command_Palette, pf: ^Palette_Files, o := Palette_Files_Options{}) {
	a := runtime.heap_allocator()
	delete(pf.root, a)
	pf.root = o.root != "" ? strings.clone(o.root, a) : ""
	pf.dirs = o.dirs
	pf.limit = o.limit > 0 ? o.limit : PALETTE_FILES_LIMIT_DEFAULT
	pf.source = {
		name       = "file",
		title      = o.title != "" ? o.title : i18n.later("Files"),
		prefix     = .Paths,
		plain      = o.plain,
		remember   = true,
		searches   = true,
		enter      = o.enter != "" ? o.enter : i18n.later("Open"),
		alternates = o.alternates,
		read       = palette_files_read,
		user       = pf,
	}
	palette_add(p, &pf.source)
}

// Updates the active filesearch.Index (0 clears results) and optional root prefix, bumping the source version so an open
// palette queries the new index immediately.
palette_files_set :: proc(pf: ^Palette_Files, index: filesearch.Index, root := "") {
	a := runtime.heap_allocator()
	if pf.index == index && pf.root == root { return }
	delete(pf.root, a)
	pf.root = root != "" ? strings.clone(root, a) : ""
	pf.index = index
	pf.source.version += 1
}

// Records a chosen file path in the index's LMDB frecency store on a background chore so the interface thread never
// blocks on disk I/O. Safe no-op when `index` is 0, `path` is empty, or GT_FILESEARCH is disabled.
palette_files_opened :: proc(s: ^State, index: filesearch.Index, path: string) {
	if s == nil || index == 0 || path == "" || !filesearch.available() { return }
	a := runtime.heap_allocator()
	j := new(Palette_Files_Open_Job, a)
	j^ = {index = index, path = strings.clone(path, a)}
	task(s, palette_files_open_work, nil, j, palette_files_open_free)
}

// Frees memory owned by `pf` (does not close `pf.index`, which belongs to the caller).
palette_files_destroy :: proc(pf: ^Palette_Files) {
	delete(pf.root, runtime.heap_allocator())
	pf^ = {}
}

@(private = "file")
palette_files_split_rel :: proc(rel: string) -> (name, dir: string) {
	i := strings.last_index_byte(rel, '/')
	if i < 0 { return rel, "" }
	return rel[i + 1:], rel[:i]
}

@(private = "file")
palette_files_read :: proc(p: ^Command_Palette, src: ^Palette_Source, q: Palette_Question) {
	pf := (^Palette_Files)(src.user)
	if pf == nil || pf.index == 0 || !filesearch.available() {
		ans: Palette_Answer
		palette_answer(q, &ans)
		return
	}
	a := runtime.heap_allocator()
	j := new(Palette_Files_Job, a)
	j^ = {
		q     = q,
		index = pf.index,
		root  = pf.root != "" ? strings.clone(pf.root, a) : "",
		query = strings.clone(q.query, a),
		dirs  = pf.dirs,
		limit = pf.limit > 0 ? pf.limit : PALETTE_FILES_LIMIT_DEFAULT,
	}
	task(p.owner != nil ? p.owner : gs(), palette_files_work, palette_files_done, j, palette_files_job_free)
}

@(private = "file")
palette_files_work :: proc(d: rawptr) {
	j := (^Palette_Files_Job)(d)
	page, err := filesearch.search(j.index, j.query, {limit = j.limit, dirs = j.dirs}, runtime.heap_allocator())
	if err != .None { return }
	defer filesearch.page_destroy(&page, runtime.heap_allocator())
	if len(page.hits) == 0 { return }

	a := palette_answer_allocator(&j.ans)
	items := make([]Palette_Item, len(page.hits), a)
	sep: u8 = '/'
	when ODIN_OS == .Windows { sep = '\\' }
	for hit, i in page.hits {
		name, dir := palette_files_split_rel(hit.path)
		id: string
		if j.root != "" {
			id = fsx.path_join(j.root, hit.path, sep, a)
		} else {
			id = strings.clone(hit.path, a)
		}
		items[i] = {
			id     = id,
			title  = strings.clone(name, a),
			detail = dir != "" ? strings.clone(dir, a) : "",
			icon   = hit.dir ? lucide.FOLDER : lucide.FILE,
			last   = strings.clone(hit.path, a),
		}
	}
	j.ans.items = items
}

@(private = "file")
palette_files_done :: proc(d: rawptr, _: u64) {
	j := (^Palette_Files_Job)(d)
	j.answered = true
	palette_answer(j.q, &j.ans)
	palette_files_job_free(j)
}

@(private = "file")
palette_files_job_free :: proc(d: rawptr) {
	j := (^Palette_Files_Job)(d)
	if !j.answered {
		palette_answer_free(&j.ans)
		palette_question_drop(j.q)
	}
	a := runtime.heap_allocator()
	delete(j.root, a)
	delete(j.query, a)
	free(j, a)
}

@(private = "file")
palette_files_open_work :: proc(d: rawptr) {
	j := (^Palette_Files_Open_Job)(d)
	_ = filesearch.note_opened(j.index, j.path)
}

@(private = "file")
palette_files_open_free :: proc(d: rawptr) {
	j := (^Palette_Files_Open_Job)(d)
	a := runtime.heap_allocator()
	delete(j.path, a)
	free(j, a)
}
