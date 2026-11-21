package file_browser_test

import "base:runtime"
import "core:testing"
import desktop "gt:desktop"
import "gt:testkit/session"
import "gt:ui"

// ui.Shell_Menu: fresh serial applies and renders items, submenus, and bitmap icons; stale serial is dropped; click
// returns the chosen id; destroying Shell_Menu with a queued ui.post result drops it safely.
@(test)
shell_menu_apply_render_click_and_stale :: proc(t: ^testing.T) {
	Holder :: struct {
		sm:      ui.Shell_Menu,
		opened:  bool,
		clicked: u32,
	}
	h: Holder
	defer ui.shell_menu_destroy(&h.sm)

	build :: proc(s: ^session.Session) {
		h := (^Holder)(s.user)
		if !h.opened {
			h.opened = true
			ui.menu_open("###sm_test", ui.Vec2{20, 20})
		}
		if ui.menu("###sm_test") {
			_ = ui.menu_item("Built-in###bi")
			if id := ui.shell_menu_items(&h.sm, "sh", separator = true, invoke = false); id != 0 {
				h.clicked = id
			}
		}
	}

	s := session.start(t, {build = build, user = &h, no_renderer = true, size = {600, 400}})
	session.frames(s, 2)

	// Seed a serial and verify stale serial is ignored and freed cleanly.
	h.sm.state = s.state
	h.sm.serial = 5
	a := runtime.heap_allocator()
	stale := [?]desktop.Context_Item{{id = 99, label = "Stale Action"}}
	ui.shell_menu_apply(&h.sm, 4, desktop.context_items_clone(stale[:], a))
	testing.expect(t, !h.sm.ready && len(h.sm.items) == 0, "stale serial dropped")

	// Apply matching serial with an icon on a leaf and a submenu.
	px := [4]u8{255, 128, 0, 255}
	sub_kids := [?]desktop.Context_Item{{id = 12, label = "Extract Here"}}
	fresh := [?]desktop.Context_Item{
		{id = 7, label = "Open with Code", icon = {rgba = px[:], size = {1, 1}}},
		{label = "7-Zip", icon = {rgba = px[:], size = {1, 1}}, children = sub_kids[:]},
	}
	ui.shell_menu_apply(&h.sm, 5, desktop.context_items_clone(fresh[:], a))
	testing.expect(t, h.sm.ready && len(h.sm.items) == 2, "fresh items applied")
	session.frames(s, 2)

	// Menu shows the shell leaf and submenu; clicking the leaf returns id 7.
	testing.expect(t, session.find_text(s, "Open with Code") != nil, "shell leaf item built")
	testing.expect(t, session.find_text(s, "7-Zip") != nil, "shell submenu item built")
	session.click(s, "mi_1_sh_0")
	testing.expect_value(t, h.clicked, u32(7))
	testing.expect_value(t, h.sm.invoked, u32(7))

	ui.shell_menu_clear(&h.sm)
	testing.expect(t, !h.sm.ready && len(h.sm.items) == 0, "clear resets items")
}

// Destroying Shell_Menu while an async query is in flight or posted to ui.post must never crash or leak.
@(test)
shell_menu_destroy_while_query_in_flight :: proc(t: ^testing.T) {
	build :: proc(s: ^session.Session) { _ = s }
	s := session.start(t, {build = build, user = nil, no_renderer = true, size = {400, 300}})
	session.frames(s, 1)

	sm: ui.Shell_Menu
	serial := ui.shell_menu_query(&sm, s.state, {paths = {"/nonexistent/shell_menu_race.txt"}})
	testing.expect(t, serial > 0, "query started")
	// Destroy immediately (joining worker while any posted callback may still sit in s.state.posts).
	ui.shell_menu_destroy(&sm)
	// Drain queued posts on the next frames: detached gate drops the items cleanly.
	session.frames(s, 3)
}
