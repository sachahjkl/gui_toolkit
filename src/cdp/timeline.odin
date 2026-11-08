package tk_cdp

// A timeline of what happened in a toolkit window: each action with when it happened and a picture of the window after it, the
// time of every frame in between. One folder per run:
//
//   index.html     a page that stands alone (the pictures are in it): send it with a bug report
//   timeline.json  the steps and frames; `play` runs it again and compares
//   trace.json     Chrome's trace format: chrome://tracing, https://ui.perfetto.dev
//   steps.txt      the actions, a script for `play`
//   step-NNN.png   the pictures (step-NNN.diff.png: where one differs from the reference)
//
// What was on screen and what was typed is in there as is: a run on real data is not to be shared as it stands.
//
// While it runs a step only takes its picture, as the window's encoder made it (fast, large), and keeps it in memory. Smaller
// pictures, comparisons and files all come at the end: a run does not wait for them, and what they cost does not show in the
// frames it measures.

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

// A pixel counts as different over this (of 255 on any channel); a step may differ on this share of its pixels (numbers shown
// live, a caret).
PIXEL_DELTA :: 32
MAX_SHARE   :: 0.004
// How long a step waits for the window to rest before its picture.
SETTLE_MS :: 1500
// How often a recording asks what was done, when nothing was.
@(private) RECORD_POLL :: 250 * time.Millisecond
@(private) FRAMES_ALL_AFTER :: "1e15"   // a build no window reaches: only `now` comes back

Frame :: struct {
	build:                                        int,
	t, frame_ms, build_ms, layout_ms, total_ms: f64,
}

Step :: struct {
	t:        f64,
	line:     string,
	image:    string,
	settled:  bool,
	compared: bool,     // there was a reference to compare with
	against:  string,   // its line ("" and compared: the reference has no such step)
	in_reference: bool,
	share:    f64,
	has_share: bool,
	diff:     string,
	differs:  bool,
}

Timeline_Result :: struct {
	steps, failed: int,
	lines:         []string,   // the actions, without the start
}

@(private)
Run :: struct {
	c:           ^Client,
	dir, kind:   string,
	steps:       [dynamic]Step,
	frames:      [dynamic]Frame,
	pictures:    [dynamic][]byte,
	last_build:  int,
	base:        f64,
	against:     []Step,   // the reference's steps (nil: none)
	against_dir: string,
	max_diff:    f64,
	failed:      int,
}

// A script's lines, from a script or from a timeline.json (its steps, with when they happened: `times`, and its folder).
Script :: struct {
	lines: []string,
	times: []f64,   // nil: a script, no times
	dir:   string,  // a timeline's folder: its reference
}

read_script :: proc(file: string, allocator := context.allocator) -> (s: Script, ok: bool) {
	data, err := os.read_entire_file(file, allocator)
	if err != nil { return }
	text := string(data)
	lines := make([dynamic]string, allocator)
	if strings.has_suffix(file, ".json") {
		steps, read := timeline_steps(text, allocator)
		if !read { return }
		times := make([dynamic]f64, allocator)
		for st in steps {
			if st.line == "start" { continue }
			append(&lines, st.line)
			append(&times, st.t)
		}
		return {lines[:], times[:], strings.clone(filepath.dir(file), allocator)}, true
	}
	for l in strings.split_lines(text, context.temp_allocator) {
		line := strings.trim_suffix(l, "\r")
		if strings.trim_space(line) == "" || strings.has_prefix(line, "#") { continue }
		append(&lines, line)
	}
	return {lines = lines[:]}, true
}

// The steps of a timeline.json: their line, time and picture.
timeline_steps :: proc(text: string, allocator := context.allocator) -> (steps: []Step, ok: bool) {
	v, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil { return }
	o, _ := v.(json.Object)
	list, is_list := o["steps"].(json.Array)
	if !is_list { return }
	out := make([]Step, len(list), allocator)
	for item, i in list {
		st, _ := item.(json.Object)
		out[i] = {t = number(st["t"]), line = strings.clone(str(st["line"]), allocator), image = strings.clone(str(st["image"]), allocator)}
	}
	return out, true
}

@(private)
run_begin :: proc(r: ^Run) -> bool {
	res, ok := call(r.c, "Toolkit.frames", `{"after":` + FRAMES_ALL_AFTER + `}`)
	if !ok { return false }
	o, _ := res.(json.Object)
	r.base = number(o["now"])
	st, got := call(r.c, "Toolkit.state")
	if !got { return false }
	so, _ := st.(json.Object)
	r.last_build, _ = integer(so["build"])
	return run_step(r, "start", r.base)
}

// The frames since the last pull; the clock's time now.
@(private)
run_pull :: proc(r: ^Run) -> (now: f64, ok: bool) {
	res, called := call(r.c, "Toolkit.frames", fmt.tprintf(`{{"after":%d}}`, r.last_build))
	if !called { return 0, false }
	o, _ := res.(json.Object)
	list, _ := o["frames"].(json.Array)
	for item in list {
		f, _ := item.(json.Object)
		build, _ := integer(f["build"])
		append(&r.frames, Frame{build, number(f["t"]) - r.base, number(f["frameMs"]), number(f["buildMs"]), number(f["layoutMs"]), number(f["totalMs"])})
		r.last_build = max(r.last_build, build)
	}
	return number(o["now"]), true
}

// After an action: the window at rest, its picture.
@(private)
run_step :: proc(r: ^Run, line: string, at: f64) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()   // (a picture's base64 is large: what is kept is copied out)
	idle, called := wait_idle(r.c, SETTLE_MS * time.Millisecond)
	if !called { return false }
	png, shot := screenshot(r.c)
	if !shot { return false }
	append(&r.pictures, png)
	append(&r.steps, Step{t = at - r.base, line = strings.clone(line), image = fmt.aprintf("step-%03d.png", len(r.steps)), settled = idle})
	_, pulled := run_pull(r)
	return pulled
}

// A step's picture written as it is kept, and compared with the reference.
@(private)
run_settle :: proc(r: ^Run, s: ^Step, n: int) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	pic, decoded := png_decode(r.pictures[n], context.temp_allocator)
	delete(r.pictures[n])
	r.pictures[n] = nil
	if decoded && !png_write(fmt.tprintf("%s/%s", r.dir, s.image), pic) { fmt.eprintfln("%s/%s cannot be written", r.dir, s.image) }
	if r.against == nil { return }
	s.compared = true
	if n < len(r.against) {
		other := r.against[n]
		s.against, s.in_reference = other.line, true
		reference, read := png_read(fmt.tprintf("%s/%s", r.against_dir, other.image), context.temp_allocator)
		cmp := decoded && read ? compare(reference, pic, PIXEL_DELTA, context.temp_allocator) : Comparison{size_differs = true}
		s.has_share = true
		if cmp.size_differs {
			s.share = 1
		} else {
			s.share = cmp.share
			if cmp.share > r.max_diff {
				s.diff = fmt.aprintf("%s.diff.png", strings.trim_suffix(s.image, ".png"))
				png_write(fmt.tprintf("%s/%s", r.dir, s.diff), cmp.diff)
			}
		}
		s.differs = s.share > r.max_diff
	} else {
		s.differs = true
	}
	if s.differs { r.failed += 1 }
}

@(private)
run_finish :: proc(r: ^Run, failure: string) -> Timeline_Result {
	for &s, n in r.steps { run_settle(r, &s, n) }
	if r.against != nil && len(r.against) > len(r.steps) && failure == "" { r.failed += len(r.against) - len(r.steps) }
	end: f64
	if len(r.steps) > 0 {
		end = r.steps[len(r.steps) - 1].t
		if len(r.frames) > 0 { end = max(end, r.frames[len(r.frames) - 1].t) }
	}
	when_ := time_text(time.now())
	data := timeline_json(r, failure, end, when_, false)
	write_file(fmt.tprintf("%s/timeline.json", r.dir), data)
	lines := make([dynamic]string)
	steps := strings.builder_make(context.temp_allocator)
	for s in r.steps {
		if s.line == "start" { continue }
		append(&lines, strings.clone(s.line))
		fmt.sbprintf(&steps, "%s\n", s.line)
	}
	if len(lines) == 0 { strings.write_string(&steps, "\n") }
	write_file(fmt.tprintf("%s/steps.txt", r.dir), strings.to_string(steps))
	write_file(fmt.tprintf("%s/trace.json", r.dir), chrome_trace(r))
	write_file(fmt.tprintf("%s/index.html", r.dir), timeline_page(timeline_json(r, failure, end, when_, true)))
	return {len(r.steps), r.failed, lines[:]}
}

@(private)
write_file :: proc(path, text: string) {
	if err := os.write_entire_file(path, text); err != nil { fmt.eprintfln("%s: %v", path, err) }
}

@(private)
run_destroy :: proc(r: ^Run) {
	for p in r.pictures { delete(p) }
	delete(r.pictures)
	for s in r.steps {
		delete(s.line)
		delete(s.image)
		if s.diff != "" { delete(s.diff) }
	}
	delete(r.steps)
	delete(r.frames)
}

// ISO 8601 in UTC, to the millisecond, as JS's toISOString.
@(private)
time_text :: proc(t: time.Time) -> string {
	y, mo, d := time.date(t)
	h, mi, s, ns := time.precise_clock_from_time(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", y, int(mo), d, h, mi, s, ns / 1_000_000)
}

// timeline.json, or the data of the page (`inline`: the pictures in it, the frames' times only).
@(private)
timeline_json :: proc(r: ^Run, failure: string, end: f64, when_: string, inline: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"kind":%s,"when":%s,"durationMs":%s,"failed":%d`, quote(r.kind), quote(when_), json_number(end), r.failed)
	if failure != "" { fmt.sbprintf(&b, `,"error":%s`, quote(failure)) }
	strings.write_string(&b, `,"steps":[`)
	for s, i in r.steps {
		if i > 0 { strings.write_byte(&b, ',') }
		image := inline ? data_url(fmt.tprintf("%s/%s", r.dir, s.image)) : s.image
		fmt.sbprintf(&b, "\n {{\"t\":%s,\"line\":%s,\"image\":%s,\"settled\":%v", json_number(s.t), quote(s.line), quote(image), s.settled)
		if s.compared { fmt.sbprintf(&b, `,"against":%s`, s.in_reference ? quote(s.against) : "null") }
		if s.has_share { fmt.sbprintf(&b, `,"share":%s`, json_number(s.share)) }
		if s.diff != "" { fmt.sbprintf(&b, `,"diff":%s`, quote(inline ? data_url(fmt.tprintf("%s/%s", r.dir, s.diff)) : s.diff)) }
		if s.compared { fmt.sbprintf(&b, `,"differs":%v`, s.differs) }
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "\n],\"frames\":[")
	for f, i in r.frames {
		if i > 0 { strings.write_byte(&b, ',') }
		if inline {
			fmt.sbprintf(&b, `{{"t":%s,"totalMs":%s,"build":%d}}`, json_number(f.t), json_number(f.total_ms), f.build)
		} else {
			fmt.sbprintf(&b, "\n {{\"build\":%d,\"t\":%s,\"frameMs\":%s,\"buildMs\":%s,\"layoutMs\":%s,\"totalMs\":%s}}", f.build, json_number(f.t), json_number(f.frame_ms), json_number(f.build_ms), json_number(f.layout_ms), json_number(f.total_ms))
		}
	}
	strings.write_string(&b, "\n]}\n")
	return strings.to_string(b)
}

@(private)
data_url :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return "" }
	encoded, _ := base64.encode(data, allocator = context.temp_allocator)
	return fmt.tprintf("data:image/png;base64,%s", encoded)
}

// Chrome's trace format: a slice per build and its layout, a mark per step.
@(private)
chrome_trace :: proc(r: ^Run) -> string {
	us :: proc(ms: f64) -> i64 { return i64(ms * 1000 + (ms >= 0 ? 0.5 : -0.5)) }
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"traceEvents":[{"ph":"M","pid":1,"tid":1,"name":"process_name","args":{"name":"toolkit window"}},{"ph":"M","pid":1,"tid":1,"name":"thread_name","args":{"name":"UI"}}`)
	for f in r.frames {
		// (a frame is sampled at the next frame's start: its build ended before that; the order and lengths are what they were)
		ts := f.t - f.total_ms
		fmt.sbprintf(&b, `,{{"ph":"X","pid":1,"tid":1,"name":"build","cat":"ui","ts":%d,"dur":%d,"args":{{"build":%d,"frameMs":%s}}}}`, us(ts), us(f.total_ms), f.build, json_number(f.frame_ms))
		fmt.sbprintf(&b, `,{{"ph":"X","pid":1,"tid":1,"name":"layout","cat":"ui","ts":%d,"dur":%d}}`, us(ts + f.build_ms), us(f.layout_ms))
		fmt.sbprintf(&b, `,{{"ph":"C","pid":1,"tid":1,"name":"frame ms","ts":%d,"args":{{"frameMs":%s}}}}`, us(f.t), json_number(f.frame_ms))
	}
	for s in r.steps {
		fmt.sbprintf(&b, `,{{"ph":"i","pid":1,"tid":1,"s":"t","name":%s,"cat":"step","ts":%d}}`, quote(s.line), us(s.t))
	}
	strings.write_string(&b, `],"displayTimeUnit":"ms"}`)
	return strings.to_string(b)
}

Record_Options :: struct {
	dir:      string,
	stop:     ^bool,   // set (atomically, from any thread) to end the recording
	injected: bool,    // the protocol's events too (a test of the recorder)
}

// What a person does in the window, until `stop` is set (or the window goes away: what was seen is kept). The result's lines
// are the caller's.
record_timeline :: proc(c: ^Client, o: Record_Options) -> Timeline_Result {
	r := Run{c = c, dir = o.dir, kind = "recorded", max_diff = MAX_SHARE}
	defer run_destroy(&r)
	_ = os.make_directory_all(o.dir)
	failure := ""
	recording: {
		if _, ok := call(c, "Toolkit.startRecording", fmt.tprintf(`{{"injected":%v}}`, o.injected)); !ok { failure = c.failure; break recording }
		if !run_begin(&r) { failure = c.failure; break recording }
		for !sync.atomic_load(o.stop) {
			n, ok := record_poll(&r)
			if !ok { failure = c.failure; break recording }
			if _, pulled := run_pull(&r); !pulled { failure = c.failure; break recording }
			if n == 0 { time.sleep(RECORD_POLL) }
		}
		if _, ok := record_poll(&r); !ok { failure = c.failure; break recording }
		if _, ok := call(c, "Toolkit.stopRecording"); !ok { failure = c.failure }
	}
	if failure != "" { fmt.printfln("the recording ended: %s", failure) }
	return run_finish(&r, failure)
}

// The lines done since the last poll, each a step. How many came.
@(private)
record_poll :: proc(r: ^Run) -> (n: int, ok: bool) {
	res, called := call(r.c, "Toolkit.pollRecording")
	if !called { return 0, false }
	o, _ := res.(json.Object)
	list, _ := o["lines"].(json.Array)
	// (copied: a step's own calls reuse the temporary memory)
	lines := make([dynamic]string, context.temp_allocator)
	times := make([dynamic]f64, context.temp_allocator)
	for item in list {
		l, _ := item.(json.Object)
		append(&lines, str(l["line"]))
		append(&times, number(l["t"]))
	}
	for line, i in lines {
		if line == "idle" { continue }
		if !run_step(r, line, times[i]) { return 0, false }
	}
	return len(lines), true
}

Play_Options :: struct {
	source:   string,   // a script, or a timeline.json
	dir:      string,
	against:  string,   // the run to compare with ("": the timeline played, if it is one)
	realtime: bool,     // the recorded pauses kept
	max_diff: f64,      // 0: MAX_SHARE
}

// A script or a timeline.json run again, a picture after each action, compared with `against` or the timeline it plays.
play_timeline :: proc(c: ^Client, o: Play_Options) -> Timeline_Result {
	script, read := read_script(o.source, context.temp_allocator)
	if !read { fmt.printfln("the run ended: %s cannot be read", o.source); return {failed = 1} }
	reference := o.against != "" ? o.against : script.dir
	r := Run{c = c, dir = o.dir, kind = "played", max_diff = o.max_diff > 0 ? o.max_diff : MAX_SHARE}
	defer run_destroy(&r)
	if reference != "" {
		if text, err := os.read_entire_file(fmt.tprintf("%s/timeline.json", reference), context.temp_allocator); err == nil {
			r.against, _ = timeline_steps(string(text), context.temp_allocator)
			r.against_dir = reference
		}
	}
	_ = os.make_directory_all(o.dir)
	failure := ""
	playing: {
		if !run_begin(&r) { failure = c.failure; break playing }
		last: f64
		for line, i in script.lines {
			if line == "idle" { continue }
			if o.realtime && script.times != nil {
				gap := script.times[i] - last
				last = script.times[i]
				if gap > 0 { time.sleep(time.Duration(gap * f64(time.Millisecond))) }
			}
			w := words(line)
			if len(w) == 0 { continue }
			known, ok := act(c, w[0], w[1:])
			if !known { failure = fmt.tprintf("not an action: %s", line); break playing }
			if !ok { failure = c.failure; break playing }
			now, pulled := run_pull(&r)
			if !pulled || !run_step(&r, line, now) { failure = c.failure; break playing }
		}
	}
	if failure != "" {
		r.failed += 1
		fmt.printfln("the run ended: %s", failure)
	}
	return run_finish(&r, failure)
}
