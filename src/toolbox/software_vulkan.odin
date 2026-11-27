package tk_toolbox

// Vulkan on the CPU for a program a tool starts: Mesa's lavapipe, never the machine's GPU. A test's picture is the same
// on every machine, and a test never takes a person's graphics card (program_session_start).

import "core:os"
import "core:strings"

// The name of lavapipe's driver manifest, before its architecture: lvp_icd.x86_64.json, lvp_icd.aarch64.json.
@(private) SOFTWARE_VULKAN_PREFIX :: "lvp_icd"
// The architecture in the manifest's name for this build: another architecture's driver does not load.
@(private) SOFTWARE_VULKAN_ARCH :: "x86_64" when ODIN_ARCH == .amd64 else "aarch64" when ODIN_ARCH == .arm64 else ""
// What a program a tool starts takes Vulkan's drivers from, and its implicit layers off: NVIDIA's (VK_LAYER_NV_optimus)
// loads its driver into every Vulkan program, whatever the driver chosen.
@(private) SOFTWARE_VULKAN_DRIVER_ENV :: "VK_DRIVER_FILES"
@(private) SOFTWARE_VULKAN_LAYERS_OFF :: "VK_LOADER_LAYERS_DISABLE=~implicit~"

// Whether `path` names lavapipe's manifest for this architecture (one with no architecture in its name too).
@(private)
software_vulkan_is :: proc(path: string) -> bool {
	name := path
	if i := strings.last_index_any(name, "/\\"); i >= 0 { name = name[i + 1:] }
	if !strings.has_prefix(name, SOFTWARE_VULKAN_PREFIX) || !strings.has_suffix(name, ".json") { return false }
	arch := name[len(SOFTWARE_VULKAN_PREFIX):len(name) - len(".json")]
	return arch == "" || arch == "." + SOFTWARE_VULKAN_ARCH
}

// lavapipe's manifest: `given` (VK_DRIVER_FILES as it is) when it names lavapipe alone, else the first in `folders`
// (Vulkan's icd.d folders, in the loader's order). In temp memory. ok false: no lavapipe on this machine.
@(private)
software_vulkan_find :: proc(given: string, folders: []string) -> (path: string, ok: bool) {
	if given != "" && !strings.contains_rune(given, ':') && software_vulkan_is(given) && os.exists(given) { return given, true }
	for folder in folders {
		entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
		if err != nil { continue }
		for e in entries {
			if e.type != .Directory && software_vulkan_is(e.name) { return strings.clone(e.fullpath, context.temp_allocator), true }
		}
	}
	return "", false
}

// lavapipe's manifest on this machine (software_vulkan_folders), in temp memory.
software_vulkan_driver :: proc() -> (path: string, ok: bool) {
	given, _ := os.lookup_env(SOFTWARE_VULKAN_DRIVER_ENV, context.temp_allocator)
	return software_vulkan_find(given, software_vulkan_folders())
}
