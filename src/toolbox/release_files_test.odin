package tk_toolbox

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "../paint"
import signing "../signing"
import update "../update"

// Each size drawn by the program; the .ico holds its sizes in order, the small ones as DIBs when asked.
@(test)
a_logo_writes_its_files :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, fmt.tprintf("tk_toolbox_logo_%d", os.get_pid())}, context.temp_allocator)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	Drawn :: struct { count: int, pixels: [8][2]int }
	drawn: Drawn
	ico := fmt.tprintf("%s/res/x.ico", dir)
	why := write_logo({draw = proc(pixels, size: int, user: rawptr) -> paint.Canvas {
		d := (^Drawn)(user)
		if d.count < len(d.pixels) { d.pixels[d.count] = {pixels, size} }
		d.count += 1
		return paint.canvas_make(pixels, pixels)
	}, user = &drawn, dir = dir, master = 64, sizes = {16, 32}, ico = ico, ico_sizes = {16, 48}, ico_png_from = 32})
	testing.expect_value(t, why, "")
	testing.expect_value(t, drawn.count, 5)
	// (each drawn at the master's size or more, by steps of LOGO_SHRINK_STEP, and told the size it is for)
	testing.expect_value(t, drawn.pixels[0], [2]int{64, 64})
	testing.expect_value(t, drawn.pixels[1], [2]int{64, 16})
	testing.expect_value(t, drawn.pixels[2], [2]int{128, 32})
	testing.expect_value(t, drawn.pixels[4], [2]int{192, 48})
	small, _ := os.read_entire_file(fmt.tprintf("%s/logo_16.png", dir), context.temp_allocator)
	width, _ := endian.get_u32(small[16:], .Big)
	testing.expect_value(t, width, 16)
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

// A shrink reaches its size exactly, from any width; a picture already that size is given back as it is.
@(test)
a_logo_shrinks_to_its_size :: proc(t: ^testing.T) {
	c := logo_shrink(paint.canvas_make(1000, 1000), 24)
	testing.expect_value(t, c.width, 24)
	testing.expect_value(t, c.height, 24)
	paint.canvas_destroy(&c)
	same := paint.canvas_make(16, 16)
	kept := logo_shrink(same, 16)
	testing.expect(t, raw_data(kept.pixels) == raw_data(same.pixels), "no copy of a picture at its size")
	paint.canvas_destroy(&kept)
	// (without a master nor a draw_size, a size is drawn at its size)
	at := logo_picture({draw = proc(pixels, size: int, _: rawptr) -> paint.Canvas { return paint.canvas_make(pixels, pixels) }}, 20)
	testing.expect_value(t, at.width, 20)
	paint.canvas_destroy(&at)
}

// A manifest signed by the key of the environment is the one the program reads; a program not named as a release's is refused.
@(test)
an_update_manifest_is_signed :: proc(t: ^testing.T) {
	seed: [32]byte
	for i in 0 ..< 32 { seed[i] = byte(i + 1) }
	public, _ := signing.public_key_of(seed[:], context.temp_allocator)
	product := update.Product{name = "app", sign_context = "app-update-v1\n", public_key = public}
	base, _ := os.temp_directory(context.temp_allocator)
	dir := fmt.tprintf("%s/tk_toolbox_update_%d", base, os.get_pid())
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	program := fmt.tprintf("%s/%s", dir, update.expected_file_name(product, "1.2.3", update.PLATFORM_LINUX_X64, context.temp_allocator))
	data := make([]u8, update.MIN_BINARY, context.temp_allocator)
	copy(data, "\x7fELF")
	_ = os.write_entire_file(program, data)
	os.set_env(UPDATE_KEY_ENV, signing.key_encode(seed[:], context.temp_allocator))
	defer os.unset_env(UPDATE_KEY_ENV)
	out := fmt.tprintf("%s/%s", dir, update.manifest_name(update.PLATFORM_LINUX_X64, "", context.temp_allocator))
	testing.expect_value(t, update_manifest(product, program, "1.2.3", "", out), "")
	manifest, _ := os.read_entire_file(out, context.temp_allocator)
	sig, _ := os.read_entire_file(fmt.tprintf("%s.sig", out), context.temp_allocator)
	m, err := update.verify(product, manifest, string(sig), {platform = update.PLATFORM_LINUX_X64}, context.temp_allocator)
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
