#+build windows
package examples_test

// examples/whatsnew in this process, with no window, driven over the devtools protocol as a tool would, by a client with no socket (devtools.Local_Client):
// each page must show no layout warning and nothing a screen reader cannot name, and must look like its reference image; then the scenarios of what broke before,
// and Chrome's DevTools' way through the box tree. (The socket itself: tests/devtools. tools/timeline.mjs, which is a Node program: tests/e2e/timeline.mjs. Windows only:
// the reference images were made with the system's fonts, on WARP.)

import "base:runtime"
import "core:bytes"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"

import "core:image/png"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "../../devtools"
import "../../examples/whatsnew"
import "../../testkit/session"

// The numbers a page shows live (its frame counters, its timings) may differ on this share of its pixels, by this much.
@(private = "file") MAX_SHARE :: 0.004
// The last frame of a screencast against the window: it is drawn by the window just after.
@(private = "file") CAST_MAX_SHARE :: 0.02
@(private = "file") PIXEL_DELTA :: 32
// What a call may take before the test has failed (a limit for a failing run only).
@(private = "file") CALL_LIMIT :: 60 * time.Second
@(private = "file") IDLE_TIMEOUT_MS :: 10000
// A point of the content, where the lazy column and the wheel page are.
@(private = "file") CONTENT_X :: 700
@(private = "file") CONTENT_Y :: 400
// A wheel's burst: pixels a notch, notches.
@(private = "file") BURST_DELTA :: 1500
@(private = "file") BURST_NOTCHES :: 12
// The items a lazy column builds at most, for a window's height.
@(private = "file") LAZY_MAX_BUILT :: 200
@(private = "file") WINDOW_HEIGHT :: 720
// Colours within this of each other are one (rounding through sRGB).
@(private = "file") COLOR_TOLERANCE :: 3
// A pixel inside a button, past its rounded corner.
@(private = "file") INSIDE_BUTTON :: [2]f64{4, 3}
// Frames a client's end takes to be seen.
@(private = "file") CLIENT_GONE_FRAMES :: 4
// Rounds of a loop in which nothing asks for a frame: at rest.
@(private = "file") CAST_REST_ROUNDS :: 40
// A long text, read while it is replaced: nothing of the old one or a mix of both.
@(private = "file") LONG_TEXT_BYTES :: 300
@(private = "file") LONG_TEXT_ROUNDS :: 10
@(private = "file") CAST_STOPS :: 12
@(private = "file") METRIC_CLICKS :: 6
@(private = "file") METRIC_SLACK_FRAMES :: 3
@(private = "file") METRIC_SLACK_MS :: 0.011
@(private = "file") SHOT_PART_WIDTH :: 40

@(private = "file")
PAGES := [][2]string{
	{"pacing", "1  Frame pacing"}, {"lazy", "2  Lazy column"}, {"warning", "3  Layout warnings"}, {"emboss", "4  Emboss"},
	{"rich", "5  Rich text"}, {"merge", "6  next_merge"}, {"wheel", "7  Wheel"}, {"find", "8  Find"},
	{"smooth", "9  Smooth"}, {"box_at", "10  box_at"}, {"webgpu", "11  WebGPU"}, {"tests", "12  Test guard"},
}

// The application and its server.
@(private = "file")
Rig :: struct {
	s:   ^session.Session,
	app: ^whatsnew.App,
	srv: ^devtools.Server,
	c:   ^Client,
}

// A client: what it was told and has not read yet.
@(private = "file")
Client :: struct {
	rig:     ^Rig,
	l:       devtools.Local_Client,
	next_id: i64,
	events:  [dynamic]Event,
	closed:  bool,
}

@(private = "file") Event :: struct { method: string, params: json.Value }

@(private = "file")
start_whatsnew :: proc(t: ^testing.T, loc := #caller_location) -> ^Rig {
	context.allocator = runtime.heap_allocator()
	app, _ := whatsnew.open({}, headless_default = true)
	if !testing.expect(t, app != nil, "whatsnew opens", loc = loc) { session.stop_test(t, "no application", loc) }
	testing.cleanup(t, proc(p: rawptr) {
		context.allocator = runtime.heap_allocator()
		r := (^Rig)(p)
		devtools.stop(r.app.devtools)
		r.app.devtools = nil
		whatsnew.close(r.app)
		free(r)
	}, new_rig(app))
	r := the_rig
	r.srv = devtools.start_local(app.win, "whatsnew")
	app.devtools = r.srv
	r.s = session.attach(t, {win = app.win, state = &app.s, renderer = &app.r, user = app, allocator = context.allocator,
		frame = proc(user: rawptr) { whatsnew.frame((^whatsnew.App)(user)) }}, loc)
	session.frames(r.s, 2)
	r.c = connect(r)
	return r
}

@(private = "file") the_rig: ^Rig

@(private = "file")
new_rig :: proc(app: ^whatsnew.App) -> ^Rig {
	the_rig = new(Rig)
	the_rig.app = app
	return the_rig
}

@(private = "file")
connect :: proc(r: ^Rig) -> ^Client {
	c := new(Client, r.s.test.temp_allocator)
	c.rig = r
	c.l = devtools.local_connect(r.srv)
	c.events.allocator = r.s.test.temp_allocator
	return c
}

// The client goes, and the frames that show it.
@(private = "file")
leave :: proc(c: ^Client) {
	if c.closed { return }
	c.closed = true
	devtools.local_close(c.l)
	session.frames(c.rig.s, CLIENT_GONE_FRAMES)
}

// A command's answer: `refused` is the error it was answered with. What came before it is kept in `c.events`.
@(private = "file")
ask :: proc(c: ^Client, method: string, params := "{}", loc := #caller_location) -> (result: json.Value, refused: string) {
	s := c.rig.s
	c.next_id += 1
	id := c.next_id
	devtools.local_send(c.l, fmt.tprintf(`{{"id":%d,"method":%q,"params":%s}}`, id, method, params))
	end := time.tick_add(time.tick_now(), CALL_LIMIT)
	answered := false
	for {
		// (the whole batch: what came after the answer in it is not lost)
		for m in devtools.local_take(c.l, context.temp_allocator) {
			v, err := json.parse_string(m, parse_integers = true, allocator = context.temp_allocator)
			if err != nil { session.failed(s, fmt.tprintf("%s: not JSON: %v", method, err), loc) }
			o := v.(json.Object) or_continue
			if name, ok := o["method"].(json.String); ok {
				append(&c.events, Event{string(name), o["params"]})
				continue
			}
			if i64(number(o["id"])) != id { continue }
			answered = true
			if e, ok := o["error"].(json.Object); ok { refused = text_of(e["message"]) } else { result = o["result"] }
		}
		if answered { return }
		if time.tick_diff(time.tick_now(), end) <= 0 { session.failed(s, fmt.tprintf("%v passed waiting for the answer to %s", CALL_LIMIT, method), loc) }
		session.frame(s)
	}
}

// A command that must be answered: a refusal ends the test.
@(private = "file")
send :: proc(c: ^Client, method: string, params := "{}", loc := #caller_location) -> json.Value {
	v, refused := ask(c, method, params, loc)
	if refused != "" { session.failed(c.rig.s, fmt.tprintf("%s %s: %s", method, params, refused), loc) }
	return v
}

@(private = "file")
idle :: proc(c: ^Client, loc := #caller_location) {
	v := send(c, "Toolkit.waitIdle", fmt.tprintf(`{{"timeout":%d}}`, IDLE_TIMEOUT_MS), loc)
	if !bool_of(field(v, "idle")) { session.failed(c.rig.s, "still moving after its limit", loc) }
}

@(private = "file")
Picture :: session.Image

// The screenshot of the whole window, or of `clip` ("": all).
@(private = "file")
shot :: proc(c: ^Client, clip := "", loc := #caller_location) -> Picture {
	params := clip == "" ? `{"format":"png"}` : fmt.tprintf(`{{"format":"png","clip":%s}}`, clip)
	return decode_shot(c.rig.s, text_of(field(send(c, "Page.captureScreenshot", params, loc), "data")), loc)
}

@(private = "file")
decode_shot :: proc(s: ^session.Session, data: string, loc := #caller_location) -> Picture {
	raw, derr := base64.decode(data, allocator = context.temp_allocator)
	if derr != nil { session.failed(s, "a picture that is not base64", loc) }
	img, err := png.load_from_bytes(raw, {.alpha_add_if_missing}, context.temp_allocator)
	if err != nil { session.failed(s, fmt.tprintf("a picture that is not a PNG: %v", err), loc) }
	return {bytes.buffer_to_bytes(&img.pixels), img.width, img.height}
}

////////////////////////////////
// JSON

@(private = "file") field :: proc(v: json.Value, name: string) -> json.Value { o, _ := v.(json.Object); return o[name] }
@(private = "file") text_of :: proc(v: json.Value) -> string { s, _ := v.(json.String); return string(s) }
@(private = "file") bool_of :: proc(v: json.Value) -> bool { b, _ := v.(json.Boolean); return bool(b) }
@(private = "file") list_of :: proc(v: json.Value) -> json.Array { a, _ := v.(json.Array); return a }
@(private = "file")
number :: proc(v: json.Value) -> f64 {
	#partial switch n in v {
	case json.Integer: return f64(n)
	case json.Float:   return f64(n)
	}
	return 0
}

// A DOM node's attributes: name and value in turn.
@(private = "file")
attribute :: proc(n: json.Value, name: string) -> string {
	a := list_of(field(n, "attributes"))
	for i := 0; i + 1 < len(a); i += 2 { if text_of(a[i]) == name { return text_of(a[i + 1]) } }
	return ""
}

// The first node that `ok` says is the one, depth first.
@(private = "file")
search :: proc(n: json.Value, data: string, ok: proc(n: json.Value, data: string) -> bool) -> json.Value {
	if ok(n, data) { return n }
	for c in list_of(field(n, "children")) { if r := search(c, data, ok); r != nil { return r } }
	return nil
}

@(private = "file") by_id :: proc(root: json.Value, id: string) -> json.Value { return search(root, id, proc(n: json.Value, id: string) -> bool { return attribute(n, "id") == id }) }
@(private = "file") first_text :: proc(n: json.Value) -> json.Value { return search(n, "", proc(n: json.Value, _: string) -> bool { return number(field(n, "nodeType")) == 3 }) }
@(private = "file") node_id :: proc(n: json.Value) -> int { return int(number(field(n, "nodeId"))) }

@(private = "file")
document :: proc(c: ^Client, loc := #caller_location) -> json.Value { return field(send(c, "DOM.getDocument", `{"depth":-1}`, loc), "root") }

@(private = "file")
count_named :: proc(c: ^Client, name: string, loc := #caller_location) -> int {
	idle(c, loc)
	return len(list_of(field(send(c, "Toolkit.find", fmt.tprintf(`{{"name":%q}}`, name), loc), "nodes")))
}

@(private = "file")
count_labelled :: proc(c: ^Client, label: string, loc := #caller_location) -> int {
	return len(list_of(field(send(c, "Accessibility.queryAXTree", fmt.tprintf(`{{"accessibleName":%q}}`, label), loc), "nodes")))
}

// The name's value in a style's text is replaced ("name: value;").
@(private = "file")
with_property :: proc(css, name, value: string) -> string {
	at := strings.index(css, fmt.tprintf("%s: ", name))
	if at < 0 { return css }
	end := strings.index_byte(css[at:], ';')
	if end < 0 { return css }
	return fmt.tprintf("%s%s: %s;%s", css[:at], name, value, css[at + end + 1:])
}

@(private = "file") json_string :: proc(s: string) -> string { b, _ := json.marshal(s, allocator = context.temp_allocator); return string(b) }

@(private = "file")
inline_style :: proc(c: ^Client, id: int, loc := #caller_location) -> json.Value {
	return field(send(c, "CSS.getMatchedStylesForNode", fmt.tprintf(`{{"nodeId":%d}}`, id), loc), "inlineStyle")
}

@(private = "file")
set_style :: proc(c: ^Client, style: json.Value, text: string, loc := #caller_location) {
	range, _ := json.marshal(field(style, "range"), allocator = context.temp_allocator)
	send(c, "CSS.setStyleTexts", fmt.tprintf(`{{"edits":[{{"styleSheetId":%s,"range":%s,"text":%s}}]}}`, json_string(text_of(field(style, "styleSheetId"))), string(range), json_string(text)), loc)
}

@(private = "file")
computed_value :: proc(c: ^Client, id: int, name: string, loc := #caller_location) -> string {
	for p in list_of(field(send(c, "CSS.getComputedStyleForNode", fmt.tprintf(`{{"nodeId":%d}}`, id), loc), "computedStyle")) {
		if text_of(field(p, "name")) == name { return text_of(field(p, "value")) }
	}
	return ""
}

@(private = "file")
box_content :: proc(c: ^Client, id: int, loc := #caller_location) -> (x, y, width: f64) {
	m := field(send(c, "DOM.getBoxModel", fmt.tprintf(`{{"nodeId":%d}}`, id), loc), "model")
	content := list_of(field(m, "content"))
	return number(content[0]), number(content[1]), number(field(m, "width"))
}

// The colour in a css value: "rgb(1, 2, 3)", "rgba(1, 2, 3, 1)".
@(private = "file")
css_rgb :: proc(v: string) -> (out: session.Color) {
	rest := v
	if i := strings.index_byte(rest, '('); i >= 0 { rest = rest[i + 1:] }
	out.a = 255
	for k in 0 ..< 3 {
		end := strings.index_any(rest, ",) ")
		if end < 0 { return }
		n, _ := strconv.parse_int(rest[:end])
		out[k] = u8(n)
		rest = strings.trim_left(rest[end:], ", ")
	}
	return
}

////////////////////////////////
// The pages

@(test)
whatsnew_pages_look_like_their_images :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	c := r.c
	dir := fmt.tprintf("%s/tests/examples/baseline", session.repo_root())
	update, _ := os.lookup_env("TOOLKIT_TEST_UPDATE", context.temp_allocator)
	for page in PAGES {
		send(c, "Toolkit.axAction", fmt.tprintf(`{{"role":"button","name":%q,"action":"Click"}}`, page[1]))
		idle(c)
		warnings := list_of(field(send(c, "Toolkit.warnings"), "layout"))
		testing.expectf(t, len(warnings) == 0, "%s: layout warnings: %v", page[0], warnings)
		unnamed := list_of(field(send(c, "Toolkit.axAudit"), "unnamed"))
		testing.expectf(t, len(unnamed) == 0, "%s: %d controls a screen reader cannot name", page[0], len(unnamed))
		{
			got := shot(c)
			path := fmt.tprintf("%s/%s.png", dir, page[0])
			if update == "1" {
				data := devtools.png_encode(got.rgba, got.width, got.height)
				defer delete(data)
				_ = os.write_entire_file(path, data)
				continue
			}
			want, ok := session.load_png(r.s, path)
			testing.expectf(t, ok, "%s: no reference image", page[0])
			if !ok { continue }
			n := session.count_different(got, want, PIXEL_DELTA)
			share := f64(n) / f64(got.width * got.height)
			testing.expectf(t, n >= 0 && share <= MAX_SHARE, "%s: %.2f%% of the pixels differ", page[0], share * 100)
			if n < 0 || share > MAX_SHARE { session.save_png(r.s, fmt.tprintf("%s.actual.png", page[0])) }
		}
	}
}

// The lazy column after a burst of the wheel: items in view (it once showed an empty view), and only those built.
@(test)
whatsnew_lazy_column_after_a_wheel_burst :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	c := r.c
	send(c, "Toolkit.click", `{"text":"2  Lazy column"}`)
	idle(c)
	for _ in 0 ..< BURST_NOTCHES {
		send(c, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseWheel","x":%d,"y":%d,"deltaX":0,"deltaY":%d}}`, CONTENT_X, CONTENT_Y, BURST_DELTA))
	}
	idle(c)
	built := number(field(send(c, "Toolkit.metrics"), "lazyBuilt"))
	testing.expectf(t, built > 0 && built <= LAZY_MAX_BUILT, "%v items built", built)
	in_view := false
	for n in list_of(field(send(c, "Toolkit.find", `{"text":"Item "}`), "nodes")) {
		y := number(field(n, "y"))
		if y >= 0 && y < WINDOW_HEIGHT { in_view = true }
	}
	testing.expect(t, in_view, "something is in view after a burst")
}

// Find in a page, then the page left with its scope gone (it once crashed).
@(test)
whatsnew_find_then_leaving_its_page :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	c := r.c
	send(c, "Toolkit.click", `{"text":"8  Find"}`)
	idle(c)
	send(c, "Input.dispatchKeyEvent", `{"type":"rawKeyDown","key":"f","modifiers":2}`)
	send(c, "Input.dispatchKeyEvent", `{"type":"keyUp","key":"f","modifiers":2}`)
	send(c, "Input.insertText", `{"text":"the"}`)
	idle(c)
	send(c, "Toolkit.click", `{"text":"1  Frame pacing"}`)
	idle(c)
	send(c, "Toolkit.waitFor", `{"text":"1  Frame pacing","timeout":2000}`)
}

// A wait that cannot end says so.
@(test)
devtools_a_wait_times_out :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	_, refused := ask(r.c, "Toolkit.waitFor", `{"text":"no such text anywhere","timeout":100}`)
	testing.expect(t, refused != "", "waitFor says it did not find it")
}

////////////////////////////////
// The recorder

// A line of the recorder, carried out as a tool that plays it does: `click --name "x"`, `idle`, `wheel x y down across`, `press "name" --role r`.
@(private = "file")
play :: proc(c: ^Client, line: string, loc := #caller_location) {
	words := make([dynamic]string, context.temp_allocator)
	rest := line
	for len(rest) > 0 {
		rest = strings.trim_left_space(rest)
		if len(rest) == 0 { break }
		if rest[0] == '"' {
			end := strings.index_byte(rest[1:], '"')
			append(&words, rest[1:][:end])
			rest = rest[end + 2:]
		} else {
			end := strings.index_byte(rest, ' ')
			if end < 0 { end = len(rest) }
			append(&words, rest[:end])
			rest = rest[end:]
		}
	}
	switch words[0] {
	case "idle": idle(c, loc)
	case "click": send(c, "Toolkit.click", fmt.tprintf(`{{"name":%q}}`, words[2]), loc)
	case "wheel":
		num :: proc(s: string) -> f64 { v, _ := strconv.parse_f64(s); return v }
		send(c, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseWheel","x":%v,"y":%v,"deltaX":%v,"deltaY":%v}}`, num(words[1]), num(words[2]), num(words[4]) * 100, num(words[3]) * 100), loc)
	case "press": send(c, "Toolkit.axAction", fmt.tprintf(`{{"role":%q,"name":%q,"action":"Click"}}`, words[3], words[1]), loc)
	case: session.failed(c.rig.s, fmt.tprintf("no such line: %s", line), loc)
	}
}

@(private = "file")
stop_recording :: proc(c: ^Client, loc := #caller_location) -> []string {
	a := list_of(field(send(c, "Toolkit.stopRecording", loc = loc), "lines"))
	out := make([]string, len(a), context.temp_allocator)
	for l, i in a { out[i] = text_of(l) }
	return out
}

// What is done becomes a script that does the same again.
@(test)
devtools_recorder_writes_what_plays_again :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	c := r.c
	send(c, "Toolkit.startRecording", `{"injected":true}`)
	send(c, "Toolkit.click", `{"name":"nav5"}`)
	idle(c)
	lines := stop_recording(c)
	testing.expectf(t, len(lines) > 0 && lines[0] == `click --name "nav5"`, "the recorder: %v", lines)
	merge := shot(c)
	send(c, "Toolkit.click", `{"name":"nav0"}`)
	idle(c)
	testing.expect(t, session.count_different(shot(c), merge, PIXEL_DELTA) > 0, "another page")
	for l in lines { play(c, l) }
	idle(c)
	again := f64(session.count_different(shot(c), merge, PIXEL_DELTA)) / f64(merge.width * merge.height)
	testing.expectf(t, again <= MAX_SHARE, "the recorder's script, played: %.2f%% differ", again * 100)
}

// The wheel across, recorded and played; an action sent as a reader's, recorded as a press and played.
@(test)
devtools_recorder_wheel_and_reader_s_press :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	c := r.c
	send(c, "Toolkit.startRecording", `{"injected":true}`)
	send(c, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseWheel","x":%d,"y":%d,"deltaX":300,"deltaY":0}}`, CONTENT_X, CONTENT_Y))
	idle(c)
	send(c, "Toolkit.pollRecording")
	send(c, "Toolkit.axAction", `{"role":"button","name":"6  next_merge","action":"Click"}`)
	idle(c)
	lines := stop_recording(c)
	across := fmt.tprintf("wheel %d %d 0 3", CONTENT_X, CONTENT_Y)
	press := `press "6  next_merge" --role button`
	has :: proc(lines: []string, want: string) -> bool { for l in lines { if l == want { return true } }; return false }
	testing.expectf(t, has(lines, across), "the wheel across, recorded: %v", lines)
	testing.expectf(t, has(lines, press), "a reader's action, recorded: %v", lines)
	merge := shot(c)
	send(c, "Toolkit.click", `{"name":"nav0"}`)
	idle(c)
	send(c, "Toolkit.startRecording", `{"injected":true}`)
	play(c, across)
	play(c, press)
	idle(c)
	played := stop_recording(c)
	testing.expectf(t, has(played, across) && has(played, press), "played: %v", played)
	again := f64(session.count_different(shot(c), merge, PIXEL_DELTA)) / f64(merge.width * merge.height)
	testing.expectf(t, again <= MAX_SHARE, "the press played: %.2f%% differ", again * 100)
}

////////////////////////////////
// The screencast

// Frames while something changes, none at rest, and the last one is what the window shows.
@(test)
devtools_screencast_comes_to_rest :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	c := r.c
	send(c, "Page.startScreencast", `{"format":"png","minIntervalMs":0}`)
	send(c, "Toolkit.click", `{"name":"nav1"}`)
	idle(c)
	frames := 0
	last: Picture
	take :: proc(c: ^Client, frames: ^int, last: ^Picture) {
		events := c.events
		c.events = make([dynamic]Event, context.temp_allocator)   // (an answer's wait gathers more)
		for e in events {
			if e.method != "Page.screencastFrame" { continue }
			frames^ += 1
			last^ = decode_shot(c.rig.s, text_of(field(e.params, "data")))
			send(c, "Page.screencastFrameAck", fmt.tprintf(`{{"sessionId":%d}}`, int(number(field(e.params, "sessionId")))))
		}
	}
	// As a program's loop at rest: a frame only when the server asks for one, which is what wakes the window. It comes to rest within a few frames of
	// nothing changing, even though the window shows a figure of its own build (what it still sends then is the last of what changed).
	take(c, &frames, &last)
	srv := r.srv
	rest := 0
	end := time.tick_add(time.tick_now(), CALL_LIMIT)
	for rest < CAST_REST_ROUNDS || frames == 0 {
		if time.tick_diff(time.tick_now(), end) <= 0 { break }
		asked := sync.atomic_load(&srv.cast_dirty) || sync.atomic_load(&srv.waiting) > 0
		if asked { session.frame(r.s) } else { devtools.service(srv, &r.app.s, &r.app.r) }
		busy := sync.atomic_load(&srv.encoding) > 0
		for m in devtools.local_take(c.l, context.temp_allocator) {
			v, _ := json.parse_string(m, parse_integers = true, allocator = context.temp_allocator)
			o := v.(json.Object) or_continue
			if name, ok := o["method"].(json.String); ok { append(&c.events, Event{string(name), o["params"]}); asked = true }
		}
		take(c, &frames, &last)
		rest = asked || busy ? 0 : rest + 1
	}
	send(c, "Page.stopScreencast")
	testing.expect(t, frames >= 1, "a frame came")
	testing.expect(t, rest >= CAST_REST_ROUNDS, "and it came to rest")
	if frames >= 1 {
		share := f64(session.count_different(last, shot(c), PIXEL_DELTA)) / f64(last.width * last.height)
		testing.expectf(t, share <= CAST_MAX_SHARE, "the last frame is what the window shows: %.2f%% differ", share * 100)
	}
}

// A screencast stopped while its frame is being read back: pictures still come (nothing read that capture, none could start).
@(test)
devtools_a_screencast_stopped_at_any_moment :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	c := r.c
	for _ in 0 ..< CAST_STOPS {
		send(c, "Page.startScreencast", `{"format":"png","minIntervalMs":0}`)
		send(c, "Page.stopScreencast")
		testing.expect(t, shot(c).width > 0, "a picture after it")
	}
}

////////////////////////////////
// Frames and screenshots

// The frame times, whichever way they are read: the same frames, the same numbers.
@(test)
devtools_metrics_and_frames_agree :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	c := r.c
	send(c, "Toolkit.metrics", `{"reset":true}`)
	built := int(number(field(send(c, "Toolkit.state"), "build")))
	for i in 0 ..< METRIC_CLICKS {
		send(c, "Toolkit.click", fmt.tprintf(`{{"name":"nav%d"}}`, i % 2))
		send(c, "Page.captureScreenshot")
	}
	idle(c)
	m := send(c, "Toolkit.metrics")
	last_build := number(field(m, "build"))
	listed := 0
	most := 0.0
	timed := 0
	for f in list_of(field(send(c, "Toolkit.frames", fmt.tprintf(`{{"after":%d}}`, built - 1)), "frames")) {
		if number(field(f, "build")) > last_build { continue }   // (the frames that answered these calls: the metrics' were read before them)
		listed += 1
		ms := number(field(f, "frameMs"))
		most = max(most, ms)
		if ms > 0 { timed += 1 }
	}
	count := int(number(field(m, "frames")))
	testing.expectf(t, count >= METRIC_CLICKS, "%d frames in the metrics", count)
	testing.expectf(t, abs(listed - count) <= METRIC_SLACK_FRAMES, "%d frames listed, %d in the metrics", listed, count)
	testing.expectf(t, abs(most - number(field(field(m, "frameMs"), "max"))) <= METRIC_SLACK_MS, "the longest: %v and %v", most, number(field(field(m, "frameMs"), "max")))
	testing.expect(t, timed > 0, "the frames are timed")
}

// Two screenshots at once, each of its own part of the window.
@(test)
devtools_two_screenshots_at_once :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	c := r.c
	s := r.s
	c.next_id += 2
	whole_id, part_id := c.next_id - 1, c.next_id
	devtools.local_send(c.l, fmt.tprintf(`{{"id":%d,"method":"Page.captureScreenshot","params":{{"clip":{{"x":0,"y":0,"width":%d,"height":20,"scale":1}}}}}}`, part_id, SHOT_PART_WIDTH))
	devtools.local_send(c.l, fmt.tprintf(`{{"id":%d,"method":"Page.captureScreenshot","params":{{}}}}`, whole_id))
	part, whole: Picture
	end := time.tick_add(time.tick_now(), CALL_LIMIT)
	for (part.width == 0 || whole.width == 0) && time.tick_diff(time.tick_now(), end) > 0 {
		for m in devtools.local_take(c.l, context.temp_allocator) {
			v, _ := json.parse_string(m, parse_integers = true, allocator = context.temp_allocator)
			id := i64(number(field(v, "id")))
			if id != part_id && id != whole_id { continue }
			img := decode_shot(s, text_of(field(field(v, "result"), "data")))
			if id == part_id { part = img } else { whole = img }
		}
		session.frame(s)
	}
	testing.expect_value(t, part.width, SHOT_PART_WIDTH)
	testing.expect(t, whole.width > part.width, "each of its own part")
}

////////////////////////////////
// The box tree as Chrome's DevTools sees it

// A box, its text, its model, its style, its accessible node, the node at a point, and the events of a change of page.
@(test)
devtools_box_tree :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	c := r.c
	root := document(c)
	button := search(root, "", proc(n: json.Value, _: string) -> bool { return text_of(field(n, "localName")) == "button" && attribute(n, "id") == "nav0" })
	if !testing.expect(t, button != nil, "the first button") { return }
	children := list_of(field(root, "children"))
	testing.expect(t, len(children) > 0 && text_of(field(children[0], "localName")) == "html", "the document's child is html")
	id := node_id(button)
	x, y, width := box_content(c, id)
	label := first_text(button)
	testing.expect(t, label != nil && text_of(field(label, "nodeValue")) != "", "its text")
	testing.expect(t, width > 0, "its model")
	testing.expect(t, computed_value(c, id, "width") != "", "its style")
	ax := list_of(field(send(c, "Accessibility.getPartialAXTree", fmt.tprintf(`{{"nodeId":%d}}`, id)), "nodes"))[0]
	testing.expect_value(t, text_of(field(field(ax, "role"), "value")), "button")
	testing.expect_value(t, int(number(field(ax, "backendDOMNodeId"))), id)
	at := int(number(field(send(c, "DOM.getNodeForLocation", fmt.tprintf(`{{"x":%v,"y":%v}}`, x + 20, y + 5)), "nodeId")))
	finder := fmt.tprintf("%d", at)
	found := search(button, finder, proc(n: json.Value, want: string) -> bool { return fmt.tprintf("%d", node_id(n)) == want })
	testing.expect(t, found != nil, "the node at a point is in the button")
	send(c, "Overlay.highlightNode", fmt.tprintf(`{{"nodeId":%d,"highlightConfig":{{}}}}`, id))
	send(c, "Overlay.hideHighlight")
	clear(&c.events)
	send(c, "Toolkit.click", `{"name":"nav2"}`)
	idle(c)
	inserted, removed := false, false
	for e in c.events {
		if e.method == "DOM.childNodeInserted" { inserted = true }
		if e.method == "DOM.childNodeRemoved" { removed = true }
	}
	testing.expect(t, inserted && removed, "a change of page sends its events")
}

// Editing from DevTools: live, in sRGB, and gone with the client.
@(test)
devtools_edits_go_with_their_client :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	c := r.c
	dt := connect(r)
	root := document(dt)
	button := by_id(root, "nav3")
	id := node_id(button)
	x, y, _ := box_content(dt, id)
	px :: proc(c: ^Client, x, y: f64) -> session.Color { return session.pixel(shot(c), int(x + INSIDE_BUTTON.x), int(y + INSIDE_BUTTON.y)) }
	before := px(c, x, y)
	style := inline_style(dt, id)
	shown := ""
	for p in list_of(field(style, "cssProperties")) { if text_of(field(p, "name")) == "background-color" { shown = text_of(field(p, "value")) } }
	testing.expectf(t, session.near(css_rgb(shown), before, COLOR_TOLERANCE), "DevTools' colour is the screen's: %s and %v", shown, before)
	set_style(dt, style, with_property(text_of(field(style, "cssText")), "background-color", "#ff0000"))
	idle(c)
	testing.expectf(t, session.near(px(c, x, y), {255, 0, 0, 255}, COLOR_TOLERANCE), "a style edited: the box is %v", px(c, x, y))
	send(dt, "DOM.setNodeValue", fmt.tprintf(`{{"nodeId":%d,"value":"Edited"}}`, node_id(first_text(button))))
	idle(c)
	testing.expect_value(t, len(list_of(field(send(c, "Toolkit.find", `{"text":"Edited"}`), "nodes"))), 1)
	send(dt, "DOM.removeNode", fmt.tprintf(`{{"nodeId":%d}}`, node_id(by_id(root, "nav4"))))
	testing.expect_value(t, count_named(c, "nav4"), 0)
	leave(dt)
	send(c, "Toolkit.state")
	testing.expect_value(t, count_named(c, "nav4"), 1)
	testing.expectf(t, session.near(px(c, x, y), before, COLOR_TOLERANCE), "the colour is back: %v", px(c, x, y))
}

// The children as they are asked for: the depth asked, and none sent twice (each would be a new node in Chrome's frontend). What the frontend asks as it goes.
@(test)
devtools_children_as_asked :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	c := connect(r)
	root := field(send(c, "DOM.getDocument"), "root")
	html := list_of(field(root, "children"))[0]
	testing.expect_value(t, text_of(field(html, "localName")), "html")
	testing.expect(t, field(html, "children") == nil, "depth 1 by default")
	html_id := node_id(html)
	asked := fmt.tprintf(`{{"nodeId":%d}}`, html_id)
	send(c, "DOM.requestChildNodes", asked)
	send(c, "DOM.requestChildNodes", asked)
	send(c, "Toolkit.state")
	sets := make([dynamic]Event, context.temp_allocator)
	for e in c.events { if e.method == "DOM.setChildNodes" { append(&sets, e) } }
	if !testing.expect_value(t, len(sets), 1) { return }
	testing.expect_value(t, int(number(field(sets[0].params, "parentId"))), html_id)
	main_node := list_of(field(sets[0].params, "nodes"))[0]
	main_id := node_id(main_node)
	clear(&c.events)
	send(c, "DOM.requestChildNodes", fmt.tprintf(`{{"nodeId":%d,"depth":-1}}`, html_id))
	send(c, "Toolkit.state")
	deep := false
	for e in c.events {
		if e.method != "DOM.setChildNodes" || int(number(field(e.params, "parentId"))) != main_id { continue }
		for n in list_of(field(e.params, "nodes")) { if field(n, "children") != nil { deep = true } }
	}
	testing.expect(t, deep, "with a depth it goes down from what the client has")
	// what the frontend asks as it goes: answered, and what is JavaScript still refused
	_, is_list := field(send(c, "CSS.takeComputedStyleUpdates"), "nodeIds").(json.Array)
	testing.expect(t, is_list, "CSS.takeComputedStyleUpdates")
	testing.expect(t, text_of(field(send(c, "Storage.getStorageKey", `{"frameId":"x"}`), "storageKey")) != "", "Storage.getStorageKey")
	_, styled := field(send(c, "DOM.getNodesForSubtreeByStyle", `{"nodeId":1,"computedStyles":[{"name":"display","value":"grid"}]}`), "nodeIds").(json.Array)
	testing.expect(t, styled, "DOM.getNodesForSubtreeByStyle")
	attrs := list_of(field(send(c, "DOM.getAttributes", fmt.tprintf(`{{"nodeId":%d}}`, main_id)), "attributes"))
	testing.expect(t, len(attrs) > 0 && text_of(attrs[0]) == "id", "DOM.getAttributes")
	call := send(c, "Runtime.callFunctionOn", fmt.tprintf(`{{"objectId":"node:%d","functionDeclaration":"function u(){{return\"formAssociated\"in this.constructor&&this.constructor.formAssociated===!0}}"}}`, main_id))
	v, is_bool := field(field(call, "result"), "value").(json.Boolean)
	testing.expect(t, is_bool && !bool(v), "the frontend's question about a custom element")
	_, refused := ask(c, "Runtime.callFunctionOn", `{"objectId":"node:1","functionDeclaration":"function(){return 1}"}`)
	testing.expect(t, refused != "", "what is JavaScript is refused")
	leave(c)
}

// Whose edits they are: a client that never asked for the document, the next client to take the tree.
@(test)
devtools_who_owns_the_edits :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	c := r.c
	id := node_id(by_id(document(c), "nav4"))
	tool := connect(r)
	send(tool, "DOM.removeNode", fmt.tprintf(`{{"nodeId":%d}}`, id))
	testing.expect_value(t, count_named(c, "nav4"), 0)
	leave(tool)
	send(c, "Toolkit.state")
	testing.expect_value(t, count_named(c, "nav4"), 1)

	one := connect(r)
	send(one, "DOM.removeNode", fmt.tprintf(`{{"nodeId":%d}}`, node_id(by_id(document(one), "nav4"))))
	testing.expect_value(t, count_named(c, "nav4"), 0)
	two := connect(r)
	send(two, "DOM.getDocument", `{"depth":-1}`)
	testing.expect_value(t, count_named(c, "nav4"), 1)
	leave(two)
	leave(one)
}

// A text replaced stays readable in the frame it is replaced in; an attribute: only what a reader gets can be edited; undo and redo, of a label, a removal, a style; a length that is no length.
@(test)
devtools_edit_history_and_its_limits :: proc(t: ^testing.T) {
	r := start_whatsnew(t)
	c := r.c
	dt := connect(r)
	root := document(dt)
	button := by_id(root, "nav3")
	id := node_id(button)
	label := node_id(first_text(button))
	a, b := strings.repeat("A", LONG_TEXT_BYTES, context.temp_allocator), strings.repeat("B", LONG_TEXT_BYTES, context.temp_allocator)
	send(dt, "DOM.setNodeValue", fmt.tprintf(`{{"nodeId":%d,"value":%q}}`, label, a))
	idle(c)
	for i in 0 ..< LONG_TEXT_ROUNDS {
		devtools.local_send(dt.l, fmt.tprintf(`{{"id":0,"method":"DOM.setNodeValue","params":{{"nodeId":%d,"value":%q}}}}`, label, i % 2 == 0 ? b : a))
		seen := text_of(field(field(send(dt, "DOM.describeNode", fmt.tprintf(`{{"nodeId":%d}}`, label)), "node"), "nodeValue"))
		testing.expect(t, seen == a || seen == b, "a text read in the frame it is replaced in is one of them")
		idle(c)
	}

	_, refused := ask(dt, "DOM.setAttributesAsText", fmt.tprintf(`{{"nodeId":%d,"text":"id=\"x\""}}`, id))
	testing.expectf(t, strings.contains(refused, "aria-label"), "an attribute the program gives is refused, and says which can be edited: %q", refused)

	clear(&dt.events)
	send(dt, "DOM.setAttributeValue", fmt.tprintf(`{{"nodeId":%d,"name":"aria-label","value":"Called otherwise"}}`, id))
	send(dt, "DOM.markUndoableState")
	idle(c)
	testing.expect_value(t, count_labelled(c, "Called otherwise"), 1)
	send(dt, "DOM.setAttributesAsText", fmt.tprintf(`{{"nodeId":%d,"name":"aria-label","text":"aria-label=\"And again\""}}`, id))
	send(dt, "DOM.markUndoableState")
	idle(c)
	testing.expect_value(t, count_labelled(c, "And again"), 1)
	told := false
	for e in dt.events { if e.method == "DOM.attributeModified" && text_of(field(e.params, "name")) == "aria-label" && text_of(field(e.params, "value")) == "And again" { told = true } }
	testing.expect(t, told, "the client hears of it")

	send(dt, "DOM.undo")
	idle(c)
	testing.expect_value(t, count_labelled(c, "Called otherwise"), 1)
	send(dt, "DOM.undo")
	idle(c)
	testing.expect_value(t, count_labelled(c, "Called otherwise"), 0)
	send(dt, "DOM.redo")
	idle(c)
	testing.expect_value(t, count_labelled(c, "Called otherwise"), 1)
	send(dt, "DOM.undo")
	idle(c)

	send(dt, "DOM.removeNode", fmt.tprintf(`{{"nodeId":%d}}`, node_id(by_id(root, "nav5"))))
	send(dt, "DOM.markUndoableState")
	testing.expect_value(t, count_named(c, "nav5"), 0)
	send(dt, "DOM.undo")
	testing.expect_value(t, count_named(c, "nav5"), 1)
	send(dt, "DOM.redo")
	testing.expect_value(t, count_named(c, "nav5"), 0)
	send(dt, "DOM.undo")
	idle(c)

	s0 := inline_style(dt, id)
	c0 := computed_value(dt, id, "background-color")
	clear(&dt.events)
	set_style(dt, s0, with_property(text_of(field(s0, "cssText")), "background-color", "#00ff00"))
	send(dt, "DOM.markUndoableState")
	idle(c)
	testing.expect(t, session.near(css_rgb(computed_value(dt, id, "background-color")), {0, 255, 0, 255}, COLOR_TOLERANCE), "a style edited")
	send(dt, "DOM.undo")
	idle(c)
	testing.expect_value(t, computed_value(dt, id, "background-color"), c0)
	testing.expect_value(t, text_of(field(inline_style(dt, id), "cssText")), text_of(field(s0, "cssText")))
	panel_told := false
	for e in dt.events { if e.method == "CSS.styleSheetChanged" && text_of(field(e.params, "styleSheetId")) == text_of(field(s0, "styleSheetId")) { panel_told = true } }
	testing.expect(t, panel_told, "the panel is told")

	_, _, before := box_content(dt, id)
	style := inline_style(dt, id)
	set_style(dt, style, with_property(text_of(field(style, "cssText")), "width", "inf"))
	idle(c)
	_, _, after := box_content(dt, id)
	testing.expect_value(t, after, before)
	leave(dt)
}
