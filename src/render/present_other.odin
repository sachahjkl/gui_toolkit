#+build !windows
package render

import "core:time"
import win "core:sys/windows"
import "../platform"

// No Direct3D here: the renderer is wgpu over Vulkan.
SYSTEM_DIRECT3D :: false

// No QueryPerformanceCounter here: no tick.
qpc_to_tick :: proc(qpc: i64) -> time.Tick { return {} }

// No latency object here: nothing to drain.
@(private)
latency_drain :: proc(p: ^Present_State, handle: win.HANDLE) {}

// No latency object here: the slot is always free.
@(private)
latency_take :: proc(p: ^Present_State, handle: win.HANDLE, timeout_ms: int, w: ^platform.Window = nil, until_press := false) -> bool {
	p.slot_taken = true
	return true
}
