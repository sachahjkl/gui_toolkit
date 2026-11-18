# Plugins and gt-runtime

A plugin is a folder of JavaScript that a toolkit program runs: its commands go in the command palette, its settings
in the settings, its views in the window. `gt-runtime` runs one plugin as an application of its own: the window, the
theme, the palette, the settings and the toasts are the toolkit's, and the application brings only its JavaScript.

Every call and every node of a view is in the [API explorer](https://gt.sacha.house/plugins/api/). Its types are in
[gt.d.ts](../plugin-api/gt.d.ts), for an editor's completion. How a program in Odin turns plugins on is in
[plugins.md](plugins.md).

A coding agent writes plugins with the skill `gt-plugin`: [skills.md](skills.md) says how to install it.

gt-runtime gives only the module `"gt"`. A program may give its plugins a module of its own, `"app"` (opencode
native's sessions, say), which its own docs list; gt-runtime has none, so a plugin that imports `"app"` fails at its
start there, and one whose manifest says `"app": n` is refused.

## Get gt-runtime

Download `gt-runtime-windows-x64.zip` from the [latest release](https://github.com/sachahjkl/gui_toolkit/releases/latest)
and unzip it. It holds `gt-runtime.exe` and the JavaScript demos in its `js` folder:

```
gt-runtime js\counter\main.js
gt-runtime js\todo
```

On Linux, or from a checkout, `odin run tools/tk -- build gt-runtime` builds it into `build/`.

## A first plugin

A lone `main.js` is a plugin. Its manifest is implied: its id is the file's name, it has one view `main`, and it asks
for no permission.

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

Run it with `gt-runtime path/to/main.js`. A click is a message to the plugin: its handler runs, then the view renders
again. The JavaScript runs on a thread of its own, so a slow handler never stops the window.

## The manifest

A folder with a `plugin.json` is a plugin with its own name, commands, views and settings. Run it with
`gt-runtime path/to/folder`.

```json
{
	"id": "hello",
	"name": "Hello",
	"version": "1.0.0",
	"api": 3,
	"main": "main.js",
	"views": [{ "id": "main", "title": "Hello" }],
	"commands": [{ "id": "greet", "label": "Say hello" }],
	"settings": [{ "id": "name", "title": "Name", "kind": "string", "default": "world" }]
}
```

- `id`: lower case letters, digits, `_` and `-`.
- `api`: the level of the API the plugin was written for. The [explorer's levels](https://gt.sacha.house/plugins/api/#levels)
  say what each level added.
- `main`: the entry file. It exports `activate(context)`.
- `views`, `commands`, `settings`: what the plugin adds. [plugins.md](plugins.md) lists their fields.

A plugin imports `"gt"` and its own files (`"./lib/words.js"`), nothing else.

## The demos

### counter

A lone file: `gt-runtime js\counter\main.js`.

```js
// A counter, the smallest application gt-runtime runs: `gt-runtime examples/js/counter/main.js`. A lone file: its
// manifest is implied (its name, one view "main").
import { views } from "gt";

let count = 0;

export function activate() {
	views.register("main", () => ({
		kind: "column",
		children: [
			{ kind: "heading", text: "Counter" },
			{ kind: "text", key: "count", text: `The count is ${count}.` },
			{
				kind: "row",
				children: [
					{ kind: "button", key: "less", label: "−1", onClick: () => { count -= 1; } },
					{ kind: "button", key: "more", label: "+1", intent: "primary", onClick: () => { count += 1; } },
					{ kind: "space", size: "fill" },
					{ kind: "button", key: "reset", label: "Reset", disabled: count === 0, onClick: () => { count = 0; } },
				],
			},
		],
	}));
}
```

### todo

A folder with its manifest and two commands in the palette (Ctrl+K): `gt-runtime js\todo`.

`plugin.json`:

```json
{
	"id": "todo",
	"name": "Todo",
	"version": "1.0.0",
	"api": 2,
	"main": "main.js",
	"views": [{ "id": "main", "title": "Todo", "place": "internal" }],
	"commands": [
		{ "id": "clear-done", "label": "Clear the tasks done", "tags": ["remove", "completed"] },
		{ "id": "all-done", "label": "Mark every task done", "tags": ["complete"] }
	]
}
```

`main.js`:

```js
// A todo list run by gt-runtime: `gt-runtime examples/js/todo`. Its view is the toolkit's widgets, built from what
// render returns; its two commands are in the palette (Ctrl+K). The tasks live as long as the run (no file: the
// capabilities slice gives a plugin its data folder).
import { commands, toast, views } from "gt";

let tasks = [
	{ id: 1, title: "Read the plugin API", done: true },
	{ id: 2, title: "Write a view in JavaScript", done: false },
];
let next = 3;
let draft = "";

function add() {
	const title = draft.trim();
	if (title === "") return;
	tasks.push({ id: next++, title, done: false });
	draft = "";
}

function render() {
	const left = tasks.filter((t) => !t.done).length;
	return {
		kind: "column",
		children: [
			{ kind: "heading", text: "Tasks" },
			{ kind: "text", key: "left", weak: true, text: left === 1 ? "1 task left" : `${left} tasks left` },
			{
				kind: "row",
				children: [
					{ kind: "field", key: "draft", value: draft, placeholder: "What needs doing?", onChange: (v) => { draft = v; }, onSubmit: add },
					{ kind: "button", key: "add", label: "Add", intent: "primary", disabled: draft.trim() === "", onClick: add },
				],
			},
			{ kind: "separator" },
			...tasks.map((t) => ({
				kind: "row",
				key: `task-${t.id}`,
				children: [
					{ kind: "check", key: `done-${t.id}`, label: t.title, checked: t.done, onChange: (on) => { t.done = on; } },
					{ kind: "space", size: "fill" },
					{ kind: "button", key: `remove-${t.id}`, label: "Remove", intent: "danger", onClick: () => { tasks = tasks.filter((o) => o !== t); } },
				],
			})),
			tasks.length === 0 && { kind: "text", key: "empty", weak: true, text: "Nothing here yet." },
		],
	};
}

export function activate() {
	views.register("main", render);
	commands.on("clear-done", () => {
		const before = tasks.length;
		tasks = tasks.filter((t) => !t.done);
		views.update("main");
		toast.show(`${before - tasks.length} removed`, { kind: "good" });
	});
	commands.on("all-done", () => {
		for (const t of tasks) t.done = true;
		views.update("main");
	});
}
```

The field's `value` and the check box's `checked` are state: the host keeps what the person typed or ticked until the
plugin has heard of it, so a slow handler never erases a key press.
