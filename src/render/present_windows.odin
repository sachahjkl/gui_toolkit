package render

import "core:time"
import win "core:sys/windows"

// The system has Direct3D (11 and 12): the default renderer is Direct3D 11, wgpu's default backend DX12.
SYSTEM_DIRECT3D :: true

// The QueryPerformanceCounter value `qpc` on core:time's tick scale (what time.tick_now returns on Windows).
qpc_to_tick :: proc(qpc: i64) -> time.Tick {
	freq: win.LARGE_INTEGER   // (fixed at boot: the system reads it from memory it shares with the process)
	win.QueryPerformanceFrequency(&freq)
	f := i64(freq)
	if f == 0 { return {} }
	return time.Tick{_nsec = (qpc / f) * 1e9 + (qpc % f) * 1e9 / f}
}

// The surplus the latency object holds, consumed without waiting (latency_lowered says why).
@(private)
latency_drain :: proc(p: ^Present_State, handle: win.HANDLE) {
	for p.latency_debt > 0 && handle != nil && win.WaitForSingleObject(handle, 0) == win.WAIT_OBJECT_0 { p.latency_debt -= 1 }
}
