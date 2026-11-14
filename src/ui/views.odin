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
import "core:math"
import "core:strings"
import "../font"
import i18n "../i18n"
import lucide "../lucide"
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
	width_em:       f32,                        // the dialog's first width (0: DIALOG_WIDTH_EM); it grows to what is in it
	height_em:      f32,                        // 0: as tall as what is in it
	min_width_em:   f32,                        // how small the user makes it (with `resizable`)
	min_height_em:  f32,
	extent_em:      f32,                        // a panel's width or height (step 3)
	resizable:      bool,                       // the dialog has grips; its size is remembered
	top:            Maybe(f32),                 // the dialog's top at this fraction of the window (a palette); nil: centred
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
	record:       ^View_Record,
}

// The build procedure as the registry keeps it. It builds the body only: the header is the toolkit's.
View_Build :: #type proc(v: ^View, data: rawptr)

// The words of the views' header and menus (zero: view_default_labels, in the language in use).
View_Labels :: struct {
	detach, close: string,
}

view_default_labels :: proc() -> View_Labels {
	return {detach = i18n.tr("Detach"), close = i18n.tr("Close")}
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
	memory:    store.Store,
	labels:    View_Labels,
	allocator: runtime.Allocator,
}

// What view_register got.
@(private)
View_Kind :: struct {
	id:    string,   // owned
	build: View_Build,
	type:  typeid,
	o:     View_Options,   // its strings owned
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
	title:      string,      // owned: view_title's (or a ready-made view's), "": the kind's
	icon:       string,      // a ready-made view's icon for this opening ("": the kind's)
	tools:      Key,         // the header's box of the program's tools, in this build
	header:     Key,         // the header strip, in this build (view_room)
	panel:      Key,         // the dialog's panel
	// what a ready-made view owns for this opening (its options cloned), freed with the record
	owned:      rawptr,
	owned_free: proc(p: rawptr),
	allocator:  runtime.Allocator,   // the Views': what its strings are made with
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
@(private = "file")
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
		if m.open != was {
			m.open = was
			views_memory_write(vs, id, m)
		}
	}
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
	store.close(&vs.memory)
	vs^ = {}
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
	k.o.title, k.o.icon, k.o.home_place.space = strings.clone(o.title), strings.clone(o.icon), strings.clone(o.home_place.space)
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
	// (the State being built, else the one in use: the last built or selected, as ui.init selects it)
	who := owner != nil ? owner : (build_of != nil ? build_of : current)
	assert(who != nil, "view_open: no State in use: give its owner")
	r := view_record_find(vs, id, instance)
	if r == nil {
		r = new(View_Record)
		r.kind, r.instance, r.allocator = k, strings.clone(instance), vs.allocator
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
		as := m.as.? or_else (k.o.first.? or_else k.o.home)
		place := k.o.home_place
		if d, ok := m.dock.?; ok {
			// (the memory's text is temporary: a space is kept by the kind's own name; another space is the frame's
			// until step 3 knows the spaces of the program)
			place.edge = d.place.edge
			place.space = d.place.space == k.o.home_place.space ? k.o.home_place.space : ""
		}
		r.size, r.size_kept = m.dialog, m.dialog
		view_apply(vs, r, {kind = .Open, as = as, place = place})
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

// Whether it was open when the program last quit (a side pane, a tool window): the program opens it again.
view_was_open :: proc(vs: ^Views, id: string, instance := "") -> bool {
	return views_memory_of(vs, id).open
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

// Inside a build: a title for this frame (a process's name). Temporary memory is enough. The header shows it from the
// next build, which comes at once (a dialog is measured unseen before it shows: its first frame drawn has it).
view_title :: proc(v: ^View, title: string) {
	r := v.record
	if r.title == title { return }
	context.allocator = r.allocator
	delete(r.title)
	r.title = strings.clone(title)
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

// Inside a build: `if ui.view_header_tools(v) { ... }` builds controls in the header, after the title. False in a
// presentation with no header (the block is skipped).
@(require_results, deferred_none = view_header_tools_end)
view_header_tools :: proc(v: ^View) -> bool {
	b := box_from_key(v.record.tools)
	if b == nil || v.record.tools == 0 {
		push_parent(parent_box())
		return false
	}
	push_parent(b)
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

// The presentation a view is built in. Step 1: Dialog for every one; the builders of Panel and Internal (steps 2 and
// 3) and of External (step 4) replace these lines.
@(private)
view_built_as :: proc(p: View_Presentation) -> View_Presentation {
	switch p {
	case .Dialog, .Panel, .Internal, .External: return .Dialog
	}
	return .Dialog
}

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
	delete(r.title)
	r.title, r.icon = "", ""
	if r.owned != nil && r.owned_free != nil { r.owned_free(r.owned) }
	r.owned, r.owned_free = nil, nil
}

@(private = "file")
view_record_free :: proc(r: ^View_Record) {
	view_record_reset(r)
	delete(r.instance)
	delete(r.modal_name)
	free(r)
}

@(private = "file")
view_kind_free :: proc(k: ^View_Kind) {
	delete(k.id)
	delete(k.o.title)
	delete(k.o.icon)
	delete(k.o.home_place.space)
	free(k)
}

// The records closed with no answer go. Not while views are built: a build that closes a view (its own, another) must
// not free a record that is being built or move the ones after it.
@(private)
views_sweep :: proc(vs: ^Views) {
	if vs.building > 0 { return }
	context.allocator = vs.allocator
	n := 0
	for r in vs.records {
		if r.machine.state == .Closed && r.machine.answer == nil {
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
	next, fx := view_step(r.machine, e)
	r.machine = next
	if .Remember in fx {
		m := views_memory_of(vs, r.kind.id)
		m.as = next.as
		if next.as == .Panel {
			d := m.dock.? or_else View_Dock_Memory{extent_em = r.kind.o.extent_em}
			d.place = next.place
			m.dock = d
		}
		views_memory_write(vs, r.kind.id, m)
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
	if .Announce_Refused in fx && r.owner != nil && current_state() == r.owner {
		toast_add(.Warn, nil, nil, i18n.tr("No window: the renderer refused it."))
	}
	if next.state == .Closed && r.owner != nil { r.owner.anim_busy = true }   // (the next build takes the answer at once)
	// (Keep_Focus, Show, Give_Focus_Back: the dialog's own code does them, modal_begin and modals_settle. Open_Window,
	// Close_Windows, Retire_Old, Carry_State, Leave_Scrim: the builders of steps 2 to 4.)
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
@(private = "file")
views_attach_state :: proc(vs: ^Views, s: ^State) {
	for x in s.views_attached { if x == vs { return } }
	append(&s.views_attached, vs)
	append(&vs.states, s)
}

// ui.destroy: the views of `s` lose their owner (their answer is VIEW_CANCELLED), `s` and its Views forget each other,
// and its own Views goes.
@(private)
views_state_gone :: proc(s: ^State) {
	for vs in s.views_attached {
		for r in vs.records {
			if r.owner != s { continue }
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

// end_build: the views of `s` that show as dialogs, in their order (the last opened on top). A view opened by a view's
// build is built after it, in this build.
@(private)
views_build :: proc(s: ^State) {
	for vi := 0; vi < len(s.views_attached); vi += 1 {
		vs := s.views_attached[vi]
		vs.building += 1
		for i := 0; i < len(vs.records); i += 1 {
			r := vs.records[i]
			if r.owner != s || r.machine.state == .Closed { continue }
			view_dialog_build(vs, r)
		}
		vs.building -= 1
		views_sweep(vs)
	}
}

////////////////////////////////
// The Dialog presentation

// The view as a dialog: the toolkit's modal (its first frames measured unseen, its fade, its grips, Escape and the
// scrim), the header strip, then the body.
@(private = "file")
view_dialog_build :: proc(vs: ^Views, r: ^View_Record) {
	s := gs()
	k := r.kind
	key := modal_key(s, r.modal_name)
	phase, last := modal_phase(s, key)
	// (the dialog's own measure says when it settled: the frame it shows in)
	if r.machine.state == .Opening && phase != .Opening && (last.show == .Showing || last.show == .Shown) {
		view_apply(vs, r, {kind = .Settled})
	}
	// (a move between two presentations built alike has nothing to measure)
	if r.machine.state == .Moving && view_built_as(r.machine.as) == view_built_as(r.machine.from) {
		view_apply(vs, r, {kind = .Settled})
	}
	r.flag, r.ending, r.tools, r.header = true, nil, 0, 0
	o := Modal_Options{width_em = k.o.width_em, height_em = k.o.height_em, min_width_em = k.o.min_width_em, min_height_em = k.o.min_height_em, top = k.o.top}
	if k.o.resizable { o.size = &r.size }
	v := View{id = k.id, instance = r.instance, presentation = r.machine.as, place = r.machine.place, record = r}
	v.shown = phase != .Opening && (last.show == .Showing || last.show == .Shown)
	if modal(r.modal_name, &r.flag, o) {
		r.panel = parent_box().key
		if k.o.backdrop != nil { k.o.backdrop(&v, r.data) }
		if !k.o.no_header { view_dialog_header(vs, r) }
		k.build(&v, r.data)
		// (Ctrl+W closes the dialog on top, as Escape does)
		if r.flag && r.ending == nil && phase == .Top && key_press(.W, {.Ctrl}) { r.flag = false }
	}
	if code, ended := r.ending.?; ended {
		view_apply(vs, r, {kind = .End, code = code})
	} else if !r.flag {
		view_apply(vs, r, {kind = .User_Close})
	}
	if r.machine.state == .Closed { return }
	// (the size the user gave it, kept once the grip is let go)
	if k.o.resizable && r.size != r.size_kept && s.active_key[.Left] == 0 {
		m := views_memory_of(vs, k.id)
		m.dialog = r.size
		views_memory_write(vs, k.id, m)
		r.size_kept = r.size
	}
}

// A dialog's header: its icon and title, the program's tools (view_header_tools), the Detach icon, the close cross in
// the corner. The Detach icon is inactive until the Internal presentation is built (step 2).
@(private = "file")
view_dialog_header :: proc(vs: ^Views, r: ^View_Record) {
	k := r.kind
	labels := vs.labels == {} ? view_default_labels() : vs.labels
	title := r.title != "" ? r.title : i18n.tr(k.o.title)
	// (a ready-made view's icon for this opening is Lucide's)
	icon := r.icon != "" ? r.icon : k.o.icon
	icon_font := r.icon != "" ? lucide_icons() : k.o.icon_font
	if dialog_header("view_header", text_shown(title), {icon = icon, icon_font = icon_font, close = true, close_label = labels.close}) {
		r.header = parent_box().key
		next({width = children_sum(), height = children_sum(), axis = .X, cross = .Center})
		r.tools = build_box({}, "###view_tools").key
		view_detach_icon(labels.detach, view_built_as(.Internal) == .Internal)
	}
}

// The small Detach icon beside the close cross, in the weak colour. `active` false: drawn, not clickable.
@(private = "file")
view_detach_icon :: proc(label: string, active: bool) {
	em := font_size()
	side := math.round(em * VIEW_DETACH_EM)
	spacer(px(em * 0.3))
	push_tags("ghost_button", "button", "weak")
	defer pop_tags()
	flags := Box_Flags{.Draw_Text, .No_Text_Trunc}
	if active { flags += {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects} } else { flags += {.Disabled} }
	next({width = px(side), height = px(side), font = lucide_icons(), font_size = em * 0.85, text_pad = 0, text_align = .Center, radius = em * 0.3})
	b := build_box(flags, fmt.tprintf("%s###view_detach", lucide.PICTURE_IN_PICTURE_2))
	a11y_default(b, {role = .Button, name = label})
}

// The side of the header's Detach icon, in ems: smaller than the close cross (DIALOG_CLOSE_EM).
VIEW_DETACH_EM :: f32(1.5)
