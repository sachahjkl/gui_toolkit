package tk_desktop

// Pure logic and async lifecycle of desktop.Context_Menu: mnemonic stripping, canonical verb filtering, empty submenu
// and redundant separator pruning, and worker start/query/clear/destroy with zero leaks.

import "base:runtime"
import "core:sync"
import "core:testing"
import "core:time"

@(test)
context_menu_mnemonic_stripping :: proc(t: ^testing.T) {
	testing.expect_value(t, context_menu_strip_mnemonic("&Extract Here"), "Extract Here")
	testing.expect_value(t, context_menu_strip_mnemonic("Cut && &Paste\tCtrl+V"), "Cut & Paste")
	testing.expect_value(t, context_menu_strip_mnemonic("  &Open in Terminal  "), "Open in Terminal")
	testing.expect_value(t, context_menu_strip_mnemonic("&&&Archive"), "&Archive")
}

@(test)
context_menu_prunes_verbs_empty_submenus_and_separators :: proc(t: ^testing.T) {
	empty_kids := [?]Context_Item{
		{id = 1, label = "Open", verb = "open"},
		{separator = true},
		{id = 2, label = "Delete", verb = "DELETE"},
	}
	sub_kids := [?]Context_Item{
		{separator = true},
		{id = 10, label = "Extract here", verb = "extract"},
		{separator = true},
		{separator = true},
		{id = 11, label = "Add to archive...", verb = "archive"},
		{separator = true},
	}
	raw := [?]Context_Item{
		{separator = true},
		{id = 3, label = "Cut", verb = "cut"},
		{separator = true},
		{label = "Filtered Submenu", children = empty_kids[:]},
		{separator = true},
		{label = "7-Zip", children = sub_kids[:]},
		{separator = true},
		{separator = true},
		{id = 20, label = "Open with Code", verb = "VSCode"},
		{separator = true},
	}
	excluded := [?]string{"open", "cut", "delete"}
	pruned := context_items_prune(raw[:], excluded[:], context.allocator)
	defer context_items_destroy(pruned, context.allocator)

	// Leading/trailing/duplicate separators, excluded verbs, and the emptied submenu are all gone.
	testing.expect_value(t, len(pruned), 3)
	if len(pruned) == 3 {
		testing.expect_value(t, pruned[0].label, "7-Zip")
		testing.expect_value(t, len(pruned[0].children), 3)
		if len(pruned[0].children) == 3 {
			testing.expect_value(t, pruned[0].children[0].label, "Extract here")
			testing.expect(t, pruned[0].children[1].separator, "single separator kept between items")
			testing.expect_value(t, pruned[0].children[2].label, "Add to archive...")
		}
		testing.expect(t, pruned[1].separator, "single separator kept between submenu and next item")
		testing.expect_value(t, pruned[2].label, "Open with Code")
	}
}

@(test)
context_menu_worker_lifecycle :: proc(t: ^testing.T) {
	State :: struct {
		lock:   sync.Mutex,
		done:   sync.Cond,
		got:    bool,
		serial: u64,
		items:  []Context_Item,
	}
	st: State
	m: Context_Menu
	defer context_menu_destroy(&m)

	serial := context_menu_query(&m, {paths = {"/nonexistent/sample.txt"}}, proc(user: rawptr, serial: u64, items: []Context_Item) {
		st := (^State)(user)
		sync.lock(&st.lock)
		st.serial = serial
		st.items = items
		st.got = true
		sync.cond_signal(&st.done)
		sync.unlock(&st.lock)
	}, &st)
	testing.expect(t, serial > 0, "query returns positive serial")

	deadline := time.tick_add(time.tick_now(), 2 * time.Second)
	sync.lock(&st.lock)
	for !st.got && time.tick_diff(time.tick_now(), deadline) > 0 {
		_ = sync.cond_wait_with_timeout(&st.done, &st.lock, 50 * time.Millisecond)
	}
	got, got_serial, items := st.got, st.serial, st.items
	sync.unlock(&st.lock)

	defer context_items_destroy(items, runtime.heap_allocator())
	testing.expect(t, got, "worker called on_ready")
	testing.expect_value(t, got_serial, serial)
	context_menu_clear(&m)
}

@(test)
context_menu_bgra_to_rgba_modes :: proc(t: ^testing.T) {
	// 1. Opaque GDI bitmap (all alpha bytes 0): swaps B/R and sets alpha = 255.
	opaque := [8]u8{10, 20, 30, 0, 40, 50, 60, 0}
	context_menu_bgra_to_rgba(opaque[:])
	testing.expect_value(t, opaque, [8]u8{30, 20, 10, 255, 60, 50, 40, 255})

	// 2. Premultiplied PARGB bitmap (Vista+ shell menu icon): swaps B/R and un-premultiplies to straight RGBA.
	pargb := [8]u8{64, 32, 128, 128, 0, 0, 0, 0}
	context_menu_bgra_to_rgba(pargb[:])
	testing.expect_value(t, pargb[0], u8(255))
	testing.expect_value(t, pargb[1], u8(64))
	testing.expect_value(t, pargb[2], u8(128))
	testing.expect_value(t, pargb[3], u8(128))
	testing.expect_value(t, pargb[7], u8(0))

	// 3. Straight ARGB (channel > alpha): swaps B/R and leaves RGB intact.
	straight := [4]u8{20, 40, 200, 100}
	context_menu_bgra_to_rgba(straight[:])
	testing.expect_value(t, straight, [4]u8{200, 40, 20, 100})
}

@(test)
context_items_preserve_and_free_icons :: proc(t: ^testing.T) {
	px1 := [4]u8{255, 0, 0, 255}
	px2 := [4]u8{0, 255, 0, 255}
	kids := [?]Context_Item{
		{id = 2, label = "Child", icon = {rgba = px2[:], size = {1, 1}}},
	}
	raw := [?]Context_Item{
		{id = 1, label = "Leaf", icon = {rgba = px1[:], size = {1, 1}}},
		{label = "Sub", icon = {rgba = px1[:], size = {1, 1}}, children = kids[:]},
	}
	cloned := context_items_clone(raw[:], context.allocator)
	defer context_items_destroy(cloned, context.allocator)
	testing.expect_value(t, cloned[0].icon.size, [2]int{1, 1})
	testing.expect_value(t, cloned[0].icon.rgba[0], u8(255))
	testing.expect_value(t, cloned[1].icon.size, [2]int{1, 1})
	testing.expect_value(t, cloned[1].children[0].icon.rgba[1], u8(255))

	pruned := context_items_prune(raw[:], nil, context.allocator)
	defer context_items_destroy(pruned, context.allocator)
	testing.expect_value(t, len(pruned), 2)
	testing.expect_value(t, pruned[0].icon.size, [2]int{1, 1})
	testing.expect_value(t, pruned[1].children[0].icon.rgba[1], u8(255))
}
