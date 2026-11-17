# plugins: plugins in JavaScript

`gt:plugins` lets a person add commands to a program without a new build of it. A plugin is a folder with a
`plugin.json` and its JavaScript; its commands appear in the command palette, and a command's handler can show a toast.
The design and its reasons are in [src/md/features/plugins.md](../src/md/features/plugins.md). What a plugin's
JavaScript can call is in [plugin-api.md](plugin-api.md).

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
| `host_close(h)` | Stops every plugin and waits for their threads for at most 2 s. Call it before `ui.destroy`. |
| `page_info(h)` | The Plugins page, a `prefs_page.Page_Info`: each plugin, its state, its switch, Stop, and Reload plugins. |
| `run_command(h, id)` | Runs `plugin.<plugin id>.<command id>`, or `plugins.reload`. False: no such command, or its plugin cannot run now. |
| `set_enabled(h, id, on)` | Turns a plugin on or off, and writes `plugins.toml` on a chore. |
| `stop(h, id)` | Stops a plugin's runtime. The plugin is `Ready` again when its thread has ended. |
| `reload(h)` | Stops every runtime and reads the folder again. |
| `state_of(h, id)`, `find(h, id)`, `host_plugins(h)`, `loaded(h)` | What the host knows, for a page or a test. |

`Host_Options`:

| Field | |
|---|---|
| `program` | The program's folder, as `platform.user_dir` takes it (`"FromentSoftware/Papier"`). |
| `program_id` | What a manifest's `"program"` must say. A manifest that names another program is refused. |
| `folder`, `config_dir`, `state_dir` | The plugins' folder, the folder of `plugins.toml`, and the folder of the logs and markers. Each is `""` for the user's folder. |
| `announcer` | Where a plugin's messages go. nil: the window's toasts. |
| `bound_ms` | How long a message can run before its plugin is `Not_Responding` (0: 2000). |
| `memory_limit` | A plugin's heap budget in bytes (0: 64 MB). |

## Where things are

- The plugins: `<data>/<program>/plugins/<id>/`, each folder named as its plugin's id.
- What the person decided: `<config>/<program>/plugins.toml`. A plugin is off until the person turns it on.
- A plugin's log: `<state>/<program>/plugins/<id>.log`.
- The marker of a crash: `<state>/<program>/plugins/inside-<pid>-<id>.txt`. The plugin's thread writes it while it runs
  a message. A marker of a process that has ended makes its plugin `Suspended` at the next start.

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

A plugin imports `"gt"` and its own files (`"./lib/words.js"`), nothing else.

## What a plugin cannot do to the program

- It runs on a thread of its own, with a runtime of its own, started at its first use. The interface's thread runs no
  JavaScript and never waits for a plugin.
- A handler that does not return makes the plugin `Not_Responding` after the bound. Stop interrupts it at its next loop
  or call.
- An exception that nothing catches goes to the plugin's log and shows one toast. The plugin goes on.
- Past its memory budget, the plugin is `Failed` and its memory is freed.

The states, as the Plugins page shows them: `Found`, `Refused`, `Off`, `Ready`, `Starting`, `Running`,
`Not_Responding`, `Failed`, `Suspended`.

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
