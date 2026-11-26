package ui

// "Open with" (src/md/features/open-with.md): the applications the system knows for a file, with their icons, in a
// submenu, and the file opened with the one chosen. A program keeps an Open_With per menu that offers it:
//
//	open_with_ask(&ow, s, path)                     // the menu opens: the list is read on a chore
//	if menu_submenu(i18n.tr("Open with")) {
//		if open_with_items(&ow, "ow") { open_with_run(&ow) }   // or open_with_chosen for a program's own run
//	}
//	open_with_destroy(&ow)
//
// Its machine: Idle -> Reading (open_with_ask: a chore reads the handlers and each icon) -> Ready (the list; an empty
// one says so). A new ask drops the answer of the last (its serial); an answer after open_with_destroy finds no
// Open_With (the link). Nothing of it reads the system on the interface's thread: the icons are read with the list,
// once per ask, not per frame.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import base "../base"
import desktop "../desktop"
import i18n "../i18n"
import lucide "../lucide"

// The size the applications' icons are read at, in pixels (drawn at about the font's size: room for a zoom).
OPEN_WITH_ICON_PX :: 32

Open_With_State :: enum u8 { Idle, Reading, Ready }

Open_With :: struct {
	// The system's calls, made on a chore (they must be safe on any thread). nil: desktop.handlers_for_file,
	// desktop.handler_icon and desktop.open_with. A test gives its own.
	handlers_of: proc(path: string, allocator: runtime.Allocator) -> []desktop.Handler,
	icon_of:     proc(h: desktop.Handler, size: int, allocator: runtime.Allocator) -> (desktop.File_Icon, bool),
	open:        proc(path, id: string) -> bool,

	state:    Open_With_State,
	path:     string,                 // the file asked (heap)
	handlers: []desktop.Handler,      // Ready: the default first (heap)
	pictures: []desktop.File_Icon,    // one per handler, empty when it has none (heap)
	icons:    []Menu_Icon,            // ... their textures (borrow the pictures)
	chosen:   int,                    // the handler the last open_with_items chose (-1: none)

	owner:    ^State,                 // where the chores answer
	serial:   u64,                    // counts the asks: an older answer is dropped
	link:     ^Open_With_Link,
}

// What the chores' answers find the Open_With by: `ow` nil once it is destroyed (read on the interface's thread only).
// Counted: the Open_With's, each job's (atomic).
@(private)
Open_With_Link :: struct {
	ow:   ^Open_With,
	refs: int,
}

@(private = "file")
Open_With_Read :: struct {
	link:        ^Open_With_Link,
	serial:      u64,
	path:        string,                   // (heap)
	handlers_of: proc(path: string, allocator: runtime.Allocator) -> []desktop.Handler,
	icon_of:     proc(h: desktop.Handler, size: int, allocator: runtime.Allocator) -> (desktop.File_Icon, bool),
	handlers:    []desktop.Handler,        // (heap)
	pictures:    []desktop.File_Icon,      // (heap)
}

@(private = "file")
Open_With_Run :: struct {
	path, id, name: string,   // (heap)
	open:           proc(path, id: string) -> bool,
	ok:             bool,
}

// Reads the applications that open the file at `path` (it need not exist: its name says its type), and their icons, on
// a chore; the answer comes to `s` (the State the menu is built in). What was read before goes.
open_with_ask :: proc(ow: ^Open_With, s: ^State, path: string) {
	heap := runtime.heap_allocator()
	open_with_clear(ow)
	ow.path = strings.clone(path, heap)
	ow.owner = s
	ow.state = .Reading
	ow.serial += 1
	if ow.link == nil {
		ow.link = new(Open_With_Link, heap)
		ow.link^ = {ow = ow, refs = 1}
	}
	sync.atomic_add(&ow.link.refs, 1)   // (the job's: let go of in done, or in lost on the thread that found the State gone)
	j := new(Open_With_Read, heap)
	j^ = {link = ow.link, serial = ow.serial, path = strings.clone(path, heap), handlers_of = ow.handlers_of, icon_of = ow.icon_of}
	work :: proc(d: rawptr) {
		j := (^Open_With_Read)(d)
		heap := runtime.heap_allocator()
		j.handlers = j.handlers_of != nil ? j.handlers_of(j.path, heap) : desktop.handlers_for_file(j.path, heap)
		j.pictures = make([]desktop.File_Icon, len(j.handlers), heap)
		for h, i in j.handlers {
			pic: desktop.File_Icon
			ok: bool
			if j.icon_of != nil { pic, ok = j.icon_of(h, OPEN_WITH_ICON_PX, heap) } else { pic, ok = desktop.handler_icon(h, OPEN_WITH_ICON_PX, heap) }
			if ok { j.pictures[i] = pic }
		}
	}
	done :: proc(d: rawptr, _: u64) {
		j := (^Open_With_Read)(d)
		ow := j.link.ow
		if ow != nil && ow.serial == j.serial && ow.state == .Reading {
			ow.handlers, ow.pictures = j.handlers, j.pictures
			j.handlers, j.pictures = nil, nil
			ow.icons = make([]Menu_Icon, len(ow.handlers), runtime.heap_allocator())
			for p, i in ow.pictures { ow.icons[i] = {rgba = p.rgba, size = p.size} }
			ow.state = .Ready
		}
		open_with_read_free(j)
	}
	lost :: proc(d: rawptr) { open_with_read_free((^Open_With_Read)(d)) }
	task(s, work, done, j, lost)
}

@(private = "file")
open_with_read_free :: proc(j: ^Open_With_Read) {
	heap := runtime.heap_allocator()
	open_with_lists_free(j.handlers, j.pictures)
	delete(j.path, heap)
	open_with_link_release(j.link)
	free(j, heap)
}

@(private = "file")
open_with_lists_free :: proc(handlers: []desktop.Handler, pictures: []desktop.File_Icon) {
	heap := runtime.heap_allocator()
	if handlers != nil { desktop.handlers_destroy(handlers, heap) }
	for &p in pictures { desktop.file_icon_destroy(&p, heap) }
	delete(pictures, heap)
}

@(private = "file")
open_with_link_release :: proc(l: ^Open_With_Link) {
	if l != nil && sync.atomic_sub(&l.refs, 1) == 1 { free(l, runtime.heap_allocator()) }
}

// The applications as items of the menu being built (inside a menu_submenu), the default first with its word, each with
// its icon: a disabled row while they are read, and one when there is none. True when one was chosen in this build
// (open_with_chosen gives it; open_with_run opens the file with it). `id_prefix` names the items (`<prefix>_<index>`).
open_with_items :: proc(ow: ^Open_With, id_prefix := "ow") -> (chosen: bool) {
	switch ow.state {
	case .Idle: return
	case .Reading:
		_ = menu_item(fmt.tprintf("%s###%s_reading", i18n.tr("Reading…"), id_prefix), disabled = true)
		return
	case .Ready:
	}
	if len(ow.handlers) == 0 {
		_ = menu_item(fmt.tprintf("%s###%s_none", i18n.tr("No application"), id_prefix), disabled = true)
		return
	}
	for h, i in ow.handlers {
		name := text_shown(h.name)
		label := h.default ? fmt.tprintf(i18n.tr("%s (default)"), name) : name
		text := fmt.tprintf("%s###%s_%d", label, id_prefix, i)
		has_icon := i < len(ow.icons) && len(ow.icons[i].rgba) > 0
		sig: Signal
		if has_icon {
			sig = menu_item_ex(text, icon_draw = menu_icon_draw, icon_user = &ow.icons[i])
		} else {
			sig = menu_item(text, icon = lucide.APP_WINDOW, icon_font = lucide_icons())
		}
		if sig.clicked {
			ow.chosen = i
			chosen = true
		}
	}
	return
}

// The handler the last open_with_items chose (ok false: none, or the list was read again since).
open_with_chosen :: proc(ow: ^Open_With) -> (h: desktop.Handler, ok: bool) {
	if ow.state != .Ready || ow.chosen < 0 || ow.chosen >= len(ow.handlers) { return }
	return ow.handlers[ow.chosen], true
}

// Opens the file with the handler chosen (open_with_chosen), on a chore. `path` "": the file asked. When the
// application does not start, a toast says so.
open_with_run :: proc(ow: ^Open_With, path := "") {
	h, ok := open_with_chosen(ow)
	if !ok || ow.owner == nil { return }
	heap := runtime.heap_allocator()
	r := new(Open_With_Run, heap)
	r^ = {path = strings.clone(path != "" ? path : ow.path, heap), id = strings.clone(h.id, heap), name = strings.clone(h.name, heap), open = ow.open}
	work :: proc(d: rawptr) {
		r := (^Open_With_Run)(d)
		r.ok = r.open != nil ? r.open(r.path, r.id) : desktop.open_with(r.path, r.id)
	}
	done :: proc(d: rawptr, _: u64) {
		r := (^Open_With_Run)(d)
		if !r.ok { toast_add(.Bad, nil, nil, base.restricted() ? restricted_open_words() : fmt.tprintf(i18n.tr("%s did not start."), r.name)) }
		open_with_run_free(r)
	}
	lost :: proc(d: rawptr) { open_with_run_free((^Open_With_Run)(d)) }
	task(ow.owner, work, done, r, lost)
}

@(private = "file")
open_with_run_free :: proc(r: ^Open_With_Run) {
	heap := runtime.heap_allocator()
	delete(r.path, heap); delete(r.id, heap); delete(r.name, heap)
	free(r, heap)
}

// Back to Idle: the list, its icons and their textures go; a reading on its way answers nothing.
@(private)
open_with_clear :: proc(ow: ^Open_With) {
	heap := runtime.heap_allocator()
	for &ic in ow.icons { menu_icon_release(&ic) }
	delete(ow.icons, heap)
	open_with_lists_free(ow.handlers, ow.pictures)
	delete(ow.path, heap)
	ow.icons, ow.handlers, ow.pictures, ow.path = nil, nil, nil, ""
	ow.state, ow.chosen = .Idle, -1
	ow.serial += 1
}

// Frees what `ow` holds; a reading or a run on its way answers nothing. The hooks stay.
open_with_destroy :: proc(ow: ^Open_With) {
	open_with_clear(ow)
	if ow.link != nil {
		ow.link.ow = nil
		open_with_link_release(ow.link)
		ow.link = nil
	}
	ow.owner = nil
}
