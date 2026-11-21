package tk_desktop

// Asynchronous system shell context menu (src/md/features/context-menu.md): queries and invokes third-party shell
// actions for selected files, folders, or a folder background without blocking the interface thread.
//
//   * Windows (context_menu_windows.odin): one dedicated STA COM thread calls IShellFolder -> IContextMenu /
//     IContextMenu2 / IContextMenu3 (QueryContextMenu, HandleMenuMsg for dynamic submenus, GetCommandString for
//     canonical verbs, InvokeCommand) and keeps the session alive until cleared or replaced.
//   * Linux (context_menu_linux.odin): reads KIO service menus, Nemo actions, and Thunar custom actions (uca.xml)
//     off the interface thread, matches target MIME types and selection rules, and launches via platform.launch_detached.
//   * Other systems (context_menu_other.odin): returns an empty list.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "../ascii"
import "../platform"

// Maximum nesting depth walked when converting native submenus (guards against corrupt or cyclic shell menus).
CONTEXT_MENU_MAX_DEPTH :: 8

// One entry in a system shell context menu (plain value data safe to read on the interface thread).
Context_Item :: struct {
	id:        u32,            // opaque id passed back to context_menu_invoke (0 for submenus and separators)
	label:     string,         // display text (Windows '&' mnemonics stripped)
	verb:      string,         // canonical shell verb when known ("7-Zip", "open", ""; optional)
	separator: bool,           // visual divider
	disabled:  bool,
	children:  []Context_Item, // non-empty for a submenu
}

// What the caller asks shell actions for.
Context_Target :: struct {
	paths:         []string, // selected paths (or one folder path when `background` is true)
	background:    bool,     // true: right-clicked on the folder's empty background rather than on items
	exclude_verbs: []string, // canonical verbs to omit (ASCII case-insensitive, e.g. "open", "cut", "copy", "delete")
}

// Called on the Context_Menu worker thread when a query finishes. The caller owns `items` (context_items_destroy) and
// typically posts them to the interface thread via ui.post.
Context_Ready_Proc :: #type proc(user: rawptr, serial: u64, items: []Context_Item)

// Asynchronous shell context-menu controller. One per window / menu owner; its worker thread starts lazily on the first
// context_menu_query and stops in context_menu_destroy.
Context_Menu :: struct {
	lock:       sync.Mutex,
	wake:       sync.Cond,
	worker:     ^thread.Thread,
	stopping:   bool,
	next_serial: u64,

	// Pending work (guarded by `lock`): a newer query supersedes any older queued query.
	has_query:  bool,
	query:      Context_Query_Req,
	has_invoke: bool,
	invoke_serial: u64,
	invoke_id:  u32,
	invoke_hwnd: rawptr,
	has_clear:  bool,

	// Owned exclusively by the worker thread once started.
	active_serial: u64,
	native:        Context_Menu_Native,
}

@(private)
Context_Query_Req :: struct {
	serial:        u64,
	paths:         []string,
	background:    bool,
	exclude_verbs: []string,
	on_ready:      Context_Ready_Proc,
	user:          rawptr,
}

// Starts an asynchronous query for `target`. Returns the monotonic `serial` of this query (0 when `target.paths` is
// empty or `on_ready` is nil). Any older queued query is superseded; `on_ready` runs on the worker thread with `items`
// allocated from the heap (free with context_items_destroy).
context_menu_query :: proc(m: ^Context_Menu, target: Context_Target, on_ready: Context_Ready_Proc, user: rawptr) -> u64 {
	if len(target.paths) == 0 || on_ready == nil { return 0 }
	a := runtime.heap_allocator()
	req := Context_Query_Req{
		paths         = clone_strings(target.paths, a),
		background    = target.background,
		exclude_verbs = clone_strings(target.exclude_verbs, a),
		on_ready      = on_ready,
		user          = user,
	}
	sync.lock(&m.lock)
	defer sync.unlock(&m.lock)
	if m.stopping {
		query_req_destroy(&req)
		return 0
	}
	if m.worker == nil {
		context = runtime.default_context()
		m.worker = thread.create_and_start_with_data(m, context_menu_worker)
		if m.worker == nil {
			query_req_destroy(&req)
			return 0
		}
	}
	m.next_serial += 1
	req.serial = m.next_serial
	if m.has_query { query_req_destroy(&m.query) }
	m.query = req
	m.has_query = true
	m.has_clear = false
	sync.cond_signal(&m.wake)
	return req.serial
}

// Invokes item `id` from the active session matching `serial` on the worker thread. `win` is the owner window (used as
// parent HWND on Windows; nil is allowed). Ignored if `serial` is stale or `id` is 0.
context_menu_invoke :: proc(m: ^Context_Menu, serial: u64, id: u32, win: ^platform.Window = nil) {
	if serial == 0 || id == 0 { return }
	hwnd := win != nil ? platform.native_surface_handles(win).hwnd : nil
	sync.lock(&m.lock)
	defer sync.unlock(&m.lock)
	if m.stopping || m.worker == nil { return }
	m.has_invoke = true
	m.invoke_serial = serial
	m.invoke_id = id
	m.invoke_hwnd = hwnd
	sync.cond_signal(&m.wake)
}

// Releases any active native shell session on the worker thread (call when the menu closes).
context_menu_clear :: proc(m: ^Context_Menu) {
	sync.lock(&m.lock)
	defer sync.unlock(&m.lock)
	if m.worker == nil { return }
	if m.has_query {
		query_req_destroy(&m.query)
		m.has_query = false
	}
	m.has_clear = true
	sync.cond_signal(&m.wake)
}

// Stops and joins the worker thread and releases any active native session.
context_menu_destroy :: proc(m: ^Context_Menu) {
	w: ^thread.Thread
	{
		sync.lock(&m.lock)
		m.stopping = true
		if m.has_query {
			query_req_destroy(&m.query)
			m.has_query = false
		}
		m.has_invoke = false
		m.has_clear = false
		w = m.worker
		sync.cond_signal(&m.wake)
		sync.unlock(&m.lock)
	}
	if w != nil {
		thread.join(w)
		thread.destroy(w)
	}
	m^ = {}
}

// Frees a tree of Context_Item allocated by `allocator` (items from on_ready use runtime.heap_allocator()).
context_items_destroy :: proc(items: []Context_Item, allocator := context.allocator) {
	for it in items {
		delete(it.label, allocator)
		delete(it.verb, allocator)
		if len(it.children) > 0 { context_items_destroy(it.children, allocator) }
	}
	delete(items, allocator)
}

// Deep copy of a Context_Item slice into `allocator`.
context_items_clone :: proc(items: []Context_Item, allocator := context.allocator) -> []Context_Item {
	if len(items) == 0 { return nil }
	out := make([]Context_Item, len(items), allocator)
	for it, i in items {
		out[i] = {
			id        = it.id,
			label     = clone_or_empty(it.label, allocator),
			verb      = clone_or_empty(it.verb, allocator),
			separator = it.separator,
			disabled  = it.disabled,
			children  = context_items_clone(it.children, allocator),
		}
	}
	return out
}

////////////////////////////////
// Pure helpers (shared across all platforms, tested without a desktop)

// Strips Windows '&' keyboard-accelerator mnemonics from a menu label ("&Extract Here" -> "Extract Here",
// "Cut && Paste" -> "Cut & Paste"). Also trims any trailing accelerator tab ("\tCtrl+X").
context_menu_strip_mnemonic :: proc(s: string, allocator := context.temp_allocator) -> string {
	trimmed := s
	if tab := strings.index_byte(trimmed, '\t'); tab >= 0 { trimmed = trimmed[:tab] }
	sb := strings.builder_make(allocator)
	for i := 0; i < len(trimmed); i += 1 {
		if trimmed[i] == '&' {
			if i + 1 < len(trimmed) && trimmed[i + 1] == '&' {
				strings.write_byte(&sb, '&')
				i += 1
			}
			continue
		}
		strings.write_byte(&sb, trimmed[i])
	}
	return strings.trim_space(strings.to_string(sb))
}

// True when `verb` matches any entry in `excluded` (ASCII case-insensitive).
context_menu_verb_excluded :: proc(verb: string, excluded: []string) -> bool {
	if verb == "" { return false }
	for ex in excluded {
		if ascii.equal_fold(verb, ex) { return true }
	}
	return false
}

// Recursively drops empty submenus, excluded verbs, and leading/trailing/consecutive separators from `items`
// (allocating the pruned result in `allocator` and freeing nothing from the input).
context_items_prune :: proc(items: []Context_Item, excluded: []string, allocator := context.allocator) -> []Context_Item {
	out := make([dynamic]Context_Item, 0, len(items), allocator)
	for it in items {
		if it.separator {
			if len(out) == 0 || out[len(out) - 1].separator { continue }
			append(&out, Context_Item{separator = true})
			continue
		}
		if context_menu_verb_excluded(it.verb, excluded) { continue }
		if len(it.children) > 0 {
			kids := context_items_prune(it.children, excluded, allocator)
			if len(kids) == 0 {
				delete(kids, allocator)
				continue
			}
			append(&out, Context_Item{
				label    = clone_or_empty(it.label, allocator),
				verb     = clone_or_empty(it.verb, allocator),
				disabled = it.disabled,
				children = kids,
			})
			continue
		}
		if it.id == 0 || it.label == "" { continue }
		append(&out, Context_Item{
			id       = it.id,
			label    = clone_or_empty(it.label, allocator),
			verb     = clone_or_empty(it.verb, allocator),
			disabled = it.disabled,
		})
	}
	for len(out) > 0 && out[len(out) - 1].separator { pop(&out) }
	if len(out) == 0 {
		delete(out)
		return nil
	}
	return out[:]
}

////////////////////////////////
// Worker loop

@(private = "file")
context_menu_worker :: proc(data: rawptr) {
	m := (^Context_Menu)(data)
	context_menu_native_init(&m.native)
	defer context_menu_native_end(&m.native)
	for {
		req: Context_Query_Req
		do_query, do_invoke, do_clear := false, false, false
		inv_serial: u64
		inv_id: u32
		inv_hwnd: rawptr

		sync.lock(&m.lock)
		for !m.stopping && !m.has_query && !m.has_invoke && !m.has_clear {
			sync.cond_wait(&m.wake, &m.lock)
		}
		if m.stopping {
			sync.unlock(&m.lock)
			return
		}
		// Run invoke before clear/query so a click right before menu close is never lost.
		if m.has_invoke {
			do_invoke = true
			inv_serial, inv_id, inv_hwnd = m.invoke_serial, m.invoke_id, m.invoke_hwnd
			m.has_invoke = false
		} else if m.has_clear {
			do_clear = true
			m.has_clear = false
		} else if m.has_query {
			do_query = true
			req = m.query
			m.query = {}
			m.has_query = false
		}
		sync.unlock(&m.lock)

		if do_invoke {
			if inv_serial == m.active_serial {
				_ = context_menu_native_invoke(&m.native, inv_id, inv_hwnd)
			}
		} else if do_clear {
			context_menu_native_clear(&m.native)
			m.active_serial = 0
		} else if do_query {
			context_menu_native_clear(&m.native)
			items := context_menu_native_query(&m.native, req, runtime.heap_allocator())
			m.active_serial = req.serial
			if req.on_ready != nil {
				req.on_ready(req.user, req.serial, items)
			} else {
				context_items_destroy(items, runtime.heap_allocator())
			}
			query_req_destroy(&req)
		}
		free_all(context.temp_allocator)
	}
}

@(private = "file")
clone_strings :: proc(src: []string, allocator: runtime.Allocator) -> []string {
	if len(src) == 0 { return nil }
	out := make([]string, len(src), allocator)
	for s, i in src { out[i] = strings.clone(s, allocator) }
	return out
}

@(private = "file")
query_req_destroy :: proc(req: ^Context_Query_Req) {
	a := runtime.heap_allocator()
	for s in req.paths { delete(s, a) }
	delete(req.paths, a)
	for s in req.exclude_verbs { delete(s, a) }
	delete(req.exclude_verbs, a)
	req^ = {}
}
