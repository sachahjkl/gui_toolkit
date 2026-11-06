#+build linux
// Another program for tests/linux_desktop to drag with: a process of its own, that can be stopped or killed in the middle of a
// drag as a program that hangs or dies is.
//   drag_peer target: a window that takes every drop.
//   drag_peer source: a window that starts a drag at the first press.
package drag_peer

import "core:os"
import "../../../platform"

PEER_SIZE :: [2]int{300, 200}
PUMP_WAIT_MS :: 20
PEER_POS :: [2]int{700, 500}   // (on X11; a Wayland compositor places it)

main :: proc() {
	source := len(os.args) > 1 && os.args[1] == "source"
	w := platform.open_window("peer", PEER_SIZE)
	if w == nil { os.exit(1) }
	platform.show_window(w)
	platform.test_show_plain(w)
	platform.move_window(w, PEER_POS.x, PEER_POS.y)
	if !source { platform.drop_target_enable(w, true) }
	for !platform.is_closed(w) {
		for e in platform.poll_events(w, true, PUMP_WAIT_MS) {
			#partial switch e.kind {
			case .Drop_Enter: platform.drop_set_effect(w, .Copy)
			case .Mouse_Press:
				if source { platform.drag_start(w, platform.Drag_Data{text = "from the peer"}, {.Copy, .Move}) }
			}
		}
		if platform.take_paint_request(w) { platform.test_show_plain(w) }
	}
}
