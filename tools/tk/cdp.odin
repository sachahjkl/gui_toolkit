package tk

// cdp [--port 9222] <command> [args] [, <command> [args]]...: a toolkit window driven over the Chrome DevTools Protocol (src/devtools;
// the program runs with TOOLKIT_DEVTOOLS=<port>), on the client of src/cdp. No mouse or keyboard of the machine is touched.
//
//   tree [--all]                 the box tree: name, text, rect (CSS pixels), flags
//   find <text> | --name <id>    boxes whose text contains <text> (or named <id>)
//   click <text> | --name <id> [--index n] [--count 2] [--button right]
//   move <x> <y>                 the pointer
//   down <x> <y> | up <x> <y> [--button right]   a press, a release (left unless told)
//   wheel <x> <y> <notches> [<across>]   positive scrolls the content down (and to the right)
//   key <name>                   Enter, Tab, Escape, ArrowDown, F3, a, ctrl+f, shift+Tab...
//   type <text>                  text input
//   shot <file.png> [x y w h]    a screenshot (the window's pixels)
//   state                        the build counter, focus, hover, size
//   wait <ms>                    a pause (better: wait-for, idle)
//   wait-for <text> | --name <id> [--gone] [--timeout ms]    until the box is there (or gone); an error after the timeout
//   idle [--timeout ms]          until nothing moves
//   metrics [--reset]            what the frames cost: build, layout, frame times, boxes, latency in a probe build
//   warnings                     the layout's warnings of this build
//   ax [role] [--name text]      the accessibility tree a screen reader gets, or the nodes that answer
//   press <name> [--role button] [--action Click] [--value v | --number n] [--index n]   an action as a screen reader asks it
//   audit                        what a screen reader cannot name
//   record <file>                records what a person does until Enter, as a script for `play`
//   record [<file>] --timeline <dir>   the same with a picture after each action: dir/index.html, timeline.json, trace.json
//   play <file>                  runs a script: a command per line, # for comments
//   play <script or timeline.json> --timeline <dir> [--against <dir>] [--realtime] [--max-diff 0.004]
//                                the same with a picture after each action, compared with another run (by default, the
//                                timeline.json it plays); it fails if one differs. --realtime keeps the recorded pauses
//   inspect                      the address that opens Chrome's DevTools on this window (paste it in Chrome or Edge)
//   cast <dir> [--every ms]      the window's frames as PNGs until Enter (Page.startScreencast)
//   close                        closes the window (Browser.close)
//   raw <Method.name> [json]     any command
//
// Commands separated by a lone "," run in order on one connection:
//   tk cdp click "Lazy column" , idle , wheel 600 500 10 , idle , shot out.png

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import cdp "../../src/cdp"

CDP_PORT :: 9222
@(private = "file") TREE_TEXT_LONGEST :: 60
@(private = "file") CAST_EVERY_MS :: 200
@(private = "file") CAST_PUMP :: 100 * time.Millisecond

run_cdp :: proc(line: []string) -> string {
	args := line   // (its own reading: it moves through them)
	port := CDP_PORT
	if len(args) >= 2 && args[0] == "--port" {
		n, ok := strconv.parse_int(args[1])
		if !ok { return fmt.tprintf("--port %s: not a port", args[1]) }
		port, args = n, args[2:]
	}
	commands := make([dynamic][]string, context.temp_allocator)
	start := 0
	for arg, i in args {
		if arg != "," { continue }
		if i > start { append(&commands, args[start:i]) }
		start = i + 1
	}
	if start < len(args) { append(&commands, args[start:]) }
	if len(commands) == 0 { return "no command (see the head of tools/tk/cdp.odin)" }

	c, ok := cdp.connect(port)
	if !ok { return fmt.tprintf("nothing listens on port %d (TOOLKIT_DEVTOOLS=%d)", port, port) }
	defer cdp.close(&c)
	c.quiet = true   // (the failure is the command's: said once, by tk)
	for command in commands {
		if why := cdp_command(&c, command[0], command[1:]); why != "" { return why }
	}
	return ""
}

// Until a line comes on the standard input (Enter): set `pressed`.
@(private = "file")
wait_for_enter :: proc(pressed: ^bool) -> ^thread.Thread {
	return thread.create_and_start_with_poly_data(pressed, proc(pressed: ^bool) {
		buf: [256]byte
		for {
			n, err := os.read(os.stdin, buf[:])
			if err != nil || n <= 0 || strings.contains(string(buf[:n]), "\n") { break }
		}
		sync.atomic_store(pressed, true)
	}, self_cleanup = true)
}

@(private = "file")
cdp_command :: proc(c: ^cdp.Client, command: string, args: []string) -> string {
	o := cdp.options(args)
	failed :: proc(c: ^cdp.Client) -> string { return c.failure }
	query := cdp.option(&o, "name") != "" ? fmt.tprintf(`{{"name":%s}}`, cdp.quote(cdp.option(&o, "name"))) : fmt.tprintf(`{{"text":%s}}`, cdp.quote(strings.join(o.rest[:], " ", context.temp_allocator)))
	switch command {
	case "tree":
		r, ok := cdp.call(c, "Toolkit.getTree", fmt.tprintf(`{{"all":%v}}`, cdp.has_option(&o, "all")))
		if !ok { return failed(c) }
		root, _ := r.(json.Object)
		print_tree(root["root"], 0)
	case "find":
		r, ok := cdp.call(c, "Toolkit.find", query)
		if !ok { return failed(c) }
		res, _ := r.(json.Object)
		nodes, _ := res["nodes"].(json.Array)
		for n in nodes {
			b, _ := n.(json.Object)
			fmt.printfln(`%s "%s" @%s,%s %sx%s`, name_or_dot(b["name"]), cdp.str(b["text"]), num(b["x"]), num(b["y"]), num(b["w"]), num(b["h"]))
		}
	case "shot":
		if len(o.rest) == 0 { return "shot <file.png> [x y w h]" }
		clip: Maybe(cdp.Clip)
		if len(o.rest) >= 5 { clip = cdp.Clip{cdp.word_number(o.rest[1]), cdp.word_number(o.rest[2]), cdp.word_number(o.rest[3]), cdp.word_number(o.rest[4])} }
		if !cdp.shot(c, o.rest[0], clip) { return c.failure != "" ? c.failure : fmt.tprintf("%s cannot be written", o.rest[0]) }
		fmt.printfln("saved %s", o.rest[0])
	case "state":
		return print_json(c, "Toolkit.state", "{}", false)
	case "metrics":
		return print_json(c, "Toolkit.metrics", fmt.tprintf(`{{"reset":%v}}`, cdp.has_option(&o, "reset")), true)
	case "warnings":
		r, ok := cdp.call(c, "Toolkit.warnings")
		if !ok { return failed(c) }
		res, _ := r.(json.Object)
		list, _ := res["layout"].(json.Array)
		for w in list { fmt.println(cdp.str(w)) }
	case "ax":
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '{')
		if len(o.rest) > 0 { fmt.sbprintf(&b, `"role":%s`, cdp.quote(o.rest[0])) }
		if name := cdp.option(&o, "name"); name != "" { fmt.sbprintf(&b, `%s"accessibleName":%s`, len(o.rest) > 0 ? "," : "", cdp.quote(name)) }
		strings.write_byte(&b, '}')
		method := len(o.rest) > 0 || cdp.option(&o, "name") != "" ? "Accessibility.queryAXTree" : "Accessibility.getFullAXTree"
		r, ok := cdp.call(c, method, strings.to_string(b))
		if !ok { return failed(c) }
		res, _ := r.(json.Object)
		nodes, _ := res["nodes"].(json.Array)
		print_ax(nodes)
	case "audit":
		r, ok := cdp.call(c, "Toolkit.axAudit")
		if !ok { return failed(c) }
		res, _ := r.(json.Object)
		unnamed, _ := res["unnamed"].(json.Array)
		for u in unnamed {
			b, _ := u.(json.Object)
			fmt.printfln("%s %s @%s,%s %sx%s", name_or_dot(b["name"]), plain(b["key"]), num(b["x"]), num(b["y"]), num(b["w"]), num(b["h"]))
		}
		fmt.printfln("%d without a name", len(unnamed))
	case "record":
		return record(c, &o)
	case "play":
		return play(c, &o)
	case "cast":
		if len(o.rest) == 0 { return "cast <dir> [--every ms]" }
		dir := o.rest[0]
		_ = os.make_directory_all(dir)
		sc := cdp.Screencast{dir = dir}
		defer cdp.screencast_destroy(&sc)
		every := int(cdp.word_number(cdp.option(&o, "every", fmt.tprint(CAST_EVERY_MS))))
		if !cdp.screencast_start(c, &sc, every) { return failed(c) }
		fmt.println("the frames go to the folder: Enter here to stop")
		pressed: bool
		wait_for_enter(&pressed)
		for !sync.atomic_load(&pressed) {
			if !cdp.pump(c, CAST_PUMP) { return "the window is gone" }
		}
		if !cdp.screencast_stop(c) { return failed(c) }
		fmt.printfln("%d frames in %s", len(sc.names), dir)
	case "inspect":
		list, ok := cdp.targets(c.port)
		if !ok || len(list) == 0 { return "no target" }
		fmt.println(list[0].devtools_frontend_url)
	case "close":
		if _, ok := cdp.call(c, "Browser.close"); !ok { return failed(c) }
	case "raw":
		if len(o.rest) == 0 { return "raw <Method.name> [json]" }
		return print_json(c, o.rest[0], len(o.rest) > 1 ? o.rest[1] : "{}", true)
	case:
		known, ok := cdp.act(c, command, args)
		if !known { return fmt.tprintf("unknown command: %s", command) }
		if !ok { return c.failure != "" ? c.failure : fmt.tprintf("%s failed", command) }
	}
	return ""
}

@(private = "file")
record :: proc(c: ^cdp.Client, o: ^cdp.Options) -> string {
	pressed: bool
	if dir := cdp.option(o, "timeline"); dir != "" {
		fmt.println("recording what is done in the window, with its pictures and typed text: Enter here to stop")
		wait_for_enter(&pressed)
		r := cdp.record_timeline(c, {dir = dir, stop = &pressed})
		if len(o.rest) > 0 {
			script := strings.builder_make(context.temp_allocator)
			for l in r.lines { fmt.sbprintf(&script, "%s\n", l) }
			if len(r.lines) == 0 { strings.write_byte(&script, '\n') }
			if os.write_entire_file(o.rest[0], strings.to_string(script)) != nil { return fmt.tprintf("%s cannot be written", o.rest[0]) }
		}
		fmt.printfln("%d steps in %s/index.html", r.steps, dir)
		return ""
	}
	if len(o.rest) == 0 { return "record <file> | record [<file>] --timeline <dir>" }
	if _, ok := cdp.call(c, "Toolkit.startRecording"); !ok { return c.failure }
	fmt.println("recording what is done in the window: Enter here to stop")
	wait_for_enter(&pressed)
	for !sync.atomic_load(&pressed) { time.sleep(CAST_PUMP) }
	r, ok := cdp.call(c, "Toolkit.stopRecording")
	if !ok { return c.failure }
	res, _ := r.(json.Object)
	lines, _ := res["lines"].(json.Array)
	script := strings.builder_make(context.temp_allocator)
	for l, i in lines { fmt.sbprintf(&script, "%s%s", i > 0 ? "\n" : "", cdp.str(l)) }
	strings.write_byte(&script, '\n')
	if os.write_entire_file(o.rest[0], strings.to_string(script)) != nil { return fmt.tprintf("%s cannot be written", o.rest[0]) }
	fmt.printfln("%d lines in %s", len(lines), o.rest[0])
	return ""
}

@(private = "file")
play :: proc(c: ^cdp.Client, o: ^cdp.Options) -> string {
	if len(o.rest) == 0 { return "play <file> [--timeline <dir> ...]" }
	if dir := cdp.option(o, "timeline"); dir != "" {
		r := cdp.play_timeline(c, {source = o.rest[0], dir = dir, against = cdp.option(o, "against"), realtime = cdp.has_option(o, "realtime"), max_diff = cdp.word_number(cdp.option(o, "max-diff", "0"))})
		fmt.printfln("%d steps, %d differ: %s/index.html", r.steps, r.failed, dir)
		return r.failed > 0 ? fmt.tprintf("%d steps differ", r.failed) : ""
	}
	script, read := cdp.read_script(o.rest[0], context.temp_allocator)
	if !read { return fmt.tprintf("%s cannot be read", o.rest[0]) }
	for line in script.lines {
		w := cdp.words(line)
		if len(w) == 0 { continue }
		if why := cdp_command(c, w[0], w[1:]); why != "" { return why }
	}
	return ""
}

@(private = "file")
print_json :: proc(c: ^cdp.Client, method, params: string, pretty: bool) -> string {
	r, ok := cdp.call(c, method, params)
	if !ok { return c.failure }
	fmt.println(cdp.stringify(r, pretty ? 2 : 0))
	return ""
}

// A number as JavaScript prints it.
@(private = "file")
num :: proc(v: json.Value) -> string { return cdp.json_number(cdp.number(v)) }

@(private = "file")
plain :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.String:  return x
	case json.Integer, json.Float: return num(v)
	case json.Boolean: return x ? "true" : "false"
	case nil, json.Null: return "undefined"
	}
	return cdp.stringify(v)
}

@(private = "file")
name_or_dot :: proc(v: json.Value) -> string {
	s := cdp.str(v)
	return s != "" ? s : "·"
}

@(private = "file")
print_tree :: proc(v: json.Value, depth: int) {
	n, is_node := v.(json.Object)
	if !is_node { return }
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< depth { strings.write_string(&b, "  ") }
	strings.write_string(&b, name_or_dot(n["name"]))
	if text := cdp.str(n["text"]); text != "" {
		runes := 0
		for _ in text { runes += 1 }
		if runes > TREE_TEXT_LONGEST {
			cut := 0
			for _, i in text {
				if cut == TREE_TEXT_LONGEST - 3 { text = fmt.tprintf("%s...", text[:i]); break }
				cut += 1
			}
		}
		fmt.sbprintf(&b, ` "%s"`, text)
	}
	fmt.sbprintf(&b, "  @%s,%s %sx%s", num(n["x"]), num(n["y"]), num(n["w"]), num(n["h"]))
	if flags, has := n["flags"].(json.Array); has {
		strings.write_string(&b, " [")
		for f, i in flags { fmt.sbprintf(&b, "%s%s", i > 0 ? " " : "", plain(f)) }
		strings.write_string(&b, "]")
	}
	if focused, _ := n["focused"].(json.Boolean); focused { strings.write_string(&b, " *focus") }
	if hot, _ := n["hot"].(json.Boolean); hot { strings.write_string(&b, " *hot") }
	if scroll, has := n["scroll"]; has { fmt.sbprintf(&b, " scroll %s/%s", plain(scroll), plain(n["scrollMax"])) }
	fmt.println(strings.to_string(b))
	children, _ := n["children"].(json.Array)
	for child in children { print_tree(child, depth + 1) }
}

@(private = "file")
print_ax :: proc(nodes: json.Array) {
	parent := make(map[string]string, context.temp_allocator)
	for v in nodes {
		n, _ := v.(json.Object)
		parent[plain(n["nodeId"])] = plain(n["parentId"])
	}
	value_of :: proc(v: json.Value) -> string {
		o, _ := v.(json.Object)
		return plain(o["value"])
	}
	for v in nodes {
		n, _ := v.(json.Object)
		depth := 0
		for p := plain(n["parentId"]); (p in parent); p = parent[p] { depth += 1 }
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< depth { strings.write_string(&b, "  ") }
		fmt.sbprintf(&b, `%s "%s"`, value_of(n["role"]), value_of(n["name"]))
		if value, has := n["value"].(json.Object); has { fmt.sbprintf(&b, ` = "%s"`, plain(value["value"])) }
		props, _ := n["properties"].(json.Array)
		for p, i in props {
			po, _ := p.(json.Object)
			fmt.sbprintf(&b, "%s%s=%s", i == 0 ? " " : " ", plain(po["name"]), value_of(po["value"]))
		}
		if actions, _ := n["actions"].(json.Array); len(actions) > 0 {
			strings.write_string(&b, " [")
			for x, i in actions { fmt.sbprintf(&b, "%s%s", i > 0 ? " " : "", plain(x)) }
			strings.write_string(&b, "]")
		}
		fmt.println(strings.to_string(b))
	}
}
