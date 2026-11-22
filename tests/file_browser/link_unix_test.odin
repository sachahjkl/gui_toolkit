#+build linux, darwin, freebsd, openbsd, netbsd
package file_browser_test

import "core:strings"
import "core:sys/posix"

make_folder_link :: proc(link, target: string) -> bool {
	return posix.symlink(strings.clone_to_cstring(target, context.temp_allocator), strings.clone_to_cstring(link, context.temp_allocator)) == .OK
}
