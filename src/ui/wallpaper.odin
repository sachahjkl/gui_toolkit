package ui

// The desktop's background from a program (platform.set_wallpaper, src/md/features/wallpaper.md): the call blocks (a
// portal may show the picture and ask the person), so it runs on the chores and its result comes back to the window's
// thread. The program says what happened in its own words (a toast, its menu's item greyed when Unsupported).

import "base:runtime"
import "core:strings"
import "../platform"

@(private = "file")
Wallpaper_Job :: struct {
	path:   string,   // (heap)
	result: platform.Wallpaper_Result,
	done:   proc(user: rawptr, result: platform.Wallpaper_Result),
	user:   rawptr,
}

// The picture at `path` as the desktop's background, on the chores; `done(user, result)` at a build of this window
// after it (nil: nothing comes back). Call it in a build.
wallpaper_set :: proc(path: string, done: proc(user: rawptr, result: platform.Wallpaper_Result) = nil, user: rawptr = nil) {
	heap := runtime.heap_allocator()
	j := new(Wallpaper_Job, heap)
	j^ = {path = strings.clone(path, heap), done = done, user = user}
	work :: proc(d: rawptr) {
		j := (^Wallpaper_Job)(d)
		j.result = platform.set_wallpaper(j.path)
	}
	back :: proc(d: rawptr, _: u64) {
		j := (^Wallpaper_Job)(d)
		if j.done != nil { j.done(j.user, j.result) }
		wallpaper_job_free(j)
	}
	lost :: proc(d: rawptr) { wallpaper_job_free((^Wallpaper_Job)(d)) }
	task(gs(), work, back, j, lost)
}

@(private = "file")
wallpaper_job_free :: proc(j: ^Wallpaper_Job) {
	heap := runtime.heap_allocator()
	delete(j.path, heap)
	free(j, heap)
}
