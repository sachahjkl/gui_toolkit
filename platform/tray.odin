package platform

// An icon in the notification area (the "system tray"), behind an API of our own (Windows: tray_win32.odin,
// Shell_NotifyIconW version 4; other systems: tray_stub.odin answers "not supported").
//
//   * tray_create(window, png, tooltip) adds the icon; the window receives its notifications (the window may be
//     hidden). tray_destroy removes it; destroy_window removes the icons of the window.
//   * What the user does with it is read with tray_poll(tray) after poll_events (each call hands out what came since the
//     previous one): clicks, double clicks, right clicks, the item chosen in its menu, the notification shown, clicked
//     or gone.
//   * tray_set_menu gives the menu a right click (or the menu key) opens by itself (auto_menu, on by default): items,
//     separators, check and radio marks, disabled and default items, submenus. The chosen item comes as Menu_Item with
//     its id; tray_show_menu opens it from the app (a left click, say).
//   * tray_notify shows a notification (a balloon, a toast on Windows 10 and 11) from the icon.
//   * When the shell restarts (explorer.exe crashed or was restarted) the icons are added again, with their tooltip, and
//     a Recreated event says so.
//
// Icons are PNG files' bytes (nil: the exe's own icon) or RGBA pixels (tray_set_icon_rgba).

Tray_Event_Kind :: enum u8 {
	None,
	Click,           // left click, or Enter / Space on the icon (`keyboard`)
	Double_Click,
	Right_Click,     // right click or the menu key (`keyboard`): auto_menu opens the menu after it
	Middle_Click,
	Menu_Item,       // an item of the menu was chosen: `item` is its id
	Notify_Shown,    // the notification of tray_notify appeared
	Notify_Click,    // the user clicked it
	Notify_Timeout,  // it went away by itself
	Notify_Hidden,   // it was removed (another one replaced it, the icon went away)
	Hover_Open,      // the pointer rests on the icon (the system shows the tooltip unless the app draws its own)
	Hover_Close,
	Recreated,       // the shell restarted and the icon was added again
}

Tray_Event :: struct {
	kind:     Tray_Event_Kind,
	item:     int,       // Menu_Item: the item's id
	pos:      [2]i32,    // screen pixels: where the click or the anchor was (place a popup of the app there)
	keyboard: bool,      // Click / Right_Click came from the keyboard
}

Tray_Item_Kind :: enum u8 { Item, Separator, Check, Radio }

// One entry of a tray menu. `children` makes it a submenu (its own id is unused then).
Tray_Menu_Item :: struct {
	id:       int,
	text:     string,
	kind:     Tray_Item_Kind,
	checked:  bool,       // Check / Radio
	disabled: bool,
	default:  bool,       // shown in bold: what a double click on the icon would do
	children: []Tray_Menu_Item,
}

Tray_Notify_Icon :: enum u8 { None, Info, Warning, Error, App }

Tray_Notify :: struct {
	title:  string,
	body:   string,
	icon:   Tray_Notify_Icon,
	silent: bool,               // no sound
	respect_quiet_time: bool,   // not shown during the first hour after a user's first login, nor in "do not disturb"
}

// What a tray asked the system to do (tray_test_hook).
Tray_Op :: enum u8 { Add, Modify, Delete, Set_Version, Notify }

Tray :: struct {
	using native: Native_Tray,
	window:    ^Window,
	id:        u32,
	tooltip:   string,
	menu:      [dynamic]Tray_Menu_Item,   // a deep copy (tray_set_menu)
	auto_menu: bool,                      // a right click opens the menu (default true)
	events:    [dynamic]Tray_Event,
	returned:  int,                       // events handed out by the last tray_poll
	added:     bool,                      // the system shows it
}

// Test hook: when set, the calls to the system (add, modify, delete, notify) go to it instead, so tests drive the whole
// logic without an icon on the desktop. The result stands for the system's answer.
tray_test_hook: proc(op: Tray_Op, t: ^Tray) -> bool

// The events since the previous call (valid until the next one).
tray_poll :: proc(t: ^Tray) -> []Tray_Event {
	if t == nil { return nil }
	n := min(t.returned, len(t.events))
	if n > 0 {
		copy(t.events[:], t.events[n:])
		resize(&t.events, len(t.events) - n)
	}
	t.returned = len(t.events)
	return t.events[:]
}

// The menu a right click opens (a deep copy: the caller keeps its items). Empty: no menu.
tray_set_menu :: proc(t: ^Tray, items: []Tray_Menu_Item) {
	if t == nil { return }
	tray_menu_free(t.menu[:])
	clear(&t.menu)
	for it in items { append(&t.menu, tray_item_clone(it)) }
}

// The item of a menu with that id, submenus included (nil when there is none).
tray_menu_find :: proc(items: []Tray_Menu_Item, id: int) -> ^Tray_Menu_Item {
	for &it in items {
		if len(it.children) > 0 {
			if f := tray_menu_find(it.children, id); f != nil { return f }
		} else if it.kind != .Separator && it.id == id {
			return &it
		}
	}
	return nil
}

@(private)
tray_item_clone :: proc(it: Tray_Menu_Item) -> Tray_Menu_Item {
	out := it
	out.text = clone_string(it.text)
	if len(it.children) > 0 {
		out.children = make([]Tray_Menu_Item, len(it.children))
		for c, i in it.children { out.children[i] = tray_item_clone(c) }
	}
	return out
}

@(private)
tray_menu_free :: proc(items: []Tray_Menu_Item) {
	for it in items {
		delete(it.text)
		tray_menu_free(it.children)
		delete(it.children)
	}
}

@(private)
tray_free :: proc(t: ^Tray) {
	tray_menu_free(t.menu[:])
	delete(t.menu)
	delete(t.events)
	delete(t.tooltip)
	free(t)
}

@(private)
tray_push :: proc(t: ^Tray, e: Tray_Event) { append(&t.events, e) }
