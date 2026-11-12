// The compositor IPC parsers of capture/wm, fed fixed replies: no compositor needed.
package capture_test

import "core:testing"
import wm "../../src/capture/wm"

HYPR_MONITORS :: `[
 {"id": 0, "name": "DP-1", "activeWorkspace": {"id": 1, "name": "1"}, "specialWorkspace": {"id": 0, "name": ""}},
 {"id": 1, "name": "HDMI-A-1", "activeWorkspace": {"id": 4, "name": "4"}, "specialWorkspace": {"id": -98, "name": "special:magic"}}
]`

HYPR_CLIENTS :: `[
 {"address": "0x55d0c3a1b2c0", "mapped": true, "hidden": false, "at": [10, 20], "size": [800, 600],
  "workspace": {"id": 1, "name": "1"}, "class": "foot", "title": "shell", "pinned": false, "fullscreen": 0, "focusHistoryID": 2},
 {"address": "0xABC", "mapped": true, "hidden": false, "at": [1930, 40], "size": [400, 300],
  "workspace": {"id": 4, "name": "4"}, "class": "firefox", "title": "web", "pinned": false, "fullscreen": 0, "focusHistoryID": 0},
 {"address": "0x1", "mapped": true, "hidden": false, "at": [0, 0], "size": [100, 100],
  "workspace": {"id": 2, "name": "2"}, "class": "hidden-ws", "title": "", "pinned": false, "focusHistoryID": 1},
 {"address": "0x2", "mapped": true, "hidden": false, "at": [5, 5], "size": [50, 50],
  "workspace": {"id": 3, "name": "3"}, "class": "pinned", "title": "", "pinned": true, "focusHistoryID": -1},
 {"address": "0x3", "mapped": true, "hidden": false, "at": [7, 7], "size": [70, 70],
  "workspace": {"id": -98, "name": "special:magic"}, "class": "scratch", "title": "", "focusHistoryID": 3}
]`

@(test)
hyprland_orders_by_focus_and_says_visible :: proc(t: ^testing.T) {
	list, ok := wm.hyprland_parse(HYPR_CLIENTS, HYPR_MONITORS)
	defer wm.windows_free(list)
	testing.expect(t, ok)
	if !testing.expect_value(t, len(list), 5) { return }
	testing.expect_value(t, list[0].app_id, "firefox")
	testing.expect_value(t, list[0].id, 0xabc)
	testing.expect_value(t, list[0].rect, [4]i32{1930, 40, 400, 300})
	testing.expect(t, list[0].visible)
	testing.expect_value(t, list[1].app_id, "hidden-ws")
	testing.expect(t, !list[1].visible)
	testing.expect_value(t, list[2].app_id, "foot")
	testing.expect_value(t, list[2].id, 0x55d0c3a1b2c0)
	testing.expect_value(t, list[2].title, "shell")
	testing.expect(t, list[2].visible)
	testing.expect_value(t, list[3].app_id, "scratch")   // (a special workspace that a monitor shows)
	testing.expect(t, list[3].visible)
	testing.expect_value(t, list[4].app_id, "pinned")    // (never focused: last)
	testing.expect(t, list[4].visible)
}

@(test)
hyprland_refuses_what_it_does_not_send :: proc(t: ^testing.T) {
	_, ok := wm.hyprland_parse(`{"error": "x"}`, HYPR_MONITORS)
	testing.expect(t, !ok)
	_, ok = wm.hyprland_parse(HYPR_CLIENTS, `not json`)
	testing.expect(t, !ok)
}

SWAY_TREE :: `{"id": 1, "type": "root", "nodes": [
 {"id": 2, "type": "output", "name": "DP-1", "focus": [3], "nodes": [
  {"id": 3, "type": "workspace", "name": "1", "focus": [6, 4, 5],
   "nodes": [
    {"id": 4, "type": "con", "name": "term", "app_id": "foot", "pid": 10, "visible": true,
     "rect": {"x": 0, "y": 30, "width": 960, "height": 1050}, "nodes": [], "floating_nodes": []},
    {"id": 5, "type": "con", "name": "xterm", "app_id": null, "pid": 11, "visible": true,
     "window_properties": {"class": "XTerm"},
     "rect": {"x": 960, "y": 30, "width": 960, "height": 1050}, "nodes": [], "floating_nodes": []},
    {"id": 7, "type": "con", "name": null, "visible": false,
     "rect": {"x": 0, "y": 0, "width": 0, "height": 0}, "nodes": [], "floating_nodes": []}
   ],
   "floating_nodes": [
    {"id": 6, "type": "floating_con", "name": "float", "app_id": "pavucontrol", "pid": 12, "visible": true,
     "rect": {"x": 100, "y": 100, "width": 400, "height": 300}, "nodes": [], "floating_nodes": []}
   ]}
 ]}
]}`

@(test)
sway_floating_first_then_focus_order :: proc(t: ^testing.T) {
	list, ok := wm.sway_parse(SWAY_TREE)
	defer wm.windows_free(list)
	testing.expect(t, ok)
	if !testing.expect_value(t, len(list), 3) { return }   // (the empty container is not a window)
	testing.expect_value(t, list[0].app_id, "pavucontrol")
	testing.expect_value(t, list[0].rect, [4]i32{100, 100, 400, 300})
	testing.expect_value(t, list[1].app_id, "foot")
	testing.expect_value(t, list[1].id, 4)
	testing.expect_value(t, list[2].app_id, "XTerm")   // (an X11 window: its class)
	testing.expect_value(t, list[2].title, "xterm")
	for w in list { testing.expect(t, w.visible) }
}

@(test)
sway_refuses_what_is_not_a_tree :: proc(t: ^testing.T) {
	_, ok := wm.sway_parse(`[1, 2]`)
	testing.expect(t, !ok)
	_, ok = wm.sway_parse(``)
	testing.expect(t, !ok)
}
