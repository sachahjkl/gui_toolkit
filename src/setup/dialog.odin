package tk_setup

// The Setup dialog: the program, its version, the state of its install in a sentence, where its files are, and what can
// be done: Install (or Repair, Upgrade, Update the shortcuts), Uninstall, Open the installed copy, Keep standalone; the
// program's own options (Config.choices), and the install folder before the first install (Config.folder).
//
//   d: setup.Dialog                          kept by the program, at a place that does not move while it is open
//   setup.open(&d, cfg)                      at a start when setup.wanted(...), from a menu, from `--setup`
//   ev := setup.dialog(&d, cfg, em, logo)    each frame, open or not (a modal while open; it also collects the work)
//   setup.stale(&d)                          the program knows the install may have changed (its window came back)
//   setup.finish(&d, cfg)                    at the end of the process (what an uninstall left goes then)
//   setup.destroy(&d)
//
// A program that draws a screen of its own keeps the Dialog and calls `update` each frame instead of `dialog`, and the
// actions below from its buttons (the dialog uses the same): what the state is, what is offered and how the work goes
// are the same in every screen.
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
import desktop "../desktop"
import i18n "../i18n"
import "../draw"
import lucide "../lucide"
import "../platform"
import "../render"
import "../ui"

Dialog :: struct {
	open:      bool,
	known:     bool,               // the facts were read at least once since it opened
	facts:     Facts,              // as last read (strings owned)
	shortcut:  bool,               // the Desktop's shortcut, asked of Install
	choices:   [dynamic]bool,      // the program's options (Config.choices), as ticked
	folder:    ui.Text_Field,      // the install folder (Config.folder): set from the facts when they first come
	size:      [2]f32,             // what the user made it, logical pixels ({}: DIALOG_EM; the program may keep it)
	note:      string,             // what the last action said (owned)
	note_good: bool,
	installed: string,             // the copy just installed, to open (owned; "": none)
	removed:   bool,               // this copy was uninstalled while it runs: its file goes when the process ends
	leftovers: [dynamic]string,    // ... with these (owned)
	copied:    string,             // the line whose path was just copied (its id, owned): a check until the pointer leaves
	confirm:   bool,               // Uninstall was clicked once: the next click does it
	job:       ^Job,               // the work out on the dialog's thread (nil: none)
	watcher:   ^desktop.Watcher,   // while open (nil: none could start; setup.stale reads again)
	stale_flag: bool,              // atomic: the watcher (or the program) says the install changed
	state:     ^ui.State,          // atomic: the State of its last frame, which the threads wake (nil before one)
	at:        [Button_Role]draw.Rect,   // where the last frame put its buttons ({}: not shown): a program's automation clicks them
}

// The buttons a program's automation finds in Dialog.at. Secondary: what closes (Keep standalone, Not now, Close) or opens
// the installed copy.
Button_Role :: enum u8 { Install, Uninstall, Secondary }

Event :: enum u8 {
	None,
	Installed,         // keep CHOICE_INSTALLED
	Uninstalled,
	Kept_Standalone,   // keep CHOICE_STANDALONE
	Dismissed,         // closed without an answer: keep choice_dismissed(version)
	Launched,          // the installed copy was started: this one ends
}

// The program's mark beside its name (a texture of the program's renderer, and its size in pixels).
Logo :: struct {
	texture: render.Texture,
	size:    [2]f32,
}

@(private = "file") DIALOG_EM       :: [2]f32{46, 34}   // its size at first (a grip of its corner or edges makes it larger or smaller)
@(private = "file") DIALOG_MIN_EM   :: [2]f32{28, 16}   // ... and at the least (what does not fit scrolls; the buttons stay)
@(private = "file") MARGIN_EM       :: 1.5
@(private = "file") LOGO_EM         :: 4.2

// Opens the dialog: the facts are read on its thread, the places of the install are watched.
open :: proc(d: ^Dialog, c: Config) {
	if d.open { return }
	d.open, d.known, d.confirm = true, false, false
	if s := ui.current_state(); s != nil { sync.atomic_store(&d.state, s) }
	clear(&d.choices)
	for x in c.choices { append(&d.choices, x.on) }
	ui.field_clear(&d.folder)
	say(d, true, "")
	watch_begin(d, c)
	job_start(d, c, .Read)
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
finish :: proc(d: ^Dialog, c: Config) {
	if len(d.leftovers) > 0 { _ = remove_later(c, d.leftovers[:]) }
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
	ui.field_destroy(&d.folder)
	for l in d.leftovers { delete(l) }
	delete(d.leftovers)
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
watch_begin :: proc(d: ^Dialog, c: Config) {
	if d.watcher != nil { return }
	o, _ := options(c, d.choices[:])
	d.watcher = desktop.watch_start(&o, proc(user: rawptr) {
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
	c:         Config,              // (its strings and procedures are the program's: they outlive the work)
	shortcut:  bool,
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
}

@(private = "file")
job_start :: proc(d: ^Dialog, c: Config, kind: Job_Kind) {
	if d.job != nil { return }
	sync.atomic_store(&d.stale_flag, false)
	j := new(Job)
	j.kind, j.d, j.c, j.shortcut, j.removed = kind, d, c, d.shortcut, d.removed
	j.choices = make([]bool, len(d.choices))
	copy(j.choices, d.choices[:])
	j.folder = strings.clone(strings.trim_space(ui.field_string(&d.folder)))
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
		ok, text := install(j.c, j.shortcut, j.choices, j.folder)
		j.ok, j.text = ok, strings.clone(text)
	case .Uninstall:
		ok, leftovers, why := uninstall(j.c, j.choices)
		j.ok, j.leftovers, j.text = ok, leftovers, strings.clone(why)
	case .Pick_Folder:
		res := platform.pick_folder_dialog({title = i18n.tr("Install folder"), start_dir = j.folder}, context.temp_allocator)
		if res.status == .Chosen && len(res.paths) > 0 { j.ok, j.text = true, strings.clone(res.paths[0]) }
		return
	}
	j.facts = facts_clone(facts(j.c, j.choices))
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
job_collect :: proc(d: ^Dialog, c: Config) -> (ev: Event) {
	j := d.job
	if j == nil || !sync.atomic_load(&j.done) { return }
	job_join(j)
	d.job = nil
	defer job_free(j)
	if j.kind == .Pick_Folder {
		if j.ok { ui.field_set(&d.folder, j.text) }
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
			d.removed = len(d.leftovers) > 0
			say(d, true, d.removed ? i18n.tr("Removed. The program is deleted when this window closes.") : i18n.tr("Removed."))
			ev = .Uninstalled
		} else {
			say(d, false, j.text)
		}
	}
	facts_free(&d.facts)
	d.facts, j.facts = j.facts, {}
	if d.removed { d.facts.state = .Removal_Scheduled }   // (the file is still there: the disk would say Repair)
	if !d.known {
		d.known = true
		d.shortcut = d.facts.desk_lnk
		if ui.field_string(&d.folder) == "" { ui.field_set(&d.folder, d.facts.dir) }
	}
	return
}

// What the state is, in a sentence, and its tone ("good", "warn", "bad", "accent").
state_words :: proc(f: Facts, c: Config) -> (words, tone: string) {
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
		if is_upgrade(f, c.version) { return fmt.tprintf(i18n.tr("An older copy is installed (%s): upgrade it to %s?"), f.version, c.version), "accent" }
		if is_downgrade(f, c.version) { return fmt.tprintf(i18n.tr("A newer copy is installed (%s): this one (%s) is older."), f.version, c.version), "warn" }
		return fmt.tprintf(i18n.tr("A copy is installed (%s): this one runs on its own."), f.version != "" ? f.version : "?"), "warn"
	case .Removal_Scheduled: return i18n.tr("Uninstalled: the program is deleted when this window closes."), "warn"
	case .Nix_Package:
		if leftover(f) { return i18n.tr("Installed by Nix. An earlier install left files here: they can be removed."), "accent" }
		return i18n.tr("Installed by Nix: the Nix package has the menu entry and the icon."), "good"
	}
	return "", ""
}

// The words of this system for the pieces of an install, in the language in use (whole sentences: a language puts the
// pieces' words where its grammar wants them).
@(private = "file")
words_menu :: proc() -> string {
	when ODIN_OS == .Windows { return i18n.tr("Start menu") } else { return i18n.tr("applications menu") }
}

@(private = "file")
words_record :: proc() -> string {
	when ODIN_OS == .Windows { return i18n.tr("Settings > Apps") } else { return i18n.tr("icons") }
}

@(private = "file")
words_installed :: proc() -> string {
	when ODIN_OS == .Windows { return i18n.tr("Installed. Start it from the Start menu, or now:") } else { return i18n.tr("Installed. Start it from the applications menu, or now:") }
}

@(private = "file")
words_pieces_missing :: proc() -> string {
	when ODIN_OS == .Windows {
		return i18n.tr("Installed, but a shortcut, the Settings entry or a file is missing.")
	} else {
		return i18n.tr("Installed, but the menu entry, an icon or a file is missing.")
	}
}

// The dialog, while it is open (a modal over the window); called each frame, open or not. What happened, if anything.
//
// Laid out dense, as a tool's panel: a title bar (the name, the close control); a header (what the dialog offers, the
// versions, the state as a badge); the install location; the options as a grid of boxes; what the disk says (where the
// files are, a note); the buttons. Config.square: every corner square.
dialog :: proc(d: ^Dialog, c: Config, em: f32, logo: Maybe(Logo) = nil) -> (ev: Event) {
	ev = update(d, c)
	if !d.open { return }
	was_open := d.open
	busy := d.job != nil && d.job.kind != .Read
	if ui.modal_sized("setup", DIALOG_EM * em, &d.size, &d.open, DIALOG_MIN_EM * em) {
		f := &d.facts
		if c.square { ui.parent_box().radius = 0 }
		if c.backdrop != nil { c.backdrop(c.user) }
		title_bar(d, c, em)
		// what the dialog says scrolls when it is made small; its buttons stay under it
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###setup_scroll") {
			ui.spacer(ui.px(em * 0.5))
			head(d, c, em, logo)
			if d.known {
				location(d, c, em, busy)
				if !f.from_nix { options_grid(d, c, em) }
				ui.spacer(ui.px(em * 0.6))
				info(d, c, em, busy)
			}
			ui.spacer(ui.px(em * 0.5))
		}
		ui.spacer(ui.px(em * 0.4))
		if bev := buttons(d, c, em); bev != .None { ev = bev }
		ui.spacer(ui.px(em * 0.8))
	}
	if was_open && !d.open && ev == .None { ev = closed_event(d) }
	if !d.open { watch_end(d) }
	return
}

////////////////////////////////
// The controller: what a screen of the program's own calls (the dialog calls the same)

// Each frame, open or not: collects the work that ended (its event), reads the install again when it changed, stops
// watching once closed.
update :: proc(d: ^Dialog, c: Config) -> (ev: Event) {
	if s := ui.current_state(); s != nil { sync.atomic_store(&d.state, s) }
	ev = job_collect(d, c)
	if !d.open {
		watch_end(d)
		return
	}
	if d.job == nil && sync.atomic_load(&d.stale_flag) { job_start(d, c, .Read) }
	return
}

// Install, Uninstall or the folder picker is at work (the buttons wait; reading the state is not work).
busy :: proc(d: ^Dialog) -> bool { return d.job != nil && d.job.kind != .Read }

// What the install button says for the state ("": none is offered: not read yet, just installed, removed, from Nix).
install_label :: proc(d: ^Dialog, c: Config) -> string {
	f := &d.facts
	if !d.known || d.installed != "" && f.state != .This_Copy || f.state == .Removal_Scheduled || f.from_nix { return "" }
	#partial switch f.state {
	case .Other_Copy:
		switch {
		case is_upgrade(f^, c.version):   return fmt.tprintf(i18n.tr("Upgrade to %s"), c.version)
		case is_downgrade(f^, c.version): return fmt.tprintf(i18n.tr("Go back to %s"), c.version)
		}
		return i18n.tr("Replace the installed copy")
	case .Repair:    return i18n.tr("Repair")
	case .This_Copy: return i18n.tr("Update the shortcuts")
	}
	return i18n.tr("Install")
}

// Uninstall is offered: something of an install is there.
can_uninstall :: proc(d: ^Dialog) -> bool {
	return d.known && (d.facts.state == .This_Copy || d.facts.state == .Repair || d.facts.state == .Other_Copy || d.facts.state == .Nix_Package && leftover(d.facts))
}

// What closes the screen without installing: Close, Not now (an upgrade), Keep standalone (no install, another copy).
Closing :: enum u8 { Close, Not_Now, Keep_Standalone }

closing :: proc(d: ^Dialog, c: Config) -> Closing {
	switch {
	case d.installed != "" && d.facts.state != .This_Copy: return .Close
	case is_upgrade(d.facts, c.version):                   return .Not_Now
	case d.known && (d.facts.state == .Not_Installed || d.facts.state == .Other_Copy): return .Keep_Standalone
	}
	return .Close
}

// Starts Install (with Dialog.shortcut, choices and folder) on the dialog's thread; nothing while work is out.
start_install :: proc(d: ^Dialog, c: Config) { if d.known && d.job == nil { job_start(d, c, .Install) } }

// Starts Uninstall on the dialog's thread (a screen asks first: Dialog.confirm); nothing while work is out.
start_uninstall :: proc(d: ^Dialog, c: Config) { if d.known && d.job == nil { job_start(d, c, .Uninstall) } }

// Opens the system's folder picker for the install folder (Dialog.folder takes the answer).
pick_folder :: proc(d: ^Dialog, c: Config) { if d.job == nil { job_start(d, c, .Pick_Folder) } }

// Starts the copy just installed (Dialog.installed): Launched, the program then ends; None when it does not start.
open_installed :: proc(d: ^Dialog) -> Event {
	if d.installed != "" && launch(d.installed) { return .Launched }
	say(d, false, fmt.tprintf(i18n.tr("%s does not start"), d.installed))
	return .None
}

// Closes the screen by `how`: the event to keep (Kept_Standalone, Dismissed: not again for this version, or None).
close :: proc(d: ^Dialog, how: Closing) -> Event {
	if !d.open { return .None }
	d.open = false
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
@(private = "file")
rad :: proc(c: Config, em, k: f32) -> f32 { return c.square ? 0 : math.round(em * k) }

// The dialog's own header: "<name> Setup", and the close control in its corner (the program's, else the toolkit's button,
// which closes the dialog through its `open`).
@(private = "file")
title_bar :: proc(d: ^Dialog, c: Config, em: f32) {
	if ui.dialog_header("setup_title_bar", fmt.tprintf(i18n.tr("%s Setup"), c.identity.name), {close = true}) {
		if c.close != nil {
			if c.close("###setup_close_x", em, c.user) { d.open = false }
		}
	}
}

// A framed panel across the dialog, inside its margins: `if panel(...) { ... }`.
@(private = "file", deferred_none = panel_end)
panel :: proc(c: Config, em: f32, id: string, axis := ui.Axis.Y) -> bool {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	ui.push_parent(ui.build_box({}, fmt.tprintf("%s_line", id)))
	ui.spacer(ui.px(em * MARGIN_EM))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = axis, cross = .Center, radius = rad(c, em, 0.4)})
	box: ^ui.Box
	if ui.tags("input") { box = ui.build_box({.Draw_Background, .Draw_Border}, id) }
	ui.push_parent(box)
	return true
}

@(private = "file")
panel_end :: proc() {
	ui.pop_parent()
	ui.spacer(ui.px(ui.font_size() * MARGIN_EM))
	ui.pop_parent()
}

// What the screen offers for this state ("Install Classeur", "Repair Classeur"...), and the state in a word.
headline :: proc(f: Facts, c: Config) -> (title, badge: string) {
	name := c.identity.name
	switch f.state {
	case .Not_Installed:     return fmt.tprintf(i18n.tr("Install %s"), name), i18n.tr("Not installed")
	case .This_Copy:         return fmt.tprintf(i18n.tr("%s is installed"), name), i18n.tr("Installed")
	case .Repair:            return fmt.tprintf(i18n.tr("Repair %s"), name), i18n.tr("To repair")
	case .Other_Copy:
		if is_upgrade(f, c.version) { return fmt.tprintf(i18n.tr("Upgrade %s"), name), i18n.tr("Older installed") }
		if is_downgrade(f, c.version) { return fmt.tprintf(i18n.tr("Replace %s"), name), i18n.tr("Newer installed") }
		return fmt.tprintf(i18n.tr("Replace %s"), name), i18n.tr("Other copy")
	case .Removal_Scheduled: return fmt.tprintf(i18n.tr("%s is uninstalled"), name), i18n.tr("Removed")
	case .Nix_Package:       return fmt.tprintf(i18n.tr("%s from Nix"), name), i18n.tr("Nix package")
	}
	return name, ""
}

// The header: the logo, what is offered and the versions, the state as a badge.
@(private = "file")
head :: proc(d: ^Dialog, c: Config, em: f32, logo: Maybe(Logo)) {
	f := &d.facts
	if panel(c, em, "###setup_head", .X) {
		ui.spacer(ui.px(em * 0.9))
		if l, has := logo.?; has {
			side := math.round(em * 2.6)
			ui.next({width = ui.px(side), height = ui.px(side)})
			b := ui.build_box({}, "###setup_logo")
			p := ui.frame_new(Logo)
			p^ = l
			b.custom, b.custom_user = logo_draw, p
			ui.spacer(ui.px(em * 0.8))
		}
		title, badge := i18n.tr("Reading the install…"), ""
		if d.known { title, badge = headline(f^, c) }
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###setup_words") {
			ui.spacer(ui.px(em * 0.55))
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.7)), font_size = math.round(em * 1.25), text_pad = 0})
			ui.label(fmt.tprintf("%s###setup_name", title))
			if ui.tags("weak") {
				installed := i18n.tr("not installed")
				if d.known && f.state != .Not_Installed && f.state != .Nix_Package { installed = f.version != "" ? fmt.tprintf(i18n.tr("v%s installed"), f.version) : i18n.tr("installed") }
				vendor := c.identity.vendor != "" ? fmt.tprintf("  ·  %s", c.identity.vendor) : ""
				ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.35)), font_size = math.round(em * 0.9), text_pad = 0})
				ui.label(fmt.tprintf("%s%s###setup_version", fmt.tprintf(i18n.tr("This copy: v%s → %s"), c.version, installed), vendor))
			}
			ui.spacer(ui.px(em * 0.55))
		}
		if badge != "" {
			_, tone := state_words(f^, c)
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.text_size(em * 1.2), height = ui.px(math.round(em * 2)), radius = rad(c, em, 0.3), text_pad = 0, text_align = .Center})
			if ui.tags("button", tone) {
				b := ui.build_box({.Draw_Background, .Draw_Border, .Draw_Text}, fmt.tprintf("%s###setup_badge", badge))
				b.text_align = .Center
			}
		}
		ui.spacer(ui.px(em * 0.9))
	}
}

// Where it goes: a field and the system's folder picker before the first install, else where it is.
@(private = "file")
location :: proc(d: ^Dialog, c: Config, em: f32, busy: bool) {
	f := &d.facts
	choose := c.folder && f.state == .Not_Installed && !f.from_nix
	ui.spacer(ui.px(em * 0.6))
	line_next()
	if ui.row(id = "###setup_location_label") {
		ui.spacer(ui.px(em * MARGIN_EM))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.5)), text_pad = 0})
			ui.label(fmt.tprintf("%s###setup_loc", choose ? i18n.tr("Install location") : i18n.tr("Installed program")))
		}
	}
	line_next()
	if ui.row(.Center, id = "###setup_location_row") {
		ui.spacer(ui.px(em * MARGIN_EM))
		if choose {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.1)), radius = rad(c, em, 0.3)})
			_ = ui.line_edit("###setup_folder", &d.folder)
			ui.spacer(ui.px(em * 0.4))
			if button(c, "###setup_pick", i18n.tr("Choose…"), lucide.FOLDER_OPEN, .Primary, em) && !busy { pick_folder(d, c) }
		} else {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.1)), axis = .X, cross = .Center, radius = rad(c, em, 0.3)})
			well: ^ui.Box
			if ui.tags("input") { well = ui.build_box({.Draw_Background, .Draw_Border}, "###setup_where") }
			if ui.parent(well) { where_row(d, "###w1", "", f.exe, true, em) }
		}
		ui.spacer(ui.px(em * MARGIN_EM))
	}
	if choose {
		if why := desktop.check_install_dir(strings.trim_space(ui.field_string(&d.folder)), c.identity.name); why != "" {
			line_next()
			if ui.row(id = "###setup_folder_why_row") {
				ui.spacer(ui.px(em * MARGIN_EM))
				if ui.tags("bad") {
					ui.next({width = ui.fill(), text_pad = 0, font_size = math.round(em * 0.86)})
					ui.paragraph(fmt.tprintf("%s###setup_folder_why", why))
				}
				ui.spacer(ui.px(em * MARGIN_EM))
			}
		}
	}
}

// "Options": a section header, then the Desktop shortcut and the program's choices, two framed boxes a line.
@(private = "file")
options_grid :: proc(d: ^Dialog, c: Config, em: f32) {
	ui.spacer(ui.px(em * 0.7))
	if panel(c, em, "###setup_options_head", .X) {
		ui.next({width = ui.px(max(math.round(em * 0.22), 2)), height = ui.px(math.round(em * 1.9)), bg = ui.color("accent")})
		ui.build_box({.Draw_Background}, "###setup_options_bar")
		ui.spacer(ui.px(em * 0.7))
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), text_pad = 0})
		ui.label(fmt.tprintf("%s###setup_options_label", i18n.tr("Options")))
	}
	n := 1 + min(len(c.choices), len(d.choices))
	// (one per line, as wide as the dialog: a long label wraps in its tile, never past it)
	for k in 0 ..< n {
		ui.spacer(ui.px(em * 0.4))
		line_next()
		if ui.row(.Center, id = fmt.tprintf("###setup_options_%d", k)) {
			ui.spacer(ui.px(em * MARGIN_EM))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y, radius = rad(c, em, 0.4)})
			tile: ^ui.Box
			if ui.tags("input") { tile = ui.build_box({.Draw_Background, .Draw_Border}, fmt.tprintf("###setup_tile_%d", k)) }
			if ui.parent(tile) {
				ui.spacer(ui.px(em * 0.5))
				ui.next({width = ui.fill()})
				if k == 0 {
					ui.checkbox("###setup_shortcut", i18n.tr("Shortcut on the Desktop"), &d.shortcut, wrap = true)
				} else {
					ui.checkbox(fmt.tprintf("###setup_choice_%d", k - 1), i18n.tr(c.choices[k - 1].label), &d.choices[k - 1], wrap = true)
				}
				ui.spacer(ui.px(em * 0.5))
			}
			ui.spacer(ui.px(em * MARGIN_EM))
		}
	}
}

// What the disk says, in a framed box: the state in a sentence, the launcher and the record, this copy, the note of
// NixOS, and what the last action said.
@(private = "file")
info :: proc(d: ^Dialog, c: Config, em: f32, busy: bool) {
	f := &d.facts
	if panel(c, em, "###setup_info") {
		ui.spacer(ui.px(em * 0.45))
		words, tone := state_words(f^, c)
		line_next()
		if ui.row(.Center, id = "###setup_state_row") {
			ui.spacer(ui.px(em * 0.9))
			if ui.tags(tone == "accent" ? "" : tone) {
				ui.next({width = ui.fill(), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###setup_state", words))
			}
			ui.spacer(ui.px(em * 0.9))
		}
		where_row(d, "###w2", words_menu(), f.start_lnk ? c.identity.name : "-", false, em)
		where_row(d, "###w3", words_record(), f.record ? c.identity.name : "-", false, em)
		where_row(d, "###w4", i18n.tr("this copy"), f.running, true, em)
		if f.nixos && f.state != .Nix_Package && f.state != .This_Copy {
			line_next()
			if ui.row(id = "###setup_nixos_row") {
				ui.spacer(ui.px(em * 0.9))
				if ui.tags("weak") {
					ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
					ui.paragraph(fmt.tprintf("%s###setup_nixos", i18n.tr("On NixOS, a Nix package is the better install: Nix updates it. An install here makes this copy run by itself (nix-build makes the libraries it needs).")))
				}
				ui.spacer(ui.px(em * 0.9))
			}
		}
		if d.note != "" || busy {
			ui.spacer(ui.px(em * 0.3))
			line_next()
			if ui.row(.Center, id = "###setup_note_row") {
				ui.spacer(ui.px(em * 0.9))
				if ui.tags(busy ? "weak" : d.note_good ? "good" : "bad") {
					ui.next({width = ui.fill(), text_pad = 0})
					ui.paragraph(fmt.tprintf("%s###setup_note", busy ? i18n.tr("Working…") : d.note))
				}
				ui.spacer(ui.px(em * 0.9))
			}
		}
		ui.spacer(ui.px(em * 0.45))
	}
}

// A line of the dialog: as wide as it, as tall as what it holds.
@(private = "file")
line_next :: proc() {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
}

// A line of the well: what, at a fixed width and weak, then where. A path that does not fit is cut; the pointer over it
// shows it whole, and a click on it or on the copy button after it puts it on the clipboard.
@(private = "file")
where_row :: proc(d: ^Dialog, id, key, value: string, path: bool, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.55)), axis = .X, cross = .Center})
	if ui.row(.Center, id = id) {
		ui.spacer(ui.px(em * 0.9))
		if key != "" {
			if ui.tags("weak") {
				ui.next({width = ui.px(em * 9), height = ui.pct(1), text_pad = 0})
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
			ui.spacer(ui.px(em * 0.4))
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
		ui.spacer(ui.px(em * 0.9))
	}
}

@(private = "file")
Copy_Glyph :: struct { color: draw.Color, copied: bool }

// Two sheets, one over the other (copy); a check once copied. Drawn: the icons' font has no such glyph.
@(private = "file")
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

// Uninstall on the left; on the right, what closes, and what installs (or the installed copy to open). While the work
// runs, a click does nothing.
@(private = "file")
buttons :: proc(d: ^Dialog, c: Config, em: f32) -> (ev: Event) {
	d.at = {}
	// (keys are made under the row: the box of a button is looked for there, right after it)
	mark :: proc(d: ^Dialog, role: Button_Role, id: string) { if b := ui.prev_box(id); b != nil { d.at[role] = b.rect } }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###setup_buttons") {
		ui.spacer(ui.px(em * MARGIN_EM))
		if can_uninstall(d) {
			// (the first click asks; the second uninstalls)
			// (beside a Nix package, what goes is only what an earlier install left)
			nix := d.facts.state == .Nix_Package
			words := d.confirm ? (nix ? i18n.tr("Click again to remove") : i18n.tr("Click again to uninstall")) : (nix ? i18n.tr("Remove what is left") : i18n.tr("Uninstall"))
			if button(c, "###setup_uninstall", words, lucide.TRASH_2, .Danger, em) && !busy(d) {
				if d.confirm { start_uninstall(d, c) } else { d.confirm = true }
			}
			mark(d, .Uninstall, "###setup_uninstall")
		}
		ui.spacer(ui.fill())
		just_installed := d.installed != "" && d.facts.state != .This_Copy
		how := closing(d, c)
		CLOSING_WORDS := [Closing]string{.Close = i18n.tr("Close"), .Not_Now = i18n.tr("Not now"), .Keep_Standalone = i18n.tr("Keep standalone")}
		CLOSING_IDS := [Closing]string{.Close = "###setup_close", .Not_Now = "###setup_later", .Keep_Standalone = "###setup_standalone"}
		if button(c, CLOSING_IDS[how], CLOSING_WORDS[how], lucide.X, .Cancel, em) { ev = close(d, how) }
		if !just_installed { mark(d, .Secondary, CLOSING_IDS[how]) }
		if just_installed {
			ui.spacer(ui.px(em * 0.5))
			if button(c, "###setup_launch", i18n.tr("Open the installed copy"), lucide.EXTERNAL_LINK, .Success, em) { ev = open_installed(d) }
			mark(d, .Secondary, "###setup_launch")
		}
		if label := install_label(d, c); label != "" {
			ui.spacer(ui.px(em * 0.5))
			if button(c, "###setup_install", label, d.facts.state == .Repair ? lucide.WRENCH : lucide.DOWNLOAD, .Success, em) && !busy(d) { start_install(d, c) }
			mark(d, .Install, "###setup_install")
		}
		ui.spacer(ui.px(em * MARGIN_EM))
	}
	if d.confirm && ui.key_press(.Escape) { d.confirm = false }
	return
}

// A button: the program's (Config.button), else the toolkit's button with its glyph and the soft pair of its intent.
@(private = "file")
button :: proc(c: Config, id, label, glyph: string, intent: ui.Intent, em: f32) -> bool {
	if c.button != nil { return c.button(id, label, glyph, intent, em, c.user) }
	clicked := ui.button_icon(id, glyph, label, icon_font = ui.lucide_icons(), intent = intent).clicked
	// (button_icon rounds its own corners: a square dialog squares them after, before they are drawn)
	if c.square { if b := ui.prev_box(id); b != nil { b.radius = 0 } }
	return clicked
}
