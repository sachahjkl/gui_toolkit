package tk_update

// The Updater: what a program runs to update itself. A thread of its own checks the release (its manifest and signature, then
// check_release), downloads the program it names (tk_http) and puts it in place (place). It checks a while after the start,
// then every `every`; a check that failed is made again after `retry`. With auto_install, what a check finds is installed at
// once; else the program offers it and calls install_now. The program restarts itself when it wants to: the new program is in
// place, the running one goes on.
//
//	u := update.updater_start({product = PRODUCT, folder = "https://github.com/o/app/releases/latest/download/",
//	                           current = APP_VERSION, exe = process.executable_path(), news = on_news, user = app})
//	update.set_auto(u, check = true, install = true)
//	...   // on_news (the updater's thread) posts to the interface's thread, which reads update.status(u)
//	update.updater_stop(u)
//
// A copy installed by a package manager (from the Nix store) is never updated: its phase is Managed, and nothing is asked.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import http "../http"
import i18n "../i18n"

CHECK_EVERY :: 24 * time.Hour
RETRY_AFTER :: time.Hour
// After the start: the session's network may come later than the program, and the start has better to do.
FIRST_CHECK :: 20 * time.Second
// A manifest and its signature are small; the program is bounded by the manifest.
MANIFEST_TIMEOUT :: 30 * time.Second

Updater_Options :: struct {
	product:     Product,
	folder:      string,          // the URL of the folder of the release's files, "/" at the end: its manifest, .sig and program
	channel:     string,          // "": a product without channels
	current:     string,          // the running version (X.Y.Z)
	exe:         string,          // the running program, the one replaced
	user_agent:  string,          // "": tk_http's
	every:       time.Duration,   // between two checks (0: CHECK_EVERY)
	retry:       time.Duration,   // after a check that failed (0: RETRY_AFTER)
	first_check: time.Duration,   // after the start (0: FIRST_CHECK)
	// Called on the updater's thread when status changed (never after updater_stop returned): the program posts to its
	// interface's thread (ui.post), which reads status. nil: the program reads status when it likes.
	news:        proc(user: rawptr),
	user:        rawptr,
}

Phase :: enum {
	Idle,          // nothing on offer: the last check found nothing newer, or none was made
	Checking,
	Available,     // a newer version, signed and checked, not installed (auto_install off)
	Downloading,   // and put in place
	Installed,     // the new program is in place: it runs at the next start
	Managed,       // a package manager updates this copy: nothing is checked
}

// What the updater is at, for the program to show. Strings in the caller's temporary allocator.
Status :: struct {
	phase:   Phase,
	version: string,   // Available, Downloading, Installed: the version on offer
	result:  string,   // what the last check or install found ("" none yet): "up to date", a failure's reason...
	failed:  bool,     // that result is a failure
	asked:   bool,     // that result answers check_now or install_now: the program says it, even "up to date"
	serial:  int,      // grows at each change: a program says each result once
}

Updater :: struct {
	options:   Updater_Options,   // (its strings owned)
	mutex:     sync.Mutex,
	cond:      sync.Cond,
	phase:     Phase,
	offer:     Manifest,          // Available, Downloading (owned)
	version:   string,            // Installed (owned)
	result:    string,            // (owned)
	failed:    bool,
	asked:     bool,
	serial:    int,
	auto_check, auto_install: bool,
	want_check, want_install: bool,
	want_asked: bool,             // the check or install wanted was asked by the user
	next_check: time.Time,
	stopped:   bool,
	holders:   int,               // the program and the thread: the last one frees it
}

@(private = "file")
heap :: proc() -> runtime.Allocator { return runtime.heap_allocator() }

// Starts the updater of the running program, its thread waiting. Nothing is checked before set_auto or check_now. What an
// earlier update left beside the program is removed (remove_leftovers).
updater_start :: proc(options: Updater_Options) -> ^Updater {
	u := new(Updater, heap())
	o := options
	o.folder = strings.clone(o.folder, heap())
	o.channel = strings.clone(o.channel, heap())
	o.current = strings.clone(o.current, heap())
	o.exe = strings.clone(o.exe, heap())
	o.user_agent = strings.clone(o.user_agent, heap())
	if o.every <= 0 { o.every = CHECK_EVERY }
	if o.retry <= 0 { o.retry = RETRY_AFTER }
	if o.first_check <= 0 { o.first_check = FIRST_CHECK }
	u.options = o
	u.next_check = time.time_add(time.now(), o.first_check)
	if strings.has_prefix(o.exe, "/nix/store/") {   // (desktop.in_nix_store: Nix updates it)
		u.phase = .Managed
		u.holders = 1
		return u
	}
	remove_leftovers(o.exe)
	u.holders = 2
	// (the thread frees itself when it ends, maybe after the caller's allocator: it is the heap's, like the rest)
	context.allocator = heap()
	thread.create_and_start_with_poly_data(u, updater_run, self_cleanup = true)
	return u
}

// Stops the updater: no news after it returns. A download under way ends on its own (nothing is put in place after the stop).
updater_stop :: proc(u: ^Updater) {
	if u == nil { return }
	sync.lock(&u.mutex)
	u.stopped = true
	sync.cond_signal(&u.cond)
	updater_release(u)   // (unlocks)
}

// Whether the updater checks by itself (after the start, then every `every`), and installs what it finds.
set_auto :: proc(u: ^Updater, check, install: bool) {
	sync.guard(&u.mutex)
	u.auto_check, u.auto_install = check, install
	sync.cond_signal(&u.cond)
}

// A check now, asked by the user: its result is said even when there is nothing new. Ignored while one is under way, while a
// version is being installed or is installed.
check_now :: proc(u: ^Updater) {
	sync.guard(&u.mutex)
	if u.phase == .Managed { u.result, u.failed, u.asked = replace(u.result, i18n.tr("a package manager updates this copy")), false, true; u.serial += 1; return }
	if u.phase == .Checking || u.phase == .Downloading || u.phase == .Installed { return }
	u.want_check, u.want_asked = true, true
	sync.cond_signal(&u.cond)
}

// Installs the version on offer (Available).
install_now :: proc(u: ^Updater) {
	sync.guard(&u.mutex)
	if u.phase != .Available { return }
	u.want_install, u.want_asked = true, true
	sync.cond_signal(&u.cond)
}

status :: proc(u: ^Updater, allocator := context.temp_allocator) -> Status {
	sync.guard(&u.mutex)
	version := u.phase == .Installed ? u.version : (u.phase == .Available || u.phase == .Downloading) ? u.offer.version : ""
	return {u.phase, strings.clone(version, allocator), strings.clone(u.result, allocator), u.failed, u.asked, u.serial}
}

// The state in a sentence, for a settings line or a status bar.
status_words :: proc(st: Status, allocator := context.temp_allocator) -> string {
	switch st.phase {
	case .Managed:     return i18n.tr("A package manager updates this copy.")
	case .Checking:    return i18n.tr("Checking for a newer version…")
	case .Downloading: return fmt.aprintf(i18n.tr("Downloading version %s…"), st.version, allocator = allocator)
	case .Available:   return fmt.aprintf(i18n.tr("Version %s is available."), st.version, allocator = allocator)
	case .Installed:   return fmt.aprintf(i18n.tr("Version %s is installed: it runs at the next start."), st.version, allocator = allocator)
	case .Idle:
	}
	switch {
	case st.result == "": return i18n.tr("Not checked yet.")
	case st.failed:       return fmt.aprintf(i18n.tr("The last check failed: %s."), st.result, allocator = allocator)
	}
	return i18n.tr("Up to date.")
}

////////////////////////////////
// The thread

@(private = "file")
replace :: proc(old, new_text: string) -> string {
	delete(old, heap())
	return strings.clone(new_text, heap())
}

// (called locked; unlocks)
@(private = "file")
updater_release :: proc(u: ^Updater) {
	u.holders -= 1
	last := u.holders == 0
	sync.unlock(&u.mutex)
	if !last { return }
	o := &u.options
	delete(o.folder, heap()); delete(o.channel, heap()); delete(o.current, heap()); delete(o.exe, heap()); delete(o.user_agent, heap())
	manifest_destroy(&u.offer, heap())
	delete(u.version, heap()); delete(u.result, heap())
	free(u, heap())
}

// A change said: the program hears of it (locked: updater_stop waits for a news under way).
@(private = "file")
tell :: proc(u: ^Updater) {
	u.serial += 1
	if u.options.news != nil && !u.stopped { u.options.news(u.options.user) }
}

@(private = "file")
updater_run :: proc(u: ^Updater) {
	sync.lock(&u.mutex)
	for !u.stopped {
		install := u.want_install && u.phase == .Available
		check := u.want_check || (u.auto_check && time.diff(time.now(), u.next_check) <= 0)
		if u.phase == .Installed { check, install = false, false }
		if !install && !check {
			if u.auto_check && u.phase != .Installed {
				_ = sync.cond_wait_with_timeout(&u.cond, &u.mutex, max(time.diff(time.now(), u.next_check), time.Millisecond))
			} else {
				sync.cond_wait(&u.cond, &u.mutex)
			}
			continue
		}
		asked := u.want_asked
		u.want_check, u.want_install, u.want_asked = false, false, false
		if install {
			updater_install(u, asked)
		} else {
			updater_check(u, asked)
			if u.phase == .Available && u.auto_install && !u.stopped { updater_install(u, asked) }
		}
		free_all(context.temp_allocator)
	}
	updater_release(u)
}

// (locked; unlocked during the requests)
@(private = "file")
updater_check :: proc(u: ^Updater, asked: bool) {
	before := u.phase
	u.phase = .Checking
	tell(u)
	o := u.options
	sync.unlock(&u.mutex)
	m, why, nothing_new := fetch_release(o)
	sync.lock(&u.mutex)
	u.asked = asked
	switch {
	case why != "":
		u.result, u.failed = replace(u.result, why), true
		u.phase = before == .Available ? .Available : .Idle   // (a check that failed says nothing against what was on offer)
		u.next_check = time.time_add(time.now(), o.retry)
	case nothing_new:
		u.result, u.failed = replace(u.result, i18n.tr("up to date")), false
		manifest_destroy(&u.offer, heap())
		u.phase = .Idle
		u.next_check = time.time_add(time.now(), o.every)
	case:
		manifest_destroy(&u.offer, heap())
		u.offer = m
		u.result, u.failed = replace(u.result, fmt.tprintf(i18n.tr("version %s is available"), m.version)), false
		u.phase = .Available
		u.next_check = time.time_add(time.now(), o.every)
	}
	tell(u)
}

// (locked; unlocked during the download)
@(private = "file")
updater_install :: proc(u: ^Updater, asked: bool) {
	u.phase = .Downloading
	tell(u)
	o := u.options
	m := u.offer   // (stays u's: only this thread changes the offer)
	sync.unlock(&u.mutex)
	why := ""
	status, data, err := http.get(strings.concatenate({o.folder, m.file}, context.temp_allocator), {max_bytes = int(m.size), user_agent = o.user_agent}, heap())
	switch {
	case err != .None: why = http.error_text(err)
	case status != 200: why = fmt.tprintf(i18n.tr("the server answered %d for %s"), status, m.file)
	}
	sync.lock(&u.mutex)
	if why == "" && !u.stopped {
		if e := place(o.exe, data, m); e != .None { why = error_text(e) }
	} else if why == "" {
		why = i18n.tr("stopped")
	}
	delete(data, heap())
	u.asked = asked
	if why != "" {
		u.result, u.failed = replace(u.result, fmt.tprintf(i18n.tr("version %s was not installed: %s"), m.version, why)), true
		u.phase = .Available
	} else {
		u.version = replace(u.version, m.version)
		u.result, u.failed = replace(u.result, fmt.tprintf(i18n.tr("version %s is installed: it runs at the next start"), m.version)), false
		u.phase = .Installed
	}
	tell(u)
}

// The release's manifest and signature, checked. why: a failure; nothing_new: no newer version (or none for this system).
@(private = "file")
fetch_release :: proc(o: Updater_Options) -> (m: Manifest, why: string, nothing_new: bool) {
	name := manifest_name(PLATFORM, o.channel, context.temp_allocator)
	req := http.Request{max_bytes = MAX_MANIFEST, user_agent = o.user_agent, timeout = MANIFEST_TIMEOUT}
	status, manifest, err := http.get(strings.concatenate({o.folder, name}, context.temp_allocator), req, context.temp_allocator)
	if err != .None { return {}, http.error_text(err), false }
	if status == 404 { return {}, "", true }   // (no release for this system yet)
	if status != 200 { return {}, fmt.tprintf(i18n.tr("the server answered %d"), status), false }
	sig_req := req
	sig_req.max_bytes = MAX_SIGNATURE_TEXT
	sig_status, signature, sig_err := http.get(strings.concatenate({o.folder, name, ".sig"}, context.temp_allocator), sig_req, context.temp_allocator)
	if sig_err != .None { return {}, http.error_text(sig_err), false }
	if sig_status != 200 { return {}, i18n.tr("the update has no signature: refused"), false }
	found, e := check_release(o.product, manifest, strings.trim_space(string(signature)), PLATFORM, o.channel, o.current, "", heap())
	#partial switch e {
	case .None:      return found, "", false
	case .Not_Newer: return {}, "", true
	}
	return {}, error_text(e), false
}
