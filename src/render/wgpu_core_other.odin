#+build !windows
package render

import "core:time"

// A one-millisecond sleep while polling for a wgpu request.
@(private)
thread_sleep_1ms :: proc() { time.sleep(time.Millisecond) }

// No HLSL compiler to choose: Vulkan here.
@(private)
find_dxc :: proc() -> string { return "" }
