package tk

import "core:fmt"
import toolbox "../../src/toolbox"

// tk crash_symbolize <report> <map, folder of maps, or executable>: the report with the program's frames named (toolbox.crash_symbolize).
run_crash_symbolize :: proc(a: ^Args) -> string {
	text, why := toolbox.crash_symbolize(a.positionals[0], a.positionals[1], context.temp_allocator)
	if why != "" { return why }
	fmt.print(text)
	return ""
}
