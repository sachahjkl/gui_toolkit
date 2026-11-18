---
name: gt-plugin
description: Write, run and test a JavaScript plugin for a gui_toolkit program (papier, classeur, inspecteur, cliche, opencode native, atelier or any program built on gui_toolkit), or a small JavaScript application for gt-runtime. Use this skill whenever the task touches a plugin.json, a main.js that does `import ... from "gt"`, gt-runtime, a plugin's commands, toasts, views, display lists, nodes, settings, lazy lists (a `list` node with `row(i)`), permissions (files, net, clipboard), PermissionError, or the Plugins page, even when the user only says "a plugin", "a small app", "a dashboard" or "a screen" for one of these programs.
---

# A plugin for a gui_toolkit program

A plugin is a folder of JavaScript that a program runs. Its commands go in the command palette, its settings in the
settings, its views in the window. `gt-runtime` runs one plugin as an application of its own: the window, the theme,
the palette, the settings and the toasts are the toolkit's.

The program draws a view with its own widgets. The plugin only returns a tree of plain objects, so the view looks and
behaves as the program does. You write no layout code, no spacing and no colours.

This toolkit gives API level 5.

## Read first

- `references/gt.d.ts`: the types of the module `"gt"`, every call and every node. Check a name here before you use it.
- `references/plugins.md`: the guide. The manifest's fields, permissions, views and lazy lists.
- `references/gt-runtime.md`: gt-runtime and two complete demos (a counter, a todo list).
- `references/plugin-api.md`: the reference, one section per call, with its level and its permission.

If this file and a reference disagree, the reference is right: it is copied from the toolkit when the skill is
published.

## The method

1. Decide what the plugin adds: commands, views, settings.
2. Write `plugin.json` with those entries. A lone `main.js` is enough for one view and no permission.
3. Write `main.js`. Export `activate(context)` and register the handlers there.
4. Run it with `gt-runtime <folder or file.js>`.
5. Read the plugin's log after each run (see "The log").
6. Check the pitfalls at the end of this file.

## The folder

```
hello/
  plugin.json
  main.js
  lib/words.js        optional: imported as "./lib/words.js"
```

A plugin imports `"gt"` and its own files. Nothing else exists: no npm package, no Node module, no `fetch` global, no
DOM. A specifier must start with `./` or `../` and stay inside the folder.

In a program, the folder goes in `<data>/<program>/plugins/<id>/`, named as the plugin's id.

## plugin.json

```json
{
	"id": "hello",
	"name": "Hello",
	"version": "1.0.0",
	"api": 5,
	"main": "main.js",
	"program": "papier",
	"commands": [{ "id": "greet", "label": "Say hello", "tags": ["welcome"] }],
	"views": [{ "id": "main", "title": "Hello", "place": "internal" }],
	"settings": [{ "id": "name", "title": "Name", "kind": "string", "default": "world" }],
	"permissions": ["clipboard.write"]
}
```

- `id`: lower case letters, digits, `_` and `-`. It is also the folder's name.
- `api`: the level the plugin was written for. A program refuses a level it does not give. Write the lowest level
  that has every call you use: the reference names the level of each call.
- `main`: the entry file (`main.js` when absent).
- `program`: the program the plugin is for. Leave it out for a plugin of any program, and for gt-runtime.
- `commands`: `id`, `label`, and optionally `group`, `icon`, `tags`.
- `views`: `id`, `title`, `place` (`internal`, `dialog`, `panel` or `window`). The person moves it from there.
- `settings`: `id`, `title`, `description`, `kind` (`bool`, `int`, `float`, `string`), `default`, and optionally `min`
  and `max`, or `choices` for a string. A default out of its bounds or its choices refuses the manifest.
- `permissions`: see "Permissions".

The contributions are data. The program reads them without running any JavaScript. The plugin's code starts at its
first use: a command chosen, a view shown.

## The levels

A level only adds calls. Each call in `references/plugin-api.md` says the level that added it:

- level 1: `commands.on`, `toast.show`;
- level 2: views (`views.register`, `views.update`);
- level 3: `settings.get`, `settings.onChange`;
- level 4: `files`, `http`, `clipboard`, and the permissions;
- level 5: the lazy list node (`kind: "list"`).

## activate, commands and toasts

```js
import { commands, toast } from "gt";

export function activate(context) {
	// context: { id, name, version, api }
	commands.on("greet", () => toast.show("Hello from " + context.name, { kind: "good" }));
}
```

- Register every handler in `activate`. A command whose handler is not registered does nothing.
- A handler can return a promise. The command stays "running" until it settles.
- An exception that nothing catches goes to the log and shows one toast. The plugin goes on.

## Views and display lists

```js
import { views } from "gt";

let count = 0;
export function activate() {
	views.register("main", () => ({ kind: "column", children: [
		{ kind: "heading", text: "Counter" },
		{ kind: "text", key: "count", text: `Count: ${count}` },
		{ kind: "button", key: "add", label: "Add", intent: "primary", onClick: () => { count += 1; } },
		count > 10 && { kind: "text", key: "many", weak: true, text: "That is a lot." },
	] }));
}
```

- The render takes nothing and returns a tree of nodes. The nodes are in `references/gt.d.ts` (`Node`).
- The program writes the tree as a display list and replays it at each frame. It runs no JavaScript per frame. So a
  render runs only after a handler of the view, or when you call `views.update(id)`.
- Call `views.update(id)` after a change that no handler of the view made: a command, a promise that settled.
- A child that is `null`, `undefined` or `false` is skipped. Write `cond && node`.
- A node's `key` is unique in the view. A node without a key is known by its place. Give a key to every node whose
  place can change (rows of an array), or its state moves to another node.
- The same key twice drops the second node and its children. The log says so.
- A field's text, a check box's `checked` and a switch's `on` belong to the program. A `value` you give is shown,
  unless the person typed since the change you last heard of. This keeps a slow plugin from erasing key presses.
- The program adds the gaps between nodes. Add a `space` node only for more room, or `size: "fill"` to push the rest
  of a row to its end.

## Settings

```js
import { settings, views } from "gt";

export function activate() {
	settings.onChange((id, value) => { /* the views render again after this */ });
	views.register("main", () => ({ kind: "text", text: `Hello, ${settings.get("name")}` }));
}
```

`settings.get` answers at once from the plugin's copy. The person changes the value in the program's settings.

## Lazy lists

A `list` node shows `count` rows (1 000 000 at most). The program asks only for the rows in view and a margin, as
the person scrolls. A list of a million rows costs what its screen shows.

```js
let items = [], version = 0;
views.register("main", () => ({ kind: "list", key: "items", count: items.length, version, rowHeight: 2,
	row: (i) => ({ kind: "row", children: [
		{ kind: "text", text: items[i].name },
		{ kind: "button", key: "open", label: "Open", onClick: () => open(items[i]) },
	] }),
}));
```

- `row(i)` returns the node of row `i`. A row not answered yet shows a placeholder.
- Increment `version` when what the rows show changes. With the same version, the program keeps the rows it has.
- A key in a row is that row's: `key: "open"` in each row is correct.
- `rowHeight` is in lines of text. `visibleRows` is the list's height in rows (10 when absent).

## Permissions

A plugin reaches only its own data folder without a permission. The words of `permissions`:

| Word | What it allows |
|---|---|
| `files` | `files.pick`, and the files and folders the person picks |
| `folder:documents`, `folder:downloads` | paths `~documents/...` and `~downloads/...` |
| `clipboard.read`, `clipboard.write` | `clipboard.read()`, `clipboard.write(text)` |
| `net:<origin>` | `http.fetch` to that origin (`"net:https://api.example.com"`) |
| `net:*` | any public address, never the machine's own nor the local network |

- A plugin that asks for permissions is off until the person turns it on. The program shows a dialog with each
  permission in words. gt-runtime shows it at the first start.
- A new version that asks for more is off again until the person allows the new set. Ask for the least you need.
- A call without its grant rejects with `PermissionError`. A file's failure is a `FileError`, a request's a
  `NetworkError`. Catch them and show the person what to do.
- A relative path is in the plugin's data folder, kept when the code is replaced.
- The program does the work, never the plugin's process: each call is a request that the program checks and answers.
  Every call that waits returns a promise. No synchronous file or network call exists.

```js
import { files, http } from "gt";

await files.write("notes/today.txt", "...");                     // its own data folder
const res = await http.fetch("https://api.example.com/v1/items"); // { status, url, text }
const items = JSON.parse(res.text);
```

## Running it

```
gt-runtime path/to/folder          a folder with its plugin.json
gt-runtime path/to/main.js         a lone file: its id the file's name, one view "main", no permission
```

- The first view fills the window. The commands are in the palette (Ctrl+K). The settings (Ctrl+,) hold the plugin's
  settings and the Plugins page.
- Get gt-runtime from a release (`gt-runtime-windows-x64.zip`, with demos in its `js` folder). From a checkout of the
  toolkit, `odin run tools/tk -- build gt-runtime` builds it into `build/`.
- In a program, put the folder in its plugins folder, turn the plugin on in the Plugins page, then use "Reload plugins"
  after each change.

## The log

A plugin's log is `<state>/<program>/plugins/<id>.log`. For gt-runtime:

- Linux: `~/.local/state/gt-runtime/plugins/<id>.log`;
- Windows: `%LOCALAPPDATA%\gt-runtime\state\plugins\<id>.log`.

The log holds the uncaught exceptions, the keys given twice and the nodes dropped. Read it after each run: a view that
shows less than expected usually has a line there.

## Testing

- Run the plugin in gt-runtime and use each command and each control once.
- Keep the logic in plain functions in a module of the folder (`./lib/...`), apart from the render. Then a render is
  a function of the state, and you can check the state by reading the view.
- A program's own tests drive plugins headless with `gt:testkit/session` (`tests/plugins` in the toolkit). That is
  the program's work, in Odin, not the plugin's.

## Pitfalls

- **`~` in a key is refused.** The program keys a row of a list as `<list>~<row>`. Also `#` and a leading `/` are
  refused: they are the toolkit's id syntax.
- **No list inside a row of a list.** Each outer row would ask for rows of its own. The node is dropped and logged.
- **Row handlers are the row's.** An `onClick` in `row(i)` closes over `i`. It runs for that row only, until the
  program lets the row go. Do not keep a row's handler elsewhere.
- **The bound and Not responding.** A handler that runs past the bound (2 s by default) makes the plugin
  `Not_Responding`. Its views say so, with Stop. Never loop or compute long in a handler: split the work, or await.
  The time of a promise does not count; only the time without a turn of the plugin's queue does.
- **The clipboard is read only during a person's act.** `clipboard.read` and `files.pick` work in a command or a
  click in the view. In a promise's continuation the act is over, and the call rejects. Call them first in the handler.
- **Paths that escape are refused.** `..` and links are refused everywhere, also inside the data folder.
- **One process per plugin.** Each plugin runs in a process of its own. Two plugins share nothing, and a module's
  variables are lost at a reload or a Stop. Keep what must last in the data folder with `files.write`.
- **No render per frame.** The view changes only after a handler of the view or `views.update(id)`. The module `gt`
  has no timer: do not write an animation or a clock in a plugin.
- **Memory.** Past its budget (64 MB by default) the plugin is `Failed`. Use a lazy list for large data, not a
  column of a thousand rows.
