package render

// Failures the system does not give on demand, for tests (-define:TOOLKIT_RENDER_FAULTS=true; off, fault_hit is false at compile
// time and nothing of this is in the program): the next calls of a kind fail as if the driver had refused them, so that the paths
// that handle it run. Per thread: tests run side by side.

RENDER_FAULTS :: #config(TOOLKIT_RENDER_FAULTS, false)

Fault :: enum {
	Create_Buffer,    // Direct3D 11: the instance buffer and the frame's tables refused
	Map,              // Direct3D 11: a dynamic buffer of the frame not mapped
	Capture_Map,      // WebGPU: capture_poll's map answers Failed
	Capture_Map_Late, // WebGPU: capture_poll's map is held back until fault_capture_map_answer
	Create_Device,    // recover: no device can be had
	Create_Swapchain, // Direct3D 11: a window's swap chain refused
	Acquire,          // WebGPU: the surface has no texture to give (a hidden window)
	Recreate_Texture, // recover: a texture cannot be made again
	Damage_Clear,     // the texture that clears a region refused
	Resize_Buffers,   // Direct3D 11: ResizeBuffers says the device is gone
	Composition,      // DirectComposition unavailable for a translucent window
}

@(private = "file", thread_local) fault_skip: [Fault]int
@(private = "file", thread_local) fault_count: [Fault]int
@(private = "file", thread_local) fault_fired_count: [Fault]int

// Past the next `skip` calls of this kind, the next `count` fail.
fault_arm :: proc(f: Fault, skip := 0, count := 1) {
	fault_skip[f], fault_count[f], fault_fired_count[f] = skip, count, 0
}

// How many calls failed since fault_arm.
fault_fired :: proc(f: Fault) -> int { return fault_fired_count[f] }

@(private)
fault_hit :: #force_inline proc(f: Fault) -> bool {
	when RENDER_FAULTS {
		if fault_skip[f] > 0 { fault_skip[f] -= 1; return false }
		if fault_count[f] <= 0 { return false }
		fault_count[f] -= 1
		fault_fired_count[f] += 1
		return true
	} else {
		return false
	}
}
