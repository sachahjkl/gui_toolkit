package tk_toolbox

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "../paint"

// Each size drawn by the program; the .ico holds its sizes in order, the small ones as DIBs when asked.
@(test)
a_logo_writes_its_files :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, fmt.tprintf("tk_toolbox_logo_%d", os.get_pid())}, context.temp_allocator)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	drawn := 0
	ico := fmt.tprintf("%s/res/x.ico", dir)
	why := write_logo({render = proc(size: int, user: rawptr) -> paint.Canvas {
		(^int)(user)^ += 1
		return paint.canvas_make(size, size)
	}, user = &drawn, dir = dir, master = 64, sizes = {16, 32}, ico = ico, ico_sizes = {16, 48}, ico_png_from = 32})
	testing.expect_value(t, why, "")
	testing.expect_value(t, drawn, 5)
	for name in ([]string{"logo.png", "logo_16.png", "logo_32.png"}) {
		testing.expectf(t, os.exists(fmt.tprintf("%s/%s", dir, name)), "%s", name)
	}
	data, err := os.read_entire_file(ico, context.temp_allocator)
	testing.expect(t, err == nil, "the .ico, its folder made")
	count, _ := endian.get_u16(data[4:], .Little)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, data[6], 16)
	testing.expect_value(t, data[6 + 16], 48)
	png_at, _ := endian.get_u32(data[6 + 16 + 12:], .Little)
	testing.expect_value(t, string(data[png_at + 1:png_at + 4]), "PNG")
	dib_at, _ := endian.get_u32(data[6 + 12:], .Little)
	testing.expect(t, string(data[dib_at + 1:dib_at + 4]) != "PNG", "16 px: a DIB")
}

// Three numbers, or nothing; the header written only when it changes.
@(test)
a_version_header :: proc(t: ^testing.T) {
	testing.expect_value(t, version_header("0.9.12"), "#define VER_MAJOR 0\r\n#define VER_MINOR 9\r\n#define VER_PATCH 12\r\n#define VER_STRING \"0.9.12\"\r\n")
	testing.expect_value(t, version_header("0.9"), "")
	testing.expect_value(t, version_header("0.9.x"), "")
	testing.expect_value(t, version_header("1..2"), "")
	base, _ := os.temp_directory(context.temp_allocator)
	path := fmt.tprintf("%s/tk_toolbox_version_%d/version.h", base, os.get_pid())
	defer os.remove_all(filepath.dir(path))
	testing.expect_value(t, write_version_header(path, "1.2.3"), "")
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), version_header("1.2.3"))
	testing.expect(t, write_version_header(path, "1.2") != "", "not three numbers")
}
