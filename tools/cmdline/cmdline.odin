// The command line of the tools, as it was typed. PowerShell 7 passes `-name:value` to a program as two arguments,
// `-name:` and `value`, once a `--` came before it on the line: `odin run tools/run_tests -- -backend:wgpu` reaches the
// program as `-backend:` `wgpu` (odin passes on what it gets as it is; from cmd or bash the program gets `-backend:wgpu`).
// The tools join them again.
package cmdline

import "core:strings"

// The arguments, each `-name:` followed by its value joined back into `-name:value` (allocated when joined).
joined :: proc(given: []string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, len(given), allocator)
	for i := 0; i < len(given); i += 1 {
		a := given[i]
		if len(a) > 2 && a[0] == '-' && a[len(a) - 1] == ':' && i + 1 < len(given) {
			a = strings.concatenate({a, given[i + 1]}, allocator)
			i += 1
		}
		append(&out, a)
	}
	return out[:]
}
