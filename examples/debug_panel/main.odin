// gui_toolkit example: the debug panel (src/md/features/debug-panel.md, docs/debug.md). A drone hovers over a grid,
// drawn by the program; its state and its acts are shared with the debug window (Ctrl+Alt+Shift+D in a build with the
// devtools): its model, its rotation, position and scale as dragged vectors, its colours, its motion, a plot of its
// height, Print (the drone as Odin source) and Reset. The World panel holds the scene's values. The Flight panel holds
// its animation (src/md/features/curve-editor.md): its hover height and its sway over time as curves, played live on the
// drone, and the easing of its landing.
//
//   odin run tools/tk -- build debug_panel
//   build/debug_panel                                  the window; Ctrl+Alt+Shift+D: the debug window
//   build/debug_panel --debug                          the debug window open at the start, on the Drone panel
//   build/debug_panel --debug=Flight                   on another panel
//   build/debug_panel --headless --still               no window of the system, the time held (tk cdp, a picture)
//   build/debug_panel --theme=Glacier --light          a theme of ui.THEMES, its light version
//   build/debug_panel --frames=3                       three frames, then exit (a check that it runs)
package debug_panel

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "gt:debug"
import "gt:devtools"
import "gt:draw"
import host "gt:host"
import "gt:platform"
import "gt:render"
import turn "gt:turn"
import "gt:ui"

WINDOW_SIZE :: [2]int{1280, 760}
// The time held by --still, seconds: the rotors and the hover at a pose worth a picture.
STILL_TIME :: 1.35

Model :: enum { Scout, Hauler, Twin, Needle }
Mode :: enum { Hover, Patrol, Land }

Drone :: struct {
	model:     int,
	frame:     Model,
	rotation:  [3]f32,   // degrees: z turns it in the picture, x and y lean it
	position:  [3]f32,   // x, y from the scene's centre in pixels; z its height, which scales it
	scale:     [3]f32,
	half_dims: [2]f32,   // the body's half width and height, pixels
	body:      ui.Color,
	light:     ui.Color,
	mode:      Mode,
	rotor_rpm: f32,
	lights_on: bool,
	name:      string,
	hover:     debug.Curve,       // its height over its place, pixels, over time
	sway:      [3]debug.Curve,    // what its rotation leans and turns by over time, degrees
	landing:   ui.Cubic_Bezier,   // how it comes down when its mode is Land
}

World :: struct {
	gravity:   f32,
	wind:      [2]f32,
	time_rate: f32,
	grid:      bool,
	grid_step: int,
	shadow:    f32,
	paused:    bool,
}

App :: struct {
	shared:   host.Shared,
	main:     host.Host,
	devtools: ^devtools.Server,
	drone:    Drone,
	world:    World,
	time:     f64,               // the scene's, seconds
	still:    bool,
	height:   ui.Value_History(120),   // the drone's height each frame (the Drone panel's plot)
	play:     debug.Playback,    // where the drone's curves are
	landed:   f32,               // 0 flying, 1 down: its landing, along its easing
	prints:   int,
	choice:   ui.Theme_Choice,
	shown:    ui.Theme_Shown,
}

// The hover: up, a dip, back over two seconds; the sway: a lean that answers it and a slow turn. As Print writes them.
HOVER :: debug.Curve{count = 4, keys = {
	0 = {time = 0, value = 0, out_handle = {0.25, 10}},
	1 = {time = 0.7, value = 18, in_handle = {-0.2, 0}, out_handle = {0.2, 0}},
	2 = {time = 1.3, value = -6, in_handle = {-0.2, 0}, out_handle = {0.25, 0}},
	3 = {time = 2, value = 0, in_handle = {-0.25, -6}},
}}
SWAY :: [3]debug.Curve{
	{count = 3, keys = {0 = {time = 0, value = 0, out_handle = {0.3, 4}}, 1 = {time = 1, value = 6, in_handle = {-0.3, 0}, out_handle = {0.3, 0}}, 2 = {time = 2, value = 0, in_handle = {-0.3, 4}}}},
	{count = 3, keys = {0 = {time = 0, value = -4, interp = .Linear}, 1 = {time = 1.2, value = 5}, 2 = {time = 2, value = -4, in_handle = {-0.25, 0}}}},
	{count = 2, keys = {0 = {time = 0, value = -8, out_handle = {0.6, 0}}, 1 = {time = 2, value = 8, in_handle = {-0.6, 0}}}},
}

DRONE_START :: Drone{
	model = 1, frame = .Scout, rotation = {8, -14, 12}, position = {0, -20, 1}, scale = {1, 1, 1}, half_dims = {74, 26},
	body = {0.92, 0.47, 0.2, 1}, light = {0.35, 0.85, 1, 1}, mode = .Hover, rotor_rpm = 380, lights_on = true,
	name = "scout-07", hover = HOVER, sway = SWAY, landing = {0.2, 0, 0, 1},
}
// A landing's time, ms; the height it lands at, pixels over the drone's place.
LANDING_MS :: 1200
LANDED_HEIGHT :: -150
WORLD_START :: World{gravity = 9.81, wind = {1.5, -0.4}, time_rate = 1, grid = true, grid_step = 48, shadow = 0.35}

// The drone's panel: what the program shares of it, each frame its procedure runs (debug-panel.md).
drone_debug :: proc(app: ^App) {
	d := &app.drone
	debug.number("model", &d.model, lo = 0, hi = 3)
	debug.choice("frame", &d.frame)
	debug.choice("mode", &d.mode)
	debug.text("name", &d.name)
	if debug.section("Transform") {
		debug.vector("rotation", &d.rotation, lo = -180, hi = 180, step = 0.5)
		debug.vector("position", &d.position, step = 0.5)
		debug.vector("scale", &d.scale, lo = 0.1, hi = 4, step = 0.01)
		debug.vector("half dims", &d.half_dims, lo = 4, hi = 200, step = 1)
	}
	if debug.section("Look") {
		debug.color("body", &d.body)
		debug.color("light", &d.light)
		debug.toggle("lights", &d.lights_on)
	}
	if debug.section("Motion") {
		debug.number("rotor rpm", &d.rotor_rpm, lo = 0, hi = 2000, step = 10)
		debug.plot("height", &app.height)
	}
	debug.watch("prints", app.prints)
	if debug.act("Print") {
		fmt.println(debug.odin_text(d^))
		app.prints += 1
	}
	if debug.act("Reset") { d^ = DRONE_START }
}

// The drone's animation: its curves played on the program's clock (app.play), the easing of its landing.
flight_debug :: proc(app: ^App) {
	d := &app.drone
	debug.curve("hover", &d.hover, &app.play)
	debug.curves("sway", d.sway[:], &app.play)
	debug.easing("landing", &d.landing)
	debug.choice("mode", &d.mode)
	if debug.act("Print curves") {
		fmt.println(debug.curve_text(d.hover))
		fmt.println(debug.curves_text(d.sway[:]))
	}
}

// The scene's panel, the whole World by reflection, and its time.
world_debug :: proc(app: ^App) {
	debug.value("world", &app.world)
	debug.watch("time", fmt.tprintf("%.2f s", app.time))
	if debug.act("Reset world") { app.world = WORLD_START }
}

build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	if !app.world.paused && !app.still { app.time += f64(h.state.dt * app.world.time_rate) }
	d := &app.drone
	// (its curves on the program's clock: the debug window pauses, scrubs and loops the same Playback)
	dt := app.world.paused || app.still ? 0 : h.state.dt * app.world.time_rate
	debug.playback_step(&app.play, dt, span_of(d))
	app.landed = ui.tween_curve(ui.key_from_string(0, "drone_landing"), d.mode == .Land ? 1 : 0, LANDING_MS, d.landing)
	ui.value_history_push(&app.height, drone_height(app))
	ui.next({width = ui.fill(), height = ui.fill()})
	ui.custom("###scene", scene_draw, app)
	h.state.anim_busy = !app.world.paused && !app.still   // (the rotors turn: a frame after another)
}

// The time the drone's curves loop over: from their first key to their last.
span_of :: proc(d: ^Drone) -> [2]f32 {
	all := [4]debug.Curve{d.hover, d.sway[0], d.sway[1], d.sway[2]}
	return debug.curves_span(all[:])
}

// The drone's height over its place: its position's y and its hover curve, then its landing.
drone_height :: proc(app: ^App) -> f32 {
	d := &app.drone
	flying := -d.position.y + debug.curve_eval(d.hover, app.play.time)
	return flying + (LANDED_HEIGHT - flying) * app.landed
}

// Its rotation: its own and its sway curves, which a landing settles.
drone_rotation :: proc(app: ^App) -> [3]f32 {
	d := &app.drone
	return d.rotation + debug.curves_eval(d.sway, app.play.time) * (1 - app.landed)
}

scene_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	app := (^App)(user)
	d := &app.drone
	w := &app.world
	sc := ui.scale()
	r := b.rect
	// the ground: the theme's window colour, a grid
	draw.rect(dc, r, ui.theme_color("background"))
	grid := ui.theme_color("border")
	if w.grid && w.grid_step > 4 {
		step := f32(w.grid_step) * sc
		for x := r.min.x + math.mod(r.max.x * 0.5, step); x < r.max.x; x += step { draw.rect(dc, {{x, r.min.y}, {x + sc, r.max.y}}, grid) }
		for y := r.min.y + math.mod(r.max.y * 0.5, step); y < r.max.y; y += step { draw.rect(dc, {{r.min.x, y}, {r.max.x, y + sc}}, grid) }
	}
	// the drone's place: the left part of the window, the debug window is at the right
	centre := draw.Vec2{r.min.x + (r.max.x - r.min.x) * 0.36, r.min.y + (r.max.y - r.min.y) * 0.5}
	sway := w.wind * f32(math.sin(app.time * 0.7)) * 4
	at := centre + (draw.Vec2{d.position.x, -drone_height(app)} + sway) * sc
	depth := clamp(d.position.z, 0.2, 4)
	k := draw.Vec2{d.scale.x, d.scale.y} * depth * sc
	rotation := drone_rotation(app)
	// (a lean about x and y shortens the drone across: a cosine of its angle)
	k.x *= f32(math.abs(math.cos(f64(rotation.y) * math.PI / 180)))
	k.y *= f32(math.abs(math.cos(f64(rotation.x) * math.PI / 180)))
	// its shadow on the ground, under it, smaller the higher it is
	ground := centre.y + 190 * sc
	lift := clamp((ground - at.y) / (300 * sc), 0, 1)
	sw := d.half_dims.x * k.x * (1.2 - 0.5 * lift)
	draw.rect(dc, {{at.x - sw, ground - 6 * sc}, {at.x + sw, ground + 6 * sc}}, {0, 0, 0, w.shadow * (1 - 0.6 * lift)}, 6 * sc, soft = 10 * sc)
	draw.push_transform(dc, draw.affine_around(draw.affine_mul(draw.affine_rotate(turn.from_degrees(rotation.z)), draw.affine_scale(k)), at))
	defer draw.pop_transform(dc)
	hx, hy := d.half_dims.x, d.half_dims.y
	arms := 2 if d.frame != .Twin else 1
	spin := f32(math.mod(app.time * f64(d.rotor_rpm) / 60, 1))
	// the arms and the rotors, two a side
	for side in ([]f32{-1, 1}) {
		for i in 0 ..< arms {
			dy := arms == 1 ? 0 : (f32(i) - 0.5) * hy * 1.6
			tip := draw.Vec2{at.x + side * (hx + 34), at.y + dy - hy * 0.6}
			draw.line(dc, {at.x + side * hx * 0.6, at.y + dy * 0.5}, tip, 6, {0.2, 0.22, 0.26, 1})
			// (the blades seen edge on: a long ellipse whose width turns with the spin)
			bw := 30 * f32(math.abs(math.cos(f64(spin + f32(i) * 0.25 + (side > 0 ? 0.1 : 0)) * math.TAU))) + 6
			draw.rect(dc, {{tip.x - bw, tip.y - 3}, {tip.x + bw, tip.y + 3}}, {0.75, 0.78, 0.82, 0.85}, 3)
			draw.rect(dc, {{tip.x - 5, tip.y - 5}, {tip.x + 5, tip.y + 5}}, {0.15, 0.16, 0.18, 1}, 5)
		}
	}
	// the body: its shape by its model
	radius := [4]f32{hy, hy * 0.5, 8, hy * 0.9}[clamp(d.model, 0, 3)]
	body := draw.Rect{{at.x - hx, at.y - hy}, {at.x + hx, at.y + hy}}
	if d.frame == .Needle { body.min.x += hx * 0.3; body.max.x -= hx * 0.3 }
	draw.rect(dc, body, d.body, radius)
	draw.rect(dc, {{body.min.x + 6, body.min.y + 4}, {body.max.x - 6, at.y - hy * 0.2}}, {1, 1, 1, 0.18}, max(radius - 4, 0))
	if d.frame == .Hauler { draw.rect(dc, {{at.x - hx * 0.55, at.y + hy}, {at.x + hx * 0.55, at.y + hy + 18}}, {0.25, 0.27, 0.3, 1}, 4) }
	// its eye and its lights
	draw.rect(dc, {{at.x + hx * 0.35, at.y - 8}, {at.x + hx * 0.75, at.y + 8}}, {0.08, 0.09, 0.11, 1}, 8)
	if d.lights_on {
		blink := f32(0.55 + 0.45 * math.sin(app.time * 5))
		l := d.light
		l.a *= blink
		draw.rect(dc, {{at.x + hx * 0.45, at.y - 4}, {at.x + hx * 0.65, at.y + 4}}, l, 4)
		draw.rect(dc, {{at.x - hx - 4, at.y - 4}, {at.x - hx + 4, at.y + 4}}, l, 4, soft = 6)
	}
}

main :: proc() {
	frames := -1
	open_debug, still, headless := false, false, false
	debug_panel := "Drone"
	app := new(App)
	defer free(app)
	app.choice = {name = "Graphite", mode = .Dark, finish = .Flat}
	for a in os.args[1:] {
		switch {
		case strings.has_prefix(a, "--frames="): frames, _ = strconv.parse_int(a[len("--frames="):])
		case a == "--debug":    open_debug = true
		case strings.has_prefix(a, "--debug="): open_debug, debug_panel = true, a[len("--debug="):]
		case a == "--still":    still = true
		case a == "--headless": headless = true
		case a == "--light":    app.choice.mode = .Light
		case strings.has_prefix(a, "--theme="): app.choice.name = a[len("--theme="):]
		}
	}
	app.drone, app.world, app.still = DRONE_START, WORLD_START, still
	if still {
		// (the time held: the height's plot shows the two seconds before it, as a running drone's would)
		for i in 0 ..< len(app.height.values) {
			app.time = STILL_TIME - f64(len(app.height.values) - i) / 60
			app.play.time = f32(app.time)
			ui.value_history_push(&app.height, drone_height(app))
		}
		app.time = STILL_TIME
		app.play = {time = STILL_TIME, paused = true}
	}
	if !host.host_open(&app.main, &app.shared, {title = "Debug panel", size = WINDOW_SIZE, headless = headless}, build, app) { os.exit(1) }
	defer host.host_close(&app.main)
	h := &app.main
	h.background = ui.theme_lookup(&app.shared.theme, {}, "background")
	h.params = proc(h: ^host.Host, p: ^ui.Build_Params) {
		app := (^App)(h.user)
		if ui.theme_show(&app.shared.theme, ui.THEMES[:], app.choice, &app.shown, render.blend_space(&app.shared.r)) {
			platform.set_dark_title(h.win, !app.shown.light)
			h.background = ui.theme_lookup(&app.shared.theme, {}, "background")
		}
	}
	h.before_input = proc(h: ^host.Host) { app := (^App)(h.user); devtools.service(app.devtools, &h.state, &app.shared.r) }
	app.devtools = devtools.start_from_env(h.win, "Debug panel")
	defer devtools.stop(app.devtools)
	// (once: the window runs the procedures when it shows them, the tools when they ask)
	debug.panel(&h.state, "Drone", drone_debug, app)
	debug.panel(&h.state, "World", world_debug, app)
	debug.panel(&h.state, "Flight", flight_debug, app)
	if open_debug {
		debug.open(&h.state)
		debug.show_panel(&h.state, debug_panel)
	}
	if frames >= 0 {
		for _ in 0 ..< frames { host.host_frame(h) }
		fmt.printfln("debug_panel: %d frames, %d boxes", frames, h.state.boxes_built)
		return
	}
	if !platform.is_offscreen(h.win) { platform.show_window(h.win) }
	for !platform.is_closed(h.win) {
		host.hosts_wait({h})
		host.host_frame(h)
	}
}

