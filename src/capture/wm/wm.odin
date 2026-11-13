// Package capture_wm: where the windows are, as a Wayland compositor's own IPC says (the Wayland protocols do not give
// a window's position). One provider per compositor, chosen from the environment: Hyprland (HYPRLAND_INSTANCE_SIGNATURE,
// "j/clients" and "j/monitors" on its socket), sway (SWAYSOCK, i3 IPC GET_TREE). The parsers are pure (the tests feed
// them fixed replies); the queries are in wm_linux.odin. A new compositor is one more Provider value, one procedure that
// queries it and one parser.
package capture_wm

import "base:runtime"
import "core:encoding/json"
import "core:slice"
import "core:strings"

Provider :: enum u8 {
	None,
	Hyprland,
	Sway,
}

// A window as the compositor's IPC says.
Window :: struct {
	id:      u64,        // the compositor's (Hyprland's address, sway's con id)
	title:   string,
	app_id:  string,     // Hyprland's class, sway's app_id (an X11 window's WM_CLASS class)
	rect:    [4]i32,     // x, y, width, height: logical, on the desktop; the visible frame
	visible: bool,       // on a workspace shown now, not hidden: its rect is on the screen
}

windows_destroy :: proc(list: []Window, allocator := context.allocator) {
	for w in list {
		delete(w.title, allocator)
		delete(w.app_id, allocator)
	}
	delete(list, allocator)
}

// Hyprland's replies to "j/clients" and "j/monitors" as windows, front to back (by focusHistoryID: the last focused first,
// an approximation of the stacking that Hyprland's IPC does not give). A window is visible when it is mapped, not hidden,
// and on a workspace a monitor shows (or pinned). ok is false when a reply is not what Hyprland sends.
hyprland_parse :: proc(clients, monitors: string, allocator := context.allocator) -> (list: []Window, ok: bool) {
	arena: runtime.Arena
	defer runtime.arena_destroy(&arena)
	scratch := runtime.arena_allocator(&arena)
	cv, cerr := json.parse_string(clients, allocator = scratch)
	if cerr != nil { return nil, false }
	mv, merr := json.parse_string(monitors, allocator = scratch)
	if merr != nil { return nil, false }
	carr, is_carr := cv.(json.Array)
	marr, is_marr := mv.(json.Array)
	if !is_carr || !is_marr { return nil, false }

	shown := make([dynamic]i64, scratch)
	for m in marr {
		mo, is_obj := m.(json.Object)
		if !is_obj { continue }
		if ws, has := mo["activeWorkspace"].(json.Object); has { append(&shown, num(ws["id"])) }
		if ws, has := mo["specialWorkspace"].(json.Object); has {
			if id := num(ws["id"]); id != 0 { append(&shown, id) }
		}
	}

	Ranked :: struct { w: Window, rank: i64 }
	ranked := make([dynamic]Ranked, scratch)
	for c in carr {
		co, is_obj := c.(json.Object)
		if !is_obj { continue }
		at, has_at := co["at"].(json.Array)
		size, has_size := co["size"].(json.Array)
		if !has_at || !has_size || len(at) < 2 || len(size) < 2 { continue }
		ws_id: i64
		if ws, has := co["workspace"].(json.Object); has { ws_id = num(ws["id"]) }
		visible := truth(co["mapped"], true) && !truth(co["hidden"], false) && (truth(co["pinned"], false) || slice.contains(shown[:], ws_id))
		w := Window{
			id = address_of(text(co["address"])),
			title = text(co["title"]),
			app_id = text(co["class"]),
			rect = {i32(num(at[0])), i32(num(at[1])), i32(num(size[0])), i32(num(size[1]))},
			visible = visible,
		}
		rank := num(co["focusHistoryID"])
		if rank < 0 { rank = max(i64) }   // (-1: never focused)
		append(&ranked, Ranked{w, rank})
	}
	slice.stable_sort_by(ranked[:], proc(a, b: Ranked) -> bool { return a.rank < b.rank })
	list = make([]Window, len(ranked), allocator)
	for r, i in ranked {
		list[i] = r.w
		list[i].title = strings.clone(r.w.title, allocator)
		list[i].app_id = strings.clone(r.w.app_id, allocator)
	}
	return list, true
}

// sway's reply to GET_TREE as windows, front to back: a workspace's floating windows before its tiled ones, and among
// siblings the order of their parent's `focus` list (the last focused first). ok is false when the reply is not a tree.
sway_parse :: proc(tree: string, allocator := context.allocator) -> (list: []Window, ok: bool) {
	arena: runtime.Arena
	defer runtime.arena_destroy(&arena)
	scratch := runtime.arena_allocator(&arena)
	v, err := json.parse_string(tree, allocator = scratch)
	if err != nil { return nil, false }
	root, is_obj := v.(json.Object)
	if !is_obj { return nil, false }
	found := make([dynamic]Window, scratch)
	sway_walk(root, &found, scratch)
	list = make([]Window, len(found), allocator)
	for w, i in found {
		list[i] = w
		list[i].title = strings.clone(w.title, allocator)
		list[i].app_id = strings.clone(w.app_id, allocator)
	}
	return list, true
}

@(private = "file")
sway_walk :: proc(node: json.Object, out: ^[dynamic]Window, scratch: runtime.Allocator) {
	nodes, _ := node["nodes"].(json.Array)
	floating, _ := node["floating_nodes"].(json.Array)
	if len(nodes) == 0 && len(floating) == 0 {
		kind := text(node["type"])
		if kind != "con" && kind != "floating_con" { return }
		// (a container without a client is an empty split, not a window)
		app_id := text(node["app_id"])
		if props, has := node["window_properties"].(json.Object); has && app_id == "" { app_id = text(props["class"]) }
		_, has_pid := node["pid"]
		if app_id == "" && !has_pid { return }
		r, _ := node["rect"].(json.Object)
		append(out, Window{
			id = u64(num(node["id"])),
			title = text(node["name"]),
			app_id = app_id,
			rect = {i32(num(r["x"])), i32(num(r["y"])), i32(num(r["width"])), i32(num(r["height"]))},
			visible = truth(node["visible"], false),
		})
		return
	}
	focus, _ := node["focus"].(json.Array)
	for group in ([2]json.Array{floating, nodes}) {
		// the children in focus order, then any the focus list does not name
		done := make([dynamic]bool, len(group), scratch)
		for f in focus {
			id := num(f)
			for c, i in group {
				co, is_obj := c.(json.Object)
				if !is_obj || done[i] || num(co["id"]) != id { continue }
				done[i] = true
				sway_walk(co, out, scratch)
			}
		}
		for c, i in group {
			if done[i] { continue }
			if co, is := c.(json.Object); is { sway_walk(co, out, scratch) }
		}
	}
}

// A number of the reply, whichever way json read it; 0 for anything else.
@(private)
num :: proc(v: json.Value) -> i64 {
	#partial switch n in v {
	case json.Integer: return n
	case json.Float:   return i64(n)
	}
	return 0
}

@(private)
text :: proc(v: json.Value) -> string {
	s, _ := v.(json.String)
	return s
}

@(private)
truth :: proc(v: json.Value, default: bool) -> bool {
	#partial switch b in v {
	case json.Boolean: return b
	case json.Integer: return b != 0   // (Hyprland's "fullscreen" and others went from bool to int)
	}
	return default
}

// Hyprland's "0x55d0c3a1b2c0" as a number; 0 when it is not hexadecimal.
@(private)
address_of :: proc(s: string) -> u64 {
	t := strings.trim_prefix(s, "0x")
	v: u64
	for c in transmute([]u8)t {
		d: u64
		switch c {
		case '0' ..= '9': d = u64(c - '0')
		case 'a' ..= 'f': d = u64(c - 'a' + 10)
		case 'A' ..= 'F': d = u64(c - 'A' + 10)
		case: return 0
		}
		v = v << 4 | d
	}
	return v
}
