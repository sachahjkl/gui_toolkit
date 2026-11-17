# The plugin API

Made by `odin run tools/tk -- plugin_api` from `src/plugin_api/api.odin`: do not edit. This toolkit gives level 3 of the API and accepts plugins written for levels 1 to 3. How a program turns plugins on: [plugins.md](plugins.md).

A plugin imports the API as an ES module, and its entry file exports `activate(context)`:

```js
import { commands, toast } from "gt";

export function activate(context) {
	commands.on("hello", () => toast.show("Hello from " + context.name));
}
```

The types are in `plugin-api/gt.d.ts`; each level's are in `plugin-api/level-<n>.d.ts`.

## commands

### `commands.on(id, handler)`

Registers the handler of one of the manifest's commands: choosing the command in the palette calls it. A second call for the same command replaces the handler.

Level 1. Permission: none.

| Argument | Type | |
|---|---|---|
| `id` | `string` | The command's id, as the manifest's `commands` declares it. |
| `handler` | `() => void | Promise<void>` | Called with no argument when the command is chosen. It may return a promise. |

## toast

### `toast.show(text, options?)`

Shows a message to the person: a toast of the window, or the system's notification when the program says its messages there.

Level 1. Permission: none.

| Argument | Type | |
|---|---|---|
| `text` | `string` | What it says. |
| `options` | `Toast_Options`, optional |  |

## views

### `views.register(id, render)`

Registers the render of one of the manifest's views. A second call for the same view replaces it.

Level 2. Permission: none.

| Argument | Type | |
|---|---|---|
| `id` | `string` | The view's id, as the manifest's `views` declares it. |
| `render` | `() => Node` |  |

### `views.update(id)`

Asks for the view's render again, after the current handler: the plugin's state changed outside a handler of the view (a command, a promise that settled).

Level 2. Permission: none.

| Argument | Type | |
|---|---|---|
| `id` | `string` | The view's id. |

## settings

### `settings.get(id)`

The value of one of the manifest's settings: the person's, else its default. A boolean, a number or a string, as the setting's kind says.

Level 3. Permission: none.

| Argument | Type | |
|---|---|---|
| `id` | `string` | The setting's id, as the manifest's `settings` declares it. |

### `settings.onChange(handler)`

Registers a function called after each change of one of the plugin's settings, in the settings or their file. The views are rendered again after it.

Level 3. Permission: none.

| Argument | Type | |
|---|---|---|
| `handler` | `(id: string, value: string | number | boolean) => void | Promise<void>` |  |

## Nodes

A view's render returns a tree of nodes: plain objects, each with its `kind`, an optional `key` (unique in the view; a node without one is known by its place), and the fields of its kind. A container's `children` is an array; `null`, `undefined` and `false` in it are skipped.

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

### `text`

A paragraph of text; it wraps in a column.

Level 2.

| Field | Type | |
|---|---|---|
| `text` | `string` |  |
| `weak` | `boolean`, optional | Drawn in the weak colour. |

### `heading`

A title of a part of the view.

Level 2.

| Field | Type | |
|---|---|---|
| `text` | `string` |  |

### `button`

A button.

Level 2.

| Field | Type | |
|---|---|---|
| `label` | `string` |  |
| `intent` | `Button_Intent`, optional |  |
| `disabled` | `boolean`, optional |  |
| `onClick` | `() => void | Promise<void>`, optional | Called when it is pressed. |

### `row`

Its children side by side. It has children.

Level 2.

### `column`

Its children one under the other. It has children.

Level 2.

### `card`

A titled panel around its children, as wide as the view. It has children.

Level 2.

| Field | Type | |
|---|---|---|
| `title` | `string`, optional |  |

### `space`

Room between two nodes ("small" when absent).

Level 2.

| Field | Type | |
|---|---|---|
| `size` | `Space_Size`, optional |  |

### `field`

A line of text the person types. The host keeps what is typed: a value the plugin gives is shown unless the person typed since the plugin last heard of it. Without a value, the field keeps its own text.

Level 2.

| Field | Type | |
|---|---|---|
| `value` | `string`, optional |  |
| `placeholder` | `string`, optional |  |
| `onChange` | `(value: string) => void | Promise<void>`, optional | Called with the text at each change. |
| `onSubmit` | `(value: string) => void | Promise<void>`, optional | Called with the text when Enter is pressed. |

### `check`

A check box and its words.

Level 2.

| Field | Type | |
|---|---|---|
| `label` | `string` |  |
| `checked` | `boolean`, optional |  |
| `onChange` | `(value: boolean) => void | Promise<void>`, optional | Called with its new state when the person changes it. |

### `switch`

A switch and its words.

Level 2.

| Field | Type | |
|---|---|---|
| `label` | `string` |  |
| `on` | `boolean`, optional |  |
| `onChange` | `(value: boolean) => void | Promise<void>`, optional | Called with its new state when the person changes it. |

### `separator`

A line across the view.

Level 2.

## The explorer's file

`plugin-api/api.json` describes the same API for the site's explorer, which reads nothing else. Its shape:

- `level`, `oldest`: the level this toolkit gives and the oldest it accepts.
- `modules`: each with its `name` and its `calls`; a call has `name`, `doc`, `level`, `capability` (`"None"`: no permission), `result` and `arguments`.
- `types`: the objects and enums the calls and nodes name; an object has `fields`, an enum `values`.
- `nodes`: each kind of node of a view, with `name` (its `kind` in JavaScript), `type`, `doc`, `level`, `container` and `fields`.
- A field (of an argument list, an object or a node) has `name`, `type` (as TypeScript writes it), `optional`, `state` and `doc`. A `state` field is kept by the host (a field's text, a box's state): what the person changed stays until the plugin has heard of it.

The site's [API explorer](https://gt.sacha.house/plugins/api/) is made from this file by `tk site_build`, which fails when the file is missing or malformed.

A key is only added: a site reading this file keeps working when a level adds calls, types, nodes or keys.

## Types

### `Toast_Kind`

How a toast looks.

One of `"info"`, `"good"`, `"warn"`, `"bad"`.

### `Toast_Options`

A toast's options.

| Field | Type | |
|---|---|---|
| `kind` | `Toast_Kind`, optional | Its look ("info" when absent). |
| `title` | `string`, optional | A line in bold above the text. |

### `Activate_Context`

What the entry file's activate(context) is given (gt:plugins makes it: plugins/runtime.odin, context_object).

| Field | Type | |
|---|---|---|
| `id` | `string` | The plugin's id, as plugin.json says it. |
| `name` | `string` | Its name. |
| `version` | `string` | Its version ("" when plugin.json says none). |
| `api` | `number` | The level of the API this program gives. |

### `Button_Intent`

What a button's colour says.

One of `"neutral"`, `"primary"`, `"success"`, `"warning"`, `"danger"`.

### `Space_Size`

A step of the toolkit's spacing scale; `fill` takes the room left in a row.

One of `"small"`, `"medium"`, `"large"`, `"fill"`.
