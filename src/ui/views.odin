package ui

// Views: one content, four presentations (docs/views.md). A view is a build procedure and its data, declared once by
// an id. The program opens and closes it and reads its answer; the toolkit decides where it is built and remembers the
// presentation the user chose, per id, in a gt:store file.
//
// Every ui.State has a Views: its own, made on first use, or one the program gives it (set_views: one Views shared by
// the windows of a program, kept in a file). A zero Views works: nothing is to be called before the first view.
//
//   vs := ui.state_views(&app.state)                                                 (or ui.views() in a build)
//   ui.view_register(vs, "conflict", conflict_view, {title = i18n.later("A name is taken")})
//   ui.view_open(vs, "conflict", &app.conflict)                                       during a build
//   if code, ok := ui.view_ended(vs, "conflict"); ok { ... }                          during a later build
//
// A program that keeps the memory in a file, or shares a Views between windows:
//
//   ui.views_init(&app.views, {path = views_path})    at start-up, before its first view opens (it reads the file)
//   ui.set_views(&window.state, &app.views)           each window's State
//   ui.views_destroy(&app.views)                      after the last build (a State's own Views goes with ui.destroy)
//
// The dialogs of a State are built at the end of its build (end_build), on top of the page and under the menus and the
// toasts: a program does not call anything to build them.
//
// Step 1 of the work (src/md/features/views.md, section 7.3) builds the Dialog presentation only. Panel, Internal and
// External are states of the machine already; until their builders come (steps 2 to 4), a view in one of them is built
// as a Dialog (view_built_as).

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "../font"
import i18n "../i18n"
import "../platform"
import store "../store"

// What a view is, given once when it is registered. Sizes are in ems of the owner's style.
View_Options :: struct {
	title:          string,                     // in the header (English, shown with i18n.tr; view_title changes it per frame)
	icon:           string,                     // a glyph of icon_font before the title ("": none)
	icon_font:      font.Font_Id,               // 0: the state's icon font
	home:           View_Presentation,          // .Dialog or .Panel: where re-attach brings it
	home_place:     View_Place,                 // with home .Panel
	first:          Maybe(View_Presentation),   // its first opening, before the user chose (nil: home)
	// its internal window with no rect of its own (none remembered, none given by a move) opens against this edge of
	// the program's content, MODAL_MARGIN_EM in (Right: at the top right); nil: centred over it
	float_edge:     Maybe(View_Edge),
	width_em:       f32,                        // the dialog's first width (0: DIALOG_WIDTH_EM); it grows to what is in it
	height_em:      f32,                        // 0: as tall as what is in it
	min_width_em:   f32,                        // how small the user makes it (with `resizable`)
	min_height_em:  f32,
	extent_em:      f32,                        // a panel's width or height (step 3)
	extent_frac:    f32,                        // ... as a share of its space's width or height instead (0: extent_em)
	// its side zone minimised (by its Minimise, or folded by a narrow space) keeps a column this wide and builds the
	// view in it with View.rail: its compact form (a list of marks). 0: the zone becomes the toolkit's rail of icons
	rail_em:        f32,
	tabs_always:    bool,                       // its stack's tab strip shows even when it is alone there (a terminal)
	// the "+" after its stack's tabs, the band's menu and the palette: the program opens a new instance of this kind
	// (view_open with a new name); `data` is the shown view's. Every instance of this kind opened during the call joins
	// that stack, its tab last and shown. nil: no "+"
	new_tab:        proc(data: rawptr),
	new_tab_label:  string,                     // the menu's and the palette's words, in English as `title` ("New terminal",
	                                            // i18n.later: translated when shown); "": "New tab"
	resizable:      bool,                       // the dialog has grips; its size is remembered
	top:            Maybe(f32),                 // the dialog's top at this fraction of the window (a palette); nil: centred
	quick:          bool,                       // summoned by a key and left as fast (a palette): its dialog fades in faster
	no_header:      bool,                       // the build draws the top itself (a palette's search band): no header strip
	// drawn first in the view's box, under its header and its body (a blur of the window behind a dialog)
	backdrop:       proc(v: ^View, data: rawptr),
	under_children: bool,                       // its external window gets a native child window (step 4)
	moved:          proc(data: rawptr, win: ^platform.Window),   // it is now built in `win` (step 4); nil: none
}

// The handle a build procedure gets. The program reads it during the build; it does not keep it.
View :: struct {
	id, instance: string,
	presentation: View_Presentation,
	place:        View_Place,   // with .Panel
	shown:        bool,         // false: this build is unseen (it is measured before it shows)
	// built in its side zone minimised, View_Options.rail_em wide: the view builds its compact form (views.md, Minimise)
	rail:         bool,
	record:       ^View_Record,
}

// The build procedure as the registry keeps it. It builds the body only: the header is the toolkit's.
View_Build :: #type proc(v: ^View, data: rawptr)

// Said during the view's build: what it shows waits for an answer (a source's, a worker's). A dialog opening stays unseen,
// built at each frame, until a build no longer says it, for MODAL_READY_WAIT_MS (100 ms) at most from its opening; then it
// shows what it holds. Once shown, it is not hidden again; another presentation shows as it would (views.md 3.4).
view_not_ready :: proc(v: ^View) {
	if v.record == nil { return }
	#partial switch v.presentation {
	case .Dialog:   modal_not_ready(v.record.panel)
	case .Internal: if !v.shown { v.record.inot_ready = true }   // (view_settle holds its unseen builds, as a dialog's)
	}
}

// Where a refit of an internal window is (view_refit).
@(private)
Internal_Refit :: enum u8 { None, Asked, Measured }

// Said during the view's build: what is in it changed size, its content came late (a plugin's first list, an answer of a
// worker). An internal window the person did not resize takes the height of what is in it again: its next build is
// as tall as what is in it, and the one after keeps that height (within the window). A dialog as tall as what is in it
// follows it already, a panel and a window of the system keep their size. Cheap: one layout at the content's height.
view_refit :: proc(v: ^View) {
	r := v.record
	if r == nil || v.presentation != .Internal || r.isized || r.irefit != .None { return }
	r.irefit = .Asked
	gs().anim_busy = true   // (the next build measures it)
}

// The words of the views' header and menus (a word left empty: view_default_labels', in the language in use). The
// program gives its source words (English, i18n.later): they are translated when shown, at each build.
View_Labels :: struct {
	detach, close, reattach: string,   // detach: the Detach icon's name; reattach: back to its home
	close_view:              string,   // an external window's Close button (its system close re-attaches)
	window, floating:        string,   // "Detach into a window" (External), "Open as a floating window" (Internal)
	dock_left, dock_right, dock_bottom: string,
	// a stack's strip: its right end (minimise, maximise, restore either, close every view of the stack), its "+";
	// maximise and restore are a resizable dialog's header button too
	minimize, maximize, restore, close_stack, new_tab: string,
}

view_default_labels :: proc() -> View_Labels {
	return {
		detach = i18n.tr("Detach"), close = i18n.tr("Close"), reattach = i18n.tr("Re-attach"), close_view = i18n.tr("Close view"),
		window = i18n.tr("Detach into a window"), floating = i18n.tr("Open as a floating window"),
		dock_left = i18n.tr("Dock left"), dock_right = i18n.tr("Dock right"), dock_bottom = i18n.tr("Dock bottom"),
		minimize = i18n.tr("Minimise the panel"), maximize = i18n.tr("Maximise"), restore = i18n.tr("Restore"),
		close_stack = i18n.tr("Close the panel"), new_tab = i18n.tr("New tab"),
	}
}

Views_Options :: struct {
	path:   string,        // the memory file, in the program's state folder ("": memory only, a test's)
	labels: View_Labels,   // zero: view_default_labels()
}

// The views of a program: what is registered, what is open, what is remembered. A State owns one (state_views), or
// several windows share the program's (set_views). Its zero value is ready: memory only, the allocator of its first use.
Views :: struct {
	kinds:     map[string]^View_Kind,
	records:   [dynamic]^View_Record,   // open, or holding an answer not taken; in opening order (the last is on top)
	states:    [dynamic]^State,         // the States that build its views (each lists it in State.views_attached)
	building:  int,                     // views of it are being built (views_build): the records stay where they are
	z_next:    u64,                     // the last stamp of an internal window brought to the front (View_Record.z)
	spaces:    map[string]^View_Space,  // the dock spaces, by name ("": the frame's; views_panels.odin)
	dock_next: u64,                     // the last stamp of a view docked (View_Record.dock_order)
	version:   u64,                     // changes when a view opens, closes or moves (views_version)
	windows:   View_Windows,            // the backend of the external windows (views_set_windows; none: they are refused)
	// the program's end of each build of a view's window (views_set_window_end): its overlays there
	window_end:      View_Window_End,
	window_end_user: rawptr,
	memory:    store.Store,
	labels:    View_Labels,
	// go to (acts.odin): the hash of the act name it waits for in its windows' frames (0: none), and the builds left
	act_want:        u64,
	act_want_builds: int,
	allocator: runtime.Allocator,
}

// What view_register got.
@(private)
View_Kind :: struct {
	id:    string,   // owned
	build: View_Build,
	type:  typeid,
	o:     View_Options,   // its strings owned
	opened: bool,          // opened in this run (views_destroy writes its line, view_restore)
	// its "+" (view_new_tab): the stack the next instances opened join, how many are still awaited, until when (the
	// owner's clock, ms)
	tab_place:  View_Place,
	tab_wanted: int,
	tab_until:  f64,
	// a ready-made view of the toolkit's whose answer is the toolkit's (the file browser: no program polls view_ended):
	// called when it ends by its own build or by the person (End, User_Close), its answer taken
	on_end: proc(data: rawptr, code: int),
}

// One instance of a view: open, or closed with an answer not taken yet.
@(private)
View_Record :: struct {
	kind:       ^View_Kind,
	instance:   string,      // owned
	data:       rawptr,
	machine:    View_Machine,
	owner:      ^State,      // the window it belongs to (nil: its owner window went)
	modal_name: string,      // owned: the id of its dialog
	flag:       bool,        // the dialog's `open`: Escape, the scrim and the close cross set it false
	ending:     Maybe(int),  // view_end in this build
	size:       Vec2,        // the dialog's size in ems ({}: its first size)
	size_kept:  Vec2,        // the size the memory has
	asked:      Vec2,        // view_size's for this opening, in ems (an axis of 0: the kind's)
	// its dialog fills the window (view_maximise, the header's button): this opening's only, never the memory's, and
	// off once it leaves the Dialog presentation (src/md/features/views.md, section 2.9)
	maximised:  bool,
	title:      string,      // owned: view_title's (or a ready-made view's), "": the kind's
	icon:       string,      // a ready-made view's icon for this opening (Lucide's), or view_icon's ("": the kind's)
	icon_own:   string,      // owned: view_icon's
	icon_font:  font.Font_Id,   // view_icon's font (0: the kind's, else the State's)
	icon_set:   bool,        // the icon is view_icon's (not a ready-made view's Lucide one)
	tools:      Key,         // the header's box of the program's tools, in this build
	header:     Key,         // the header strip, in this build (view_room)
	panel:      Key,         // the dialog's panel, or the internal window's frame (view_room)
	strip_tools: Key,        // as a panel shown in its stack's strip: the strip's slot of its tools, in this build (0: none)
	hover_strip: bool,       // a lone panel: its stack's strip shown on the hover of its top edge (view_hover_strip)
	// the build that last placed its zone's fold button (view_fold_button): its strip, built before its body, reads the
	// last one and leaves its Minimise out
	fold_built: u64,
	// the internal window: its frame, its rect (window px; a height of 0: as tall as what is in it, until it settles),
	// the rect the memory has, its unseen layouts (view_settle), its place among the internal windows, the focus to
	// give back when it closes and whether the focus goes into it at its next build, the press of a dialog's header that
	// goes on in its header (a drag that detached it)
	iframe:     Key,
	irect:      Rect,
	irect_kept: Rect,
	ifit:       bool,        // it opened with no rect of its own: its unseen builds widen it to what is in it, centred
	iarea:      Rect,        // ... over this: the program's content when it opened (window px; view_content_area)
	inatural:   f32,         // what is in it needs this width, on one line (window px, its last build): its least width
	imeasures:  int,
	ilayout:    u64,
	// a content that comes late (views.md 3.4): its last build said view_not_ready, since when it is measured unseen
	// (build_now_ms; 0: shown), a refit asked (view_refit: its next build is as tall as what is in it, then that height is
	// its own), and whether the person resized it (a refit leaves the person's height)
	inot_ready: bool,
	iopen_ms:   f64,
	irefit:     Internal_Refit,
	isized:     bool,
	z:          u64,
	focus_back: Key,
	focus_in:   bool,
	hand_from:  Key,
	// a drag of the dialog's header: where the dialog was when its press began (the window moves from there), and its
	// height (an Escape during the drag shows the dialog back there at once)
	hand_origin: Vec2,
	dialog_rect: Rect,
	dialog_back: bool,   // that Escape: the dialog's next build shows it at once, at `dialog_rect`
	// what a ready-made view owns for this opening (its options cloned), freed with the record
	owned:      rawptr,
	owned_free: proc(p: rawptr),
	allocator:  runtime.Allocator,   // the Views': what its strings are made with
	vs:            ^Views,   // the Views it is of (view_drag_handle)
	settled_build: u64,      // the build that settled it (views_settle_all: once per build)
	dock_order:    u64,      // its place among the tabs of its zone (the last docked shown first when none is chosen)
	// the box its body is built in, per presentation, as the last build that built it there made it (state_carry)
	roots:         [View_Presentation]Key,
	announce:      bool,     // no window could open: the owner's next build says so (a toast)
	// its external window (views_external.odin): what the backend gave, what the next step does with it
	w_state:       ^State,
	w_win:         ^platform.Window,
	w_handle:      rawptr,
	w_want:        bool,      // a window is wanted and not open yet
	w_hidden:      bool,      // its owner hid: the window is off the screen until the owner shows (views_windows_follow)
	w_close:       bool,      // the window goes at the next step
	w_shown_build: u64,       // the window State's build when it was shown (0: not shown yet)
	w_measures:    int,       // its unseen layouts
	w_layout:      u64,
	w_at:          Maybe([2]int),   // where it opens on the screen (a drop outside the owner), physical pixels
	w_move_to:     Maybe([2]int),   // where the next step moves it (a drag of its header)
	w_title:       string,    // owned: the title the window has
	w_drag:        View_Window_Drag,
	// what was typed after its opening in a window of its own, before the window showed (views_hold_input, view_input_arrive)
	keys_pending:  bool,
	held_typed:    [dynamic]rune,
	held_keys:     [dynamic]platform.Event,
	// the builds that built it this frame, as an internal window, as a panel (each presentation once per build)
	ibuilt:        u64,
	pbuilt:        u64,
}

// Optional: the memory file and the words of a Views the program keeps (a zero Views is memory only). Call it at
// start-up, before its first view opens: it reads the file on the calling thread.
views_init :: proc(vs: ^Views, o: Views_Options, allocator := context.allocator) {
	assert(len(vs.kinds) == 0 && len(vs.records) == 0, "views_init: before its first view")
	vs.allocator = allocator
	vs.labels = o.labels
	store.open(&vs.memory, o.path, allocator = allocator)
}

// (a zero Views takes the allocator of its first use)
@(private)
views_ready :: proc(vs: ^Views) {
	if vs.allocator.procedure == nil { vs.allocator = context.allocator }
}

// The Views of `s`: the one set_views gave it, else its own (made at its first use, gone with ui.destroy).
state_views :: proc(s: ^State) -> ^Views {
	if s.views == nil { s.views = &s.own_views }
	return s.views
}

// The Views of the State in use (the one being built, else the last one built or selected).
views :: proc() -> ^Views { return state_views(gs()) }

// `s` builds its views from `vs` (the program's, shared by its windows), not from one of its own. Call it before the
// first view of `s` opens.
set_views :: proc(s: ^State, vs: ^Views) { s.views = vs }

// Closes every view with no answer, writes which ones were open (view_was_open), flushes the memory and frees
// everything. Call it after the last build of its windows. A State's own Views is destroyed by ui.destroy.
views_destroy :: proc(vs: ^Views) {
	views_ready(vs)
	context.allocator = vs.allocator
	for id, k in vs.kinds {
		was := false
		for r in vs.records {
			if r.kind != k { continue }
			_, fx := view_step(r.machine, {kind = .Quit})
			if .Was_Open in fx { was = true }
		}
		m := views_memory_of(vs, id)
		// (a view opened in this run has a line from now on, even closed: view_restore's first start is over for it)
		_, has_line := store.get(&vs.memory, id)
		if m.open != was || (k.opened && !has_line) {
			m.open = was
			views_memory_write(vs, id, m)
		}
		views_instances_quit(vs, id, k)
	}
	// (their windows go first, while each window's State and this Views still know each other)
	for r in vs.records { view_window_close(vs, r, false) }
	for s in vs.states {
		for x, i in s.views_attached {
			if x == vs { unordered_remove(&s.views_attached, i); break }
		}
		if s.views == vs && vs != &s.own_views { s.views = nil }
	}
	delete(vs.states)
	for r in vs.records { view_record_free(r) }
	delete(vs.records)
	for _, k in vs.kinds { view_kind_free(k) }
	delete(vs.kinds)
	for _, sp in vs.spaces { view_space_free(sp) }
	delete(vs.spaces)
	store.close(&vs.memory)
	vs^ = {}
}

// The key of an instance's own line: `<id>/<instance>` (the id's own line: "").
@(private)
view_instance_key :: proc(id, instance: string) -> string {
	return instance == "" ? id : fmt.tprintf("%s/%s", id, instance)
}

// At the quit: a line per instance of `id` open now (open=1, its presentation and its place), and the lines of the
// instances not open go: the memory holds the instances to reopen, not every one ever opened.
@(private = "file")
views_instances_quit :: proc(vs: ^Views, id: string, k: ^View_Kind) {
	open := make(map[string]bool, 8, context.temp_allocator)
	for r in vs.records {
		if r.kind != k || r.instance == "" { continue }
		_, fx := view_step(r.machine, {kind = .Quit})
		if .Was_Open not_in fx { continue }
		open[r.instance] = true
		key := view_instance_key(id, r.instance)
		m := views_memory_of(vs, key)
		m.open, m.as = true, r.machine.as
		if r.machine.as == .Panel {
			d := m.dock.? or_else View_Dock_Memory{extent_em = k.o.extent_em}
			d.place = r.machine.place
			m.dock = d
		}
		views_memory_write(vs, key, m)
	}
	prefix := fmt.tprintf("%s/", id)
	for key in store.keys(&vs.memory) {
		if strings.has_prefix(key, prefix) && !(key[len(prefix):] in open) { store.remove(&vs.memory, key) }
	}
}

// The instances of `id` open at the last quit (their names, in `allocator`), each to be opened again by the program
// with its own data (view_open with that instance): each opens where it was. Read at start-up, before they open.
view_restored_instances :: proc(vs: ^Views, id: string, allocator := context.allocator) -> []string {
	views_ready(vs)
	out := make([dynamic]string, 0, 4, allocator)
	prefix := fmt.tprintf("%s/", id)
	for key in store.keys(&vs.memory) {
		if !strings.has_prefix(key, prefix) || len(key) == len(prefix) { continue }
		if !views_memory_of(vs, key).open { continue }
		append(&out, strings.clone(key[len(prefix):], allocator))
	}
	return out[:]
}

// Declares a view: `build` is a `proc(v: ^ui.View, data: ^T)`. Call it once per id, at start-up. The data's type is
// checked at each view_open.
view_register :: proc(vs: ^Views, id: string, build: $B, o: View_Options) where intrinsics.type_is_proc(B) && intrinsics.type_proc_parameter_count(B) == 2 && intrinsics.type_proc_return_count(B) == 0 {
	#assert(intrinsics.type_proc_parameter_type(B, 0) == ^View, "view_register: the build's first parameter is a ^ui.View")
	P :: intrinsics.type_proc_parameter_type(B, 1)
	#assert(intrinsics.type_is_pointer(P), "view_register: the build's data is a pointer")
	view_register_raw(vs, id, transmute(View_Build)build, typeid_of(intrinsics.type_elem_type(P)), o)
}

@(private)
view_register_raw :: proc(vs: ^Views, id: string, build: View_Build, type: typeid, o: View_Options) {
	views_ready(vs)
	context.allocator = vs.allocator
	assert(id not_in vs.kinds, "view_register: an id registered twice")
	assert(o.home == .Dialog || o.home == .Panel, "view_register: the home is a Dialog or a Panel")
	k := new(View_Kind)
	k.id, k.build, k.type, k.o = strings.clone(id), build, type, o
	// (its words are the program's source words, kept as given and translated when shown: a language changed during the
	// session shows at the next build)
	k.o.title, k.o.icon, k.o.home_place.space = strings.clone(o.title), strings.clone(o.icon), strings.clone(o.home_place.space)
	k.o.new_tab_label = strings.clone(o.new_tab_label)
	vs.kinds[k.id] = k
}

// Whether `id` is registered.
view_registered :: proc(vs: ^Views, id: string) -> bool { return id in vs.kinds }

// Opens the view. One already open comes forward (a dialog goes on top). It opens in its last presentation (the
// memory), else `first`, else its home. `data` must stay valid until the view is closed: the program owns it. The
// owner is the State being built; outside a build, `owner` names it. An answer not taken from a former opening is
// dropped.
view_open :: proc(vs: ^Views, id: string, data: ^$T, instance := "", owner: ^State = nil) {
	_ = view_open_raw(vs, id, rawptr(data), typeid_of(T), instance, owner)
}

@(private)
view_open_raw :: proc(vs: ^Views, id: string, data: rawptr, type: typeid, instance: string, owner: ^State) -> ^View_Record {
	views_ready(vs)
	context.allocator = vs.allocator
	k, known := vs.kinds[id]
	assert(known, "view_open: the id is not registered (view_register)")
	assert(k.type == type, "view_open: the data is not of the type view_register got")
	k.opened = true
	// (the State being built, else the one in use: the last built or selected, as ui.init selects it)
	who := owner != nil ? owner : (build_of != nil ? build_of : current)
	assert(who != nil, "view_open: no State in use: give its owner")
	r := view_record_find(vs, id, instance)
	if r == nil {
		r = new(View_Record)
		r.kind, r.instance, r.allocator, r.vs = k, strings.clone(instance), vs.allocator, vs
		r.machine = {home = k.o.home, home_place = k.o.home_place}
		r.modal_name = instance == "" ? fmt.aprintf("view_%s", id) : fmt.aprintf("view_%s/%s", id, instance)
		append(&vs.records, r)
	}
	r.data = data
	if r.machine.state == .Closed {
		r.owner = who
		views_attach_state(vs, who)
		view_record_reset(r)
		m := views_memory_of(vs, id)
		// (an instance's own line, when it has one: where that instance was; the sizes stay the id's)
		seen := m
		if instance != "" {
			if _, has := store.get(&vs.memory, view_instance_key(id, instance)); has { seen = views_memory_of(vs, view_instance_key(id, instance)) }
		}
		as := seen.as.? or_else (k.o.first.? or_else k.o.home)
		place := k.o.home_place
		if d, ok := seen.dock.?; ok {
			// (the memory's text is temporary: a space is kept by a name owned elsewhere, the kind's or a space's; a
			// space never built in this run is the frame's)
			place.edge, place.stack = d.place.edge, d.place.stack
			place.space = ""
			if d.place.space == k.o.home_place.space {
				place.space = k.o.home_place.space
			} else if sp, known_space := vs.spaces[d.place.space]; known_space {
				place.space = sp.name
			}
		}
		r.size, r.size_kept = m.dialog, m.dialog
		// (a "+" of its kind waits for it: it joins that stack, its tab last and shown; at once or frames later, a shell
		// the program asked a server for)
		joined := view_new_tab_take(vs, k, r, clock_ms(who))
		if joined { as, place = .Panel, k.tab_place }
		view_apply(vs, r, {kind = .Open, as = as, place = place})
		if joined { view_space_activate(vs, r) }
	} else {
		view_apply(vs, r, {kind = .Open})
	}
	return r
}

// Closes it now, in whatever presentation. Its build is not called again. No answer is kept.
view_close :: proc(vs: ^Views, id: string, instance := "") {
	r := view_record_find(vs, id, instance)
	if r == nil { return }
	view_apply(vs, r, {kind = .Program_Close})
	r.machine.answer = nil
	views_sweep(vs)
}

view_is_open :: proc(vs: ^Views, id: string, instance := "") -> bool {
	r := view_record_find(vs, id, instance)
	return r != nil && r.machine.state != .Closed
}

// Whether the keyboard focus is in this view, in whatever presentation: on a box of its body (or its header) in the
// State it is shown in, and, in a window of its own, that window is the active one. A program's command keys that a
// view's own keys would conflict with ask it (or views_focus) rather than guess from where the focus is not.
view_has_focus :: proc(vs: ^Views, id: string, instance := "") -> bool {
	r := view_record_find(vs, id, instance)
	return r != nil && view_record_has_focus(r)
}

// The view that has the keyboard focus (see view_has_focus), if one has. Its strings are the view's: valid while it is
// open.
views_focus :: proc(vs: ^Views) -> (id, instance: string, ok: bool) {
	for r in vs.records {
		if view_record_has_focus(r) { return r.kind.id, r.instance, true }
	}
	return "", "", false
}

@(private = "file")
view_record_has_focus :: proc(r: ^View_Record) -> bool {
	m := r.machine
	if m.state == .Closed || m.state == .Opening { return false }
	p := view_shown_in(m)
	if m.state == .Dragged { p = m.as }   // (dragged: the floating window it is during the drag)
	st := view_state_of(r, p)
	root := r.roots[p]
	if st == nil || root == 0 { return false }
	if p == .External && (st.window == nil || !st.window.active) { return false }
	return view_focus_inside(st, root)
}

// At start-up: opens the view when it was open as the program last quit; at the very first start (the memory has no
// line for it yet) when `first_start_open`. A view the user closed stays closed at the next starts. True: it opened.
view_restore :: proc(vs: ^Views, id: string, data: ^$T, first_start_open := false, instance := "", owner: ^State = nil) -> bool {
	views_ready(vs)
	_, known := store.get(&vs.memory, id)
	if known ? !views_memory_of(vs, id).open : !first_start_open { return false }
	view_open(vs, id, data, instance, owner)
	return true
}

// Whether it was open when the program last quit (a side pane, a tool window): the program opens it again.
view_was_open :: proc(vs: ^Views, id: string, instance := "") -> bool {
	return views_memory_of(vs, view_instance_key(id, instance)).open
}

// The box that holds the whole view in window `s`, as its last build made it: an internal window's frame, a dialog's
// panel, a panel's stack (its strip with it). 0: it is not open, or shown in another window (its own).
@(private)
view_box_in :: proc(vs: ^Views, id: string, s: ^State, instance := "") -> Key {
	r := view_record_find(vs, id, instance)
	if r == nil || r.machine.state == .Closed { return 0 }
	p := view_shown_in(r.machine)
	if r.machine.state == .Dragged { p = r.machine.as }   // (dragged: the floating window it is during the drag)
	if view_state_of(r, p) != s { return 0 }
	switch p {
	case .Internal: return r.iframe
	case .Dialog:   return r.panel
	case .Panel:
		body := s.boxes[r.roots[.Panel]] or_else nil
		if body == nil { return 0 }
		return body.parent != nil ? body.parent.key : body.key
	case .External: return 0
	}
	return 0
}

// The presentation it has now (Closed: its last one, or its home).
view_presentation :: proc(vs: ^Views, id: string, instance := "") -> View_Presentation {
	if r := view_record_find(vs, id, instance); r != nil { return r.machine.as }
	k, known := vs.kinds[id]
	if !known { return .Dialog }
	m := views_memory_of(vs, id)
	return m.as.? or_else (k.o.first.? or_else k.o.home)
}

// The size the user gave its dialog, in ems ({}: none: its first size), as it is now while it is open, else as the
// memory has it.
view_dialog_size :: proc(vs: ^Views, id: string, instance := "") -> Vec2 {
	if r := view_record_find(vs, id, instance); r != nil && r.machine.state != .Closed { return r.size }
	return views_memory_of(vs, id).dialog
}

// Whether its dialog fills the window now (the header's Maximise, a double click on the header, view_maximise).
view_maximised :: proc(vs: ^Views, id: string, instance := "") -> bool {
	r := view_record_find(vs, id, instance)
	return r != nil && r.machine.state != .Closed && r.maximised
}

// Its dialog fills the window (`on`), or goes back to the size it had. For this opening only: call it after view_open
// to open a viewer maximised. Nothing while it is not open or not shown as a dialog; the size the user gave it (the
// memory's) is not changed.
view_maximise :: proc(vs: ^Views, id: string, on: bool, instance := "") {
	r := view_record_find(vs, id, instance)
	if r == nil || r.machine.state == .Closed { return }
	view_maximise_record(r, on)
}

@(private)
view_maximise_record :: proc(r: ^View_Record, on: bool) {
	if view_shown_in(r.machine) != .Dialog || r.maximised == on { return }
	r.maximised = on
	if r.owner != nil { r.owner.anim_busy = true }   // (the next build lays it out at its new size)
}

// Moves it to another presentation (what the header's icons and the menus do). The choice is remembered.
view_present :: proc(vs: ^Views, id: string, p: View_Presentation, place := View_Place{}, instance := "") {
	if r := view_record_find(vs, id, instance); r != nil { view_apply(vs, r, {kind = .Present, as = p, place = place}) }
}

// Back to its home presentation and place. The view stays open.
view_reattach :: proc(vs: ^Views, id: string, instance := "") {
	if r := view_record_find(vs, id, instance); r != nil { view_apply(vs, r, {kind = .Reattach}) }
}

// The answer of a view that ended, taken once: ok is false until it ended, and after it was taken. VIEW_CANCELLED: the
// user closed it (Escape, the close cross, a press outside), or its owner window went.
view_ended :: proc(vs: ^Views, id: string, instance := "") -> (code: int, ok: bool) {
	r := view_record_find(vs, id, instance)
	if r == nil || r.machine.state != .Closed { return 0, false }
	code, ok = r.machine.answer.?
	r.machine.answer = nil
	views_sweep(vs)
	return
}

// Inside a build: ends the view with this answer. It is not built again, in this frame or after it.
view_end :: proc(v: ^View, code: int) {
	v.record.ending = code
	v.record.flag = false   // (its dialog leaves this build's dialogs: the focus goes back at once)
}

// Inside a build: an icon for this opening (the kind's View_Options.icon is the default: one id, a different icon per
// opening, as view_title gives a title). `icon_font` 0: the kind's icon font, else the State's. Shown from the next build.
view_icon :: proc(v: ^View, icon: string, icon_font: font.Font_Id = 0) {
	r := v.record
	if r.icon_set && r.icon == icon && r.icon_font == icon_font { return }
	delete(r.icon_own, r.allocator)
	r.icon_own = strings.clone(icon, r.allocator)
	r.icon, r.icon_font, r.icon_set = r.icon_own, icon_font, true
	if r.vs != nil { r.vs.version += 1 }
	gs().anim_busy = true
}

// Inside a build: the size of its dialog for this opening, in ems (an axis of 0: the kind's width_em or height_em), as
// view_title gives a title: a dialog that hugs what it shows (a picture's viewer). It wins over the size the user gave
// the id's dialog before (the memory's); a resize of this opening by the user wins over it, and is remembered. A
// non-resizable dialog is that wide even past DIALOG_MAX_WIDTH_EM (the window's edge holds it). Shown from the next
// build, which comes at once (a dialog that opens is measured unseen: its first frame drawn has it).
view_size :: proc(v: ^View, width_em, height_em: f32) {
	r := v.record
	asked := Vec2{max(width_em, 0), max(height_em, 0)}
	if r.asked == asked { return }
	r.asked = asked
	// (the remembered size gives way for this opening; size_kept with it: nothing is written until the user resizes)
	if r.kind.o.resizable { r.size, r.size_kept = {}, {} }
	// (a dialog not shown yet was laid out at the old size in this build: unseen, the next one at this size is the first
	// drawn; views.md 3.4)
	if v.presentation == .Dialog && !v.shown { modal_not_ready(r.panel) }
	gs().anim_busy = true
}

// Inside a build: a title for this frame (a process's name). Temporary memory is enough. The header shows it from the
// next build, which comes at once (a dialog is measured unseen before it shows: its first frame drawn has it).
view_title :: proc(v: ^View, title: string) {
	r := v.record
	if r.title == title { return }
	context.allocator = r.allocator
	delete(r.title)
	r.title = strings.clone(title)
	if r.vs != nil { r.vs.version += 1 }   // (the palette's commands say the title: views_commands_update)
	gs().anim_busy = true
}

// Inside a build: the room of the body in this presentation, from the last layout (a viewer sizes its picture by it).
// Before a first layout: the window's size.
view_room :: proc(v: ^View) -> Vec2 {
	s := gs()
	panel := s.boxes[v.record.panel] or_else nil
	if panel == nil || panel.last_build + 1 < s.build_index { return s.window_size }
	room := panel.rect.max - panel.rect.min
	if head := s.boxes[v.record.header] or_else nil; head != nil { room.y -= head.rect.max.y - head.rect.min.y }
	inset := border_inset(panel)
	return {max(room.x - 2 * inset, 0), max(room.y - 2 * inset, 0)}
}

// Inside a build: `if ui.view_header_tools(v) { ... }` builds controls in the header, after the title (a panel: in its
// stack's strip, after the moves, when the strip shows). Its box is made at the first call of a build: a header whose
// body asks for no tools has none. False in a presentation with no header (the block is skipped).
@(require_results, deferred_none = view_header_tools_end)
view_header_tools :: proc(v: ^View) -> bool {
	r := v.record
	// (a panel has no header: its stack's strip, when it shows one, has the slot)
	slot := v.presentation == .Panel ? r.strip_tools : r.header
	head := box_from_key(slot)
	if head == nil || slot == 0 {
		push_parent(parent_box())
		return false
	}
	if r.tools == 0 {
		push_parent(head)
		next({width = children_sum(), height = children_sum(), axis = .X, cross = .Center})
		r.tools = build_box({}, "###view_tools").key
		pop_parent()
	}
	push_parent(box_from_key(r.tools))
	return true
}

@(private)
view_header_tools_end :: proc() { pop_parent() }

// Whether a view of `vs` shown as a dialog holds the keys of the State being built: a program's own key handling
// waits for it.
views_hold_keys :: proc(vs: ^Views) -> bool {
	s := gs()
	for r in vs.records {
		if r.owner == s && r.machine.state != .Closed && view_built_as(r.machine.as) == .Dialog { return true }
	}
	return false
}

////////////////////////////////
// The registry

// The presentation a view is built in: each is its own (an External window with no backend is refused when it is asked
// for: views_windows_step).
@(private)
view_built_as :: proc(p: View_Presentation) -> View_Presentation { return p }

@(private)
view_record_find :: proc(vs: ^Views, id, instance: string) -> ^View_Record {
	for r in vs.records {
		if r.kind.id == id && r.instance == instance { return r }
	}
	return nil
}

// What an opening starts from: no answer pending, no title or icon of a former opening, no data of a ready-made view.
@(private = "file")
view_record_reset :: proc(r: ^View_Record) {
	r.ending = nil
	r.imeasures, r.ilayout, r.focus_in, r.hand_from, r.focus_back = 0, 0, false, 0, 0
	delete(r.title)
	r.title, r.icon = "", ""
	delete(r.icon_own, r.allocator)
	r.icon_own, r.icon_font, r.icon_set = "", 0, false
	r.asked = {}
	r.maximised = false
	if r.owned != nil && r.owned_free != nil { r.owned_free(r.owned) }
	r.owned, r.owned_free = nil, nil
}

@(private = "file")
view_record_free :: proc(r: ^View_Record) {
	view_record_reset(r)
	delete(r.instance)
	delete(r.modal_name)
	delete(r.w_title)
	delete(r.held_typed)
	delete(r.held_keys)
	free(r)
}

@(private = "file")
view_kind_free :: proc(k: ^View_Kind) {
	delete(k.id)
	delete(k.o.title)
	delete(k.o.icon)
	delete(k.o.home_place.space)
	delete(k.o.new_tab_label)
	free(k)
}

// The records closed with no answer go. Not while views are built: a build that closes a view (its own, another) must
// not free a record that is being built or move the ones after it. Not while its window is open: the next step closes
// it through the record (its handle), then sweeps (views.md, section 4.1, decision 16).
@(private)
views_sweep :: proc(vs: ^Views) {
	if vs.building > 0 { return }
	context.allocator = vs.allocator
	n := 0
	for r in vs.records {
		if r.machine.state == .Closed && r.machine.answer == nil && r.w_state == nil {
			view_record_free(r)
			continue
		}
		vs.records[n] = r
		n += 1
	}
	resize(&vs.records, n)
}

// Steps the machine of `r` and applies what it says.
@(private)
view_apply :: proc(vs: ^Views, r: ^View_Record, e: View_Event) {
	was_internal := r.machine.state != .Closed && (view_built_as(r.machine.as) == .Internal || r.machine.state == .Moving && view_built_as(r.machine.from) == .Internal)
	before := r.machine
	next, fx := view_step(r.machine, e)
	r.machine = next
	if next.state != before.state || next.as != before.as || next.place != before.place { vs.version += 1 }
	// (a maximised dialog is the Dialog presentation's alone: a floating window or a panel has its own size, and a
	// re-attach shows the dialog at the user's size. Off once it is seen elsewhere, not when a move starts: the dialog
	// still shows, maximised, while its new place is measured)
	if next.state != .Closed && view_shown_in(next) != .Dialog { r.maximised = false }
	// the internal window's focus (a dialog's is its modal's: modal_begin, modals_settle)
	if .Keep_Focus in fx && r.owner != nil { r.focus_back = r.owner.focus_key }
	if (.Show in fx || .Raise in fx) && next.state != .Opening && view_built_as(next.as) == .Internal {
		view_raise(vs, r)
		r.focus_in = true
	}
	if next.state == .Closed && was_internal && r.owner != nil && view_focus_inside(r.owner, r.iframe) {
		back := r.owner.boxes[r.focus_back] or_else nil
		r.owner.focus_key = back != nil ? r.focus_back : 0
	}
	if .Remember in fx {
		// (the id's line: where its next new instance opens; an instance's own line: where that one was)
		keys := [2]string{r.kind.id, view_instance_key(r.kind.id, r.instance)}
		for key, i in keys {
			if i == 1 && r.instance == "" { break }
			m := views_memory_of(vs, key)
			m.as = next.as
			if next.as == .Panel {
				d := m.dock.? or_else View_Dock_Memory{extent_em = r.kind.o.extent_em}
				d.place = next.place
				m.dock = d
			}
			views_memory_write(vs, key, m)
		}
	}
	if .Raise in fx && view_built_as(next.as) == .Dialog && vs.building == 0 {
		// (a dialog brought forward is the one on top)
		for x, i in vs.records {
			if x != r { continue }
			ordered_remove(&vs.records, i)
			append(&vs.records, r)
			break
		}
	}
	// (opening in a window of its own: what is typed until it shows is its own, views_hold_input)
	if before.state == .Closed && next.state == .Opening && next.as == .External {
		r.keys_pending = true
		clear(&r.held_typed)
		clear(&r.held_keys)
	} else if next.state == .Closed {
		r.keys_pending = false
	}
	// (said in the owner's next build: a refusal comes from views_windows_step, between two frames)
	if .Announce_Refused in fx { r.announce = true }
	if .Carry_State in fx { view_carry(r, before.from, before.as) }
	// a view shown now in another window than before: `moved` (a native child window follows it)
	if next.state == .Shown && before.state != .Opening && before.state != .Closed {
		was := view_shown_in(before)
		if next.as != was && r.kind.o.moved != nil {
			if a, b := view_window_of(r, was), view_window_of(r, next.as); a != b && b != nil { r.kind.o.moved(r.data, b) }
		}
	}
	// (opened straight into a window of its own (first = .External, the memory): it was never in its owner's window,
	// where the program made its native child; `moved` says where it is, as after a move)
	if next.state == .Shown && before.state == .Opening && next.as == .External && r.kind.o.moved != nil {
		if b := view_window_of(r, .External); b != nil && (r.owner == nil || b != r.owner.window) { r.kind.o.moved(r.data, b) }
	}
	// its window: wanted while a presentation of it is External, gone at the next step when none is (Open_Window,
	// Close_Windows, Retire_Old of an External, a drop out of a window)
	if view_uses_window(next) {
		if r.w_state == nil { r.w_want = true }
		r.w_close = false
	} else if r.w_state != nil || r.w_want {
		r.w_want = false
		r.w_close = r.w_state != nil
	}
	if next.state == .Closed && r.owner != nil { r.owner.anim_busy = true }   // (the next build takes the answer at once)
	// (an event from another window's build, or from between two frames: the owner makes a frame for it)
	if r.owner != nil && build_of != r.owner { r.owner.anim_busy = true }
	// (a view whose answer is the toolkit's own: told now, last, its answer taken; what it does may close it again)
	if next.state == .Closed && before.state != .Closed && (e.kind == .End || e.kind == .User_Close) && r.kind.on_end != nil {
		code := next.answer.? or_else VIEW_CANCELLED
		r.machine.answer = nil
		r.kind.on_end(r.data, code)
	}
	// (Retire_Old, Leave_Scrim: the builders stop building the old place, views_builders.odin)
}

// begin_build of `s`, after its input is read: what is typed (text and key presses) while a view of `s` opens in a
// window of its own, not shown yet, goes to that view (the keys reach the owner while the window is hidden). The only
// hold: a view in the owner's window is built in the frame it opens (end_build), its focus there before the next keys.
// It ends with the window's first frame shown, or with its refusal (the floating window it falls back to gets them).
@(private)
views_hold_input :: proc(s: ^State) {
	taker: ^View_Record
	for vs in s.views_attached {
		for r in vs.records {
			if r.owner != s || !r.keys_pending { continue }
			if taker != nil { taker.keys_pending = false }   // (an older one waits no more: the newest has the keyboard)
			taker = r
		}
	}
	if taker == nil || (len(s.typed) == 0 && len(s.events.list) == 0) { return }
	context.allocator = taker.allocator
	append(&taker.held_typed, ..s.typed[:])
	clear(&s.typed)
	for e, i in s.events.list {
		if s.events.consumed[i] || e.kind != .Key_Press { continue }
		append(&taker.held_keys, e)
		s.events.consumed[i] = true
	}
}

// At the start of a view's first shown build (its window's, or the floating window of a refusal), before its code reads
// input: what was held for it is this build's input, first, in the State it is built in. Its unseen builds focused its
// field already.
@(private)
view_input_arrive :: proc(r: ^View_Record, shown: bool) {
	if !r.keys_pending || !shown { return }
	s := gs()
	if len(r.held_typed) > 0 { inject_at_elems(&s.typed, 0, ..r.held_typed[:]) }
	if n := len(r.held_keys); n > 0 {
		inject_at_elems(&s.events.list, 0, ..r.held_keys[:])
		falses := make([]bool, n, context.temp_allocator)
		inject_at_elems(&s.events.consumed, 0, ..falses)
	}
	r.keys_pending = false
	clear(&r.held_typed)
	clear(&r.held_keys)
}

// The presentation it is seen in: during a move, the old one.
@(private)
view_shown_in :: proc(m: View_Machine) -> View_Presentation { return m.state == .Moving ? m.from : m.as }

// Whether a presentation of it is its external window: where it is, where it goes, or where it still shows.
@(private)
view_uses_window :: proc(m: View_Machine) -> bool {
	#partial switch m.state {
	case .Opening, .Shown, .Dragged: return m.as == .External
	case .Moving:                    return m.as == .External || m.from == .External
	}
	return false
}

// The window of the system a presentation of it is in.
@(private)
view_window_of :: proc(r: ^View_Record, p: View_Presentation) -> ^platform.Window {
	if p == .External { return r.w_win }
	return r.owner != nil ? r.owner.window : nil
}

// The State a presentation of it is built in.
@(private)
view_state_of :: proc(r: ^View_Record, p: View_Presentation) -> ^State {
	return p == .External ? r.w_state : r.owner
}

// A move settles: the scroll and the focus of its old place go to the new one (state_carry).
@(private = "file")
view_carry :: proc(r: ^View_Record, from, to: View_Presentation) {
	a, b := view_state_of(r, from), view_state_of(r, to)
	if a == nil || b == nil || r.roots[from] == 0 || r.roots[to] == 0 { return }
	state_carry(a, r.roots[from], b, r.roots[to])
}

////////////////////////////////
// The memory

@(private)
views_memory_of :: proc(vs: ^Views, id: string) -> View_Memory {
	text, found := store.get(&vs.memory, id)
	if !found { return {} }
	m, ok := views_parse(text)
	if !ok { return {} }
	return m
}

@(private)
views_memory_write :: proc(vs: ^Views, id: string, m: View_Memory) {
	_ = store.set(&vs.memory, id, views_format(m))
}

////////////////////////////////
// The States that own views

// `vs` is among the views `s` builds at the end of its builds.
// (each side forgets the other when it goes: views_destroy and ui.destroy may come in either order)
@(private)
views_attach_state :: proc(vs: ^Views, s: ^State) {
	for x in s.views_attached { if x == vs { return } }
	context.allocator = vs.allocator
	append(&s.views_attached, vs)
	append(&vs.states, s)
}

// ui.destroy: the views of `s` lose their owner (their answer is VIEW_CANCELLED), `s` and its Views forget each other,
// and its own Views goes.
@(private)
views_state_gone :: proc(s: ^State) {
	for vs in s.views_attached {
		for r in vs.records {
			// (the window of a view, ended by its backend outside a step: the view goes back to its home)
			if r.w_state == s {
				r.w_state, r.w_win, r.w_handle, r.w_shown_build, r.w_close = nil, nil, nil, 0, false
				r.roots[.External] = 0
				if view_uses_window(r.machine) { view_apply(vs, r, {kind = .Reattach}) }
				r.w_want = false
			}
			if r.owner != s { continue }
			view_window_close(vs, r, false)   // (its window goes with its owner)
			view_apply(vs, r, {kind = .Owner_Gone})
			r.owner = nil
		}
		for x, i in vs.states {
			if x == s { unordered_remove(&vs.states, i); break }
		}
	}
	delete(s.views_attached)
	s.views_attached = nil
	s.views = nil
	views_destroy(&s.own_views)
}

// (the builders of the presentations: views_builders.odin)
