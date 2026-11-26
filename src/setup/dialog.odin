package tk_setup

// The Setup dialog: the program, its version, the state of its install in a sentence, where its files are, and what can
// be done: Install (or Repair, Upgrade, Update the shortcuts), Uninstall, Open the installed copy, Do not install; the
// program's own options (Setup_Options.choices), and the install folder before the first install (Setup_Options.folder).
//
//   d: setup.Dialog                          kept by the program, at a place that does not move while it is open
//   setup.open(&d, cfg, logo)                at a start when setup.wanted(...), from a menu, from `--setup`: the view
//                                            "setup" (home Dialog, ui's views) opens in the window being built
//   setup.set_logo(&d, logo)                 a logo made later (a task's answer): shown from the next frame
//   ev := setup.update(&d, cfg)              each frame, open or not: the work that ended, the answer of the view
//   setup.stale(&d)                          the program knows the install may have changed (its window came back)
//   setup.finish(&d, cfg)                    at the end of the process (what an uninstall left goes then)
//   setup.destroy(&d)
//
// A program that draws a screen of its own keeps the Dialog, calls `update` each frame, and the actions below from its
// buttons (the view uses the same): what the state is, what is offered and how the work goes are the same in every
// screen.
//
// Nothing is read or written on the interface thread: reading the state, Install, Uninstall and the folder picker run on
// a thread of the dialog's, one at a time; meanwhile the dialog says so and its buttons wait, and the end of the work
// wakes the program (ui.post to the State of the dialog's last frame: destroy the dialog before that State). While the dialog is open, the places of the install are watched (desktop.watch_start): what
// changes them elsewhere (another copy, the system's settings, a file removed by hand) is read again at once.
//
// The events tell the program what to keep (Choice_*) and when to end (Launched: the installed copy runs).

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:thread"
import base "../base"
import desktop "../desktop"
import i18n "../i18n"
import "../draw"
import lucide "../lucide"
import "../platform"
import "../render"
import svg "../svg"
import "../ui"

Dialog :: struct {
	open:      bool,
	known:     bool,               // the facts were read at least once since it opened
	facts:     Facts,              // as last read (strings owned)
	shortcut:  bool,               // the Desktop's shortcut, asked of Install
	scope:     desktop.Scope,      // for the person or for every account, asked of Install: the facts' when they first come
	choices:   [dynamic]bool,      // the program's options (Setup_Options.choices), as ticked
	folder:    ui.Line_Edit,      // the install folder (Setup_Options.folder): set from the facts when they first come
	note:      string,             // what the last action said (owned)
	note_good: bool,
	installed: string,             // the copy just installed, to open (owned; "": none)
	removed:   bool,               // this copy was uninstalled while it runs: its file goes when the process ends
	leftovers: [dynamic]string,    // ... with these (owned)
	at_restart: bool,              // uninstalled, and the program for everyone goes at the next restart (Windows: Facts.at_restart)
	copied:    string,             // the line whose path was just copied (its id, owned): a check until the pointer leaves
	confirm:   bool,               // Uninstall was clicked once: the next click does it
	job:       ^Job,               // the work out on the dialog's thread (nil: none)
	watcher:   ^desktop.Watcher,   // while open (nil: none could start; setup.stale reads again)
	stale_flag: bool,              // atomic: the watcher (or the program) says the install changed
	state:     ^ui.State,          // atomic: the State of its last frame, which the threads wake (nil before one)
	at:        [Button_Role]draw.Rect,   // where the last frame put its buttons ({}: not shown): a program's automation clicks them
	in_page:   bool,               // open as a page of the settings (page), not as the view
	page_build: u64,               // the build that last drew the page: a build without it closes it (update)
	// the view (open): the Views it is in (its window's at `open`), what its build draws with, and the event its buttons gave (update says it)
	views:     ^ui.Views,
	options:   Setup_Options,
	logo:      Maybe(Logo),        // the view's mark: open's, then set_logo's (the program does not write it)
	vendor_mark: Maybe(Logo),      // its vendor's mark in the "By" line: open's, then set_vendor_mark's (nil: the name alone)
	details:   Maybe(bool),        // the person opened or folded the details (nil: folded)
	nix_logo:  Maybe(svg.Document),   // Nix's snowflake, read at the first build of the Nix screen (destroy frees it)
	pending:   Event,
	building:  bool,               // the view's build runs: a close from its buttons ends the view there
}

// The id of the setup's view.
VIEW :: "setup"

// The buttons a program's automation finds in Dialog.at. Secondary: what closes (Do not install, Not now, Close) or opens
// the installed copy.
Button_Role :: enum u8 { Install, Uninstall, Secondary }

Event :: enum u8 {
	None,
	Installed,         // keep CHOICE_INSTALLED
	Uninstalled,
	Kept_Standalone,   // keep CHOICE_STANDALONE
	Dismissed,         // closed without an answer: keep choice_dismissed(version)
	Launched,          // the installed copy is to start (Dialog.installed): this one ends, then starts it (launch)
}

// The program's mark beside its name (a texture of the program's renderer, and its size in pixels).
Logo :: struct {
	texture: render.Texture,
	size:    [2]f32,
}

@(private = "file") DIALOG_EM       :: [2]f32{46, 40}   // its size at first (a grip of its corner or edges makes it larger or smaller)
@(private = "file") DIALOG_MIN_EM   :: [2]f32{28, 16}   // ... and at the least (what does not fit scrolls; the buttons stay)
@(private = "file") LOGO_EM         :: 4.2

// Opens the view "setup" (registered the first time) in the State in use, the window being built (ui.views()): the facts are read on its
// thread, the places of the install are watched. `o` and `logo` are what the view draws with (the options' strings and
// procedures are the program's constants; the logo and the vendor's mark are textures of the window's renderer).
open :: proc(d: ^Dialog, o: Setup_Options, logo: Maybe(Logo) = nil, vendor_mark: Maybe(Logo) = nil) {
	vs := ui.views()
	if d.open && !d.in_page && d.views == vs && ui.view_is_open(vs, VIEW) { return }
	if !ui.view_registered(vs, VIEW) {
		ui.view_register(vs, VIEW, view_build, ui.View_Options{
			title = "Setup", width_em = DIALOG_EM.x, height_em = DIALOG_EM.y, min_width_em = DIALOG_MIN_EM.x, min_height_em = DIALOG_MIN_EM.y,
			resizable = true, backdrop = view_backdrop,
		})
	}
	// (a controller already started, by the page or by the program's own facts, goes on in the view)
	if !d.open { start(d, o) }
	d.in_page = false
	d.views, d.options, d.logo, d.vendor_mark, d.pending = vs, o, logo, vendor_mark, .None
	ui.view_open(vs, VIEW, d)
}

// Starts the controller without the toolkit's view: the facts are read on the dialog's thread, the places watched. A
// screen of the program's own (a view of its own, a page) calls it; open and page do.
start :: proc(d: ^Dialog, o: Setup_Options) {
	if d.open { return }
	d.open, d.known, d.confirm, d.in_page = true, false, false, false
	if s := ui.current_state(); s != nil { sync.atomic_store(&d.state, s) }
	clear(&d.choices)
	for x in o.choices { append(&d.choices, x.on) }
	ui.line_edit_clear(&d.folder)
	say(d, true, "")
	watch_begin(d, o)
	job_start(d, o, .Read)
}

// The mark beside the program's name, given or changed after `open` (a program that makes its logo from a task's
// answer): the view shows it from its next frame. nil: none.
set_logo :: proc(d: ^Dialog, logo: Maybe(Logo)) {
	d.logo = logo
	if s := sync.atomic_load(&d.state); s != nil { s.anim_busy = true }   // (a frame shows it, even a window at rest)
}

// The vendor's mark in the "By" line, given or changed after `open`, as set_logo. nil: the vendor's name alone.
set_vendor_mark :: proc(d: ^Dialog, mark: Maybe(Logo)) {
	d.vendor_mark = mark
	if s := sync.atomic_load(&d.state); s != nil { s.anim_busy = true }
}

// A mark made from a PNG file's bytes (a program's #load) as a texture of `r`, `size` pixels on screen ({}: the
// image's own). ok = false: the bytes are no PNG. logo_destroy frees it, before the window's renderer goes.
logo_make :: proc(r: ^render.Renderer, file: []u8, size: [2]f32 = {}) -> (l: Logo, ok: bool) {
	img := platform.clipboard_image_decode("image/png", file, context.temp_allocator) or_return
	l.texture = render.create_texture_rgba(r, img.size.x, img.size.y)
	render.update_texture_rgba(r, l.texture, 0, 0, img.size.x, img.size.y, img.rgba)
	l.size = size != {} ? size : {f32(img.size.x), f32(img.size.y)}
	return l, true
}

logo_destroy :: proc(r: ^render.Renderer, l: ^Maybe(Logo)) {
	if x, has := l.?; has { render.destroy_texture(r, x.texture) }
	l^ = nil
}

// The install may have changed (the program's own reason: its window came back, a place no watcher sees): read again.
stale :: proc(d: ^Dialog) {
	sync.atomic_store(&d.stale_flag, true)
	wake(d)
}

// From any thread: the next frame of the program comes soon (it collects the work, reads the install again).
@(private = "file")
wake :: proc(d: ^Dialog) {
	if s := sync.atomic_load(&d.state); s != nil { _ = ui.post(s, proc(data: rawptr, word: u64) {}) }
}

// At the end of the process: what an uninstall left because this process held it goes then (a helper of the system's
// waits for the process).
finish :: proc(d: ^Dialog, o: Setup_Options) {
	if len(d.leftovers) > 0 { _ = remove_later(o, d.leftovers[:]) }
	for l in d.leftovers { delete(l) }
	delete(d.leftovers)
	d.leftovers = nil
}

// Waits for the work out, stops the watcher, frees everything.
destroy :: proc(d: ^Dialog) {
	if d.job != nil { job_join(d.job); job_free(d.job) }
	watch_end(d)
	facts_free(&d.facts)
	delete(d.note)
	delete(d.installed)
	delete(d.copied)
	delete(d.choices)
	ui.line_edit_destroy(&d.folder)
	for l in d.leftovers { delete(l) }
	delete(d.leftovers)
	if doc, has := &d.nix_logo.?; has { svg.destroy(doc) }
	d^ = {}
}

@(private)
facts_free :: proc(f: ^Facts) {
	delete(f.dir); delete(f.exe); delete(f.running); delete(f.version)
	f^ = {}
}

@(private = "file")
facts_clone :: proc(f: Facts) -> Facts {
	o := f
	o.dir, o.exe, o.running, o.version = strings.clone(f.dir), strings.clone(f.exe), strings.clone(f.running), strings.clone(f.version)
	return o
}

@(private = "file")
say :: proc(d: ^Dialog, good: bool, text: string) {
	delete(d.note)
	d.note, d.note_good = strings.clone(text), good
}

////////////////////////////////
// The watch

@(private = "file")
watch_begin :: proc(d: ^Dialog, o: Setup_Options) {
	if d.watcher != nil { return }
	integration, _ := options(o, d.choices[:])
	d.watcher = desktop.watch_start(&integration, proc(user: rawptr) {
		d := (^Dialog)(user)
		sync.atomic_store(&d.stale_flag, true)
		wake(d)
	}, d)   // (the options are temp memory, as options() makes them: the watcher copies the places)
}

@(private = "file")
watch_end :: proc(d: ^Dialog) {
	if d.watcher == nil { return }
	desktop.watch_stop(d.watcher)
	d.watcher = nil
}

////////////////////////////////
// The work, on the dialog's thread

@(private)
Job_Kind :: enum u8 { Read, Install, Uninstall, Pick_Folder }

@(private)
Job :: struct {
	kind:      Job_Kind,
	d:         ^Dialog,             // (it does not move while the work is out: destroy waits for it)
	c:         Setup_Options,   // (its strings and procedures are the program's: they outlive the work)
	shortcut:  bool,
	scope:     desktop.Scope,
	choices:   []bool,              // owned
	folder:    string,              // owned
	removed:   bool,                // the facts say Removal_Scheduled
	allocator: runtime.Allocator,   // the opener's: what the work gives back is freed by the dialog
	thread:    ^thread.Thread,
	done:      bool,                // atomic
	// what it gives back
	facts:     Facts,
	ok:        bool,
	text:      string,              // the installed program, or why not; the folder picked
	leftovers: [dynamic]string,
	at_restart: bool,               // Uninstall: the program for everyone goes at the next restart (system_removal_at_restart)
}

@(private = "file")
job_start :: proc(d: ^Dialog, o: Setup_Options, kind: Job_Kind) {
	if d.job != nil { return }
	sync.atomic_store(&d.stale_flag, false)
	j := new(Job)
	j.kind, j.d, j.c, j.shortcut, j.removed, j.scope = kind, d, o, d.shortcut, d.removed, d.scope
	j.choices = make([]bool, len(d.choices))
	copy(j.choices, d.choices[:])
	j.folder = strings.clone(strings.trim_space(ui.line_edit_string(&d.folder)))
	j.allocator = context.allocator
	j.thread = thread.create_and_start_with_data(j, job_run, priority = .Low)
	if j.thread == nil {
		// (no thread: the work is done here, at once)
		job_run(j)
	}
	d.job = j
	if kind != .Read { d.confirm = false }
}

@(private = "file")
job_run :: proc(data: rawptr) {
	j := (^Job)(data)
	context.allocator = j.allocator
	defer {
		free_all(context.temp_allocator)
		sync.atomic_store(&j.done, true)
		wake(j.d)
	}
	switch j.kind {
	case .Read:
	case .Install:
		ok, text := install(j.c, j.shortcut, j.choices, j.folder, j.scope)
		j.ok, j.text = ok, strings.clone(text)
	case .Uninstall:
		j.at_restart = system_removal_at_restart(j.c)
		ok, leftovers, why := uninstall(j.c, j.choices)
		j.ok, j.leftovers, j.text = ok, leftovers, strings.clone(why)
	case .Pick_Folder:
		res := platform.pick_folder_dialog({title = i18n.tr("Install folder"), start_dir = j.folder}, context.temp_allocator)
		if res.status == .Chosen && len(res.paths) > 0 { j.ok, j.text = true, strings.clone(res.paths[0]) }
		return
	}
	j.facts = facts_clone(facts(j.c, j.choices, j.scope))
}

@(private = "file")
job_join :: proc(j: ^Job) {
	if j.thread != nil { thread.join(j.thread); thread.destroy(j.thread); j.thread = nil }
}

@(private = "file")
job_free :: proc(j: ^Job) {
	facts_free(&j.facts)
	delete(j.choices); delete(j.folder); delete(j.text)
	for l in j.leftovers { delete(l) }
	delete(j.leftovers)
	free(j)
}

// The work that ended: its facts, its words and its event.
@(private = "file")
job_collect :: proc(d: ^Dialog, o: Setup_Options) -> (ev: Event) {
	j := d.job
	if j == nil || !sync.atomic_load(&j.done) { return }
	job_join(j)
	d.job = nil
	defer job_free(j)
	if j.kind == .Pick_Folder {
		if j.ok { ui.line_edit_set(&d.folder, j.text) }
		return
	}
	switch j.kind {
	case .Read, .Pick_Folder:
	case .Install:
		if j.ok {
			ev = .Installed
			if desktop.same_path(j.text, j.facts.running) {
				say(d, true, i18n.tr("Done: everything is in place."))
			} else {
				say(d, true, words_installed())
				delete(d.installed)
				d.installed = strings.clone(j.text)
			}
		} else {
			say(d, false, j.text)
		}
	case .Uninstall:
		for l in j.leftovers { append(&d.leftovers, l) }
		delete(j.leftovers)
		j.leftovers = nil
		if j.ok {
			delete(d.installed)
			d.installed = ""
			d.at_restart = j.at_restart
			d.removed = len(d.leftovers) > 0 || d.at_restart
			switch {
			case d.at_restart: say(d, true, i18n.tr("Removed. The program is deleted at the next restart."))
			case d.removed:    say(d, true, i18n.tr("Removed. The program is deleted when this window closes."))
			case:              say(d, true, i18n.tr("Removed."))
			}
			ev = .Uninstalled
		} else {
			say(d, false, j.text)
		}
	}
	facts_free(&d.facts)
	d.facts, j.facts = j.facts, {}
	if d.removed { d.facts.state, d.facts.at_restart = .Removal_Scheduled, d.at_restart }   // (the file is still there: the disk would say Repair)
	if !d.known {
		d.known = true
		d.shortcut = d.facts.desk_lnk
		d.scope = d.facts.scope
		choices_from_facts(d.facts, o, d.choices[:])   // (a box of a part shows what the system has, not a default)
		if ui.line_edit_string(&d.folder) == "" { ui.line_edit_set(&d.folder, d.facts.dir) }
	}
	return
}

// What the state is, in a sentence, and its tone ("good", "warn", "bad", "accent").
state_words :: proc(f: Facts, o: Setup_Options) -> (words, tone: string) {
	if base.restricted() { return restricted_words(), "warn" }
	if f.other_scope { return i18n.tr("Two copies are installed: one for you, one for everyone. Uninstall removes both."), "warn" }
	switch f.state {
	case .Not_Installed: return i18n.tr("Not installed: this copy runs on its own."), "warn"
	case .This_Copy:     return i18n.tr("Installed: this is the installed copy."), "good"
	case .Repair:
		switch {
		case !f.exe_there: return i18n.tr("The installed program is missing: what is left of it can be repaired or removed."), "bad"
		case !f.manifest:  return i18n.tr("A copy is installed by an earlier setup: Repair puts this copy in its place."), "accent"
		}
		return words_pieces_missing(), "bad"
	case .Other_Copy:
		if is_upgrade(f, o.version) { return fmt.tprintf(i18n.tr("An older copy is installed (%s): upgrade it to %s?"), f.version, o.version), "accent" }
		if is_downgrade(f, o.version) { return fmt.tprintf(i18n.tr("A newer copy is installed (%s): this one (%s) is older."), f.version, o.version), "warn" }
		return fmt.tprintf(i18n.tr("A copy is installed (%s): this one runs on its own."), f.version != "" ? f.version : "?"), "warn"
	case .Removal_Scheduled:
		if f.at_restart { return i18n.tr("Uninstalled: the program is deleted at the next restart."), "warn" }
		return i18n.tr("Uninstalled: the program is deleted when this window closes."), "warn"
	case .Nix_Package:
		if leftover(f) { return i18n.tr("Installed by Nix. An earlier install left files here: they can be removed."), "accent" }
		return i18n.tr("Installed by Nix: the Nix package has the menu entry and the icon."), "good"
	}
	return "", ""
}

// (words_menu, words_record, words_installed, words_pieces_missing: the words of this system for the pieces of an
// install, system_windows.odin, system_other.odin)

// What the program's look draws first, under the header (Setup_Options.backdrop: a blur of the window...).
@(private = "file")
view_backdrop :: proc(v: ^ui.View, data: rawptr) {
	o := (^Dialog)(data).options
	if o.square { ui.parent_box().radius = 0 }
	if o.backdrop != nil { o.backdrop(v, o.user) }
}

// The view's body, under the toolkit's header ("<name> Setup", the close cross) (src/md/features/setup-screen.md): the
// program's hero (its logo, its name, what it is, its state), where it goes, its options as a list of switches, the
// details folded (where the parts are, Uninstall), and a footer: the vendor's signature, the buttons.
// Setup_Options.square: every corner square.
@(private = "file")
view_build :: proc(v: ^ui.View, d: ^Dialog) {
	o := d.options
	em := ui.font_size()
	if s := ui.current_state(); s != nil { sync.atomic_store(&d.state, s) }
	ui.view_title(v, fmt.tprintf(i18n.tr("%s Setup"), o.identity.name))
	is_busy := busy(d)
	f := &d.facts
	d.at = {}   // (the details and the footer mark where their buttons are, for a program's automation)
	// (a copy from the Nix store: a screen of its own, nothing to install here; what an earlier install left, if any,
	// can still go from the details)
	if d.known && f.state == .Nix_Package {
		hero(d, o, em, d.logo)
		nix_panel(d, o, em)
		if leftover(f^) { details(d, o, em, is_busy) }
		ui.space(ui.GROUP_GAP)
	} else {
	// what the dialog says scrolls when it is made small; its footer stays under it
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###setup_scroll") {
		hero(d, o, em, d.logo)
		if d.known {
			scope_section(d, o, em, is_busy)
			location(d, o, em, is_busy)
			if !f.from_nix { options_card(d, o, em) }
			details(d, o, em, is_busy)
		}
		ui.space(ui.GROUP_GAP)
	}
	}
	d.building = true
	if ev := footer(d, o, em); ev != .None { d.pending = ev }
	d.building = false
	// (a button closed it: the view ends with it, the event waits for update)
	if !d.open { ui.view_end(v, 0) }
}

////////////////////////////////
// The controller: what a screen of the program's own calls (the view calls the same)

// Each frame, open or not: collects the work that ended (its event) and the answer of the view (closed by its cross,
// Escape or a press outside: Dismissed, unless there is nothing to ask), reads the install again when it changed, stops
// watching once closed.
update :: proc(d: ^Dialog, o: Setup_Options) -> (ev: Event) {
	if s := ui.current_state(); s != nil { sync.atomic_store(&d.state, s) }
	ev = job_collect(d, o)
	if d.views != nil && !d.in_page {
		if code, ended := ui.view_ended(d.views, VIEW); ended && code == ui.VIEW_CANCELLED && d.open {
			d.open = false
			if ev == .None { ev = closed_event(d) }
		}
	}
	if ev == .None && d.pending != .None { ev, d.pending = d.pending, .None }
	// (a page has no close of its own: the settings showed another page, or closed, when a build went by without it)
	if d.open && d.in_page {
		if s := ui.current_state(); s != nil && s.build_index > d.page_build + 1 {
			d.open, d.in_page, d.confirm = false, false, false
		}
	}
	if !d.open {
		watch_end(d)
		return
	}
	if d.job == nil && sync.atomic_load(&d.stale_flag) { job_start(d, o, .Read) }
	return
}

// Install, Uninstall or the folder picker is at work (the buttons wait; reading the state is not work).
busy :: proc(d: ^Dialog) -> bool { return d.job != nil && d.job.kind != .Read }

// What the install button says for the state ("": none is offered: not read yet, just installed, removed, from Nix).
install_label :: proc(d: ^Dialog, o: Setup_Options) -> string {
	f := &d.facts
	if base.restricted() { return "" }   // (restricted_words says why)
	if !d.known || d.installed != "" && f.state != .This_Copy || f.state == .Removal_Scheduled || f.from_nix { return "" }
	// (the other scope chosen with an install there: the move, which removes the other once the new one is in place)
	if f.exe_there && f.manifest && d.scope != f.scope {
		return d.scope == .System ? i18n.tr("Install for everyone") : i18n.tr("Install for me only")
	}
	#partial switch f.state {
	case .Other_Copy:
		switch {
		case is_upgrade(f^, o.version):   return fmt.tprintf(i18n.tr("Upgrade to %s"), o.version)
		case is_downgrade(f^, o.version): return fmt.tprintf(i18n.tr("Go back to %s"), o.version)
		}
		return i18n.tr("Replace the installed copy")
	case .Repair:    return i18n.tr("Repair")
	case .This_Copy: return i18n.tr("Update the shortcuts")
	}
	return i18n.tr("Install")
}

// Uninstall is offered: something of an install is there.
can_uninstall :: proc(d: ^Dialog) -> bool {
	return !base.restricted() && d.known && (d.facts.state == .This_Copy || d.facts.state == .Repair || d.facts.state == .Other_Copy || d.facts.state == .Nix_Package && leftover(d.facts))
}

// What closes the screen without installing: Close, Not now (an upgrade), Do not install (no install, another copy).
Closing :: enum u8 { Close, Not_Now, Keep_Standalone }

closing :: proc(d: ^Dialog, o: Setup_Options) -> Closing {
	switch {
	case d.installed != "" && d.facts.state != .This_Copy: return .Close
	case is_upgrade(d.facts, o.version):                   return .Not_Now
	case d.known && (d.facts.state == .Not_Installed || d.facts.state == .Other_Copy): return .Keep_Standalone
	}
	return .Close
}

// Starts Install (with Dialog.shortcut, choices and folder) on the dialog's thread; nothing while work is out.
start_install :: proc(d: ^Dialog, o: Setup_Options) { if d.known && d.job == nil { job_start(d, o, .Install) } }

// Starts Uninstall on the dialog's thread (a screen asks first: Dialog.confirm); nothing while work is out.
start_uninstall :: proc(d: ^Dialog, o: Setup_Options) { if d.known && d.job == nil { job_start(d, o, .Uninstall) } }

// Opens the system's folder picker for the install folder (Dialog.folder takes the answer).
pick_folder :: proc(d: ^Dialog, o: Setup_Options) { if d.job == nil { job_start(d, o, .Pick_Folder) } }

// Asks for the copy just installed (Dialog.installed): Launched, the program then ends and starts it with launch once
// its window is closed and its single instance released (started now, it would find this one still running and hand
// itself over to it). None when there is none.
open_installed :: proc(d: ^Dialog) -> Event {
	// (the installed copy is the user's to change: an administrator's process starts it never; base.restricted)
	return d.installed != "" && !base.restricted() ? .Launched : .None
}

// Closes the screen by `how`: the event to keep (Kept_Standalone, Dismissed: not again for this version, or None).
close :: proc(d: ^Dialog, how: Closing) -> Event {
	if !d.open { return .None }
	// (from the program's own code: the view goes too; from the view's buttons, its build ends it)
	if d.views != nil && !d.in_page && !d.building { ui.view_close(d.views, VIEW) }
	d.open, d.in_page = false, false
	watch_end(d)
	switch how {
	case .Keep_Standalone: return .Kept_Standalone
	case .Not_Now:         return .Dismissed
	case .Close:
	}
	return closed_event(d)
}

// Closed without an answer (Close, Escape, a click outside): not again for this version, unless there is nothing to
// ask (installed, just installed, removed).
@(private = "file")
closed_event :: proc(d: ^Dialog) -> Event {
	if d.facts.state == .Removal_Scheduled || d.installed != "" || d.facts.state == .This_Copy { return .None }
	return .Dismissed
}

// A corner's radius: `k` ems, none when the program wants it square.
@(private)
rad :: proc(o: Setup_Options, em, k: f32) -> f32 { return o.square ? 0 : math.round(em * k) }

// A framed panel across the dialog, inside its margins: `if panel(...) { ... }`.
@(private, deferred_none = panel_end)
panel :: proc(o: Setup_Options, em: f32, id: string, axis := ui.Axis.Y) -> bool {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	ui.push_parent(ui.build_box({}, fmt.tprintf("%s_line", id)))
	ui.space(ui.PAGE_MARGIN)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = axis, cross = .Center, radius = rad(o, em, 0.4)})
	box: ^ui.Box
	if ui.tags("input") { box = ui.build_box({.Draw_Background, .Draw_Border}, id) }
	ui.push_parent(box)
	return true
}

@(private)
panel_end :: proc() {
	ui.pop_parent()
	ui.space(ui.PAGE_MARGIN)
	ui.pop_parent()
}

// What the screen offers for this state ("Install Classeur", "Repair Classeur"...), and the state in a word.
headline :: proc(f: Facts, o: Setup_Options) -> (title, badge: string) {
	name := o.identity.name
	switch f.state {
	case .Not_Installed:     return fmt.tprintf(i18n.tr("Install %s"), name), i18n.tr("Not installed")
	case .This_Copy:         return fmt.tprintf(i18n.tr("%s is installed"), name), i18n.tr("Installed")
	case .Repair:            return fmt.tprintf(i18n.tr("Repair %s"), name), i18n.tr("To repair")
	case .Other_Copy:
		if is_upgrade(f, o.version) { return fmt.tprintf(i18n.tr("Upgrade %s"), name), i18n.tr("Older installed") }
		if is_downgrade(f, o.version) { return fmt.tprintf(i18n.tr("Replace %s"), name), i18n.tr("Newer installed") }
		return fmt.tprintf(i18n.tr("Replace %s"), name), i18n.tr("Other copy")
	case .Removal_Scheduled: return fmt.tprintf(i18n.tr("%s is uninstalled"), name), i18n.tr("Removed")
	case .Nix_Package:       return fmt.tprintf(i18n.tr("%s from Nix"), name), i18n.tr("Nix package")
	}
	return name, ""
}

// The hero: the program first. Its logo large (or its initial on a tile of its accent, when it gives none), its name,
// what it is (Identity.description), its state as a pill and the versions; under it, what the state means, in its tone.
// No frame: a band of the accent's tint, fading down into the dialog, carries it.
@(private = "file")
hero :: proc(d: ^Dialog, o: Setup_Options, em: f32, logo: Maybe(Logo)) {
	f := &d.facts
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	band := ui.build_box({}, "###setup_hero")
	tint := ui.frame_new(ui.Color)
	tint^ = ui.color("accent")
	tint.a *= HERO_TINT
	band.custom, band.custom_user = hero_draw, tint
	ui.push_parent(band)
	defer ui.pop_parent()
	ui.space(ui.GROUP_GAP)
	line_next()
	if ui.row(.Center, id = "###setup_hero_row") {
		ui.space(ui.PAGE_MARGIN)
		side := math.round(em * HERO_LOGO_EM)
		if l, has := logo.?; has {
			ui.next({width = ui.px(side), height = ui.px(side)})
			b := ui.build_box({}, "###setup_logo")
			p := ui.frame_new(Logo)
			p^ = l
			b.custom, b.custom_user = logo_draw, p
		} else {
			// (no logo given: the name's first letter on a tile of the accent, so the hero keeps its shape)
			initial := o.identity.name != "" ? o.identity.name[:1] : "?"
			ui.next({width = ui.px(side), height = ui.px(side), radius = rad(o, em, 0.9), bg = ui.color("accent"),
				fg = ui.color("accent text"), font_size = math.round(side * 0.5), text_align = .Center, text_pad = 0})
			ui.build_box({.Draw_Background, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###setup_initial", initial))
		}
		ui.space(ui.SPACE_6)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###setup_words") {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.1)), font_size = math.round(em * HERO_TITLE_EM), text_pad = 0})
			ui.label(fmt.tprintf("%s###setup_name", o.identity.name))
			if o.identity.description != "" {
				if ui.tags("weak") {
					ui.next({width = ui.fill(), text_pad = 0})
					// (the program's words: its catalogue translates them, as its boxes' labels)
					ui.paragraph(fmt.tprintf("%s###setup_description", i18n.tr(o.identity.description)))
				}
			}
			ui.space(ui.LINE_GAP)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###setup_facts") {
				words, badge := i18n.tr("Reading the install…"), ""
				if d.known { _, badge = headline(f^, o) }
				_, tone := state_words(f^, o)
				// (a copy from Nix: no pill, Nix's panel says it once, larger)
				if f.state != .Nix_Package || !d.known {
					if badge != "" { ui.pill("setup_badge", badge, state_glyph(f^), tone_color(tone)) } else { ui.pill("setup_badge", words, "", ui.color("weak text")) }
					ui.space(ui.CONTROL_GAP)
				}
				if ui.tags("weak") {
					installed := ""
					if d.known && f.state != .Not_Installed && f.state != .Nix_Package && f.version != "" && f.version != o.version {
						installed = fmt.tprintf(i18n.tr("  ·  v%s installed"), f.version)
					}
					ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.5)), text_pad = 0, font = ui.mono_font(), font_size = math.round(em * 0.86)})
					ui.label(fmt.tprintf("v%s%s###setup_version", o.version, installed))
				}
			}
			// (what the state means, under the pill that names it: weak, the pill carries the tone)
			// (the sentence only when it says more than the pill: which version, what is missing, what goes)
			if d.known && (f.state == .Repair || f.state == .Other_Copy || f.state == .Removal_Scheduled) {
				words, _ := state_words(f^, o)
				ui.space(ui.LINE_GAP)
				if ui.tags("weak") {
					ui.next({width = ui.fill(), text_pad = 0, font_size = math.round(em * 0.92)})
					ui.paragraph(fmt.tprintf("%s###setup_state", words))
				}
			}
		}
		ui.space(ui.PAGE_MARGIN)
	}
	ui.space(ui.ITEM_GAP)
}

// The hero's band: the accent's tint at its top, fading out at its foot, and a hairline under it.
@(private = "file")
hero_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	c := (^ui.Color)(user)^
	r := b.rect
	clear := c
	clear.a = 0
	stops := [2]draw.Gradient_Stop{{color = c, pos = 0}, {color = clear, pos = 1}}
	draw.gradient(dc, r, {kind = .Linear, start = {0, 0}, end = {0, r.max.y - r.min.y}, stops = stops[:], dither = true})
}

// A copy from the Nix store: the rest of the dialog says so, and only that. Nix's snowflake large on a disc of Nix's
// two blues, "Managed by Nix", why there is nothing to do here, and where the copy runs from. Centred in the room left:
// a screen that cannot be mistaken for an install that failed.
@(private = "file")
nix_panel :: proc(d: ^Dialog, o: Setup_Options, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, cross = .Center})
	if ui.column(id = "###setup_nix") {
		ui.spacer(ui.fill())
		side := math.round(em * NIX_DISC_EM)
		// (Nix's own snowflake, its six lambdas in its two blues: read once, the first time this screen is built)
		if d.nix_logo == nil {
			if doc, ok := svg.parse(NIX_SNOWFLAKE); ok { d.nix_logo = doc }
		}
		ui.next({width = ui.px(side), height = ui.px(side)})
		mark := ui.build_box({}, "###setup_nix_mark")
		if doc, has := &d.nix_logo.?; has { mark.custom, mark.custom_user = nix_logo_draw, doc }
		ui.space(ui.GROUP_GAP)
		ui.next({width = ui.text_size(), height = ui.px(math.round(em * 2)), font_size = math.round(em * 1.4), text_pad = 0})
		ui.label(fmt.tprintf("%s###setup_nix_title", i18n.tr("Managed by Nix")))
		ui.space(ui.LINE_GAP)
		line_next()
		if ui.row(id = "###setup_nix_words_row") {
			ui.space(ui.SPACE_6)
			ui.space(ui.SPACE_6)
			if ui.tags("weak") {
				ui.next({width = ui.fill(), text_pad = 0, text_align = .Center})
				words := fmt.tprintf(i18n.tr("Nix installs and updates %s."), o.identity.name)
				ui.paragraph(fmt.tprintf("%s###setup_nix_words", words))
			}
			ui.space(ui.SPACE_6)
			ui.space(ui.SPACE_6)
		}
		if d.facts.running != "" {
			ui.space(ui.LINE_GAP)
			if ui.tags("weak") {
				ui.next({width = ui.text_size(), height = ui.px(math.round(em * 1.4)), text_pad = 0, font = ui.mono_font(), font_size = math.round(em * 0.8)})
				ui.label(fmt.tprintf("%s###setup_nix_path", d.facts.running))
			}
		}
		ui.spacer(ui.fill())
	}
}

// The snowflake fitted to its box, centred.
@(private = "file")
nix_logo_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	doc := (^svg.Document)(user)
	r := b.rect
	room := r.max - r.min
	if doc.view[2] <= 0 || doc.view[3] <= 0 { return }
	scale := min(room.x / doc.view[2], room.y / doc.view[3])
	at := r.min + (room - svg.size(doc, scale)) * 0.5
	svg.draw_doc(dc, doc, at, scale, {})
}

@(private = "file") NIX_DISC_EM :: 7
// The Nix snowflake (NixOS's artwork, CC BY 4.0: src/setup/nix-snowflake-LICENSE.txt).
@(private = "file") NIX_SNOWFLAKE :: #load("nix-snowflake.svg", string)

@(private = "file") HERO_LOGO_EM  :: 4.5    // the program's logo in the hero
@(private = "file") HERO_TITLE_EM :: 1.6    // its name
@(private = "file") HERO_TINT     :: 0.14   // how much of the accent the band starts with

// The colour of a state's tone, for its pill.
@(private = "file")
tone_color :: proc(tone: string) -> ui.Color {
	switch tone {
	case "good": return ui.hue(.Green)
	case "warn": return ui.hue(.Yellow)
	case "bad":  return ui.hue(.Red)
	case "accent": return ui.color("accent")
	}
	return ui.color("weak text")
}

// The glyph of a state, in its pill.
@(private = "file")
state_glyph :: proc(f: Facts) -> string {
	switch f.state {
	case .Not_Installed:     return lucide.CIRCLE_DASHED
	case .This_Copy:         return lucide.CHECK_CIRCLE
	case .Repair:            return lucide.WRENCH
	case .Other_Copy:        return lucide.ARROW_UP_CIRCLE
	case .Removal_Scheduled: return lucide.TRASH_2
	case .Nix_Package:       return lucide.PACKAGE
	}
	return ""
}

// "By <mark> <vendor>", as the foot of the program's site: the vendor's name opens its site (Setup_Options.vendor_url).
// Nothing without a vendor.
@(private)
by_line :: proc(o: Setup_Options, mark: Maybe(Logo), em: f32, id: string) {
	if o.identity.vendor == "" { return }
	line := math.round(em * 1.35)
	size := math.round(em * 0.9)
	ui.next({width = ui.children_sum(), height = ui.px(line), axis = .X, cross = .Center})
	if ui.row(id = id) {
		if ui.tags("weak") {
			ui.next({width = ui.text_size(), height = ui.px(line), font_size = size, text_pad = 0})
			ui.label(fmt.tprintf("%s###setup_by_word", i18n.tr("By")))
		}
		ui.space(ui.ICON_GAP)
		if l, has := mark.?; has {
			side := math.round(em * 0.95)
			ui.next({width = ui.px(side), height = ui.px(side)})
			b := ui.build_box({}, "###setup_by_mark")
			p := ui.frame_new(Logo)
			p^ = l
			b.custom, b.custom_user = logo_draw, p
			ui.space(ui.ICON_GAP)
		}
		if o.vendor_url == "" {
			if ui.tags("weak") {
				ui.next({width = ui.text_size(), height = ui.px(line), font_size = size, text_pad = 0})
				ui.label(fmt.tprintf("%s###setup_by_name", o.identity.vendor))
			}
		} else {
			ui.next({font_size = size})
			if ui.button("###setup_by_name", o.identity.vendor, o = {face = .Link, height = line, tip = o.vendor_url}).clicked {
				ui.open(o.vendor_url, .Url)
			}
		}
	}
}

// Where it goes: a field and the system's folder picker before the first install, else where it is.
@(private)
location :: proc(d: ^Dialog, o: Setup_Options, em: f32, busy: bool) {
	f := &d.facts
	choose := o.folder && f.state == .Not_Installed && !f.from_nix && d.scope == .User
	if !choose && f.exe == "" { return }   // (nothing chosen, nothing there: no empty field)
	section_head(em, "###setup_location_label", f.exe_there ? i18n.tr("Installed program") : i18n.tr("Install location"))
	line_next()
	if ui.row(.Center, id = "###setup_location_row") {
		ui.space(ui.PAGE_MARGIN)
		if choose {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.1)), radius = rad(o, em, 0.3)})
			_ = ui.line_edit("###setup_folder", &d.folder)
			ui.space(ui.CONTROL_GAP)
			if button(o, "###setup_pick", i18n.tr("Choose…"), lucide.FOLDER_OPEN, .Primary, em) && !busy { pick_folder(d, o) }
		} else {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.1)), axis = .X, cross = .Center, radius = rad(o, em, 0.3)})
			well: ^ui.Box
			if ui.tags("input") { well = ui.build_box({.Draw_Background, .Draw_Border}, "###setup_where") }
			if ui.parent(well) { where_row(d, "###w1", "", f.exe, true, 0, em) }
		}
		ui.space(ui.PAGE_MARGIN)
	}
	if choose {
		if why := desktop.check_install_dir(strings.trim_space(ui.line_edit_string(&d.folder)), o.identity.name); why != "" {
			line_next()
			if ui.row(id = "###setup_folder_why_row") {
				ui.space(ui.PAGE_MARGIN)
				if ui.tags("bad") {
					ui.next({width = ui.fill(), text_pad = 0, font_size = math.round(em * 0.86)})
					ui.paragraph(fmt.tprintf("%s###setup_folder_why", why))
				}
				ui.space(ui.PAGE_MARGIN)
			}
		}
	}
}

// "Install for": for me or for everyone (src/md/features/install-scope.md), each a radio with what it means here
// under it: the person compares the two before choosing. "For everyone" is greyed with the reason when it cannot be
// offered here. Nothing when the program offers one scope, when there is nothing to do, in a restricted process, for a
// copy of the Nix store.
@(private)
scope_shown :: proc(d: ^Dialog, o: Setup_Options) -> bool {
	return d.known && !base.restricted() && !d.facts.from_nix && card(offered_scopes(o)) == 2 && install_label(d, o) != ""
}

@(private = "file")
scope_section :: proc(d: ^Dialog, o: Setup_Options, em: f32, busy: bool) {
	if !scope_shown(d, o) { return }
	section_head(em, "###setup_scope_head", i18n.tr("Install for"))
	line_next()
	if ui.row(id = "###setup_scope_row") {
		ui.space(ui.PAGE_MARGIN)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###setup_scope_column") { scope_choices(d, o, em, busy) }
		ui.space(ui.PAGE_MARGIN)
	}
}

// The two radios and their words. A change reads the facts again (where the program would go).
@(private)
scope_choices :: proc(d: ^Dialog, o: Setup_Options, em: f32, busy: bool) {
	f := &d.facts
	refused := f.system_refusal != .None
	if refused { d.scope = .User }
	chosen := int(d.scope)
	// (the label's start in a mark row: its margin, its mark, the gap after it, the text's pad; the words line up under
	// the label)
	indent := em * 0.4 + em * 1.4 + em * 0.6 + ui.top_style().text_pad
	for scope in desktop.Scope {
		if scope == .System { ui.space(ui.LINE_GAP) }
		label := scope == .System ? i18n.tr("Everyone on this computer") : i18n.tr("Only me")
		id := scope == .System ? "###setup_scope_everyone" : "###setup_scope_me"
		ui.next({width = ui.fill()})
		if ui.disabled(busy || scope == .System && refused) {
			if ui.radio(id, label, &chosen, int(scope)) { scope_set(d, o, desktop.Scope(chosen)) }
		}
		words := scope == .System && refused ? desktop.system_refusal_words(f.system_refusal) : words_scope(scope)
		// (the move: an install of the other scope is there, and goes once this one is in place)
		if f.exe_there && f.manifest && scope == d.scope && d.scope != f.scope {
			move := d.scope == .System ? i18n.tr("The copy installed for you goes once this one is in place.") : i18n.tr("The copy for everyone goes once yours is in place: an administrator allows it.")
			words = fmt.tprintf("%s %s", words, move)
		}
		line_next()
		if ui.row(id = fmt.tprintf("%s_words_row", id)) {
			ui.spacer(ui.px(indent))
			if ui.tags("weak") {
				ui.next({width = ui.fill(), text_pad = 0, font_size = math.round(em * 0.86)})
				ui.paragraph(fmt.tprintf("%s%s_words", words, id))
			}
		}
	}
}

// The scope asked of Install: the facts are read again for it.
scope_set :: proc(d: ^Dialog, o: Setup_Options, scope: desktop.Scope) {
	if d.scope == scope { return }
	d.scope = scope
	if d.job == nil { job_start(d, o, .Read) } else { sync.atomic_store(&d.stale_flag, true) }
}

// The glyph of the install button: a wrench to repair, a shield where an administrator is asked, else a download.
@(private)
install_glyph :: proc(d: ^Dialog) -> string {
	switch {
	case d.facts.state == .Repair && d.scope == d.facts.scope: return lucide.WRENCH
	case d.scope == .System:                                   return lucide.SHIELD
	}
	return lucide.DOWNLOAD
}

// A section's head: its name, small and weak, at the page's margin, LINE_GAP above what it heads.
@(private)
section_head :: proc(em: f32, id, title: string) {
	ui.space(ui.ITEM_GAP)
	line_next()
	if ui.row(.Center, id = id) {
		ui.space(ui.PAGE_MARGIN)
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.4)), text_pad = 0, font_size = math.round(em * 0.86)})
			ui.label(fmt.tprintf("%s###t", title))
		}
		ui.space(ui.PAGE_MARGIN)
	}
	ui.space(ui.LINE_GAP)
}

// "Options": the Desktop shortcut and the program's choices, a list card of switches at the page's margins. A long
// label wraps in its row, never past it.
@(private)
options_card :: proc(d: ^Dialog, o: Setup_Options, em: f32) {
	section_head(em, "###setup_options_head", i18n.tr("Options"))
	n := 1 + min(len(o.choices), len(d.choices))
	line_next()
	if ui.row(id = "###setup_options") {
		ui.space(ui.PAGE_MARGIN)
		if ui.list_card("###setup_options_card") {
			for k in 0 ..< n {
				note := k > 0 ? choice_note(o.choices[k - 1], d.scope) : ""
				if ui.card_row(fmt.tprintf("###setup_tile_%d", k), note != "" ? .Y : .X) {
					ui.next({width = ui.fill()})
					if k == 0 {
						ui.toggle("###setup_shortcut", i18n.tr("Shortcut on the Desktop"), &d.shortcut, wrap = true)
					} else if note != "" {
						// (off, and no click: this scope has not the part)
						off := false
						if ui.disabled() { ui.toggle(fmt.tprintf("###setup_choice_%d", k - 1), i18n.tr(o.choices[k - 1].label), &off, wrap = true) }
					} else {
						ui.toggle(fmt.tprintf("###setup_choice_%d", k - 1), i18n.tr(o.choices[k - 1].label), &d.choices[k - 1], wrap = true)
					}
					if note != "" { choice_note_line(fmt.tprintf("###setup_choice_note_%d", k - 1), note, em) }
				}
			}
		}
		ui.space(ui.PAGE_MARGIN)
	}
}

// Why a box cannot be ticked in `scope`, in the language in use ("": it can): Task Manager is every account's, and
// only an install for everyone gives it.
choice_note :: proc(x: Choice, scope: desktop.Scope) -> string {
	if !choice_possible(x, scope) {
		return i18n.tr("Only with an install for everyone: Task Manager is the same for every account on this computer.")
	}
	return ""
}

// A box can be ticked in `scope`: its parts are all the scope's.
choice_possible :: proc(x: Choice, scope: desktop.Scope) -> bool {
	return x.parts & desktop.supported_parts() <= desktop.scope_parts(scope)
}

// A choice's note under its box, in the weak tone.
@(private)
choice_note_line :: proc(id, note: string, em: f32) {
	if ui.tags("weak") {
		ui.next({width = ui.fill(), text_pad = 0, font_size = math.round(em * 0.86)})
		ui.paragraph(fmt.tprintf("%s%s", note, id))
	}
}

// "Details", folded at first, Uninstall on its line whether it is open or not (never hidden behind a click): the
// parts of the install, each with its mark, this copy, the note of NixOS, what the last action said, and Uninstall.
@(private = "file")
details :: proc(d: ^Dialog, o: Setup_Options, em: f32, busy: bool) {
	f := &d.facts
	open := d.details.? or_else false
	ui.space(ui.ITEM_GAP)
	line_next()
	if ui.row(.Center, id = "###setup_details_head") {
		ui.space(ui.PAGE_MARGIN)
		if ui.button("###setup_details", i18n.tr("Details"), open ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT, {face = .Link, icon_font = ui.lucide_icons()}).clicked {
			d.details = !open
		}
		ui.spacer(ui.fill())
		if can_uninstall(d) {
			// (the first click asks; the second uninstalls; beside a Nix package, what goes is only what an earlier
			// install left)
			nix := f.state == .Nix_Package
			words := d.confirm ? (nix ? i18n.tr("Click again to remove") : i18n.tr("Click again to uninstall")) : (nix ? i18n.tr("Remove what is left") : i18n.tr("Uninstall"))
			if ui.button("###setup_uninstall", words, lucide.TRASH_2, {face = .Link, intent = .Danger, icon_font = ui.lucide_icons()}).clicked && !busy {
				if d.confirm { start_uninstall(d, o) } else { d.confirm = true }
			}
			if b := ui.prev_box("###setup_uninstall"); b != nil { d.at[.Uninstall] = b.rect }
		}
		ui.space(ui.PAGE_MARGIN)
	}
	if !open { return }
	ui.space(ui.LINE_GAP)
	if panel(o, em, "###setup_info") {
		ui.space(ui.INNER_PAD)
		key_w := keys_width(em, words_menu(), words_record(), i18n.tr("This copy"))
		where_row(d, "###w2", words_menu(), part_words(f.start_lnk, o), false, key_w, em)
		where_row(d, "###w3", words_record(), part_words(f.record, o), false, key_w, em)
		where_row(d, "###w4", i18n.tr("This copy"), f.running, true, key_w, em)
		if f.nixos && f.state != .Nix_Package && f.state != .This_Copy {
			line_next()
			if ui.row(id = "###setup_nixos_row") {
				ui.space(ui.INNER_PAD)
				if ui.tags("weak") {
					ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
					ui.paragraph(fmt.tprintf("%s###setup_nixos", i18n.tr("On NixOS, a Nix package is the better install: Nix updates it. An install here makes this copy run by itself (nix-build makes the libraries it needs).")))
				}
				ui.space(ui.INNER_PAD)
			}
		}
		if d.note != "" || busy {
			ui.space(ui.LINE_GAP)
			line_next()
			if ui.row(.Center, id = "###setup_note_row") {
				ui.space(ui.INNER_PAD)
				if ui.tags(busy ? "weak" : d.note_good ? "good" : "bad") {
					ui.next({width = ui.fill(), text_pad = 0})
					ui.paragraph(fmt.tprintf("%s###setup_note", busy ? i18n.tr("Working…") : d.note))
				}
				ui.space(ui.INNER_PAD)
			}
		}
		ui.space(ui.INNER_PAD)
	}
}

// A part of the install as the details say it: the program's name where it is there, "not there" where it is not.
@(private = "file")
part_words :: proc(there: bool, o: Setup_Options) -> string {
	return there ? o.identity.name : i18n.tr("not there")
}

// A line of the dialog: as wide as it, as tall as what it holds.
@(private)
line_next :: proc() {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
}

// The width of the keys' column of a well: its widest key in the language in use and a gap after it, so that a key is
// never cut nor against its value.
@(private)
keys_width :: proc(em: f32, keys: ..string) -> f32 {
	widest: f32
	st := ui.top_style()
	for k in keys { widest = max(widest, ui.text_width(st.font, st.font_size, k)) }
	return math.ceil(widest + math.round(em * KEY_GAP))
}

// The room between a well's key and its value, in font sizes: a column's gap, which no role of the scale names.
@(private = "file") KEY_GAP :: ui.SPACE_4

// A line of the well: what, weak, in a column `key_w` wide (keys_width of the well's keys), then where ("" key: the value
// alone, the line under a label). A path that does not fit is cut; the pointer over it shows it whole, and a click on it
// or on the copy button after it puts it on the clipboard.
@(private)
where_row :: proc(d: ^Dialog, id, key, value: string, path: bool, key_w: f32, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.55)), axis = .X, cross = .Center})
	if ui.row(.Center, id = id) {
		ui.space(ui.INNER_PAD)   // (a line of a well: the well's inset at its sides)
		if key != "" {
			if ui.tags("weak") {
				ui.next({width = ui.px(key_w), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###k", key))
			}
		}
		mono := ui.Style_Mod{width = ui.fill(), height = ui.pct(1), text_pad = 0, font = ui.mono_font(), font_size = math.round(em * 0.86)}
		if !path || value == "" {
			ui.next(mono)
			ui.label(fmt.tprintf("%s###v", value))
		} else {
			ui.next(mono)
			ui.a11y({role = .Button, name = fmt.tprintf(i18n.tr("Copy %s"), value)})
			text := ui.build_box({.Clickable, .Draw_Text}, fmt.tprintf("%s###v", value))
			sig := ui.signal(text)
			ui.space(ui.CONTROL_GAP)
			side := math.round(em * 1.3)
			ui.next({width = ui.px(side), height = ui.px(side), cursor = .Hand})
			ui.a11y({role = .Button, name = fmt.tprintf(i18n.tr("Copy %s"), value)})
			button := ui.build_box({.Clickable, .Focusable, .Draw_Hot_Effects}, "###copy")
			bsig := ui.signal(button)
			copied := d.copied == id
			glyph := ui.frame_new(Copy_Glyph)
			glyph^ = {ui.color("text"), copied}
			button.custom, button.custom_user = copy_draw, glyph
			if sig.clicked || bsig.clicked {
				ui.window_clipboard_set(value)
				delete(d.copied)
				d.copied = strings.clone(id)
			} else if copied && !sig.hovering && !bsig.hovering {
				delete(d.copied)
				d.copied = ""   // (the check goes when the pointer leaves)
			}
			if ui.hovered_for(sig) || ui.hovered_for(bsig) {
				if ui.tooltip() {
					ui.next({width = ui.text_size(em * 0.6), height = ui.px(em * 1.8), font = ui.mono_font(), font_size = math.round(em * 0.86)})
					ui.label(fmt.tprintf("%s###tip", copied ? i18n.tr("Copied") : value))
				}
			}
		}
		ui.space(ui.INNER_PAD)
	}
}

@(private)
Copy_Glyph :: struct { color: draw.Color, copied: bool }

// Two sheets, one over the other (copy); a check once copied. Drawn: the icons' font has no such glyph.
@(private)
copy_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	g := (^Copy_Glyph)(user)
	r := b.rect
	side := min(r.max.x - r.min.x, r.max.y - r.min.y)
	c := (r.min + r.max) * 0.5
	w := max(1, math.round(side * 0.08))
	if g.copied {
		pts := [3][2]f32{c + {-0.28, 0.02} * side, c + {-0.08, 0.22} * side, c + {0.3, -0.2} * side}
		draw.polyline(dc, pts[:], w * 1.4, g.color)
		return
	}
	u := side * 0.42
	back := draw.Rect{c + {-0.32, -0.32} * side, c + {-0.32, -0.32} * side + u}
	front := draw.Rect{c + {-0.1, -0.1} * side, c + {-0.1, -0.1} * side + u}
	draw.rect(dc, back, g.color, side * 0.08, w)
	draw.rect(dc, front, g.color, side * 0.08, w)
}

@(private = "file")
logo_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	l := (^Logo)(user)
	r := b.rect
	room := r.max - r.min
	if l.size.x <= 0 || l.size.y <= 0 || room.x <= 0 { return }
	scale := min(room.x / l.size.x, room.y / l.size.y)
	sz := l.size * scale
	at := r.min + (room - sz) * 0.5
	draw.image(dc, l.texture, {at, at + sz})
}

// The footer, under a hairline, on the dialog's ground: the vendor's signature on the left; on the right, what closes,
// and what installs (or the installed copy to open). While the work runs, a click does nothing.
@(private = "file")
footer :: proc(d: ^Dialog, o: Setup_Options, em: f32) -> (ev: Event) {
	// (keys are made under the row: the box of a button is looked for there, right after it)
	mark :: proc(d: ^Dialog, role: Button_Role, id: string) { if b := ui.prev_box(id); b != nil { d.at[role] = b.rect } }
	ui.hline(ui.fill())
	ui.space(ui.ITEM_GAP)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###setup_buttons") {
		ui.space(ui.PAGE_MARGIN)
		by_line(o, d.vendor_mark, em, "###setup_by")
		ui.spacer(ui.fill())
		just_installed := d.installed != "" && d.facts.state != .This_Copy
		how := closing(d, o)
		CLOSING_WORDS := [Closing]string{.Close = i18n.tr("Close"), .Not_Now = i18n.tr("Not now"), .Keep_Standalone = i18n.tr("Do not install")}
		CLOSING_IDS := [Closing]string{.Close = "###setup_close", .Not_Now = "###setup_later", .Keep_Standalone = "###setup_standalone"}
		if button(o, CLOSING_IDS[how], CLOSING_WORDS[how], lucide.X, .Neutral, em) { ev = close(d, how) }
		if !just_installed { mark(d, .Secondary, CLOSING_IDS[how]) }
		if just_installed {
			ui.space(ui.CONTROL_GAP)
			if button(o, "###setup_launch", i18n.tr("Open the installed copy"), lucide.EXTERNAL_LINK, .Success, em) { ev = open_installed(d) }
			mark(d, .Secondary, "###setup_launch")
		}
		if label := install_label(d, o); label != "" {
			ui.space(ui.CONTROL_GAP)
			if button(o, "###setup_install", label, install_glyph(d), .Success, em) && !busy(d) { start_install(d, o) }
			mark(d, .Install, "###setup_install")
		}
		ui.space(ui.PAGE_MARGIN)
	}
	ui.space(ui.ITEM_GAP)
	if d.confirm && ui.key_press(.Escape) { d.confirm = false }
	return
}

// A button: the program's (Setup_Options.button), else the toolkit's button with its glyph and the soft pair of its intent.
@(private)
button :: proc(o: Setup_Options, id, label, glyph: string, intent: ui.Intent, em: f32) -> bool {
	if o.button != nil { return o.button(id, label, glyph, intent, em, o.user) }
	clicked := ui.button(id, label, glyph, {icon_font = ui.lucide_icons(), intent = intent}).clicked
	// (ui.button rounds its own corners: a square dialog squares them after, before they are drawn)
	if o.square { if b := ui.prev_box(id); b != nil { b.radius = 0 } }
	return clicked
}
