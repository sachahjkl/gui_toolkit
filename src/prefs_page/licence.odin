package tk_prefs_page

// The Licence page, the same in every program that sells a licence (gt:licence): its state in one word (Unregistered,
// Registered, a key that is not valid), what a licence is for, and what can be done: buy one (the site's pricing page),
// paste a key, choose a licence file, remove it. One wording in every program; the program gives its product, its name
// and its pricing page. Every read and write of the licence's file is a task's (ui.task), never the interface's thread.
//
//   prefs_page.licence_init(&app.licence, &app.ui, {store = {product = PRODUCT, program = APP}, name = "Inspecteur",
//                           pricing_url = "https://inspecteur.froment.software/pricing/"})   at the start
//   opts.licence = &app.licence                           the settings show the Licence page
//   prefs_page.licence_install_file(&app.licence, path)   a licence file dropped on the window, given on the command line
//   prefs_page.licence_end(&app.licence)                  at the end, once the chores have stopped
//
// The states: unknown until the store's first read comes (read false); then the status read last (status). A change (a
// key, a file, Remove) is one task at a time (busy): it writes, reads the status again, and its answer comes at a next
// build of the State given to licence_init.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import i18n "../i18n"
import licence "../licence"
import lucide "../lucide"
import "../platform"
import "../ui"

// The category of the Licence page (Page.current, show).
LICENCE_PAGE :: "licence"

// Other words the palette finds the Licence page by.
@(private = "file", rodata) LICENCE_TAGS := [?]string{"licence", "license", "key", "register", "buy", "support"}

// What the program gives: its product and where it keeps the licence (licence.Store_Options), its name as people read it
// ("Inspecteur", "opencode native"), the site's pricing page (where Buy a licence goes; "": no Buy button).
Licence_Options :: struct {
	store:       licence.Store_Options,
	name:        string,          // a constant of the program
	pricing_url: string,          // a constant of the program
	owner:       ^platform.Window,   // the window the file dialog belongs to (nil: none)
}

Licence :: struct {
	options: Licence_Options,
	// (on the heap: a task still on the chores when the program ends keeps it, never the Licence, which may go with the
	// program's memory)
	store:   ^licence.Store,
	state:   ^ui.State,          // where the tasks' answers come
	status:  licence.Status,     // the last read (heap)
	read:    bool,               // a status has come
	busy:    bool,               // a task on the store is on its way
	key:     ui.Line_Edit,      // the key being pasted
	problem: string,             // why the last change failed (owned; "": none)
	notice:  string,             // what the last change did (owned; "": nothing)
	confirm: bool,               // Remove was clicked once: the next click removes
	pending: string,             // a licence file given while a task was on its way (owned; "": none)
}

// The store and its first read (a task of `state`, the window the settings are built in).
licence_init :: proc(l: ^Licence, state: ^ui.State, o: Licence_Options) {
	l.options, l.state = o, state
	l.store = new(licence.Store, runtime.heap_allocator())
	licence.store_init(l.store, o.store)
	licence_run(l, .Read, "")
}

// A licence file given (dropped on the window, on the command line, chosen): installed rather than opened; after the
// task on its way, when there is one (the first read, at the start).
licence_install_file :: proc(l: ^Licence, path: string) {
	if l.busy {
		delete(l.pending)
		l.pending = strings.clone(path)
		return
	}
	licence_run(l, .Install_File, path)
}

// Whether the program is registered, from the last read (false until it came).
licence_registered :: proc(l: ^Licence) -> bool { return l.read && l.status.registered }

// At the end, the window's State closed (its tasks' answers are refused from then). A task still on its way keeps the
// store: it is left to the process's end.
licence_end :: proc(l: ^Licence) {
	licence.status_destroy(&l.status, runtime.heap_allocator())
	if l.store != nil && !l.busy {
		licence.store_destroy(l.store)
		free(l.store, runtime.heap_allocator())
	}
	ui.line_edit_wipe(&l.key)
	ui.line_edit_destroy(&l.key)
	delete(l.problem)
	delete(l.notice)
	delete(l.pending)
	l^ = {}
}

@(private = "file")
Licence_Do :: enum u8 { Read, Install, Install_File, Remove }

@(private = "file")
Licence_Job :: struct {
	l:      ^Licence,           // the answer's (done runs only while the State is open)
	store:  ^licence.Store,     // the work's
	act:    Licence_Do,
	text:   string,             // the key, or the file (heap)
	err:    licence.Error,
	status: licence.Status,     // read after the change (heap)
}

@(private = "file")
licence_run :: proc(l: ^Licence, act: Licence_Do, text: string) {
	if l.state == nil || l.store == nil || l.busy { return }
	a := runtime.heap_allocator()
	j := new(Licence_Job, a)
	j^ = {l = l, store = l.store, act = act, text = strings.clone(text, a)}
	l.busy = true
	work :: proc(d: rawptr) {
		j := (^Licence_Job)(d)
		s := j.store
		switch j.act {
		case .Read:
		case .Install:      j.err = licence.store_install(s, j.text)
		case .Install_File: j.err = licence.store_install_file(s, j.text)
		case .Remove:       if !licence.store_remove(s) { j.err = .Not_Written }
		}
		j.status = licence.store_read(s, runtime.heap_allocator())
	}
	done :: proc(d: rawptr, _: u64) {
		j := (^Licence_Job)(d)
		defer licence_job_free(d)
		l := j.l
		licence.status_destroy(&l.status, runtime.heap_allocator())
		l.status, j.status = j.status, {}
		l.read, l.busy, l.confirm = true, false, false
		if l.pending != "" {
			// (a file given meanwhile: its turn now)
			path := l.pending
			l.pending = ""
			defer delete(path)
			licence_run(l, .Install_File, path)
		}
		delete(l.problem); l.problem = ""
		if j.act == .Read { return }
		delete(l.notice); l.notice = ""
		if j.err != .None {
			l.problem = strings.clone(licence.error_text(j.err))
			return
		}
		#partial switch j.act {
		case .Install, .Install_File:
			ui.line_edit_wipe(&l.key)
			l.notice = strings.clone(i18n.tr("Licence registered: thank you."))
		case .Remove:
			l.notice = strings.clone(i18n.tr("Licence removed."))
		}
	}
	ui.task(l.state, work, done, j, licence_job_free)
}

@(private = "file")
licence_job_free :: proc(d: rawptr) {
	a := runtime.heap_allocator()
	j := (^Licence_Job)(d)
	licence.status_destroy(&j.status, a)
	delete(j.text, a)
	free(j, a)
}

// The Licence page (Page_Options.licence): its sidebar's entry.
@(private)
licence_page_info :: proc(l: ^Licence) -> Page_Info {
	return {category = LICENCE_PAGE, title = i18n.later("Licence"), icon = lucide.KEY_ROUND, build = licence_page_build, user = l, tags = LICENCE_TAGS[:]}
}

@(private = "file")
licence_page_build :: proc(user: rawptr, em: f32) {
	l := (^Licence)(user)
	name := l.options.name != "" ? l.options.name : l.options.store.product.title
	line :: proc(id, text: string, em: f32, size: f32 = 0) {
		m := ui.Style_Mod{width = ui.fill(), text_pad = 0}
		if size > 0 { m.font_size = math.round(size) }
		ui.next(m)
		ui.paragraph(fmt.tprintf("%s###%s", text, id))
	}
	h := ui.px(math.round(em * CONTROL_EM))
	switch {
	case !l.read:
		if ui.tags("weak") { line("licence_state", i18n.tr("Reading the licence…"), em) }
	case l.status.registered:
		lic := l.status.licence
		if ui.tags("good") { line("licence_state", i18n.tr("Registered"), em, em * 1.1) }
		ui.spacer(ui.px(em * 0.4))
		line("licence_holder", fmt.tprintf(i18n.tr("Holder: %s"), lic.name), em)
		if licence_editions(l.options.store.product) > 1 {
			line("licence_edition", fmt.tprintf(i18n.tr("Edition: %s"), licence.edition_title(l.options.store.product, lic.edition)), em)
		}
		ui.spacer(ui.px(em * 0.4))
		if ui.tags("weak") { line("licence_thanks", fmt.tprintf(i18n.tr("Thank you for supporting %s."), name), em) }
		ui.spacer(ui.px(em * 0.8))
		licence_remove_button(l, em)
	case:
		line("licence_state", i18n.tr("Unregistered"), em, em * 1.1)
		ui.spacer(ui.px(em * 0.4))
		if ui.tags("weak") { line("licence_why", sentence(fmt.tprintf(i18n.tr("%s is free; a licence supports its development."), name)), em) }
		if l.status.stored {
			// (a key is there, but it does not check out: said, not hidden; it can be replaced or removed)
			ui.spacer(ui.px(em * 0.4))
			if ui.tags("bad") { line("licence_stored", fmt.tprintf(i18n.tr("The licence stored here is not valid: %s"), licence.error_text(l.status.err)), em) }
		}
		if l.options.pricing_url != "" {
			ui.spacer(ui.px(em * 0.8))
			if ui.button("licence_buy", i18n.tr("Buy a licence"), lucide.HEART, {icon_font = ui.lucide_icons(), intent = .Primary}).clicked {
				ui.open(l.options.pricing_url, .Url)
			}
		}
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(id = "###licence_key_row") {
			ui.next({width = ui.fill(), height = h})
			res := ui.line_edit("###licence_key", &l.key, {placeholder = i18n.tr("Paste a licence key")})
			key := strings.trim_space(ui.line_edit_string(&l.key))
			ui.spacer(ui.px(em * 0.4))
			register := ui.button("licence_register", i18n.tr("Register"), lucide.CHECK, {icon_font = ui.lucide_icons(), intent = .Success, disabled = l.busy || key == ""})
			if (register.clicked || res.committed) && key != "" && !l.busy { licence_run(l, .Install, key) }
		}
		ui.spacer(ui.px(em * 0.5))
		if ui.button("licence_file", i18n.tr("Choose a licence file…"), lucide.FOLDER_OPEN, {icon_font = ui.lucide_icons(), disabled = l.busy}).clicked {
			licence_choose_file(l, name)
		}
		if l.status.stored {
			ui.spacer(ui.px(em * 0.5))
			licence_remove_button(l, em)
		}
	}
	if l.problem != "" {
		ui.spacer(ui.px(em * 0.5))
		if ui.tags("bad") { line("licence_problem", l.problem, em) }
	}
	if l.notice != "" {
		ui.spacer(ui.px(em * 0.5))
		if ui.tags("good") { line("licence_notice", l.notice, em) }
	}
	ui.spacer(ui.px(em * 1.2))
	if ui.tags("weak") {
		line("licence_offline", fmt.tprintf(i18n.tr("The key is checked on this computer, with no network: %s never sends it anywhere."), name), em, em * 0.9)
	}
}

// The control's height, in font sizes (the page's other controls').
@(private = "file") CONTROL_EM :: 2

// Remove the licence: the first click asks, the second removes (a key removed is gone from this computer); Escape
// gives the question up.
@(private = "file")
licence_remove_button :: proc(l: ^Licence, em: f32) {
	words := l.confirm ? i18n.tr("Click again to remove the licence") : i18n.tr("Remove the licence")
	if ui.button("licence_remove", words, lucide.TRASH_2, {icon_font = ui.lucide_icons(), intent = .Danger, face = .Ghost, disabled = l.busy}).clicked {
		if l.confirm { licence_run(l, .Remove, "") } else { l.confirm = true }
	}
	if l.confirm && ui.key_press(.Escape) { l.confirm = false }
}

// `text` as a sentence starts: its first letter in capitals when it is an ASCII letter (a name written in lower case,
// "cliche", at its start). Its own bytes in the temporary allocator.
@(private = "file")
sentence :: proc(text: string) -> string {
	if text == "" || text[0] < 'a' || text[0] > 'z' { return text }
	b := transmute([]u8)strings.clone(text, context.temp_allocator)
	b[0] -= 'a' - 'A'
	return string(b)
}

// The number of editions the product sells.
@(private = "file")
licence_editions :: proc(p: licence.Product) -> int {
	n := 0
	for e in p.editions { if e.id != "" { n += 1 } }
	return n
}

// The system's Open dialog, then the file installed: both off the interface's thread.
@(private = "file")
licence_choose_file :: proc(l: ^Licence, name: string) {
	d := licence.file_dialog(l.options.store.product, i18n.tr("Choose a licence file"), fmt.tprintf(i18n.tr("%s licence"), name))
	d.owner = l.options.owner
	ui.file_dialog(l.state, .Open, d, proc(r: platform.Dialog_Result, user: rawptr) {
		if r.status != .Chosen || len(r.paths) == 0 { return }
		// (licence_run copies the path: the result's are freed after this call)
		licence_install_file((^Licence)(user), r.paths[0])
	}, l)
}
