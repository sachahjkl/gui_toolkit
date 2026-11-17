// gt:plugins (src/md/features/plugins.md): the test that breaks the design on day one, a plugin whose command is
// `for (;;) {}`, chosen in the palette of a headless window: the window goes on building, the plugin is said not to
// respond within a bound, Stop brings it back to Ready, and its other command's toast comes. Then the manifests that are
// refused, a plugin off by default, the names of the commands, and the states a plugin goes through.
package plugins_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import plugins "gt:plugins"
import "gt:testkit"
import "gt:testkit/session"
import "gt:ui"

// The bound of Not_Responding in these tests (the default is 2 s), and how long each wait may take.
BOUND_MS :: 300
WAIT :: 10 * time.Second
// The builds the window must still make while the plugin loops.
MORE_BUILDS :: 30

SAMPLE_MANIFEST :: `{
	"id": "sample", "name": "Sample", "version": "1.0", "api": 1, "main": "main.js",
	"commands": [{"id": "hello", "label": "Say hello"}, {"id": "spin", "label": "Loop forever"}]
}`

SAMPLE_MAIN :: `import { commands, toast } from "gt";
import { greeting } from "./lib/words.js";
export function activate(context) {
	commands.on("hello", () => toast.show(greeting(context.name), { kind: "good" }));
	commands.on("spin", () => { for (;;) {} });
}
`

SAMPLE_WORDS :: `export const greeting = (name) => "Hello from " + name;
`

THROWING_MAIN :: `export function activate() { throw new Error("no start today"); }
`

Fx :: struct {
	host:    plugins.Host,
	palette: ui.Command_Palette,
	opened:  bool,
	builds:  int,
	open_with: string,   // the palette opens at the next build with this typed (a literal; "": not asked)
}

// A plugin's folder under `root`/plugins, and the toolkit's folders of the test.
write_plugin :: proc(root, id, manifest, main: string) {
	dir := fmt.tprintf("%s/plugins/%s", root, id)
	_ = os.make_directory_all(fmt.tprintf("%s/lib", dir))
	_ = os.write_entire_file(fmt.tprintf("%s/plugin.json", dir), transmute([]u8)manifest)
	_ = os.write_entire_file(fmt.tprintf("%s/main.js", dir), transmute([]u8)main)
	_ = os.write_entire_file(fmt.tprintf("%s/lib/words.js", dir), transmute([]u8)string(SAMPLE_WORDS))
}

enable :: proc(root: string, ids: ..string) {
	_ = os.make_directory_all(fmt.tprintf("%s/config", root))
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[enabled]\n")
	for id in ids { fmt.sbprintf(&b, "%s = true\n", id) }
	_ = os.write_entire_file(fmt.tprintf("%s/config/plugins.toml", root), transmute([]u8)strings.to_string(b))
}

// A headless window whose builds run the host and the palette, the host reading `root`.
open :: proc(t: ^testing.T, fx: ^Fx, root: string) -> ^session.Session {
	s := session.start(t, {user = fx, no_renderer = true, build = proc(s: ^session.Session) {
		fx := (^Fx)(s.user)
		fx.builds += 1
		if !fx.opened { return }
		plugins.host_build(&fx.host, &fx.palette)
		if fx.open_with != "" {
			ui.palette_open(&fx.palette, fx.open_with)
			fx.open_with = ""
		}
		_, _ = ui.palette_chosen(&fx.palette)   // (the plugin source's act runs here)
	}})
	plugins.host_open(&fx.host, s.state, {
		program = "gui_toolkit_plugins_test", program_id = "plugins_test",
		folder = fmt.tprintf("%s/plugins", root), config_dir = fmt.tprintf("%s/config", root), state_dir = fmt.tprintf("%s/state", root),
		bound_ms = BOUND_MS,
	})
	fx.opened = true
	// (before the session's end, which destroys the State: cleanups run last first)
	testing.cleanup(t, proc(p: rawptr) {
		fx := (^Fx)(p)
		plugins.host_close(&fx.host)
		ui.palette_destroy(&fx.palette)
		free(fx)
	}, fx)
	session.wait_until(s, fx, proc(s: ^session.Session, fx: ^Fx) -> bool { return plugins.loaded(&fx.host) }, "the plugins' folder", WAIT)
	return s
}

// Chooses a command in the palette: opened with ">" and its label typed, its ranking waited for, Enter.
choose :: proc(s: ^session.Session, fx: ^Fx, label: string) {
	fx.open_with = strings.concatenate({">", label}, context.temp_allocator)
	session.frame(s)
	session.wait_until(s, fx, proc(s: ^session.Session, fx: ^Fx) -> bool { return fx.palette.pending == 0 && fx.palette.rankings > 0 }, "the palette's list", WAIT)
	session.wait_text(s, label, WAIT)
	session.key(s, .Return)
	session.frames(s, 2)
}

wait_state :: proc(s: ^session.Session, fx: ^Fx, id: string, want: plugins.Plugin_State, loc := #caller_location) {
	Wanted :: struct { fx: ^Fx, id: string, want: plugins.Plugin_State }
	session.wait_until(s, Wanted{fx, id, want}, proc(s: ^session.Session, w: Wanted) -> bool {
		return plugins.state_of(&w.fx.host, w.id) == w.want
	}, fmt.tprintf("the state %v", want), WAIT, loc)
}

@(test)
an_endless_handler_does_not_stop_the_window :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugins")
	write_plugin(root, "sample", SAMPLE_MANIFEST, SAMPLE_MAIN)
	enable(root, "sample")
	fx := new(Fx)   // (freed by open's cleanup, which runs after the test)
	s := open(t, fx, root)
	testing.expect_value(t, plugins.state_of(&fx.host, "sample"), plugins.Plugin_State.Ready)

	// 1. the command in the palette; its runtime starts on its own thread
	choose(s, fx, "Loop forever")
	// 2. the window still builds
	from := fx.builds
	session.wait_until(s, Count{fx, from + MORE_BUILDS}, proc(s: ^session.Session, c: Count) -> bool { return c.fx.builds >= c.at }, "30 more builds", WAIT)
	// 3. said not to respond within the bound; Stop; Ready
	wait_state(s, fx, "sample", .Not_Responding)
	plugins.stop(&fx.host, "sample")
	wait_state(s, fx, "sample", .Ready)
	// 4. its other command: a new runtime, and its toast
	toasts := fx.host.toasts
	choose(s, fx, "Say hello")
	session.wait_until(s, Count{fx, toasts + 1}, proc(s: ^session.Session, c: Count) -> bool { return c.fx.host.toasts >= c.at }, "the plugin's toast", WAIT)
	testing.expectf(t, strings.contains(fx.host.last_toast, "Hello from Sample"), "the toast says '%s'", fx.host.last_toast)
	wait_state(s, fx, "sample", .Running)
}

Count :: struct { fx: ^Fx, at: int }

@(test)
a_plugin_is_off_until_turned_on :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugins")
	write_plugin(root, "sample", SAMPLE_MANIFEST, SAMPLE_MAIN)
	fx := new(Fx)   // (freed by open's cleanup, which runs after the test)
	s := open(t, fx, root)
	testing.expect_value(t, plugins.state_of(&fx.host, "sample"), plugins.Plugin_State.Off)
	testing.expect(t, !plugins.run_command(&fx.host, "plugin.sample.hello"), "a command of a plugin that is off ran")
	plugins.set_enabled(&fx.host, "sample", true)
	testing.expect_value(t, plugins.state_of(&fx.host, "sample"), plugins.Plugin_State.Ready)
	// (turned on: written to plugins.toml on a chore; the next read finds it on)
	session.wait_until(s, root, proc(s: ^session.Session, root: string) -> bool {
		data, err := os.read_entire_file(fmt.tprintf("%s/config/plugins.toml", root), context.temp_allocator)
		return err == nil && strings.contains(string(data), "sample = true")
	}, "plugins.toml", WAIT)
	plugins.reload(&fx.host)
	session.wait_until(s, fx, proc(s: ^session.Session, fx: ^Fx) -> bool { return plugins.state_of(&fx.host, "sample") == .Ready }, "the reload", WAIT)
	plugins.set_enabled(&fx.host, "sample", false)
	testing.expect_value(t, plugins.state_of(&fx.host, "sample"), plugins.Plugin_State.Off)
}

@(test)
a_failed_start_and_a_suspended_plugin :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugins")
	write_plugin(root, "sample", SAMPLE_MANIFEST, THROWING_MAIN)
	write_plugin(root, "other", `{"id": "other", "api": 1, "commands": [{"id": "go"}]}`, SAMPLE_MAIN)
	enable(root, "sample", "other")
	// (a marker of a process that is gone: the program ended inside "other" last time)
	_ = os.make_directory_all(fmt.tprintf("%s/state", root))
	_ = os.write_entire_file(fmt.tprintf("%s/state/inside-999999999-other.txt", root), transmute([]u8)string("pid: 999999999\nstart: 1\nplugin: other\n"))
	fx := new(Fx)   // (freed by open's cleanup, which runs after the test)
	s := open(t, fx, root)
	testing.expect_value(t, plugins.state_of(&fx.host, "other"), plugins.Plugin_State.Suspended)
	testing.expect(t, !plugins.run_command(&fx.host, "plugin.other.go"), "a command of a suspended plugin ran")
	testing.expect(t, plugins.run_command(&fx.host, "plugin.sample.hello"), "the command did not run")
	wait_state(s, fx, "sample", .Failed)
	p := plugins.find(&fx.host, "sample")
	testing.expectf(t, strings.contains(p.failure, "no start today"), "the failure says '%s'", p.failure)
	testing.expect(t, !plugins.run_command(&fx.host, "plugin.sample.hello"), "a command of a failed plugin ran")
	plugins.set_enabled(&fx.host, "other", true)
	testing.expect_value(t, plugins.state_of(&fx.host, "other"), plugins.Plugin_State.Ready)
}

@(test)
manifests_refused :: proc(t: ^testing.T) {
	Case :: struct { text, why: string }
	cases := [?]Case{
		{`{"id": "a", "api": 99}`, "needs level 99"},
		{`{"id": "a"}`, "does not say the level"},
		{`{"id": "Bad Id", "api": 1}`, "is not an id"},
		{`{"id": "a.b", "api": 1}`, "is not an id"},
		{`{"id": "a", "api": 1, "program": "papier"}`, "a plugin of papier"},
		{`{"id": "a", "api": 1, "main": "../x.js"}`, "not a file of its folder"},
		{`{"id": "a", "api": 1, "commands": [{"id": "Go"}]}`, "command id"},
		{`{"id": "a", "api": 1, "commands": [{"id": "go"}, {"id": "go"}]}`, "twice"},
		{`[1, 2]`, "not an object"},
		{`{"id": `, "not JSON"},
	}
	for c in cases {
		m, why := plugins.manifest_parse(c.text, "plugins_test")
		testing.expectf(t, strings.contains(why, c.why), "%s: refused for '%s', not for '%s'", c.text, why, c.why)
		plugins.manifest_destroy(&m)
		delete(why)
	}
	m, why := plugins.manifest_parse(SAMPLE_MANIFEST, "plugins_test")
	defer plugins.manifest_destroy(&m)
	testing.expectf(t, why == "", "the sample is refused: %s", why)
	testing.expect_value(t, len(m.commands), 2)
	testing.expect_value(t, m.commands[1].label, "Loop forever")
	testing.expect_value(t, m.commands[0].group, "Sample")   // (its group: the plugin's name)
}

@(test)
command_names :: proc(t: ^testing.T) {
	testing.expect_value(t, plugins.command_id("sample", "hello"), "plugin.sample.hello")
	id, cmd, ok := plugins.command_split("plugin.sample.file.open")
	testing.expect(t, ok && id == "sample" && cmd == "file.open", "a command id with dots")
	for bad in ([?]string{"plugin.sample", "plugin..x", "plugin.sample.", "other.sample.x", "plugins.reload"}) {
		_, _, is := plugins.command_split(bad)
		testing.expectf(t, !is, "%s was split", bad)
	}
	testing.expect(t, plugins.id_valid("my-plugin_2", false), "a good id")
	testing.expect(t, !plugins.id_valid("my.plugin", false), "a plugin id with a dot")
	testing.expect(t, plugins.id_valid("file.open", true), "a command id with a dot")
}

@(test)
module_specifiers :: proc(t: ^testing.T) {
	Case :: struct { referrer, spec, name: string, ok: bool }
	cases := [?]Case{
		{plugins.BOOT_MODULE, "./main.js", "main.js", true},
		{"main.js", "./lib/words.js", "lib/words.js", true},
		{"lib/words.js", "../util.js", "util.js", true},
		{"lib/words.js", "./../../x.js", "", false},
		{"main.js", "lib/x.js", "", false},
		{"main.js", "/etc/passwd", "", false},
		{"main.js", "./a//b.js", "", false},
	}
	for c in cases {
		name, ok := plugins.module_resolve(c.referrer, c.spec)
		testing.expectf(t, ok == c.ok && (!ok || name == c.name), "%s from %s: '%s' %v", c.spec, c.referrer, name, ok)
	}
}
