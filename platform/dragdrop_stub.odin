#+build !windows
package platform

// Drag and drop on the systems that have no implementation yet (dragdrop.odin has the API): every call answers "not
// supported", so an app written for it builds and runs, without drops.

drop_target_enable :: proc(w: ^Window, on: bool) -> bool { return !on }
drop_target_enabled :: proc(w: ^Window) -> bool { return false }
drop_data :: proc(w: ^Window) -> ^Drag_Data { return nil }
drop_active :: proc(w: ^Window) -> bool { return false }
drop_set_effect :: proc(w: ^Window, effect: Maybe(Drop_Effect)) {}
drop_data_release :: proc(w: ^Window) {}
drop_inject :: proc(w: ^Window, kind: Event_Kind, pos: [2]f32, data: ^Drag_Data = nil, allowed: Drop_Effects = {.Copy, .Move, .Link}, mods: Modifiers = {}) -> bool { return false }

Drag_Image :: struct {
	rgba:   []u8,
	size:   [2]int,
	offset: [2]int,
}

drag_start :: proc(w: ^Window, data: Drag_Data, allowed: Drop_Effects, image: Maybe(Drag_Image) = nil) -> (effect: Maybe(Drop_Effect), ok: bool) { return nil, false }
drag_threshold :: proc(w: ^Window) -> [2]f32 { return {4, 4} }
drag_sending :: proc(w: ^Window) -> bool { return false }
drop_self_test :: proc(w: ^Window, data: Drag_Data, pos: [2]f32, allowed: Drop_Effects) -> bool { return false }
