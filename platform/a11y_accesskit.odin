#+build windows
package platform

// The Windows adapter: AccessKit's UI Automation provider (native/a11y, gt_a11y.lib), compiled in with
// -define:A11Y_ACCESSKIT=true. A program that has a Rust library of its own builds gt_a11y into it (as a dependency:
// its gt_a11y_* functions stay exported) and builds with -define:A11Y_NATIVE_LINK=false (as for the text backend).

import "core:fmt"
import win "core:sys/windows"

A11Y_ACCESSKIT :: #config(A11Y_ACCESSKIT, false)
A11Y_NATIVE_LINK :: #config(A11Y_NATIVE_LINK, true)

// The window message the adapter's wake posts (from any thread): the window procedure queues an .Accessibility event.
@(private) A11Y_MESSAGE :: win.WM_APP + 0x3A2

when A11Y_ACCESSKIT {

when !A11Y_NATIVE_LINK {
	foreign import gt_a11y "system:kernel32.lib"   // the symbols come from the program's own Rust library
} else {
	foreign import gt_a11y {
		"../build/a11y/gt_a11y.lib",
		"system:ntdll.lib",
		"system:userenv.lib",
		"system:ws2_32.lib",
		"system:bcrypt.lib",
		"system:advapi32.lib",
		"system:kernel32.lib",
		"system:dbghelp.lib",
		"system:ole32.lib",
		"system:oleaut32.lib",
		"system:uiautomationcore.lib",
		"system:user32.lib",
	}
}

@(private) GT_A11Y_ABI :: 1

@(private) Gt_Adapter :: struct {}

@(private)
Gt_Update :: struct {
	nodes:       [^]A11y_Node,
	node_count:  uint,
	ids:         [^]u64,
	id_count:    uint,
	props:       [^]A11y_Prop,
	prop_count:  uint,
	bytes:       [^]u8,
	byte_count:  uint,
	floats:      [^]f32,
	float_count: uint,
	root, focus: u64,
	tree_id:     [16]u8,
	tree_info:   u32,
	_:           u32,
	toolkit_name: [^]u8,
	toolkit_name_len: uint,
	toolkit_version: [^]u8,
	toolkit_version_len: uint,
}

@(private)
Gt_Action :: struct {
	action:      u32,
	data_kind:   u32,
	target_node: u64,
	tree_id:     [16]u8,
	num, x, y:   f64,
	value:       [^]u8,
	value_len:   uint,
	sel:         [4]u64,
}

@(default_calling_convention = "c", private)
foreign gt_a11y {
	gt_a11y_abi :: proc() -> u32 ---
	gt_a11y_new :: proc(window: rawptr, focused: i32, wake: proc "c" (user: rawptr), wake_user: rawptr) -> ^Gt_Adapter ---
	gt_a11y_free :: proc(a: ^Gt_Adapter) ---
	gt_a11y_wm_getobject :: proc(a: ^Gt_Adapter, wparam: uint, lparam: int, result: ^int) -> i32 ---
	gt_a11y_state :: proc(a: ^Gt_Adapter) -> i32 ---
	gt_a11y_update :: proc(a: ^Gt_Adapter, u: ^Gt_Update) -> i32 ---
	gt_a11y_window_focus :: proc(a: ^Gt_Adapter, focused: i32) ---
	gt_a11y_take_action :: proc(a: ^Gt_Adapter, out: ^Gt_Action) -> i32 ---
}

@(private) a11y_abi_checked: int   // 0 not yet, 1 matches, -1 another ABI: the adapter stays off

// Whether this build reads its windows to assistive technologies (the adapter is compiled in).
a11y_available :: proc() -> bool { return true }

@(private)
a11y_wake :: proc "c" (user: rawptr) {
	win.PostMessageW(win.HWND(user), A11Y_MESSAGE, 0, 0)
}

@(private)
a11y_attach :: proc(w: ^Window) {
	if a11y_abi_checked == 0 { a11y_abi_checked = gt_a11y_abi() == GT_A11Y_ABI ? 1 : -1 }
	if a11y_abi_checked < 0 { return }
	w.a11y = gt_a11y_new(rawptr(w.hwnd), w.focused ? 1 : 0, a11y_wake, rawptr(w.hwnd))
}

@(private)
a11y_detach :: proc(w: ^Window) {
	if w.a11y != nil { gt_a11y_free((^Gt_Adapter)(w.a11y)); w.a11y = nil }
}

@(private)
a11y_wm_getobject :: proc(w: ^Window, wparam: win.WPARAM, lparam: win.LPARAM) -> (win.LRESULT, bool) {
	if w.a11y == nil { return 0, false }
	r: int
	if gt_a11y_wm_getobject((^Gt_Adapter)(w.a11y), uint(wparam), int(lparam), &r) != 0 { return win.LRESULT(r), true }
	return 0, false
}

@(private)
a11y_window_focus :: proc(w: ^Window, focused: bool) {
	if w.a11y != nil { gt_a11y_window_focus((^Gt_Adapter)(w.a11y), focused ? 1 : 0) }
}

// What the window's adapter needs now (see A11y_State). Cheap: call it every frame.
a11y_state :: proc(w: ^Window) -> A11y_State {
	if w == nil || w.a11y == nil { return .Off }
	switch gt_a11y_state((^Gt_Adapter)(w.a11y)) {
	case 1:
		return .Full
	case 2:
		// (once a client asked, the tree is kept up to date: UiaClientsAreListening only tells of clients that subscribed
		// to events, and one that only asks, such as Inspect or a test, would read a tree left behind)
		return .Incremental
	}
	return .Off
}

// Hands an update over to the window's adapter (the toolkit's own name and version go with a whole tree).
a11y_send :: proc(w: ^Window, u: ^A11y_Update, toolkit_name := "gui_toolkit", toolkit_version := "") -> A11y_Send {
	if w == nil || w.a11y == nil { return .Inactive }
	g := Gt_Update{
		nodes = raw_data(u.nodes), node_count = uint(len(u.nodes)),
		ids = raw_data(u.ids), id_count = uint(len(u.ids)),
		props = raw_data(u.props), prop_count = uint(len(u.props)),
		bytes = raw_data(u.bytes), byte_count = uint(len(u.bytes)),
		floats = raw_data(u.floats), float_count = uint(len(u.floats)),
		root = u.root, focus = u.focus, tree_id = ([16]u8)(u.tree), tree_info = u.tree_info ? 1 : 0,
		toolkit_name = raw_data(toolkit_name), toolkit_name_len = uint(len(toolkit_name)),
		toolkit_version = raw_data(toolkit_version), toolkit_version_len = uint(len(toolkit_version)),
	}
	switch gt_a11y_update((^Gt_Adapter)(w.a11y), &g) {
	case 1:  return .Applied
	case 0:  return .Inactive
	case -1:
		when ODIN_DEBUG { fmt.eprintln("a11y: an update was refused (it breaks the tree)") }
		return .Invalid
	}
	return .Failed
}

// The oldest request of an assistive technology not taken yet (ok = false: none). Its value stays valid until the
// next call.
a11y_take_request :: proc(w: ^Window) -> (r: A11y_Request, ok: bool) {
	if w == nil || w.a11y == nil { return }
	a: Gt_Action
	if gt_a11y_take_action((^Gt_Adapter)(w.a11y), &a) == 0 { return }
	if a.action > u32(max(A11y_Action)) { return }
	r.action = A11y_Action(a.action)
	r.data = a.data_kind <= u32(max(A11y_Request_Data)) ? A11y_Request_Data(a.data_kind) : .None
	r.target = a.target_node
	r.tree = A11y_Tree_Id(a.tree_id)
	r.num = a.num
	r.point = {a.x, a.y}
	if a.value != nil { r.value = string(a.value[:a.value_len]) }
	r.sel = a.sel
	return r, true
}

} else {

a11y_available :: proc() -> bool { return false }
@(private) a11y_attach :: proc(w: ^Window) {}
@(private) a11y_detach :: proc(w: ^Window) {}
@(private) a11y_wm_getobject :: proc(w: ^Window, wparam: win.WPARAM, lparam: win.LPARAM) -> (win.LRESULT, bool) { return 0, false }
@(private) a11y_window_focus :: proc(w: ^Window, focused: bool) {}
a11y_state :: proc(w: ^Window) -> A11y_State { return .Off }
a11y_send :: proc(w: ^Window, u: ^A11y_Update, toolkit_name := "gui_toolkit", toolkit_version := "") -> A11y_Send { return .Inactive }
a11y_take_request :: proc(w: ^Window) -> (r: A11y_Request, ok: bool) { return }

}

_ :: fmt
