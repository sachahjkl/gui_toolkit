package tk_toolbox

// The files a program makes from its logo: the program draws it (a proc that gives a canvas of a size), the toolbox writes
// what every program needs of it: its PNG files, the .ico of its Windows executable, the project's picture.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "../paint"

// The sizes Windows asks an .ico for: Explorer's lists and tiles, the taskbar, the window's corner, at every scale.
@(rodata) ICO_SIZES := [?]int{16, 20, 24, 32, 40, 48, 64, 128, 256}

// The project's picture: what the repository and opencode's sessions of it show.
PROJECT_IMAGE      :: ".project/image.png"
PROJECT_IMAGE_SIZE :: 512

// What write_logo writes. A size is drawn at that size (render), never scaled from another.
Logo :: struct {
	render:        proc(size: int, user: rawptr) -> paint.Canvas,
	user:          rawptr,
	dir:           string,   // the folder of the PNG files ("assets")
	master:        int,      // <dir>/logo.png at that size; 0: none
	sizes:         []int,    // <dir>/logo_<size>.png
	ico:           string,   // the .ico ("assets/papier.ico"); "": none
	ico_sizes:     []int,    // nil: ICO_SIZES
	ico_png_from:  int,      // the sizes below are classic DIBs (old readers); 0: all PNG
	project_image: bool,     // PROJECT_IMAGE, PROJECT_IMAGE_SIZE px
}

// Writes the files of the logo and says each. why: "" when all are written, else the file that is not.
write_logo :: proc(logo: Logo) -> (why: string) {
	png :: proc(logo: Logo, size: int, path: string) -> string {
		c := logo.render(size, logo.user)
		defer paint.canvas_destroy(&c)
		_ = os.make_directory_all(filepath.dir(path))
		if !paint.write_png(c, path) { return fmt.tprintf("%s cannot be written", path) }
		fmt.printfln("wrote %s", path)
		return ""
	}
	if logo.master > 0 {
		if why = png(logo, logo.master, fmt.tprintf("%s/logo.png", logo.dir)); why != "" { return }
	}
	for size in logo.sizes {
		if why = png(logo, size, fmt.tprintf("%s/logo_%d.png", logo.dir, size)); why != "" { return }
	}
	if logo.ico != "" {
		sizes := logo.ico_sizes != nil ? logo.ico_sizes : ICO_SIZES[:]
		entries := make([]paint.Ico_Entry, len(sizes), context.temp_allocator)
		for size, i in sizes {
			c := logo.render(size, logo.user)
			defer paint.canvas_destroy(&c)
			data := size >= logo.ico_png_from ? paint.png_encode(c, context.temp_allocator) : paint.dib_encode(c, context.temp_allocator)
			entries[i] = {size, data}
		}
		_ = os.make_directory_all(filepath.dir(logo.ico))
		if os.write_entire_file(logo.ico, paint.ico_encode(entries, context.temp_allocator)) != nil {
			return fmt.tprintf("%s cannot be written", logo.ico)
		}
		fmt.printfln("wrote %s", logo.ico)
	}
	if logo.project_image {
		if why = png(logo, PROJECT_IMAGE_SIZE, PROJECT_IMAGE); why != "" { return }
	}
	return ""
}
