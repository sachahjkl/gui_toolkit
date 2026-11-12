#+build linux, windows
package tk_desktop

// Where the system gives thumbnails: one larger than asked is reduced (platform's resampler, which these systems build).

import "base:runtime"
import "../platform"

// `rgba` at most `size` on its longer side (its ratio kept): reduced into `allocator`, else itself.
@(private)
thumbnail_fit :: proc(rgba: []u8, w, h, size: int, allocator: runtime.Allocator) -> Thumbnail {
	if w <= size && h <= size { return {rgba, {w, h}} }
	k := f32(size) / f32(max(w, h))
	dw, dh := max(1, int(f32(w) * k + 0.5)), max(1, int(f32(h) * k + 0.5))
	small := platform.rgba_resample(rgba, w, h, dw, dh, allocator)
	delete(rgba, allocator)
	return {small, {dw, dh}}
}
