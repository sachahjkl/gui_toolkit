package tk_host

// The graphics device asked for at the process's start, before main (src/md/infrastructure/cpu-first-frames.md): its
// adapter answers while the program starts and its window opens, and the first frame on the CPU waits for that answer
// only (render.preload_adapter_wait). host_open then finds it being made and does not ask again.
//
// Not in a test process (the tests open their windows themselves, on the software device), not with
// -define:TOOLKIT_EARLY_DEVICE=false, nor with TOOLKIT_EARLY_DEVICE=0 in the environment. A program that ends before any
// window (a command line's answer) leaves the thread to the process's end. A program that wants another kind of device
// (WARP for a headless window) is given its own by its init, and this one is released.

// (required: in a test build, or with the define off, the init is empty)
@(require) import "base:runtime"
@(require) import "core:os"
@(require) import "../render"

EARLY_DEVICE :: #config(TOOLKIT_EARLY_DEVICE, true)

@(init, private = "file")
early_device :: proc "contextless" () {
	when EARLY_DEVICE && !ODIN_TEST {
		context = runtime.default_context()
		if os.get_env("TOOLKIT_EARLY_DEVICE", context.temp_allocator) == "0" { return }
		// (a host window's: transparent, in linear light, the format of the first pipelines)
		render.preload_device()
		free_all(context.temp_allocator)
	}
}
