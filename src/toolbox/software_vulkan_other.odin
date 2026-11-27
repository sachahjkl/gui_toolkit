#+build !linux
package tk_toolbox

// Elsewhere a program session does not start (sway_other.odin): no folder to look in.
@(private)
software_vulkan_folders :: proc() -> []string { return nil }
