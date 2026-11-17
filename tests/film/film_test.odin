// gt:film: a headless window recorded while a script drives it. With no ffmpeg on the PATH the tests that encode say so and
// end: the machine cannot make a film.
package film_test

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "gt:film"
import host "gt:host"
import "gt:render"
import "gt:ui"

@(private = "file") WINDOW :: [2]int{320, 200}
@(private = "file") STAGE :: [2]int{400, 260}

@(private = "file")
App :: struct {
	shared: host.Shared,
	main:   host.Host,
	clicks: int,
}

@(private = "file")
build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	ui.next({fixed_x = 100, fixed_y = 80, width = ui.px(120), height = ui.px(40)})
	if ui.button("go", "Go").clicked { app.clicks += 1 }
}

@(private = "file")
has_ffmpeg :: proc() -> bool {
	state, out, errs, err := os.process_exec({command = {"ffmpeg", "-version"}}, context.temp_allocator)
	_, _ = out, errs
	return err == nil && state.exit_code == 0
}

// The frames of a video file by ffprobe; -1 when it cannot say.
@(private = "file")
frames_in :: proc(path: string) -> int {
	state, out, errs, err := os.process_exec({command = {"ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0",
		"-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", path}}, context.temp_allocator)
	_ = errs
	if err != nil || state.exit_code != 0 { return -1 }
	n, ok := strconv.parse_int(strings.trim_space(string(out)))
	return ok ? n : -1
}

// A pointer that glides to a button and clicks it: the program sees the click once, every frame is in the file, and the
// window stands on a stage larger than itself.
@(test)
a_scripted_click_is_filmed :: proc(t: ^testing.T) {
	if !has_ffmpeg() { fmt.println("film_test: no ffmpeg on the PATH: no film made"); return }
	app := new(App)
	defer free(app)
	if !testing.expect(t, host.host_open(&app.main, &app.shared, {title = "film test", size = WINDOW, headless = true}, build, app), "the window opens") { return }
	defer host.host_close(&app.main)
	dir, _ := os.temp_directory(context.temp_allocator)
	out := fmt.tprintf("%s/film_test.mp4", dir)
	rec: film.Recorder
	why := film.start(&rec, {win = app.main.win, state = &app.main.state, renderer = &app.shared.r, user = &app.main,
		frame = proc(user: rawptr) { host.host_frame((^host.Host)(user)) }}, {out = out, fps = 30, size = STAGE, encoder = .X264})
	if !testing.expectf(t, why == "", "the film starts: %s", why) { return }
	film.pointer_show(&rec, true, {10, 10})
	film.hold(&rec, 0.2)
	go := film.box(&rec, "go")
	if testing.expect(t, go != nil, "the button is found by its name") {
		film.move_to(&rec, film.center(go), 0.3)
		film.click(&rec)
	}
	film.hold(&rec, 0.2)
	frames := rec.frames
	why = film.finish(&rec)
	testing.expectf(t, why == "", "the film ends whole: %s", why)
	testing.expect_value(t, app.clicks, 1)
	testing.expectf(t, frames >= 20, "frames written: %d", frames)
	if n := frames_in(out); n >= 0 { testing.expect_value(t, n, frames) }
	_ = os.remove(out)
}

// read_pixels_bgra gives read_pixels' bytes with red and blue swapped.
@(test)
the_bgra_frame_is_the_rgba_one_swapped :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	if !testing.expect(t, host.host_open(&app.main, &app.shared, {title = "film test", size = WINDOW, headless = true}, build, app), "the window opens") { return }
	defer host.host_close(&app.main)
	for _ in 0 ..< 2 { host.host_frame(&app.main) }
	rgba := render.read_pixels(&app.shared.r)
	defer delete(rgba)
	bgra := render.read_pixels_bgra(&app.shared.r)
	defer delete(bgra)
	if !testing.expect_value(t, len(bgra), len(rgba)) { return }
	same := true
	for i := 0; i < len(rgba); i += 4 {
		if bgra[i] != rgba[i + 2] || bgra[i + 1] != rgba[i + 1] || bgra[i + 2] != rgba[i] || bgra[i + 3] != rgba[i + 3] { same = false; break }
	}
	testing.expect(t, same, "the same pixels, red and blue swapped")
}
