package tk_prefs_page

// The program's installation, the same in every program: the offer at a start (gt:setup's dialog, as a modal), the
// Installation page of the settings (setup.page), the user's answer kept in the settings (install.choice), and what an
// uninstall leaves for the end of the process. A program declares what it is (setup.Setup_Options: its desktop.Identity,
// its version, its own parts) and calls:
//
//   prefs_page.install_init(&app.install, &app.prefs, setup_options())   at the start, its settings loaded
//   prefs_page.install_vendor_mark(&app.install, &renderer, VENDOR_PNG)   its renderer made: the "By" line's mark
//   prefs_page.install_offer(&app.install, &state, offer)                 its window open: reads the install on a task,
//                                                                         then follows general.menu and general.autostart
//                                                                         (install_follow) for the installed copy
//   if prefs_page.install_frame(&app.install) == .Launched { quit() }      each frame: the work that ended, the answer
//   prefs_page.install_open(&app.install)                                 --setup: the setup's view now (during a build)
//   opts.install = &app.install                                           the settings show the Installation page
//   prefs_page.install_end(&app.install)                                  at the end, before the window's State goes
//   prefs_page.install_launch(&app.install)                               last, its single instance released
//
// The command line (--install, --uninstall, --setup) is setup.command_of and setup.command_run.

import "base:runtime"
import "core:log"
import "core:strings"
import config "../config"
import desktop "../desktop"
import i18n "../i18n"
import lucide "../lucide"
import process "../process"
import "../render"
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
	// the vendor's mark in the "By" line of the modal and the page (nil: the name alone): install_vendor_mark makes it,
	// install_end frees it
	vendor_mark: Maybe(setup.Logo),
	mark_renderer: ^render.Renderer,   // the renderer that holds vendor_mark's texture
	// what the start's reading found (install_offer): the program may wait for it (its updater wants to know which copy runs)
	known:      bool,
	running_it: bool,                  // this program is the installed copy
	running:    string,                // owned: this program's executable
	reading:    bool,                  // the start's reading is out on a task
	pending:    setup.Event,           // what the page's build met: install_frame says it
	launch:     string,                // owned: the installed copy install_launch starts ("": none)
	// install_follow: the window whose tasks run it (install_offer's), where its failure is said, and its state
	// machine: idle, running, or running with another asked (the last change wins)
	state:      ^ui.State,
	announcer:  ^ui.Announcer,
	following:  bool,
	follow_again: bool,
	watch:      int,
}

// The program's declaration. Registers install.choice when the program did not (a value read from the file before
// waits for it in the registry). general.menu and general.autostart are hidden until install_follow finds this copy
// integrated, and followed from then on; `announcer` says when the desktop refuses them (nil: the log only). Called again
// with another registry (a program that reads its settings anew), it leaves the old one's watch: call it before the old
// registry is destroyed.
install_init :: proc(in_: ^Install, prefs: ^config.Prefs, o: setup.Setup_Options, announcer: ^ui.Announcer = nil) {
	// (a watch is an id in one registry: kept across registries it would name another observer of the new one, which
	// install_end would then remove, and the new registry's two settings would go unfollowed)
	if in_.watch != 0 && in_.prefs != prefs {
		if in_.prefs != nil { config.unwatch(in_.prefs, in_.watch) }
		in_.watch = 0
	}
	in_.prefs, in_.options, in_.announcer = prefs, o, announcer
	if config.ref_of(prefs, INSTALL_CHOICE_PREF) == config.NO_REF { config.register(prefs, INSTALL_DEFS[:]) }
	follow_show(in_, false)
	if in_.watch == 0 {
		in_.watch = config.watch(prefs, "general.", proc(user: rawptr, name: string, _: ^config.Prefs) {
			if name == MENU_PREF || name == AUTOSTART_PREF { install_follow((^Install)(user)) }
		}, in_)
	}
}

@(private = "file")
Follow_Job :: struct {
	in_:        ^Install,
	o:          setup.Setup_Options,
	menu:       bool,
	autostart:  bool,
	integrated: bool,     // out: this copy is the installed one
	failed:     string,   // out, owned: what the desktop said went wrong
}

// The settings general.menu and general.autostart made true for the installed copy: on a task, the install is read;
// when this copy is the installed one, its launcher in the applications menu and its start with the session are
// written as the two say, the program's other parts as the install left them. A copy that is not installed (a build,
// Nix's, which Nix integrates) never writes anything because of a setting, and the two are hidden. Called by
// install_offer's answer, by install_frame after an install or an uninstall, and on a change of either setting: a
// program calls it only to run it again for another reason. One at a time; one asked during a run runs after it.
install_follow :: proc(in_: ^Install) {
	if !desktop.supported() || in_.state == nil || in_.prefs == nil { return }
	if in_.following { in_.follow_again = true; return }
	in_.following = true
	// (the job in the heap: its work makes `failed` on the chores, and `lost` may free it there; the program's
	// allocator, a test's tracker, would see a block it never gave)
	j := new(Follow_Job, runtime.heap_allocator())
	j^ = {in_ = in_, o = in_.options, menu = config.bool_of(in_.prefs, MENU_PREF), autostart = config.bool_of(in_.prefs, AUTOSTART_PREF)}
	ui.task(in_.state, proc(data: rawptr) {
		j := (^Follow_Job)(data)
		defer free_all(context.temp_allocator)
		f := setup.facts(j.o)
		j.integrated = f.running_it && f.exe_there && !f.from_nix
		if !j.integrated { return }
		choices := make([]bool, len(j.o.choices), context.temp_allocator)
		for x, i in j.o.choices { choices[i] = x.on }
		setup.choices_from_facts(f, j.o, choices)
		o, _ := setup.options(j.o, choices)
		o.exe = f.exe
		o.start_menu, o.autostart = j.menu, j.autostart
		// (a default the system keeps itself, Windows': asking for it opens the system's page, never on a setting's change)
		o.default_documents = o.default_documents && .Default_Documents in f.parts
		if r := desktop.apply(&o); r.error != .None {
			j.failed = strings.concatenate({desktop.error_text(r.error), " ", r.detail}, runtime.heap_allocator())
		}
	}, proc(data: rawptr, _: u64) {
		j := (^Follow_Job)(data)
		defer follow_free(j)
		in_ := j.in_
		in_.following = false
		follow_show(in_, j.integrated)
		if j.failed != "" {
			log.errorf("install: the desktop's launcher cannot be changed: %s", j.failed)
			if in_.announcer != nil { ui.announce(in_.announcer, .Bad, i18n.tr("The desktop's launcher cannot be changed"), j.failed) }
		}
		if in_.follow_again {
			in_.follow_again = false
			install_follow(in_)
		}
	}, j, follow_free)
}

@(private = "file")
follow_free :: proc(data: rawptr) {
	j := (^Follow_Job)(data)
	delete(j.failed, runtime.heap_allocator())
	free(j, runtime.heap_allocator())
}

// general.menu and general.autostart shown on the settings' page only where install_follow applies them.
@(private = "file")
follow_show :: proc(in_: ^Install, on: bool) {
	names := [?]string{MENU_PREF, AUTOSTART_PREF}
	for name in names {
		if r := config.ref_of(in_.prefs, name); r != config.NO_REF { config.entry(in_.prefs, r).def.hidden = !on }
	}
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
	// (the job in the heap, as install_follow's: its work makes `running` on the chores, and `lost` may free it there)
	j := new(Offer_Job, runtime.heap_allocator())
	j^ = {in_ = in_, o = in_.options, choice = strings.clone(install_choice(in_), runtime.heap_allocator()), offer = offer}
	in_.reading = true
	in_.state = state
	ui.task(state, proc(data: rawptr) {
		j := (^Offer_Job)(data)
		f := setup.facts(j.o)
		j.running_it = f.running_it
		j.running = strings.clone(f.running, runtime.heap_allocator())
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
		// (Install's own copy, in the program's allocator, which install_end frees: the job's is the heap's)
		delete(in_.running)
		in_.running = strings.clone(j.running)
		if j.offer { install_open(in_) }
		install_follow(in_)
	}, j, offer_free)
}

@(private = "file")
offer_free :: proc(data: rawptr) {
	j := (^Offer_Job)(data)
	delete(j.choice, runtime.heap_allocator())
	delete(j.running, runtime.heap_allocator())
	free(j, runtime.heap_allocator())
}

// The vendor's mark of the "By" line in the modal and on the Installation page, from the bytes of its PNG (a program's
// #load), as a texture of `r`, the renderer of the windows they show in. Once: a second call does nothing, so a
// window that opens again calls it again freely. A view already open takes it at once. install_end frees it. False:
// the bytes are no PNG (the "By" line names the vendor alone).
install_vendor_mark :: proc(in_: ^Install, r: ^render.Renderer, png: []u8) -> bool {
	if in_.mark_renderer != nil { return true }
	mark, ok := setup.logo_make(r, png)
	if !ok { return false }
	in_.vendor_mark, in_.mark_renderer = mark, r
	if in_.dialog.open { setup.set_vendor_mark(&in_.dialog, in_.vendor_mark) }
	return true
}

// Shows the setup's view now (--setup, Settings > Apps' Uninstall), in the window being built (a task's answer runs
// in its build).
install_open :: proc(in_: ^Install) {
	if in_.dialog.open && !in_.dialog.in_page { return }
	if in_.dialog.open { _ = setup.close(&in_.dialog, .Close) }   // (the page's: the view takes it over)
	setup.open(&in_.dialog, in_.options, in_.logo, in_.vendor_mark)
}

// Each frame of the window the setup belongs to: the work that ended, the view's answer, the answer kept; what happened
// (the answer is already kept). Launched: the program ends (its window closes, its single instance goes), and
// install_launch starts the installed copy. Installed, Uninstalled: the program follows what its own settings say of the
// desktop again, if it applies them.
install_frame :: proc(in_: ^Install) -> (ev: setup.Event) {
	ev = setup.update(&in_.dialog, in_.options)
	install_event(in_, ev)
	if ev == .None { ev = in_.pending }
	in_.pending = .None
	if ev == .Installed || ev == .Uninstalled { install_follow(in_) }
	return
}

// At the end of the process, before the window's State goes: what an uninstall left because this process held it is
// deleted once it ends; the dialog's thread is waited for.
install_end :: proc(in_: ^Install) {
	if in_.watch != 0 && in_.prefs != nil { config.unwatch(in_.prefs, in_.watch) }
	in_.watch, in_.state = 0, nil
	setup.finish(&in_.dialog, in_.options)
	setup.destroy(&in_.dialog)
	if in_.mark_renderer != nil { setup.logo_destroy(in_.mark_renderer, &in_.vendor_mark) }
	in_.mark_renderer = nil
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

// The answer the offer obeys: install.choice's value for this run, whichever layer gives it (a policy, the command line,
// the user's file: config's order), "" when none.
install_choice :: proc(in_: ^Install) -> string {
	return config.string_of(in_.prefs, INSTALL_CHOICE_PREF)
}

// The answer an event leaves (`set`: there is one to keep), from the answer in force (`saved`).
//   Installed         installed
//   Kept_Standalone   standalone
//   Uninstalled       standalone: the person took the install away on purpose; offering it again at the next start
//                     would undo that
//   Dismissed         not again for this version; an earlier "standalone" or "installed" stays, unless an upgrade was
//                     declined
choice_after :: proc(ev: setup.Event, upgrade: bool, saved, version: string) -> (choice: string, set: bool) {
	#partial switch ev {
	case .Installed:                    return setup.CHOICE_INSTALLED, true
	case .Kept_Standalone, .Uninstalled: return setup.CHOICE_STANDALONE, true
	case .Dismissed:
		if upgrade || (saved != setup.CHOICE_STANDALONE && saved != setup.CHOICE_INSTALLED) { return setup.choice_dismissed(version), true }
	}
	return "", false
}

// What an event leaves: the answer in the user's layer (a higher layer for this run, the command line's, still wins:
// config keeps the user's value for the file), and the installed copy to start.
@(private)
install_event :: proc(in_: ^Install, ev: setup.Event) {
	if ev == .Launched {
		delete(in_.launch)
		in_.launch = strings.clone(in_.dialog.installed)
		return
	}
	upgrade := setup.is_upgrade(in_.dialog.facts, in_.options.version)
	if choice, set := choice_after(ev, upgrade, install_choice(in_), in_.options.version); set {
		// (set even when the value in force is the same: it may be the command line's, and the user's file must have it)
		_ = config.set_from_string(in_.prefs, INSTALL_CHOICE_PREF, choice, .User)
	}
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
	in_.dialog.vendor_mark = in_.vendor_mark
	if ev := setup.page(&in_.dialog, in_.options, em); ev != .None {
		install_event(in_, ev)
		in_.pending = ev
	}
}
