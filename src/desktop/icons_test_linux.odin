#+build linux
package tk_desktop

import "core:fmt"
import "core:os"
import "core:testing"
import "../png"

// A theme of the test's own: a PNG per type at 16 pixels, an SVG folder that scales; a MIME database that names them.
@(private = "file")
theme_make :: proc(t: ^testing.T) -> (roots: Xdg_Roots, base: string) {
	tmp, _ := os.temp_directory(context.temp_allocator)
	base = fmt.tprintf("%s/tk_icons_%d", tmp, os.get_pid())
	_ = os.remove_all(base)
	theme := fmt.tprintf("%s/data/icons/Test", base)
	_ = os.make_directory_all(fmt.tprintf("%s/16x16/mimetypes", theme))
	_ = os.make_directory_all(fmt.tprintf("%s/scalable/places", theme))
	_ = os.make_directory_all(fmt.tprintf("%s/data/mime", base))
	_ = os.make_directory_all(fmt.tprintf("%s/config/gtk-3.0", base))
	write :: proc(t: ^testing.T, path: string, data: []u8) { testing.expect(t, os.write_entire_file(path, data) == nil, path) }
	write(t, fmt.tprintf("%s/index.theme", theme), transmute([]u8)string(
		"[Icon Theme]\nName=Test\nInherits=hicolor\nDirectories=16x16/mimetypes,scalable/places\n\n" +
		"[16x16/mimetypes]\nSize=16\nType=Fixed\n\n[scalable/places]\nSize=48\nMinSize=8\nMaxSize=512\nType=Scalable\n"))
	square :: proc(r, g, b: u8) -> []u8 {
		px := make([]u8, 16 * 16 * 4, context.temp_allocator)
		for i := 0; i < len(px); i += 4 { px[i], px[i + 1], px[i + 2], px[i + 3] = r, g, b, 255 }
		return png.encode(px, 16, 16, .Fast, context.temp_allocator)
	}
	write(t, fmt.tprintf("%s/16x16/mimetypes/text-plain.png", theme), square(255, 0, 0))
	write(t, fmt.tprintf("%s/16x16/mimetypes/image-x-generic.png", theme), square(0, 255, 0))
	write(t, fmt.tprintf("%s/scalable/places/folder.svg", theme), transmute([]u8)string(
		`<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="#0000ff"/></svg>`))
	write(t, fmt.tprintf("%s/data/mime/globs2", base), transmute([]u8)string("50:text/plain:*.txt\n50:image/png:*.png\n"))
	write(t, fmt.tprintf("%s/data/mime/generic-icons", base), transmute([]u8)string("image/png:image-x-generic\n"))
	write(t, fmt.tprintf("%s/config/gtk-3.0/settings.ini", base), transmute([]u8)string("[Settings]\ngtk-icon-theme-name=Test\n"))
	d := make([]string, 1, context.temp_allocator)
	d[0] = fmt.tprintf("%s/data", base)
	return {data = d}, base
}

@(test)
the_icons_of_a_theme :: proc(t: ^testing.T) {
	roots, base := theme_make(t)
	defer os.remove_all(base)
	testing.expect_value(t, icon_theme_name(fmt.tprintf("%s/config", base)), "Test")

	// a type's own icon, by its name (text/plain: text-plain)
	txt, ok := icon_of_path_in(roots, "Test", "/x/notes.txt", false, 16, context.allocator)
	defer file_icon_destroy(&txt)
	testing.expect(t, ok, "text-plain")
	testing.expect_value(t, txt.size, [2]int{16, 16})
	testing.expect_value(t, txt.rgba[0], 255)

	// a type with no icon of its own: its family's (mime/generic-icons), from the nearest size there is
	pic, pok := icon_of_path_in(roots, "Test", "/x/photo.png", false, 24, context.allocator)
	defer file_icon_destroy(&pic)
	testing.expect(t, pok, "image-x-generic")
	testing.expect_value(t, pic.rgba[1], 255)

	// a folder: an SVG, rendered at the size asked (when librsvg is here)
	if svg_available() {
		dir, dok := icon_of_path_in(roots, "Test", "/x/somewhere", true, 32, context.allocator)
		defer file_icon_destroy(&dir)
		testing.expect(t, dok, "folder.svg")
		testing.expect_value(t, dir.size, [2]int{32, 32})
		mid := (16 * 32 + 16) * 4
		testing.expect_value(t, [4]u8{dir.rgba[mid], dir.rgba[mid + 1], dir.rgba[mid + 2], dir.rgba[mid + 3]}, [4]u8{0, 0, 255, 255})
	} else {
		fmt.println("icons: librsvg is not here: the SVG check is skipped")
	}
	// chosen at one size, made at another: the file of 16 pixels for a picture asked at 40, chosen as at 16
	big, bok := icon_of_path_in(roots, "Test", "/x/notes.txt", false, 40, context.allocator, 16)
	defer file_icon_destroy(&big)
	testing.expect(t, bok)
	testing.expect_value(t, big.size, [2]int{16, 16})   // (a PNG as it is: its size; an SVG would be made at 40)
	// a type the theme has nothing for: none
	_, none := icon_of_path_in(roots, "Test", "/x/data.bin", false, 16, context.allocator)
	testing.expect(t, !none)
}
