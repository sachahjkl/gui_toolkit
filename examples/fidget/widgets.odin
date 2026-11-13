package fidget

// Two widgets of this gallery's own, built from the toolkit's boxes: no other program has needed them.

import "core:fmt"
import "core:math"
import "../../src/ui"

// Toggle chips: bit i of `mask` is chip i. They wrap onto more lines when there is not enough room. True when `mask`
// changed this frame.
chips :: proc(id: string, labels: []string, mask: ^u32) -> (changed: bool) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.flow({em * 0.45, em * 0.45}) {
		for label, i in labels {
			on := mask^ & (1 << u32(i)) != 0
			// (a raised button's tags: on, the primary one's)
			tag := ui.intent_tag(on ? .Primary : .Neutral)
			if tag != "" { ui.push_tags("button", tag) } else { ui.push_tags("button") }
			ui.next({width = ui.text_size(em * 0.5, 0.6), height = ui.px(ui.dense(em * 1.9)), radius = em * 0.95, text_align = .Center})
			b := ui.build_box({.Clickable, .Focusable, .Draw_Text, .Draw_Background, .Draw_Border, .Draw_Hot_Effects}, fmt.tprintf("%s###%s_%d", label, id, i))
			ui.pop_tags()
			if ui.signal(b).clicked { mask^ ~= (1 << u32(i)); changed = true }
			ui.a11y_default(b, {role = .Button, toggled = mask^ & (1 << u32(i)) != 0 ? .True : .False})
		}
	}
	return
}

RATING_MAX :: 5
RATING_GROW_RATE :: 40
RATING_GROW_SCALE :: 0.35

// Five marks; a click on the current value again clears it. True when `value` changed this frame.
rating :: proc(id: string, value: ^int) -> (changed: bool) {
	em := ui.font_size()
	before := value^
	ui.next({axis = .X})
	box := ui.build_box({}, id)
	if v, ok := ui.a11y_numeric_request(box.key, f32(value^), 1); ok { value^ = clamp(int(math.round(v)), 0, RATING_MAX) }
	defer ui.a11y_default(box, {role = .Slider, numeric = f64(value^), min = 0, max = RATING_MAX, step = 1, value = fmt.aprintf("%d / %d", value^, RATING_MAX, allocator = ui.frame_allocator())})
	if ui.parent(box) {
		for i in 0 ..< RATING_MAX {
			cell_id := fmt.tprintf("%s_%d", id, i)
			prev := ui.box_from_key(ui.key_from_string(box.key, cell_id))
			grow := ui.anim(ui.key_from_string(box.key, fmt.tprintf("%s_g", cell_id)), prev != nil ? prev.hot_t : 0, RATING_GROW_RATE)
			lit := i < value^
			if !lit { ui.push_tags("weak") }
			ui.next({width = ui.px(em * 2), height = ui.pct(1), font = ui.widget_icons(), font_size = em * (1 + RATING_GROW_SCALE * grow), text_align = .Center})
			b := ui.build_box({.Clickable, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###%s", lit ? ui.ICON_RADIO_ON : ui.ICON_RADIO, cell_id))
			if !lit { ui.pop_tags() }
			if ui.signal(b).clicked { value^ = value^ == i + 1 ? 0 : i + 1 }
		}
	}
	return value^ != before
}
