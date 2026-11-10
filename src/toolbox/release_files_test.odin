package tk_toolbox

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "../paint"
import update "../update"

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

// A manifest signed by the key of the environment is the one the program reads; a program not named as a release's is refused.
@(test)
an_update_manifest_is_signed :: proc(t: ^testing.T) {
	seed: [32]byte
	for i in 0 ..< 32 { seed[i] = byte(i + 1) }
	public, _ := update.public_key_of(seed[:], context.temp_allocator)
	product := update.Product{name = "app", sign_context = "app-update-v1\n", public_key = public}
	base, _ := os.temp_directory(context.temp_allocator)
	dir := fmt.tprintf("%s/tk_toolbox_update_%d", base, os.get_pid())
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	program := fmt.tprintf("%s/%s", dir, update.expected_file_name(product, "1.2.3", update.PLATFORM_LINUX_X64, context.temp_allocator))
	data := make([]u8, update.MIN_BINARY, context.temp_allocator)
	copy(data, "\x7fELF")
	_ = os.write_entire_file(program, data)
	os.set_env(UPDATE_KEY_ENV, update.seed_encode(seed[:], context.temp_allocator))
	defer os.unset_env(UPDATE_KEY_ENV)
	out := fmt.tprintf("%s/%s", dir, update.manifest_name(update.PLATFORM_LINUX_X64, "", context.temp_allocator))
	testing.expect_value(t, update_manifest(product, program, "1.2.3", "", out), "")
	manifest, _ := os.read_entire_file(out, context.temp_allocator)
	sig, _ := os.read_entire_file(fmt.tprintf("%s.sig", out), context.temp_allocator)
	m, err := update.verify(product, manifest, string(sig), update.PLATFORM_LINUX_X64, "", context.temp_allocator)
	testing.expect_value(t, err, update.Error.None)
	testing.expect_value(t, m.version, "1.2.3")
	testing.expect(t, update_manifest(product, program, "1.2.4", "", out) != "", "named for another version")
}

// A key goes nowhere a commit could take it: the toolkit's work tree is one, the temporary folder is not.
@(test)
a_key_is_kept_out_of_work_trees :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	testing.expect(t, !in_git_tree(fmt.tprintf("%s/no-such-key", base)), "the temporary folder")
	testing.expect(t, in_git_tree("src/toolbox/no-such-key"), "a work tree")
}
