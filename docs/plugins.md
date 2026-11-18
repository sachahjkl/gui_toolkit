# plugins: plugins in JavaScript

`gt:plugins` lets a person add commands to a program without a new build of it. A plugin is a folder with a
`plugin.json` and its JavaScript; its commands appear in the command palette, and a command's handler can show a toast.
The design and its reasons are in [src/md/features/plugins.md](../src/md/features/plugins.md). What a plugin's
JavaScript can call is in [plugin-api.md](plugin-api.md) and the site's
[API explorer](https://gt.sacha.house/plugins/api/). A plugin's author starts with [gt-runtime.md](gt-runtime.md).

```odin
import plugins "gt:plugins"
```

Only a program that imports the package links the JavaScript engine (`gt:js`, about 2 MB). No other package of the
toolkit imports it.

## Turning plugins on in a program

```odin
App :: struct {
	palette:   ui.Command_Palette,
	announcer: ui.Announcer,
	plugins:   plugins.Host,
	...
}

// once, after the window's State exists
plugins.host_open(&app.plugins, &app.ui, {program = APP_FOLDER, program_id = "papier", announcer = &app.announcer})

// each build, before ui.palette_chosen
plugins.host_build(&app.plugins, &app.palette)
ui.palette_chosen(&app.palette)   // the plugins' source runs its choice here

// the settings: the Plugins page among the program's pages
o.pages = {..., plugins.page_info(&app.plugins)}

// at the end, before ui.destroy
plugins.host_close(&app.plugins)
```

| Call | What it does |
|---|---|
| `host_open(h, state, options)` | Starts the host. The folder is read on a chore at the first `host_build`. |
| `host_build(h, palette)` | Each build: adds the palette's `plugin` source, applies what the plugins posted, and marks a plugin `Not_Responding` past the bound. It reads atomics only. |
| `host_close(h)` | Stops every plugin and waits for their processes for at most 2 s, then kills the ones left. Call it before `ui.destroy`. |
| `page_info(h)` | The Plugins page, a `prefs_page.Page_Info`: each plugin, its state, its switch, Stop, and Reload plugins. |
| `run_command(h, id)` | Runs `plugin.<plugin id>.<command id>`, or `plugins.reload`. False: no such command, or its plugin cannot run now. |
| `set_enabled(h, id, on)` | Turns a plugin on or off, and writes `plugins.toml` on a chore. |
| `stop(h, id)` | Stops a plugin's runtime; its process is killed when it has not ended 1 s later. The plugin is `Ready` again when its process has ended. |
| `grant(h, id)`, `revoke(h, id)` | Grants a plugin what its manifest asks and turns it on (the grant dialog's Allow); takes back its permissions and the files it was given. |
| `path_resolve(path, data_dir, granted, picked)`, `net_allowed(granted, url)`, `permission_parse(word)`, `origin_of(url)`, `host_is_private(host)`, `url_join(base, location)` | The broker's checks, for a test or a program's own page. |
| `list_info(h, plugin_id, view_id, key)`, `list_scroll_to(h, plugin_id, view_id, key, row)` | What the host knows of a view's lazy list (its rows built, its asks, the answers dropped); scrolls it to a row. For a test or a program's own page. |
| `restart(h, id)` | A `Failed` plugin is `Ready` again: its next use starts a new process. A failed view's Restart calls it. |
| `test_crash(h, id)`, `test_hang(h, id)` | A test's hooks: the plugin's process panics at its next turn, or waits there where no interrupt reaches it. |
| `test_escape(h, id, read_path, create_dir)` | A test's hook: the plugin's process tries to read a file, create one and open a TCP socket; a toast says which it could (`escaped: none` when isolated). |
| `sandbox_available()` | Whether this system can isolate a plugin's process, and why not. |
| `reload(h)` | Stops every runtime and reads the folder again. |
| `state_of(h, id)`, `find(h, id)`, `host_plugins(h)`, `loaded(h)` | What the host knows, for a page or a test. |
| `open_view(h, plugin_id, view_id)` | Opens a plugin's view among the window's views, at its manifest's place, and starts the plugin when it does not run. The palette's `plugin-view.<plugin id>.<view id>` items call it. |
| `view_body(h, plugin_id, view_id)` | Builds a plugin's view in the box being built, in the program's own layout (gt-runtime's window). |
| `view_field(h, plugin_id, view_id, key)`, `view_keys(h, plugin_id, view_id)` | A field's shown and rendered text, the keys of a view's last list: what a test reads. |
| `settings_pages(h)` | One settings page per plugin that has settings, for `Page_Options.pages`. |

`Host_Options`:

| Field | |
|---|---|
| `program` | The program's folder, as `platform.user_dir` takes it (`"FromentSoftware/Papier"`). |
| `program_id` | What a manifest's `"program"` must say. A manifest that names another program is refused. |
| `folder`, `config_dir`, `state_dir` | The plugins' folder, the folder of `plugins.toml`, and the folder of the logs. Each is `""` for the user's folder. |
| `announcer` | Where a plugin's messages go. nil: the window's toasts. |
| `bound_ms` | How long a message can run before its plugin is `Not_Responding` (0: 2000). |
| `memory_limit` | A plugin's heap budget in bytes (0: 64 MB). |
| `sandbox` | `If_Available` (the default), `Required` or `Off`: see "What a plugin's process can do". |
| `data_dir` | The folder of the plugins' own data folders (`""`: `<data>/<program>/plugin-data`). |
| `prefs` | The program's preferences: the plugins' settings are registered there as `plugins.<plugin id>.<setting id>`. nil: a plugin's settings keep their defaults. |
| `single` | One plugin instead of the folder: its folder, or a lone `.js` file whose manifest is implied. It is on from the start (gt-runtime). |

## Where things are

- The plugins: `<data>/<program>/plugins/<id>/`, each folder named as its plugin's id.
- What the person decided: `<config>/<program>/plugins.toml`. A plugin is off until the person turns it on.
- A plugin's log: `<state>/<program>/plugins/<id>.log`.
- A plugin's process: the program's own executable, started again with `--gt-plugin-host` at the plugin's first use.
  The program's `main` needs nothing for it: `gt:plugins` takes that argument before `main` runs. Its standard input and
  output are the plugin's channel to the program; its standard error is the program's.

## A plugin

```
sample/
  plugin.json
  main.js
```

```json
{
	"id": "sample", "name": "Sample", "version": "1.0.0", "api": 1, "main": "main.js",
	"commands": [{ "id": "hello", "label": "Say hello" }]
}
```

```js
import { commands, toast } from "gt";

export function activate(context) {
	commands.on("hello", () => toast.show("Hello from " + context.name));
}
```

The manifest's fields:

- `id`: lower case letters, digits, `_` and `-`. It is also the folder's name.
- `api`: the level of the API the plugin was written for. A level that this program does not give is refused, with a
  sentence on the Plugins page.
- `main`: the entry file, `main.js` by default.
- `program`: the program the plugin is for. When it is absent, the plugin is for any program.
- `commands`: each with `id`, `label`, and optionally `group`, `icon` and `tags`.
- `views`: each with `id`, `title`, and `place`: `internal` (a window inside the program's, the default), `dialog`,
  `panel` or `window`. The person moves it from there; the window's views remember where.
- `settings`: each with `id`, `title`, `description`, `kind` (`bool`, `int`, `float` or `string`), `default`, and
  optionally `min` and `max`, or `choices` for a string. A default out of its bounds or its choices is refused.

- `permissions`: what it needs beyond its own data folder, each a word: `files` (what the person picks in the
  system's dialog), `folder:documents`, `folder:downloads`, `clipboard.read`, `clipboard.write`, `net:*` (any public
  address) or `net:<origin>` (`"net:https://api.example.com"`, `"net:http://localhost:8080"`).

A plugin imports `"gt"` and its own files (`"./lib/words.js"`), nothing else.

## Permissions

A plugin that asks for permissions is off until the person turns it on. Turning it on shows a dialog with each
permission in words; Allow keeps the grant in `plugins.toml` and turns the plugin on. A new version that asks for more
is off again until the person allows the new set. The Plugins page says what each plugin may do, with "Take back its
permissions".

The work is the program's, never the plugin's process's: a call of `files`, `http` or `clipboard` is a request to the
program's broker, which checks the grant, does the work on the chores and answers. A call without its grant rejects
with `PermissionError`.

```js
import { files, http, clipboard } from "gt";

await files.write("notes/today.txt", "…");          // its own data folder: no permission
const text = await files.read("~documents/a.txt");   // "folder:documents"
const path = await files.pick();                     // "files", during a command or a click in its view
const res = await http.fetch("https://api.example.com/v1/items");   // "net:https://api.example.com"
await clipboard.write("copied");                     // "clipboard.write"
```

- A relative path is in the plugin's data folder, `<data>/<program>/plugin-data/<id>/`, kept when its code is
  replaced. `..` and links are refused everywhere.
- Each redirect of a request is checked as its first address. `net:*` never reaches the machine's own addresses nor the
  local network's: name such an origin.
- `clipboard.read` and `files.pick` work only while the person acts in the plugin (a command, a click in its view).

## A view

A view's render returns a tree of nodes ([plugin-api.md](plugin-api.md), "Nodes"). The host writes it as a display
list in the plugin's process, which sends it to the program; the window replays the last list at each build with the toolkit's widgets. A click, a
change or Enter is a message to the plugin: its handler runs, then the view renders again.

```js
import { views } from "gt";

let count = 0;
export function activate() {
	views.register("main", () => ({ kind: "column", children: [
		{ kind: "text", text: `Count: ${count}` },
		{ kind: "button", key: "add", label: "Add", onClick: () => { count += 1; } },
	] }));
}
```

- A node's `key` is unique in the view. A node without one is known by its place. A key given twice drops the second
  node, and the plugin's log says so.
- What the person types in a field is the host's. A field with `value` shows the plugin's value, unless the person typed
  since the change the plugin last heard of. A field without `value` keeps its own text. Check boxes (`checked`) and
  switches (`on`) follow the same rule.
- `views.update(id)` renders a view again after a command or a promise.
- A `list` node (API level 5) shows `count` rows and asks the plugin only for those in view and a margin, as the person
  scrolls. `row(i)` returns row `i`'s node; a row not answered yet shows a placeholder. Change `version` when what the
  rows show changes: the rows are asked again.

```js
let items = [], version = 0;
views.register("main", () => ({ kind: "list", key: "items", count: items.length, version, rowHeight: 2,
	row: (i) => ({ kind: "row", children: [
		{ kind: "text", text: items[i].name },
		{ kind: "button", key: "open", label: "Open", onClick: () => open(items[i]) },
	] }),
}));
```

- A key in a row is that row's: `key: "open"` in each row is fine. A list inside a row of a list is dropped.
- When the plugin stops, the view keeps its last list and says why: Not responding (with Stop), Stopped (with Start),
  or the failure.

## gt-runtime

`gt-runtime` runs one plugin as an application: the window, the theme, the palette, the settings and the toasts are the
toolkit's.

```
gt-runtime examples/js/todo              a plugin's folder
gt-runtime examples/js/counter/main.js   a lone file: one view "main", its name the file's
```

The plugin's first view fills the window. Its commands are in the palette (Ctrl+K). The settings (Ctrl+,) hold the look,
the plugin's own settings and the Plugins page. `odin run tools/tk -- build gt-runtime` builds it into `build/`. A
release attaches `gt-runtime-windows-x64.zip`, with the JavaScript demos in its `js` folder.

## What a plugin cannot do to the program

- It runs in a process of its own, with a runtime of its own, started at its first use. The program runs no
  JavaScript, and its interface's thread never waits for a plugin: it sends messages and replays the lists that come.
- A handler that does not return makes the plugin `Not_Responding` after the bound. Stop interrupts it at its next loop
  or call; a process that does not answer within 1 s is killed.
- An exception that nothing catches goes to the plugin's log and shows one toast. The plugin goes on.
- Past its memory budget, the plugin is `Failed` and its memory is freed.
- A crash of its process (a bug of the engine, an abort) makes it `Failed`; the program goes on, and Restart starts a
  new process. Three crashes in one run make it `Suspended` until the person turns it on.

The states, as the Plugins page shows them: `Found`, `Refused`, `Off`, `Ready`, `Starting`, `Running`,
`Not_Responding`, `Failed`, `Suspended`.

## What a plugin's process can do

On Linux the process isolates itself before the plugin's code runs. It keeps its two pipes to the program and nothing
else:

- It opens and creates no file (Landlock, with no path allowed). Its `.js` and `.mjs` files are read before that, at
  its start (2 000 files and 64 MB at most); its log lines go to the program, which writes the log.
- It makes no socket (a seccomp filter), and no TCP connection (Landlock, from kernel ABI 4).
- From Landlock's ABI 6, it signals no process out of itself.
- What it reaches beyond that is the broker's: what the person granted.

`Host_Options.sandbox` says what happens where the system cannot isolate it (a kernel with no Landlock):

| Mode | |
|---|---|
| `If_Available` (the default) | The plugin runs as before; its log says it is not isolated, and why. |
| `Required` | The plugin is `Failed`: "this system cannot isolate a plugin's process". |
| `Off` | Never isolated (a program's own debugging). |

`sandbox_available()` says whether this system can. Windows and macOS do not yet: a plugin's process there has the
person's rights, as the program has. The sandbox does not bound the processor nor the memory: Stop's bound and the
memory budget do.

## Adding a call to the API

The calls are declared in `src/plugin_api/api.odin` (`gt:plugin_api`). A call is the struct of its arguments and one
entry of `DECLARATIONS`: its module, its JavaScript name, its result, the capability it needs and the level that added
it. The one bridge (`src/plugin_api/bridge.odin`) converts the arguments, checks the capability, then calls the host's
implementation.

```odin
// api.odin
// Shows a message to the person.
Toast_Show :: struct {
	text:    string,
	options: Toast_Options `optional`,
}
DECLARATIONS :: [?]Declaration{..., {module = "toast", name = "show", arguments = Toast_Show, result = .Undefined, capability = .None, level = 1}}

// the host (gt:plugins), on the plugin's thread
plugin_api.realm_set(&realm, "toast", "show", plugin_api.implement(plugin_api.Toast_Show, toast_show))
api := js.retain(rt, plugin_api.install(ctx, &realm))   // the object that import.meta.gt gives the module "gt"
source := plugin_api.module_source()                    // the text of the module "gt"
```

| Call | What it does |
|---|---|
| `implement($A, proc(^Call, ^A) -> js.Value)` | A typed implementation as an `Impl`. |
| `realm_set(realm, module, name, impl)` | Gives a declaration its implementation. False: no such declaration. |
| `install(ctx, realm)` | The API object of a realm. It sets `rt.host_data` to the realm, where the bridge finds it. |
| `module_source()` | The text of the module `"gt"`: each module exported from `import.meta.gt`. |
| `declaration_name(i)` | A declaration's JavaScript name (`"toast.show"`). |

A field's type is `string`, `f64`, `int`, `bool`, `Handler` (a function of the plugin), an enum (its value's name) or a
struct of the file (an object). A field tagged `optional` may be absent. After a change, run
`odin run tools/tk -- plugin_api`: it writes `plugin-api/gt.d.ts`, the current level's snapshot, `plugin-api/api.json`
and [plugin-api.md](plugin-api.md). `tk ci` fails while they differ from the declarations, or when an older level's
snapshot is no longer what its calls make: raise `PLUGIN_API_OLDEST` instead.

## The example

`odin run tools/tk -- build plugins`, then `build/plugins`: the Plugins page of `examples/plugins`, whose `sample`
plugin has two commands. One shows a toast. The other never returns.
