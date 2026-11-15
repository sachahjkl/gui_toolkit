package render

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

// A one-millisecond sleep while polling for a wgpu request.
@(private)
thread_sleep_1ms :: proc() { win.Sleep(1) }

// The path of dxcompiler.dll when it and dxil.dll sit next to the program ("" otherwise: FXC compiles the shaders).
@(private)
find_dxc :: proc() -> string {
	buf: [win.MAX_PATH_WIDE]u16
	n := win.GetModuleFileNameW(nil, raw_data(buf[:]), len(buf))
	if n == 0 { return "" }
	dir, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil { return "" }
	slash := strings.last_index_byte(dir, '\\')
	if slash < 0 { return "" }
	dll := fmt.tprintf("%s\\dxcompiler.dll", dir[:slash])
	il := fmt.tprintf("%s\\dxil.dll", dir[:slash])
	if !os.exists(dll) || !os.exists(il) { return "" }
	return dll
}
