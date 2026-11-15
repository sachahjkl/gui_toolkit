package render

import "core:strings"
import "core:testing"

// Why an init failed, as data: no device, no window (no-graphics.md). tests/no_graphics runs the real failure.

// What wgpu-native 29 answers on a machine whose Vulkan loader finds no driver (VK_DRIVER_FILES pointing at nothing).
@(private = "file")
NO_VULKAN :: "Validation Error\n\nCaused by:\n  No suitable graphics adapter found; noop not requested, vulkan drivers/libraries could not be loaded, metal not requested, dx12 not requested, gl not requested, webgpu not requested\n"

@(test)
failure_reason_is_the_clause_of_the_backend :: proc(t: ^testing.T) {
	testing.expect_value(t, wgpu_failure_reason(NO_VULKAN, "vulkan"), "vulkan drivers/libraries could not be loaded")
	testing.expect_value(t, wgpu_failure_reason(NO_VULKAN, "dx12"), "dx12 not requested")
	// (a backend wgpu does not name: the cause, whole)
	testing.expect(t, strings.has_prefix(wgpu_failure_reason(NO_VULKAN, "vk"), "No suitable graphics adapter found;"))
	testing.expect_value(t, wgpu_failure_reason("  Device lost \n", "vulkan"), "Device lost")
	testing.expect_value(t, wgpu_failure_reason("", "vulkan"), "")
}

@(test)
failure_text_says_what_is_missing_and_what_to_do :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	testing.expect_value(t, init_failure_text(r, context.temp_allocator), "")
	testing.expect(t, !init_fail(r, .No_Driver, "  vulkan drivers/libraries could not be loaded "))
	e, detail := init_failure(r)
	testing.expect_value(t, e, Init_Error.No_Driver)
	testing.expect_value(t, detail, "vulkan drivers/libraries could not be loaded")
	text := init_failure_text(r, context.temp_allocator)
	testing.expect(t, strings.has_prefix(text, "no graphics device this program can draw with ("), text)
	testing.expect(t, strings.contains(text, graphics_api()), text)
	testing.expect(t, strings.contains(text, detail), text)
	testing.expect(t, strings.has_suffix(text, INSTALL_HINT), text)
	for error in ([]Init_Error{.No_Window, .Failed}) {
		init_fail(r, error, "")
		testing.expect(t, strings.contains(init_failure_text(r, context.temp_allocator), "graphics device"))
	}
}

// A detail longer than the buffer is cut at the start of a character: the sentence stays valid UTF-8.
@(test)
failure_detail_is_cut_between_characters :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	long := strings.concatenate({strings.repeat("a", INIT_DETAIL_BYTES - 1, context.temp_allocator), "é and more"}, context.temp_allocator)
	init_fail(r, .Failed, long)
	_, detail := init_failure(r)
	testing.expect_value(t, len(detail), INIT_DETAIL_BYTES - 1)
	testing.expect(t, strings.has_suffix(detail, "a"))
}
