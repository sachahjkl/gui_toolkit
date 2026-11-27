package gt_base

import "core:fmt"
import "core:os"
import "core:strings"

// Where Vulkan's loader looks for drivers, in its order: each folder of XDG_DATA_DIRS (Mesa's package off NixOS, a
// development shell's), then NixOS's drivers and the system's. In temp memory.
@(private)
software_vulkan_folders :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	data, _ := os.lookup_env("XDG_DATA_DIRS", context.temp_allocator)
	if data == "" { data = "/usr/local/share:/usr/share" }
	for d in strings.split(data, ":", context.temp_allocator) {
		if d != "" { append(&out, fmt.tprintf("%s/vulkan/icd.d", d)) }
	}
	append(&out, "/run/opengl-driver/share/vulkan/icd.d", "/etc/vulkan/icd.d", "/usr/share/vulkan/icd.d")
	return out[:]
}
