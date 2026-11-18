// The sandbox of a plugin's process (plugins.md, "As built: the sandbox"), the ROADMAP's condition: the process,
// asked by test_escape, reads a file the test made, creates one in the test's folder and opens a TCP socket. Isolated,
// it can do none of them, and its modules still load (read before its sandbox) and its log is still written (by the
// program). Not isolated, it can do them all: the test sees what it says it sees.
package plugins_test

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import plugins "gt:plugins"
import "gt:testkit"
import "gt:testkit/session"

ESCAPE_MANIFEST :: `{
	"id": "escape", "name": "Escape", "api": 1, "main": "main.js",
	"commands": [{"id": "hello"}, {"id": "late"}]
}`

// `late` imports a module after the start, as a plugin's code may at any time: its source was read before the sandbox.
ESCAPE_MAIN :: `import { commands, toast } from "gt";
import { greeting } from "./lib/words.js";
export function activate(context) {
	commands.on("hello", () => toast.show(greeting(context.name)));
	commands.on("late", () => import("./lib/words.js").then((m) => toast.show(m.greeting("a late import"))));
}
`

// Runs `act`, then waits for the next toast and gives its words.
@(private = "file")
toast_after :: proc(s: ^session.Session, fx: ^Fx, act: proc(fx: ^Fx, data: [2]string), data: [2]string = {}) -> string {
	toasts := fx.host.toasts
	act(fx, data)
	session.wait_until(s, Count{fx, toasts + 1}, proc(s: ^session.Session, c: Count) -> bool { return c.fx.host.toasts >= c.at }, "the plugin's toast", WAIT)
	return fx.host.last_toast
}

// The plugin started in a host whose sandbox is `mode`, its modules checked, then its tries: the toast's words.
@(private = "file")
escape :: proc(t: ^testing.T, mode: plugins.Sandbox_Mode) -> (said, root: string) {
	root = testkit.temp_folder(t, "plugin-sandbox")
	secret := fmt.tprintf("%s/secret.txt", root)
	outside := fmt.tprintf("%s/outside", root)
	_ = os.write_entire_file(secret, transmute([]u8)string("not the plugin's"))
	_ = os.make_directory_all(outside)
	write_plugin(root, "escape", ESCAPE_MANIFEST, ESCAPE_MAIN)
	enable(root, "escape")
	fx := new(Fx)   // (freed by open's cleanup)
	s := open(t, fx, root, sandbox = mode)
	hello := toast_after(s, fx, proc(fx: ^Fx, _: [2]string) { _ = plugins.run_command(&fx.host, "plugin.escape.hello") })
	testing.expectf(t, hello == "Hello from Escape", "its first module: '%s'", hello)
	late := toast_after(s, fx, proc(fx: ^Fx, _: [2]string) { _ = plugins.run_command(&fx.host, "plugin.escape.late") })
	testing.expectf(t, late == "Hello from a late import", "a module imported after its start: '%s'", late)
	said = toast_after(s, fx, proc(fx: ^Fx, d: [2]string) { plugins.test_escape(&fx.host, "escape", d[0], d[1]) }, {secret, outside})
	return
}

@(test)
a_sandboxed_process_reaches_no_file_nor_socket :: proc(t: ^testing.T) {
	if ok, why := plugins.sandbox_available(); !ok {
		log.warnf("skipped: %s", why)
		return
	}
	said, root := escape(t, .Required)
	testing.expectf(t, said == "escaped: none", "the sandboxed process: '%s'", said)
	// (the log is the program's to write: the child's line about its sandbox reaches it)
	data, err := os.read_entire_file(fmt.tprintf("%s/state/escape.log", root), context.temp_allocator)
	sandbox := ODIN_OS == .Windows ? "isolated: AppContainer" : "isolated: Landlock"
	testing.expectf(t, err == nil && strings.contains(string(data), sandbox), "the log says no sandbox: '%s'", string(data))
}

@(test)
without_the_sandbox_the_tries_succeed :: proc(t: ^testing.T) {
	said, _ := escape(t, .Off)
	when ODIN_OS == .Linux {
		testing.expectf(t, said == "escaped: read, create, socket", "the process with no sandbox: '%s'", said)
	} else {
		testing.expectf(t, said == "escaped: read, create", "the process with no sandbox: '%s'", said)
	}
}
