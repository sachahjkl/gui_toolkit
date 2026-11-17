package tk_prefs_page

// A program's updates, the same in every program: its Updater (gt:update) started from the program's release and the
// standard Updates set (update.base_url), the rule of update.auto (only the installed copy updates by itself: a build or a
// copy run where it was unpacked waits for Check now), each change said once, and the installed copy's manifest given the
// new version on a chore. What is left to the program is its own words (update.notice in its status line or a toast) and
// its restart:
//
//	prefs_page.updates_start(&app.updates, {product = PRODUCT, repository = "owner/app", version = APP_VERSION,
//	                         prefs = &app.prefs, install = &app.install, state = &app.main.state, window = app.main.win})
//	// each frame
//	if changed, st := prefs_page.updates_follow(&app.updates); changed {
//		host.host_settle(&app.main)
//		if words, bad := update.notice(st); words != "" { say(app, bad, words) }
//	}
//	// at the end, before the windows go
//	prefs_page.updates_stop(&app.updates)

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"
import config "../config"
import "../platform"
import setup "../setup"
import "../ui"
import update "../update"

Updates_Options :: struct {
	product:    update.Product,
	repository: string,             // "owner/name": its latest release on GitHub, unless update.base_url names another folder
	version:    string,             // the running version (X.Y.Z)
	// a product with channels (update.Channel): each one's folder, the one followed being update.channel's (nil: none)
	channels:   []update.Channel,
	prefs:      ^config.Prefs,      // update.auto, update.base_url, update.channel (the standard Updates set; nil or not registered: off)
	install:    ^Install,           // which copy runs (install_offer's reading); nil: never by itself
	state:      ^ui.State,          // the window whose chores write the installed copy's manifest (nil: not written)
	window:     ^platform.Window,   // woken at each news, for updates_follow to read it (nil: `news`)
	// instead of waking `window`: what the updater's thread calls at each news (a program with several windows wakes
	// them all). nil, and no window: the program reads at its own pace
	news:       proc(user: rawptr),
	user:       rawptr,
}

// The program's updates. Its fields are read freely (`updater` for Page_Options.updater and update_badge); updates_*
// change them.
Updates :: struct {
	updater:  ^update.Updater,      // nil: not started
	options:  Updates_Options,      // (the program's: its strings are its constants)
	folder:   string,               // owned: the folder the releases are read from
	serial:   int,                  // the updater's state last said
	mode:     update.Auto_Mode,     // the mode last given to the updater
	mode_set: bool,
	channel:  string,               // owned: the channel last given to the updater ("": none)
	manifest: string,               // owned: the version the installed copy's manifest was asked to say
}

// Starts the updater, its thread waiting: nothing is checked before updates_follow finds the copy installed and
// update.auto on, or before update.check_now. Makes no system call: the running program's path is found on the
// updater's thread.
updates_start :: proc(u: ^Updates, o: Updates_Options) {
	if u.updater != nil { return }
	u.options = o
	folder, channel := "", ""
	if o.prefs != nil { folder, channel = update_source(o.prefs) }
	if len(o.channels) == 0 { channel = "" }
	u.channel = strings.clone(channel)
	// (a product with channels and no base_url: each channel's own folder, update.Updater_Options.folder "")
	if folder != "" {
		u.folder = strings.clone(folder)
	} else if len(o.channels) == 0 {
		u.folder = update.latest_release_folder(o.repository)
	}
	news, user := o.news, o.user
	if news == nil && o.window != nil {
		// (the updater's thread: the loop wakes, and updates_follow reads the state)
		news, user = proc(user: rawptr) { platform.wake((^platform.Window)(user)) }, o.window
	}
	u.updater = update.updater_start({
		product = o.product, folder = u.folder, channels = o.channels, channel = u.channel, current = o.version,
		user_agent = fmt.tprintf("%s/%s", o.product.name, o.version), news = news, user = user,
	})
	updates_auto(u)
}

// At each turn of the loop: update.auto applied as the preference and the install say now, then whether the updater
// changed since the last call (`changed`: the program says update.notice(st) once, and its windows show the new state).
// Once a version is in place, the installed copy's manifest (Settings > Apps, the next start's setup) says it, written on
// a chore of `state`.
updates_follow :: proc(u: ^Updates) -> (changed: bool, st: update.Status) {
	if u.updater == nil { return }
	updates_auto(u)
	st = update.status(u.updater)
	if st.serial == u.serial { return }
	u.serial = st.serial
	if st.phase == .Installed && st.version != u.manifest { manifest_write(u, st.version) }
	return true, st
}

// At the end, before the windows go: no news after it.
updates_stop :: proc(u: ^Updates) {
	update.updater_stop(u.updater)   // (nil: nothing)
	delete(u.folder)
	delete(u.manifest)
	delete(u.channel)
	u^ = {}
}

// What update.auto asks of the updater now: Install for the installed copy with the preference on, else Off (Check now
// still works); and update.channel's channel, for a product with channels. Each given again only when it changes: the
// preferences are lookups, the install a field.
@(private = "file")
updates_auto :: proc(u: ^Updates) {
	o := u.options
	mode := update.Auto_Mode.Off
	wanted := o.prefs != nil && config.ref_of(o.prefs, UPDATE_AUTO_PREF) != config.NO_REF && config.bool_of(o.prefs, UPDATE_AUTO_PREF)
	if wanted && o.install != nil && o.install.known && o.install.running_it { mode = .Install }
	if !u.mode_set || mode != u.mode {
		u.mode, u.mode_set = mode, true
		update.set_auto(u.updater, mode)
	}
	// (the channel the settings choose, followed at once: the updater asks the new channel's release)
	if len(o.channels) > 0 && o.prefs != nil && config.ref_of(o.prefs, UPDATE_CHANNEL_PREF) != config.NO_REF {
		channel := config.string_of(o.prefs, UPDATE_CHANNEL_PREF)
		if channel != u.channel {
			delete(u.channel)
			u.channel = strings.clone(channel)
			update.set_channel(u.updater, channel)
		}
	}
}

@(private = "file")
Manifest_Job :: struct {
	o:       setup.Setup_Options,   // (its strings and procedures are the program's constants)
	version: string,                // owned
}

@(private = "file")
manifest_write :: proc(u: ^Updates, version: string) {
	delete(u.manifest)
	u.manifest = strings.clone(version)
	in_ := u.options.install
	if in_ == nil || u.options.state == nil { return }
	// (the heap's: the chores free it on their thread, whatever the caller's allocator is)
	j := new(Manifest_Job, runtime.heap_allocator())
	j^ = {o = in_.options, version = strings.clone(version, runtime.heap_allocator())}
	ui.task(u.options.state, proc(data: rawptr) {
		j := (^Manifest_Job)(data)
		defer manifest_job_free(j)
		if ok, why := setup.updated(j.o, j.version); !ok { log.errorf("version %s is in place, but %s", j.version, why) }
	}, nil, j, manifest_job_free)
}

@(private = "file")
manifest_job_free :: proc(data: rawptr) {
	j := (^Manifest_Job)(data)
	delete(j.version, runtime.heap_allocator())
	free(j, runtime.heap_allocator())
}
