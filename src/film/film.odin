// Films of an interface (src/md/features/film.md): a program made with the toolkit, headless, on the film's clock; a
// script drives it (script.odin); each frame goes raw to ffmpeg, on a thread of its own.
//
//   rec: film.Recorder
//   if why := film.start(&rec, {win = h.win, state = &h.state, renderer = &sh.r, frame = my_frame, user = app}, {out = "a.mp4"}); why != "" { ... }
//   film.move_to(&rec, film.center(film.box(&rec, "save")))
//   film.click(&rec)
//   film.hold(&rec, 1.5)
//   film.finish(&rec)
package film

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:thread"
import "../platform"
import "../render"
import "../ui"

// What a film records: the program's headless window, its State, its renderer and how it makes a frame.
App :: struct {
	win:      ^platform.Window,
	state:    ^ui.State,
	renderer: ^render.Renderer,
	frame:    proc(user: rawptr),   // one frame of the program (host.host_frame of its host)
	user:     rawptr,
}

Encoder :: enum u8 {
	Auto,    // NVENC when a probe encodes with it, else libx264
	Nvenc,
	X264,
}

Options :: struct {
	out:     string,     // the file, .mp4
	fps:     int,        // 0: 60
	size:    [2]int,     // the film's size in pixels; zero: the window's. Larger than the window: the window on a stage
	quality: int,        // the encoder's constant quality (NVENC cq, x264 crf); 0: 18. Lower is better
	encoder: Encoder,
	stage:   Stage,      // its look when the window is smaller than the film
}

// The ground the window stands on when it is smaller than the film: a gradient, the window's corners and its shadow.
Stage :: struct {
	top, bottom:  [3]u8,   // the ground's colours, sRGB (zero: STAGE_TOP, STAGE_BOTTOM)
	radius:       f32,     // the window's corners, film pixels (0: 12)
	shadow:       f32,     // the shadow's spread, film pixels (0: 48)
}

STAGE_TOP    :: [3]u8{23, 31, 56}
STAGE_BOTTOM :: [3]u8{6, 7, 12}

Recorder :: struct {
	app:      App,
	o:        Options,
	clock:    f64,                // the program's time, ms (ui.set_clock)
	frames:   int,                // frames written
	// what runs before each frame: a script's camera, a value that moves (nil: nothing)
	each:      proc(r: ^Recorder, user: rawptr),
	each_user: rawptr,
	pointer:  Pointer,
	// the pipe
	ffmpeg:   os.Process,
	pipe:     ^os.File,
	writer:   Writer,
	failed:   string,             // the first failure ("": none)
	// the stage, made for one window size
	ground:      []u8,
	ground_for:  [2]int,
	window_at:   [2]int,          // where the window stands on the film
	canvas:      [2][]u8,         // the film's frames when staged: one written while the next is made
	canvas_next: int,
	last:        []u8,            // the frame written last (the writer's), kept until the next is written
	last_owned:  bool,
	// a fade from a frame kept (fade): the next `fade_total` frames blend from it
	fade_from:   []u8,
	fade_left:   int,
	fade_total:  int,
}

// One frame on its way to ffmpeg.
@(private)
Writer :: struct {
	file:   ^os.File,
	px:     []u8,                 // Recorder.last: freed by the next frame once written
	thread: ^thread.Thread,
	failed: bool,
}

// Starts a film: the program's clock is the film's from now, ffmpeg waits for the frames. "" when it started, else why not.
start :: proc(r: ^Recorder, app: App, o: Options) -> string {
	r^ = {app = app, o = o}
	// (the path is the Recorder's: a caller's temp memory is freed by the program's frames)
	r.o.out = strings.clone(o.out)
	if r.o.fps <= 0 { r.o.fps = 60 }
	if r.o.quality <= 0 { r.o.quality = 18 }
	if r.o.size == {} { r.o.size = app.renderer.size }
	if r.o.stage.top == {} && r.o.stage.bottom == {} { r.o.stage.top, r.o.stage.bottom = STAGE_TOP, STAGE_BOTTOM }
	if r.o.stage.radius <= 0 { r.o.stage.radius = 12 }
	if r.o.stage.shadow <= 0 { r.o.stage.shadow = 48 }
	if app.renderer.size.x > r.o.size.x || app.renderer.size.y > r.o.size.y {
		return fmt.tprintf("the window (%v) is larger than the film (%v)", app.renderer.size, r.o.size)
	}
	r.clock = ui.now_ms()
	ui.set_clock(app.state, &r.clock)
	encoder := r.o.encoder
	if encoder == .Auto { encoder = nvenc_works() ? .Nvenc : .X264 }
	read, write, err := os.pipe()
	if err != nil { return fmt.tprintf("no pipe: %v", err) }
	size := fmt.tprintf("%dx%d", r.o.size.x, r.o.size.y)
	fps := fmt.tprintf("%d", r.o.fps)
	q := fmt.tprintf("%d", r.o.quality)
	// (in temp memory, not a literal in a case: its array would be the case's, gone at the switch's end)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgr0", "-s", size, "-r", fps, "-i", "-")
	switch encoder {
	case .Nvenc, .Auto:
		// (the RGB as it is: NVENC makes its YUV on the card)
		append(&cmd, "-c:v", "h264_nvenc", "-preset", "p4", "-tune", "hq", "-rc", "vbr", "-cq", q, "-b:v", "0")
	case .X264:
		append(&cmd, "-c:v", "libx264", "-preset", "veryfast", "-crf", q, "-pix_fmt", "yuv420p")
	}
	append(&cmd, "-movflags", "+faststart", r.o.out)
	p, perr := os.process_start({command = cmd[:], stdin = read, stderr = os.stderr})
	os.close(read)
	if perr != nil {
		os.close(write)
		return fmt.tprintf("ffmpeg cannot start: %v", perr)
	}
	r.ffmpeg, r.pipe = p, write
	r.writer.file = write
	pointer_init(&r.pointer, app.win.dpi_scale)
	return ""
}

// The film ends: the last frame written, ffmpeg closes the file. "" when the file is whole, else why not.
finish :: proc(r: ^Recorder) -> string {
	if !writer_join(&r.writer) && r.failed == "" { r.failed = "ffmpeg took no more frames" }
	if r.pipe != nil { os.close(r.pipe) }
	r.pipe = nil
	state, err := os.process_wait(r.ffmpeg)
	if r.failed == "" && (err != nil || state.exit_code != 0) { r.failed = fmt.tprintf("ffmpeg ended with %d (%v)", state.exit_code, err) }
	ui.set_clock(r.app.state, nil)
	if r.last_owned { delete(r.last) }
	delete(r.fade_from)
	delete(r.ground)
	delete(r.o.out)
	for c in r.canvas { delete(c) }
	pointer_destroy(&r.pointer)
	return r.failed
}

// One frame: the script's `each`, the program's frame on the film's clock, the picture read, the pointer drawn over it,
// handed to the writer. Nothing once a write failed.
frame :: proc(r: ^Recorder) {
	if r.failed != "" { return }
	if r.each != nil { r.each(r, r.each_user) }
	r.clock += 1000 / f64(r.o.fps)
	r.app.frame(r.app.user)
	raw := render.read_pixels_bgra(r.app.renderer, context.allocator)
	size := r.app.renderer.size
	if len(raw) != size.x * size.y * 4 {
		delete(raw)
		r.failed = "the renderer gave no picture"
		return
	}
	px, owned := raw, true
	r.window_at = {}
	if size != r.o.size {
		// (the window on its stage: the ground and the shadow made once per size, the window's pixels over them)
		px, owned = staged(r, raw, size), false
		delete(raw)
	}
	pointer_draw(&r.pointer, px, r.o.size, r.window_at, r.clock)
	if r.fade_left > 0 {
		k := smooth(f32(r.fade_left) / f32(r.fade_total))
		blend(px, r.fade_from, k)
		r.fade_left -= 1
		if r.fade_left == 0 { delete(r.fade_from); r.fade_from = nil }
	}
	// (the last frame's write ends before this one starts: one on its way while the next is drawn)
	if !writer_join(&r.writer) {
		if owned { delete(px) }
		r.failed = "ffmpeg took no more frames"
		return
	}
	if r.last_owned { delete(r.last) }
	r.last, r.last_owned = px, owned
	r.writer.px = px
	r.writer.thread = thread.create_and_start_with_poly_data(&r.writer, proc(w: ^Writer) {
		_, err := os.write(w.file, w.px)
		w.failed = err != nil
	})
	r.frames += 1
}

// The film goes on with another program's window (a title card's, then the program's): from the next frame its frames
// are the film's, on the film's clock. The one before keeps its own time again.
switch_to :: proc(r: ^Recorder, app: App) {
	ui.set_clock(r.app.state, nil)
	r.app = app
	ui.set_clock(app.state, &r.clock)
}

// The frames of `seconds`.
frames_of :: proc(r: ^Recorder, seconds: f64) -> int { return max(int(math.round(seconds * f64(r.o.fps))), 0) }

@(private)
writer_join :: proc(w: ^Writer) -> bool {
	if w.thread == nil { return true }
	thread.join(w.thread)
	thread.destroy(w.thread)
	w.thread = nil
	return !w.failed
}

// The next `seconds` of frames fade in from the frame written last (a cut from a title to the program, from one scene to
// another).
fade :: proc(r: ^Recorder, seconds: f64) {
	if r.last == nil { return }
	delete(r.fade_from)
	r.fade_from = make([]u8, len(r.last))
	copy(r.fade_from, r.last)
	r.fade_total = max(frames_of(r, seconds), 1)
	r.fade_left = r.fade_total
}

// `px` toward `from` by `k` (0: px, 1: from), each byte.
@(private)
blend :: proc(px, from: []u8, k: f32) {
	if len(px) != len(from) { return }
	w := u32(clamp(k, 0, 1) * 256)
	for i in 0 ..< len(px) { px[i] = u8((u32(px[i]) * (256 - w) + u32(from[i]) * w) >> 8) }
}

// Whether ffmpeg encodes with NVENC here: a short encode of nothing (an NVIDIA card and its driver; ffmpeg built with it).
nvenc_works :: proc() -> bool {
	state, out, errs, err := os.process_exec({command = {"ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=s=256x256:d=0.1",
		"-c:v", "h264_nvenc", "-f", "null", "-"}}, context.temp_allocator)
	_, _ = out, errs
	return err == nil && state.exit_code == 0
}

////////////////////////////////
// The stage

@(private)
staged :: proc(r: ^Recorder, win: []u8, size: [2]int) -> []u8 {
	film := r.o.size
	if r.ground_for != size {
		delete(r.ground)
		r.ground = stage_ground(r.o.stage, film, size)
		r.ground_for = size
	}
	r.window_at = (film - size) / 2
	c := &r.canvas[r.canvas_next]
	r.canvas_next = 1 - r.canvas_next
	if len(c^) != len(r.ground) {
		delete(c^)
		c^ = make([]u8, len(r.ground))
	}
	copy(c^, r.ground)
	radius := r.o.stage.radius
	for y in 0 ..< size.y {
		dst := c[((r.window_at.y + y) * film.x + r.window_at.x) * 4:][:size.x * 4]
		src := win[y * size.x * 4:][:size.x * 4]
		// (rows clear of the corners copy whole; the corners' rows blend by their coverage)
		cy := min(f32(y) + 0.5, f32(size.y - y) - 0.5)
		if cy >= radius {
			copy(dst, src)
			continue
		}
		for x in 0 ..< size.x {
			cx := min(f32(x) + 0.5, f32(size.x - x) - 0.5)
			a: f32 = 1
			if cx < radius {
				d := math.hypot(radius - cx, radius - cy)
				a = clamp(radius - d + 0.5, 0, 1)
			}
			o := x * 4
			for k in 0 ..< 3 { dst[o + k] = u8(f32(src[o + k]) * a + f32(dst[o + k]) * (1 - a) + 0.5) }
		}
	}
	return c^
}

// The ground: a vertical gradient, the shadow of a rounded window of `win` centred on it (a box blur's profile, by erf
// along each side).
@(private)
stage_ground :: proc(st: Stage, film, win: [2]int) -> []u8 {
	out := make([]u8, film.x * film.y * 4)
	at := (film - win) / 2
	sigma := st.shadow * 0.5
	drop := st.shadow * 0.3   // (the light from above: the shadow falls lower)
	lo := [2]f32{f32(at.x), f32(at.y) + drop}
	hi := [2]f32{f32(at.x + win.x), f32(at.y + win.y) + drop}
	k := 1 / (math.SQRT_TWO * sigma)
	// (the shadow is the product of a profile across and one down: each computed once, not at every pixel; the window
	// changes size at each frame of a film that narrows it)
	across := make([]f32, film.x, context.temp_allocator)
	for x in 0 ..< film.x {
		px := f32(x) + 0.5
		across[x] = 0.5 * (math.erf((px - lo.x) * k) - math.erf((px - hi.x) * k))
	}
	for y in 0 ..< film.y {
		t := f32(y) / f32(max(film.y - 1, 1))
		g: [3]f32
		for c in 0 ..< 3 { g[c] = f32(st.top[c]) * (1 - t) + f32(st.bottom[c]) * t }
		py := f32(y) + 0.5
		sy := 0.5 * (math.erf((py - lo.y) * k) - math.erf((py - hi.y) * k))
		for x in 0 ..< film.x {
			shade := 1 - 0.6 * across[x] * sy
			o := (y * film.x + x) * 4
			// (B, G, R, X)
			out[o + 0] = u8(g[2] * shade + 0.5)
			out[o + 1] = u8(g[1] * shade + 0.5)
			out[o + 2] = u8(g[0] * shade + 0.5)
			out[o + 3] = 255
		}
	}
	return out
}
