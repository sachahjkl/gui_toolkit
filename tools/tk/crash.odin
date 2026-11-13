package tk

import "core:fmt"
import toolbox "../../src/toolbox"

// tk crash_symbolize <report> <map, folder of maps, or executable>: the report with the program's frames named (toolbox.crash_symbolize).
run_crash_symbolize :: proc(args: []string) -> string {
	plain := toolbox.plain_args(args)
	text, why := toolbox.crash_symbolize(plain[0], plain[1], context.temp_allocator)
	if why != "" { return why }
	fmt.print(text)
	return ""
}
