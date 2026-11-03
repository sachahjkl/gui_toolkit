#+build !windows
package tk

// A program of the system (curl, unzip): the one on the PATH.
system_program :: proc(name: string) -> string { return name }

GDIPLUS_ONLY :: "the logo and the icon are drawn by GDI+, on Windows"

draw_logo :: proc(out: string) -> string { return GDIPLUS_ONLY }

icon_pngs :: proc(png: string, sizes: []int) -> (pngs: [][]byte, why: string) { return nil, GDIPLUS_ONLY }
