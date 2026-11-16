package examples_test

// examples/showcase's Values scene, with no window of the system: every storage, value kind, unit and closed list
// builds, and its line holds the control prefs_page.control_of gives. With VALUES_SHOTS set, it also saves a picture of
// the scene for each of a few kinds (their control opened) in its session folder (build/session/...).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "../../examples/showcase"
import config "gt:config"
import prefs_page "gt:prefs_page"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") SHOT_BOUND :: 20 * time.Second

@(private = "file")
start_showcase :: proc(t: ^testing.T, args: []string, loc := #caller_location) -> (s: ^session.Session, app: ^showcase.App) {
	context.allocator = runtime.heap_allocator()
	app = showcase.open({args = args, headless = true})
	if !testing.expect(t, app != nil, "the showcase opens", loc = loc) { session.stop_test(t, "no application", loc) }
	testing.cleanup(t, proc(p: rawptr) { showcase.close((^showcase.App)(p)) }, app)
	s = session.attach(t, {win = app.main.win, state = &app.main.state, renderer = &app.shared.r, user = app, allocator = context.allocator,
		frame = proc(user: rawptr) { showcase.frame((^showcase.App)(user)) }}, loc)
	session.frames(s, 2)
	return
}

// The box a control is drawn in, by its name in setting_line's line.
@(private = "file", rodata)
CONTROL_BOXES := [prefs_page.Control]string{
	.Custom = "", .Switch = "sw", .Segments = "seg", .List = "dd", .Font_Family = "font", .Theme = "th0", .Color = "color",
	.Keys = "keys", .Number = "num", .Field = "field",
}

@(test)
the_values_scene_builds_every_kind :: proc(t: ^testing.T) {
	s, app := start_showcase(t, {"--scene=values", "--size=1280x900"})
	v := &app.values
	seen: [prefs_page.Control]bool
	for storage in config.Kind {
		for kind in config.Value_Kind {
			if !config.value_kind_stores(kind, storage) { continue }
			units := max(len(config.KIND_UNITS[kind]), 1)
			lists := storage == .String && kind == .Plain ? len(showcase.Values_List) : 1
			for unit in 0 ..< units {
				for list in 0 ..< lists {
					v.storage, v.kind, v.unit, v.list = storage, kind, unit, showcase.Values_List(list)
					session.frames(s, 2)
					name := showcase.values_name(v)
					r := config.ref_of(&v.prefs, name)
					if !testing.expectf(t, r != config.NO_REF, "%s is registered", name) { continue }
					d := config.entry(&v.prefs, r).def
					c := prefs_page.control_of(d, len(d.choices), len(app.themes_file.all), false)
					seen[c] = true
					line := session.find(s, fmt.tprintf("set_%s", name))
					if !testing.expectf(t, line != nil, "%s has its line", name) { continue }
					testing.expectf(t, session.find(s, CONTROL_BOXES[c], within = line) != nil, "%s: %v, its box %q", name, c, CONTROL_BOXES[c])
				}
			}
		}
	}
	for c in prefs_page.Control {
		if c == .Custom { continue }   // (the program's own: the scene has none)
		testing.expectf(t, seen[c], "a value of the scene gets %v", c)
	}
}

// What the pictures show: a kind (or a closed list), opened or not.
@(private = "file")
Shot :: struct { file, value: string, open: bool }

@(private = "file", rodata)
VALUE_SHOTS := [?]Shot{
	{"font_family", "font_family", true}, {"theme", "theme", false}, {"color", "color", true}, {"size", "size", false},
	{"duration", "duration", false}, {"list3", "list3", false}, {"list12", "list12", false}, {"keys", "keys", false},
	{"fraction", "fraction", false}, {"length", "length", false},
}

// (opt-in: VALUES_SHOTS=1) A picture of the scene for each of VALUE_SHOTS, in the session's folder.
@(test)
the_values_scene_pictures :: proc(t: ^testing.T) {
	if os.get_env("VALUES_SHOTS", context.temp_allocator) == "" { return }
	s, app := start_showcase(t, {"--scene=values", "--theme=Graphite", "--size=1280x860"})
	ui.set_animations(&app.main.state, .Off)   // (a row of buttons' mark is where it goes, not on its way)
	for shot in VALUE_SHOTS {
		showcase.values_choose(&app.values, shot.value, "", shot.open)
		session.frames(s, 2)
		if shot.value == "font_family" {
			session.wait_until(s, proc(s: ^session.Session) -> bool {
				return (^showcase.App)(s.user).values.page.font_families.reading == .Ready
			}, "the families", SHOT_BOUND)
		}
		session.frames(s, 6)
		session.save_png(s, fmt.tprintf("values_%s.png", shot.file))
	}
}
