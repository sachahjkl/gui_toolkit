// A program's own module (plugins.md, "As built: a program's own module"): a test program's module "notes", with a
// call answered at once (notes.list), a call that waits for a later build (notes.add, by app_answer), an event
// (note.added) and a permission (app:notes.write). Through the plugin's process, as any call. And its app.d.ts, made
// from the declaration, against the committed snapshot (-define:APP_DTS_WRITE=true writes it again).
package plugins_test

import "core:strings"
import "core:testing"
import plugin_api "gt:plugin_api"
import plugins "gt:plugins"
import "gt:testkit"
import "gt:testkit/session"

APP_DTS_WRITE :: #config(APP_DTS_WRITE, false)
NOTES_DTS :: #load("notes_app.d.ts", string)

// The module's types: a field's doc is its tag's.
Note :: struct {
	id:    int `doc:"Its id, unique in the program"`,
	title: string `doc:"Its title"`,
}
Notes_List :: struct {}
Notes_List_Result :: struct {
	items: []Note `doc:"The notes, oldest first"`,
}
Notes_Add :: struct {
	title: string `doc:"The new note's title"`,
}
Notes_Add_Result :: struct {
	id: int `doc:"The new note's id"`,
}
Note_Added :: struct {
	note: Note `doc:"The note added"`,
}

// The test program's notes, and its module: what `run` reads and the token of each add that waits.
Notes :: struct {
	module:      plugins.App_Module,
	calls:       [2]plugins.App_Call,
	events:      [1]plugins.App_Event,
	permissions: [1]plugins.App_Permission,
	items:       [dynamic]Note,
	waiting:     [dynamic]plugins.App_Token,
	titles:      [dynamic]string,   // (owned) the titles of the adds that wait
}

notes_new :: proc() -> ^Notes {
	n := new(Notes)
	n.calls = {
		{name = "notes.list", arguments = Notes_List, result = Notes_List_Result, doc = "The notes, oldest first.", run = notes_list},
		{name = "notes.add", arguments = Notes_Add, result = Notes_Add_Result, permission = "app:notes.write", doc = "Adds a note, answered once it is kept.", run = notes_add},
	}
	n.events = {{name = "note.added", payload = Note_Added, doc = "A note was added."}}
	n.permissions = {{word = "app:notes.write", words = "Add notes"}}
	n.module = {name = "Notes test", level = 1, calls = n.calls[:], events = n.events[:], permissions = n.permissions[:], user = n}
	append(&n.items, Note{id = 1, title = "eggs"})
	return n
}

notes_free :: proc(n: ^Notes) {
	delete(n.items)
	delete(n.waiting)
	for t in n.titles { delete(t) }
	delete(n.titles)
	free(n)
}

// (at once: the notes live on the interface's thread, where the call runs)
notes_list :: proc(user: rawptr, token: plugins.App_Token, args: rawptr, result: rawptr) -> (pending: bool, error: string) {
	n := (^Notes)(user)
	(^Notes_List_Result)(result).items = n.items[:]
	return false, ""
}

// (later: the program keeps the token, and answers at a later build, as a program whose task ends)
notes_add :: proc(user: rawptr, token: plugins.App_Token, args: rawptr, result: rawptr) -> (pending: bool, error: string) {
	n := (^Notes)(user)
	a := (^Notes_Add)(args)
	if a.title == "" { return false, "a note needs a title" }
	append(&n.waiting, token)
	append(&n.titles, strings.clone(a.title))   // (args live through the call only)
	return true, ""
}

// The adds that wait, answered: each note kept and its id answered.
notes_answer :: proc(fx: ^Fx, n: ^Notes) {
	for token, i in n.waiting {
		note := Note{id = len(n.items) + 1, title = n.titles[i]}
		append(&n.items, note)
		result := Notes_Add_Result{id = note.id}
		_ = plugins.app_answer(&fx.host, token, &result)
	}
	clear(&n.waiting)
}

NOTES_MANIFEST :: `{
	"id": "notes", "name": "Notes", "api": 6, "app": 1, "main": "main.js", "permissions": ["app:notes.write"],
	"commands": [{"id": "list"}, {"id": "add"}]
}`

NOTES_MAIN :: `import { commands, toast } from "gt";
import { notes, on } from "app";
export function activate() {
	on("note.added", (e) => toast.show("heard " + e.note.id + ":" + e.note.title));
	commands.on("list", () => notes.list().then((r) => toast.show("list " + r.items.map((n) => n.id + ":" + n.title).join(","))));
	commands.on("add", () => notes.add({ title: "milk" }).then((r) => toast.show("added " + r.id), (e) => toast.show(e.name + ": " + e.message)));
}
`

// A plugin of the same module that asks for no permission and listens to nothing.
DEAF_MANIFEST :: `{
	"id": "deaf", "name": "Deaf", "api": 6, "app": 1, "main": "main.js", "commands": [{"id": "add"}]
}`

DEAF_MAIN :: `import { commands, toast } from "gt";
import { notes } from "app";
export function activate() {
	commands.on("add", () => notes.add({ title: "tea" }).then((r) => toast.show("added " + r.id), (e) => toast.show(e.name + ": " + e.message)));
}
`

// The program's module, open in a host whose plugins are "notes" (granted) and "deaf".
@(private = "file")
open_notes :: proc(t: ^testing.T) -> (s: ^session.Session, fx: ^Fx, n: ^Notes) {
	root := testkit.temp_folder(t, "plugin-app")
	write_plugin(root, "notes", NOTES_MANIFEST, NOTES_MAIN)
	write_plugin(root, "deaf", DEAF_MANIFEST, DEAF_MAIN)
	enable(root, "notes", "deaf")
	n = notes_new()
	// (registered first, so run last: after open's cleanup closed the host, which reads the module until then)
	testing.cleanup(t, proc(p: rawptr) { notes_free((^Notes)(p)) }, n)
	fx = new(Fx)   // (freed by open's cleanup)
	s = open(t, fx, root, app = &n.module)
	testing.expect(t, plugins.grant(&fx.host, "notes"), "no grant")
	wait_started(s, fx, "notes")
	return
}

// Runs `command` and waits for the toast it says.
@(private = "file")
toast_of :: proc(s: ^session.Session, fx: ^Fx, command: string) -> string {
	toasts := fx.host.toasts
	testing.expectf(s.t, plugins.run_command(&fx.host, command), "the command %s did not run", command)
	session.wait_until(s, Count{fx, toasts + 1}, answered, "the call's answer", WAIT)
	return fx.host.last_toast
}

@(test)
a_call_answered_at_once :: proc(t: ^testing.T) {
	s, fx, _ := open_notes(t)
	got := toast_of(s, fx, "plugin.notes.list")
	testing.expectf(t, got == "list 1:eggs", "notes.list: '%s'", got)
}

@(test)
a_call_answered_at_a_later_build :: proc(t: ^testing.T) {
	s, fx, n := open_notes(t)
	toasts := fx.host.toasts
	testing.expect(t, plugins.run_command(&fx.host, "plugin.notes.add"), "the command did not run")
	session.wait_until(s, n, proc(s: ^session.Session, n: ^Notes) -> bool { return len(n.waiting) == 1 }, "the add waiting", WAIT)
	// (the promise waits: builds go by with no answer)
	session.frames(s, 5)
	testing.expect_value(t, fx.host.toasts, toasts)
	first := n.waiting[0]
	notes_answer(fx, n)
	session.wait_until(s, Count{fx, toasts + 1}, answered, "the add's answer", WAIT)
	testing.expectf(t, fx.host.last_toast == "added 2", "the answer: '%s'", fx.host.last_toast)
	testing.expect_value(t, len(n.items), 2)
	// (a token answered once: a second answer finds no call)
	result := Notes_Add_Result{id = 3}
	testing.expect(t, !plugins.app_answer(&fx.host, first, &result), "a token answered twice")
	testing.expect(t, !plugins.app_fail(&fx.host, first, "late"), "a token failed after its answer")
}

@(test)
an_event_reaches_only_a_plugin_that_listens :: proc(t: ^testing.T) {
	s, fx, n := open_notes(t)
	// (both running: "notes" listens to note.added since its activate, "deaf" listens to nothing)
	_ = toast_of(s, fx, "plugin.notes.list")
	_ = toast_of(s, fx, "plugin.deaf.add")   // (refused: deaf has no grant; it runs, which is what counts here)
	testing.expect_value(t, len(n.waiting), 0)
	toasts := fx.host.toasts
	payload := Note_Added{note = {id = 9, title = "bread"}}
	testing.expect_value(t, plugins.app_emit(&fx.host, "note.added", &payload), 1)
	session.wait_until(s, Count{fx, toasts + 1}, answered, "the event heard", WAIT)
	testing.expectf(t, fx.host.last_toast == "heard 9:bread", "the event: '%s'", fx.host.last_toast)
	// (an event of no such name, and a payload of another type)
	testing.expect_value(t, plugins.app_emit(&fx.host, "note.removed", &payload), -1)
	wrong := Notes_Add{title = "y"}
	testing.expect_value(t, plugins.app_emit(&fx.host, "note.added", &wrong), -1)
}

@(test)
a_call_without_its_grant_is_refused :: proc(t: ^testing.T) {
	s, fx, n := open_notes(t)
	got := toast_of(s, fx, "plugin.deaf.add")
	testing.expectf(t, strings.has_prefix(got, "PermissionError"), "deaf's notes.add: '%s'", got)
	testing.expect_value(t, len(n.waiting), 0)
}

@(test)
app_in_a_program_that_gives_none :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugin-no-app")
	// (one imports "app" without saying so: its start fails; one says it needs level 1: it is refused at once)
	write_plugin(root, "bare", `{"id": "bare", "name": "Bare", "api": 6, "main": "main.js", "commands": [{"id": "add"}]}`, DEAF_MAIN)
	write_plugin(root, "needs", `{"id": "needs", "name": "Needs", "api": 6, "app": 1, "main": "main.js", "commands": [{"id": "add"}]}`, DEAF_MAIN)
	enable(root, "bare", "needs")
	fx := new(Fx)   // (freed by open's cleanup)
	s := open(t, fx, root)
	needs := plugins.find(&fx.host, "needs")
	testing.expect_value(t, needs.state, plugins.Plugin_State.Refused)
	testing.expectf(t, strings.contains(needs.refused, "gives none"), "the refusal: '%s'", needs.refused)
	_ = plugins.run_command(&fx.host, "plugin.bare.add")
	wait_state(s, fx, "bare", .Failed)
	bare := plugins.find(&fx.host, "bare")
	testing.expectf(t, strings.contains(bare.failure, `cannot import "app": this program gives no module "app"`), "the failure: '%s'", bare.failure)
}

@(test)
the_modules_declarations_match_their_snapshot :: proc(t: ^testing.T) {
	n := notes_new()
	defer notes_free(n)
	testing.expect_value(t, plugin_api.app_module_check(&n.module), "")
	made := plugin_api.app_module_dts(&n.module)
	when APP_DTS_WRITE {
		_ = os.write_entire_file(fmt.tprintf("%s/notes_app.d.ts", #directory), transmute([]u8)made)
	} else {
		testing.expectf(t, made == NOTES_DTS, "app.d.ts is not the snapshot (odin test tests/plugins -define:APP_DTS_WRITE=true writes it):\n%s", made)
	}
	page := plugin_api.app_module_markdown(&n.module)
	testing.expect(t, strings.contains(page, "### `notes.add(args)`") && strings.contains(page, "| `app:notes.write` | Add notes |"), "the reference page")
	// (what the check refuses)
	bad := n.module
	calls := n.calls
	calls[0].name = "list"
	bad.calls = calls[:]
	testing.expect(t, plugin_api.app_module_check(&bad) != "", "a call that is not <group>.<call>")
}
