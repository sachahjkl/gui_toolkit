package tk_prefs_page

// The program's installation, the same in every program: the offer at a start (gt:setup's dialog, as a modal), the
// Installation page of the settings (setup.page), the user's answer kept in the settings (install.choice), and what an
// uninstall leaves for the end of the process. A program declares what it is (setup.Setup_Options: its desktop.Identity,
// its version, its own parts) and calls:
//
//   prefs_page.install_init(&app.install, &app.prefs, setup_options())   at the start, its settings loaded
//   prefs_page.install_offer(&app.install, &state, offer)                 its window open: reads the install on a task
//   if prefs_page.install_frame(&app.install, em) == .Launched { quit() }  each frame: the modal, the work that ended
//   prefs_page.install_open(&app.install)                                 --setup: the modal now
//   opts.install = &app.install                                           the settings show the Installation page
//   prefs_page.install_end(&app.install)                                  at the end, before the window's State goes
//   prefs_page.install_launch(&app.install)                               last, its single instance released
//
// The command line (--install, --uninstall, --setup) is setup.command_of and setup.command_run.

import "core:strings"
import config "../config"
import desktop "../desktop"
import i18n "../i18n"
import lucide "../lucide"
import process "../process"
import setup "../setup"
import "../ui"

// What the user answered the offer ("": nothing yet; setup.CHOICE_*). Hidden: no page shows it.
INSTALL_CHOICE_PREF :: "install.choice"

// The categories of the toolkit's own pages (Page.current, show).
INSTALL_PAGE     :: "install"
DIAGNOSTICS_PAGE :: "diagnostics"

@(private = "file", rodata)
INSTALL_DEFS := [?]config.Def{
	{name = INSTALL_CHOICE_PREF, description = "What was answered when the program offered to install itself.", kind = .String, default = {s = ""}, hidden = true},
}

// Other words the palette finds the toolkit's pages by.
@(private = "file", rodata) INSTALL_TAGS := [?]string{"install", "uninstall", "setup", "repair", "start menu", "path", "shortcut"}
@(private, rodata) DIAGNOSTICS_TAGS      := [?]string{"gpu", "graphics", "performance", "slow", "frames", "renderer", "report", "system"}

Install :: struct {
	dialog:     setup.Dialog,
	options:    setup.Setup_Options,   // the program's (its strings and procedures are its constants)
	prefs:      ^config.Prefs,
	logo:       Maybe(setup.Logo),     // the modal's mark (a texture of the program's renderer; nil: none)
	// what the start's reading found (install_offer): the program may wait for it (its updater wants to know which copy runs)
	known:      bool,
	running_it: bool,                  // this program is the installed copy
	running:    string,                // owned: this program's executable
	reading:    bool,                  // the start's reading is out on a task
	pending:    setup.Event,           // what the page's build met: install_frame says it
	launch:     string,                // owned: the installed copy install_launch starts ("": none)
}

// The program's declaration. Registers install.choice when the program did not (a value read from the file before
// waits for it in the registry).
install_init :: proc(in_: ^Install, prefs: ^config.Prefs, o: setup.Setup_Options) {
	in_.prefs, in_.options = prefs, o
	if config.ref_of(prefs, INSTALL_CHOICE_PREF) == config.NO_REF { config.register(prefs, INSTALL_DEFS[:]) }
}

@(private = "file")
Offer_Job :: struct {
	in_:    ^Install,
	o:      setup.Setup_Options,
	choice: string,   // owned
	offer:  bool,     // in: the program lets the modal open; out: it opens
	running_it: bool,
	running: string,  // owned
}

// At a start, the window open (`state`: its interface, whose next build takes the answer): the install is read on a
// task, and the installed copy deletes the files an update replaced. The modal opens when there is something to offer
// (setup.wanted: no install, one to repair, an older one) and the user did not answer for this version. `offer` false:
// never the modal (a test, a demo, a disposable profile); the reading still says which copy runs (known, running_it).
install_offer :: proc(in_: ^Install, state: ^ui.State, offer: bool) {
	if !desktop.supported() || in_.reading { return }
	j := new(Offer_Job)
	j^ = {in_ = in_, o = in_.options, choice = strings.clone(config.string_of(in_.prefs, INSTALL_CHOICE_PREF)), offer = offer}
	in_.reading = true
	ui.task(state, proc(data: rawptr) {
		j := (^Offer_Job)(data)
		f := setup.facts(j.o)
		j.running_it = f.running_it
		j.running = strings.clone(f.running)
		if f.running_it {
			integration, _ := setup.options(j.o)
			desktop.clean_old(&integration, process.parent_dir(f.running))
		}
		j.offer = j.offer && setup.wanted(f, j.o.version, j.choice)
		free_all(context.temp_allocator)
	}, proc(data: rawptr, _: u64) {
		j := (^Offer_Job)(data)
		defer offer_free(j)
		in_ := j.in_
		in_.reading, in_.known, in_.running_it = false, true, j.running_it
		delete(in_.running)
		in_.running, j.running = j.running, ""
		if j.offer { install_open(in_) }
	}, j, offer_free)
}

@(private = "file")
offer_free :: proc(data: rawptr) {
	j := (^Offer_Job)(data)
	delete(j.choice)
	delete(j.running)
	free(j)
}

// Shows the modal now (--setup, Settings > Apps' Uninstall).
install_open :: proc(in_: ^Install) {
	if in_.dialog.open && !in_.dialog.in_page { return }
	if in_.dialog.open { _ = setup.close(&in_.dialog, .Close) }   // (the page's: the modal takes it over)
	setup.open(&in_.dialog, in_.options)
}

// Each frame of the window the modal belongs to: the modal while it is open, the work that ended, the answer kept; what
// happened (the answer is already kept). Launched: the program ends (its window closes, its single instance goes), and
// install_launch starts the installed copy. Installed, Uninstalled: the program follows what its own settings say of the
// desktop again, if it applies them.
install_frame :: proc(in_: ^Install, em: f32) -> (ev: setup.Event) {
	if in_.dialog.in_page {
		ev = setup.update(&in_.dialog, in_.options)
	} else {
		ev = setup.dialog(&in_.dialog, in_.options, em, in_.logo)
	}
	install_event(in_, ev)
	if ev == .None { ev = in_.pending }
	in_.pending = .None
	return
}

// At the end of the process, before the window's State goes: what an uninstall left because this process held it is
// deleted once it ends; the dialog's thread is waited for.
install_end :: proc(in_: ^Install) {
	setup.finish(&in_.dialog, in_.options)
	setup.destroy(&in_.dialog)
	delete(in_.running)
	in_.running = ""
}

// Last, once the program's single instance is released: the installed copy asked for (Launched) starts. Started earlier,
// it would find this copy still running and hand itself over to it. Nothing when none was asked for.
install_launch :: proc(in_: ^Install) {
	if in_.launch != "" { _ = setup.launch(in_.launch) }
	delete(in_.launch)
	in_.launch = ""
}

// The modal or the page is open: a program leaves the keyboard to it.
install_open_now :: proc(in_: ^Install) -> bool { return in_.dialog.open && !in_.dialog.in_page }

// What an event leaves as the user's answer. Closed without one, the offer does not come again for this version; an
// earlier "standalone" or "installed" stays then, unless what was declined is an upgrade.
@(private)
install_event :: proc(in_: ^Install, ev: setup.Event) {
	saved := config.string_of(in_.prefs, INSTALL_CHOICE_PREF)
	choice := saved
	#partial switch ev {
	case .Installed:       choice = setup.CHOICE_INSTALLED
	case .Kept_Standalone: choice = setup.CHOICE_STANDALONE
	case .Dismissed:
		if setup.is_upgrade(in_.dialog.facts, in_.options.version) || (saved != setup.CHOICE_STANDALONE && saved != setup.CHOICE_INSTALLED) {
			choice = setup.choice_dismissed(in_.options.version)
		}
	case .Launched:
		delete(in_.launch)
		in_.launch = strings.clone(in_.dialog.installed)
	}
	if choice != saved { _ = config.set_from_string(in_.prefs, INSTALL_CHOICE_PREF, choice, .User) }
	return
}

// The Installation page (Page_Options.install): its sidebar's entry, built by setup.page.
@(private)
install_page_info :: proc(in_: ^Install) -> Page_Info {
	return {category = INSTALL_PAGE, title = i18n.later("Installation"), icon = lucide.PACKAGE, build = install_page_build, user = in_, tags = INSTALL_TAGS[:]}
}

@(private = "file")
install_page_build :: proc(user: rawptr, em: f32) {
	in_ := (^Install)(user)
	// (the modal open over the settings: the page waits for it rather than take its Dialog)
	if in_.dialog.open && !in_.dialog.in_page { return }
	// (the program's install_frame says what happened, this frame or the next)
	if ev := setup.page(&in_.dialog, in_.options, em); ev != .None {
		install_event(in_, ev)
		in_.pending = ev
	}
}
