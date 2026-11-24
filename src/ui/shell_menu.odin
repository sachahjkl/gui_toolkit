package ui

// Asynchronous system shell context-menu integration for ui.menu (src/md/features/context-menu.md).
// Wraps desktop.Context_Menu, posts completed item trees safely back to the interface thread via ui.post (guarded by
// an atomic refcounted gate so destroying Shell_Menu while a post is in flight never dereferences freed memory),
// uploads Context_Item.icon bitmaps lazily to GPU textures on draw, and renders items and recursive submenus.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:sync"
import desktop "../desktop"
import draw "../draw"
import "../platform"
import "../render"

// Standard built-in verbs excluded by default in file browsers that already offer Open, Cut, Copy, Paste, Delete,
// Rename, and Properties.
@(rodata)
SHELL_MENU_DEFAULT_EXCLUDE := [?]string{
	"open", "explore", "find", "cut", "copy", "paste", "delete", "rename", "properties", "link",
}

@(private = "file")
Shell_Menu_Gate :: struct {
	lock:  sync.Mutex,
	owner: ^Shell_Menu, // nil once shell_menu_destroy detaches
	refs:  int,         // 1 for owner + 1 per in-flight ui.post message
}

@(private = "file")
Shell_Menu_Ready :: struct {
	gate:   ^Shell_Menu_Gate,
	serial: u64,
	items:  []desktop.Context_Item,
}

@(private = "file")
Shell_Menu_Icon :: struct {
	rgba:     []u8, // borrows Context_Item.icon.rgba while items live
	size:     [2]int,
	texture:  render.Texture,
	renderer: ^render.Renderer,
	failed:   bool,
}

// Asynchronous system shell context-menu controller for one ui.menu owner (for example ui.file_dialog or a file
// manager). Zero-initialized; call shell_menu_destroy when the owner goes away.
Shell_Menu :: struct {
	native:   desktop.Context_Menu,
	gate:     ^Shell_Menu_Gate,
	state:    ^State,
	serial:   u64,
	items:    []desktop.Context_Item, // owned (runtime.heap_allocator)
	ready:    bool,
	icons:    [dynamic]Shell_Menu_Icon, // one per item with an icon, aligned by tree walk order
	// (invoked id on last click; cleared on next query/clear, useful in tests)
	invoked:  u32,
}

@(private = "file")
gate_ensure :: proc(m: ^Shell_Menu) -> ^Shell_Menu_Gate {
	if m.gate != nil { return m.gate }
	a := runtime.heap_allocator()
	g := new(Shell_Menu_Gate, a)
	g^ = {owner = m, refs = 1}
	m.gate = g
	return g
}

@(private = "file")
gate_release :: proc(g: ^Shell_Menu_Gate, detach_owner: bool) {
	if g == nil { return }
	free_it := false
	sync.lock(&g.lock)
	if detach_owner { g.owner = nil }
	g.refs -= 1
	free_it = g.refs <= 0
	sync.unlock(&g.lock)
	if free_it { free(g, runtime.heap_allocator()) }
}

@(private = "file")
shell_menu_icons_free :: proc(m: ^Shell_Menu) {
	for &ic in m.icons {
		if ic.texture != 0 && ic.renderer != nil {
			render.destroy_texture(ic.renderer, ic.texture)
		}
	}
	clear(&m.icons)
}

@(private = "file")
shell_menu_icons_collect :: proc(m: ^Shell_Menu, items: []desktop.Context_Item) {
	for it in items {
		if len(it.icon.rgba) > 0 && it.icon.size.x > 0 && it.icon.size.y > 0 {
			append(&m.icons, Shell_Menu_Icon{rgba = it.icon.rgba, size = it.icon.size})
		}
		if len(it.children) > 0 { shell_menu_icons_collect(m, it.children) }
	}
}

@(private = "file")
shell_menu_on_ready :: proc(user: rawptr, serial: u64, items: []desktop.Context_Item) {
	g := (^Shell_Menu_Gate)(user)
	a := runtime.heap_allocator()
	s: ^State
	sync.lock(&g.lock)
	if g.owner != nil {
		s = g.owner.state
		g.refs += 1
	}
	sync.unlock(&g.lock)
	if s == nil {
		desktop.context_items_destroy(items, a)
		return
	}
	msg := new(Shell_Menu_Ready, a)
	msg^ = {gate = g, serial = serial, items = items}
	if !post(s, shell_menu_post_done, msg) {
		desktop.context_items_destroy(msg.items, a)
		free(msg, a)
		gate_release(g, false)
	}
}

@(private = "file")
shell_menu_post_done :: proc(data: rawptr, word: u64) {
	_ = word
	a := runtime.heap_allocator()
	msg := (^Shell_Menu_Ready)(data)
	g := msg.gate
	defer {
		free(msg, a)
		gate_release(g, false)
	}
	m: ^Shell_Menu
	sync.lock(&g.lock)
	m = g.owner
	sync.unlock(&g.lock)
	if m == nil {
		desktop.context_items_destroy(msg.items, a)
		return
	}
	shell_menu_apply(m, msg.serial, msg.items)
}

// Starts an asynchronous system shell context-menu query for `target` and delivers its result back to `s` via ui.post.
// Returns the query's serial (0 when `target.paths` is empty or `s` is nil).
shell_menu_query :: proc(m: ^Shell_Menu, s: ^State, target: desktop.Context_Target) -> u64 {
	shell_menu_clear(m)
	if s == nil || len(target.paths) == 0 { return 0 }
	m.state = s
	g := gate_ensure(m)
	m.serial = desktop.context_menu_query(&m.native, target, shell_menu_on_ready, g)
	return m.serial
}

// Applies a completed query result on the interface thread (taking heap ownership of `items`). Stale serials are
// ignored and their items freed. Exposed so headless tests can drive Shell_Menu without hitting the host OS shell.
shell_menu_apply :: proc(m: ^Shell_Menu, serial: u64, items: []desktop.Context_Item) {
	a := runtime.heap_allocator()
	if serial == 0 || serial != m.serial {
		desktop.context_items_destroy(items, a)
		return
	}
	shell_menu_icons_free(m)
	desktop.context_items_destroy(m.items, a)
	m.items = items
	m.ready = true
	if m.icons.allocator.procedure == nil {
		m.icons = make([dynamic]Shell_Menu_Icon, 0, 8, a)
	}
	shell_menu_icons_collect(m, m.items)
	// ui.post already wakes the window; shell_menu_apply runs inside begin_build before widgets build.
}

@(private = "file")
shell_menu_draw_icon :: proc(box: ^Box, user: rawptr, dc: ^draw.Context) {
	ic := (^Shell_Menu_Icon)(user)
	if ic == nil || dc == nil || dc.renderer == nil || len(ic.rgba) == 0 { return }
	if ic.texture == 0 && !ic.failed {
		w, h := ic.size.x, ic.size.y
		most := render.max_texture_size(dc.renderer)
		if w <= 0 || h <= 0 || w > most || h > most || len(ic.rgba) < w * h * 4 {
			ic.failed = true
			return
		}
		ic.texture = render.create_texture_rgba(dc.renderer, w, h)
		if ic.texture == 0 {
			ic.failed = true
			return
		}
		ic.renderer = dc.renderer
		render.update_texture_rgba(dc.renderer, ic.texture, 0, 0, w, h, ic.rgba)
	}
	if ic.texture == 0 { return }
	r := box.rect
	side := math.floor(min(r.max.x - r.min.x, r.max.y - r.min.y, font_size() * 1.05))
	if side < 2 { return }
	ox := math.floor(r.min.x + ((r.max.x - r.min.x) - side) * 0.5)
	oy := math.floor(r.min.y + ((r.max.y - r.min.y) - side) * 0.5)
	draw.image(dc, ic.texture, {{ox, oy}, {ox + side, oy + side}})
}

@(private = "file")
shell_menu_build_list :: proc(m: ^Shell_Menu, items: []desktop.Context_Item, prefix: string, icon_idx: ^int, win: ^platform.Window, invoke: bool) -> u32 {
	picked: u32
	for it, i in items {
		icon_draw: Custom_Draw
		icon_user: rawptr
		if len(it.icon.rgba) > 0 && it.icon.size.x > 0 && it.icon.size.y > 0 {
			idx := icon_idx^
			icon_idx^ += 1
			if idx < len(m.icons) {
				icon_draw = shell_menu_draw_icon
				icon_user = &m.icons[idx]
			}
		}
		if it.separator {
			menu_separator()
			continue
		}
		if len(it.children) > 0 {
			sub_id := fmt.tprintf("%s_%d", prefix, i)
			if menu_submenu_ex(fmt.tprintf("%s###%s", text_shown(it.label), sub_id), disabled = it.disabled, icon_draw = icon_draw, icon_user = icon_user) {
				if sub := shell_menu_build_list(m, it.children, sub_id, icon_idx, win, invoke); sub != 0 { picked = sub }
			} else {
				// Advance icon cursor past collapsed submenu children so indices stay aligned.
				shell_menu_skip_icons(it.children, icon_idx)
			}
			continue
		}
		label := fmt.tprintf("%s###%s_%d", text_shown(it.label), prefix, i)
		if menu_item_ex(label, disabled = it.disabled, icon_draw = icon_draw, icon_user = icon_user).clicked {
			picked = it.id
			m.invoked = it.id
			if invoke {
				w := win != nil ? win : (m.state != nil ? m.state.window : nil)
				desktop.context_menu_invoke(&m.native, m.serial, it.id, w)
			}
		}
	}
	return picked
}

@(private = "file")
shell_menu_skip_icons :: proc(items: []desktop.Context_Item, icon_idx: ^int) {
	for it in items {
		if len(it.icon.rgba) > 0 && it.icon.size.x > 0 && it.icon.size.y > 0 { icon_idx^ += 1 }
		if len(it.children) > 0 { shell_menu_skip_icons(it.children, icon_idx) }
	}
}

// Renders ready shell context-menu items inside the current ui.menu block (optionally preceded by a separator when
// `separator` is true). Returns the clicked item's id (0 when none was clicked), and invokes it on the worker thread
// unless `invoke` is false.
shell_menu_items :: proc(m: ^Shell_Menu, prefix := "shell", separator := true, win: ^platform.Window = nil, invoke := true) -> u32 {
	if !m.ready || len(m.items) == 0 { return 0 }
	if separator { menu_separator() }
	icon_idx := 0
	return shell_menu_build_list(m, m.items, prefix, &icon_idx, win, invoke)
}

// Releases the active native shell session, frees items and GPU icon textures, and invalidates any in-flight query.
// Call when the menu closes.
shell_menu_clear :: proc(m: ^Shell_Menu) {
	m.serial = 0
	m.ready = false
	m.invoked = 0
	shell_menu_icons_free(m)
	desktop.context_items_destroy(m.items, runtime.heap_allocator())
	m.items = nil
	desktop.context_menu_clear(&m.native)
}

// Stops the worker thread, frees items and GPU icon textures, and detaches any queued ui.post callback.
shell_menu_destroy :: proc(m: ^Shell_Menu) {
	// The worker first: a query on its way holds the gate without a reference of its own, and its answer locks it. Freed
	// before the join, that lock read freed memory and the join waited for ever (a right click, then the dialog closed).
	desktop.context_menu_destroy(&m.native)
	// Then detach the gate so any already-queued ui.post callback drops its items instead of touching `m`.
	g := m.gate
	m.gate = nil
	gate_release(g, true)
	shell_menu_icons_free(m)
	delete(m.icons)
	desktop.context_items_destroy(m.items, runtime.heap_allocator())
	m^ = {}
}
