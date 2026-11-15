package render

import "core:fmt"
import "core:strings"

// Why init, init_window or init_offscreen returned false, in words a person can act on. A machine with no graphics
// driver must end with a sentence, not a crash: src/md/infrastructure/no-graphics.md.

Init_Error :: enum u8 {
	None,
	No_Driver,   // the graphics API found no device: no driver, or one the program cannot load
	No_Window,   // a device exists but cannot draw into this window
	Failed,      // the device, its swap chain or its pipelines failed after the driver answered
}

@(private) INIT_DETAIL_BYTES :: 256

// Kept in the Renderer after a failed init (the rest of it is released). A fixed buffer: the device is made on a thread
// of its own, and the failure must outlive that thread's allocations.
Init_Failure :: struct {
	error:      Init_Error,
	detail:     [INIT_DETAIL_BYTES]u8,   // the driver's words, cut to fit
	detail_len: int,
}

// The graphics API the renderer draws with, as a person knows it.
graphics_api :: proc() -> string {
	when USE_WGPU {
		return WGPU_BACKEND == "vulkan" ? "Vulkan" : "Direct3D 12"
	} else {
		return "Direct3D 11"
	}
}

// Why the last init of `r` failed. `detail` points into `r`.
init_failure :: proc(r: ^Renderer) -> (error: Init_Error, detail: string) {
	return r.failure.error, string(r.failure.detail[:r.failure.detail_len])
}

// The sentence for a person: what is missing, the driver's words, what to install. "" when init did not fail.
init_failure_text :: proc(r: ^Renderer, allocator := context.allocator) -> string {
	error, detail := init_failure(r)
	return init_failure_sentence(error, detail, allocator)
}

@(private)
init_failure_sentence :: proc(error: Init_Error, detail: string, allocator := context.allocator) -> string {
	api := graphics_api()
	why := detail != "" ? fmt.tprintf(": %s", detail) : ""
	switch error {
	case .None:
		return ""
	case .No_Driver:
		return fmt.aprintf("no graphics device this program can draw with (%s)%s. %s", api, why, INSTALL_HINT, allocator = allocator)
	case .No_Window:
		return fmt.aprintf("the graphics device (%s) cannot draw into this window%s. %s", api, why, INSTALL_HINT, allocator = allocator)
	case .Failed:
		return fmt.aprintf("the graphics device (%s) failed to start%s. %s", api, why, INSTALL_HINT, allocator = allocator)
	}
	return ""
}

// (what a person does about it differs by system: a package to install on Linux, an update on Windows)
@(private)
INSTALL_HINT :: "Install your system's Vulkan driver (the package mesa-vulkan-drivers on Debian and Ubuntu)." when ODIN_OS == .Linux else
	"Update the graphics driver (Windows Update, or the site of the graphics card's maker)." when ODIN_OS == .Windows else
	"Install a graphics driver."

// Records why init fails; false, for `return init_fail(...)`. Only the init paths call it: a recovery reports through `lost`.
@(private)
init_fail :: proc(r: ^Renderer, error: Init_Error, detail: string) -> bool {
	r.failure.error = error
	// (cut at a character's start: the detail is shown as text)
	n := min(len(detail), INIT_DETAIL_BYTES)
	for n > 0 && n < len(detail) && detail[n] & 0xC0 == 0x80 { n -= 1 }
	r.failure.detail_len = copy(r.failure.detail[:], strings.trim_space(detail[:n]))
	return false
}
