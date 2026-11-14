#+build !windows
package platform

import "core:strings"

// One tree, from "/".
@(private)
file_roots_read :: proc(allocator := context.allocator) -> []string {
	out := make([]string, 1, allocator)
	out[0] = strings.clone("/", allocator)
	return out
}
